# Multi-Master Kubernetes Cluster on AWS EC2 — Complete Guide From Scratch

**Architecture**

```
┌─────────────────────────┐
                    │  haproxy-lb (t3.micro)   │
                    │  Static private IP        │
                    │  :6443 → CP1, CP2, CP3    │
                    └────────────┬─────────────┘
                                 │
        ┌────────────────────────┼────────────────────────┐
        │                        │                        │
  control-plane-1          control-plane-2          control-plane-3
        │                        │                        │
        └──────────── stacked etcd, 3 members ─────────────┘

              worker-1, worker-2 join via haproxy-lb
```

6 EC2 instances total: 3 control-plane, 2 workers, 1 HAProxy LB. We use a plain EC2 instance running HAProxy instead of an AWS NLB 
— this avoids the NLB instance-target hairpin/loopback limitation (a documented AWS behavior where a target cannot reliably reach 
itself through its own load balancer), which is what blocked the earlier NLB attempts.

**Run every step in a persistent terminal session (tmux/screen) per node** 

— lost exported variables across reconnects cause a lot of "nothing works" confusion.

## Step 1: VPC and Security Groups

**Creating VPC, Subnet, Internet Gateway & Route Table**

```
# Create VPC
aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --region us-east-1 \
  --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=kubeadm-vpc}]'

# Export VPC ID
export VPC_ID=<VPC ID>

# Enable DNS Support
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-support '{"Value": true}' \
  --region us-east-1

aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames '{"Value": true}' \
  --region us-east-1

# Create Subnet
aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone us-east-1a \
  --region us-east-1 \
  --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=kubeadm-public-subnet}]'

export SUBNET_ID=<subnet ID>

# Create Internet Gateway
aws ec2 create-internet-gateway \
  --region us-east-1 \
  --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=kubeadm-igw}]'

export IGW_ID=<IGW ID>

# Attach IGW to VPC
aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID \
  --region us-east-1

# Create Route Table
aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --region us-east-1 \
  --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=kubeadm-public-rt}]'
  
export RT_ID=<route table ID>

# Create Route
aws ec2 create-route \
  --route-table-id $RT_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region us-east-1

# Associate Route Table
aws ec2 associate-route-table \
  --route-table-id $RT_ID \
  --subnet-id $SUBNET_ID \
  --region us-east-1
```

**Create Security Groups**

```
export VPC_ID=<your-vpc-id>
export SUBNET_ID=<your-subnet-id>
export KEY_NAME=<your-key-pair>
export MY_IP=<your-ip>/32

# Control-plane SG
aws ec2 create-security-group --group-name k8s-ha-cp-sg --description "HA control plane SG" --vpc-id $VPC_ID
export CP_SG_ID=<output-group-id>

# Worker SG
aws ec2 create-security-group --group-name k8s-ha-worker-sg --description "HA worker SG" --vpc-id $VPC_ID
export WORKER_SG_ID=<output-group-id>

# LB SG
aws ec2 create-security-group --group-name k8s-ha-lb-sg --description "HAProxy LB SG" --vpc-id $VPC_ID
export LB_SG_ID=<output-group-id>

# --- CP_SG_ID rules ---
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol all --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 6443 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 10250 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 5473 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 179 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol udp --port 4789 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 6443 --source-group $LB_SG_ID
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 22 --cidr $MY_IP/32
aws ec2 authorize-security-group-ingress --group-id $CP_SG_ID --protocol tcp --port 6443 --cidr $MY_IP/32

# --- WORKER_SG_ID rules ---
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol all --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 10250 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 10256 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 5473 --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 179 --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol udp --port 4789 --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 30000-32767 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol udp --port 30000-32767 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $WORKER_SG_ID --protocol tcp --port 22 --cidr $MY_IP/32

# --- LB_SG_ID rules ---
aws ec2 authorize-security-group-ingress --group-id $LB_SG_ID --protocol tcp --port 6443 --cidr $MY_IP/32
aws ec2 authorize-security-group-ingress --group-id $LB_SG_ID --protocol tcp --port 8404 --cidr $MY_IP/32
aws ec2 authorize-security-group-ingress --group-id $LB_SG_ID --protocol tcp --port 6443 --source-group $CP_SG_ID
aws ec2 authorize-security-group-ingress --group-id $LB_SG_ID --protocol tcp --port 6443 --source-group $WORKER_SG_ID
aws ec2 authorize-security-group-ingress --group-id $LB_SG_ID --protocol tcp --port 22 --cidr $MY_IP/32
```

## Step 2: Launch All 6 Instances

```
export AMI_ID=$(aws ssm get-parameters \
  --names /aws/service/canonical/ubuntu/server/26.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --region us-east-1 --query 'Parameters[0].Value' --output text)

for name in control-plane-1 control-plane-2 control-plane-3; do
  aws ec2 run-instances \
    --image-id $AMI_ID --instance-type m7i-flex.large --key-name $KEY_NAME \
    --security-group-ids $CP_SG_ID --subnet-id $SUBNET_ID --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":10,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]"
done

for name in worker-1 worker-2; do
  aws ec2 run-instances \
    --image-id $AMI_ID --instance-type c7i-flex.large --key-name $KEY_NAME \
    --security-group-ids $WORKER_SG_ID --subnet-id $SUBNET_ID --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":10,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]"
done

aws ec2 run-instances \
  --image-id $AMI_ID --instance-type t3.micro --key-name $KEY_NAME \
  --security-group-ids $LB_SG_ID --subnet-id $SUBNET_ID --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=haproxy-lb}]"

aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=control-plane-*,worker-*,haproxy-lb" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],InstanceId,PrivateIpAddress,PublicIpAddress]' \
  --output table
```

**Record all private/public IPs and instance IDs now.**

## Step 3: Hostnames

*On each node:*

```
sudo hostnamectl set-hostname control-plane-1   # control-plane-2 / control-plane-3 / worker-1 / worker-2 / haproxy-lb respectively
```

## Step 4: /etc/hosts

*On all 6 nodes, append (adjust 127.0.1.1 line to match each node's own hostname):*

```
127.0.0.1 localhost
127.0.1.1 <this-node-hostname>

<cp1-private-ip>  control-plane-1
<cp2-private-ip>  control-plane-2
<cp3-private-ip>  control-plane-3
<w1-private-ip>   worker-1
<w2-private-ip>   worker-2
<lb-private-ip>   k8s-lb
```

## Step 5: Common Setup — Run on control-plane-1/2/3, worker-1, worker-2 (NOT the LB)

```
# Swap off
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# containerd v1.7.28
curl -LO https://github.com/containerd/containerd/releases/download/v1.7.28/containerd-1.7.28-linux-amd64.tar.gz
sudo tar Cxzvf /usr/local containerd-1.7.28-linux-amd64.tar.gz
curl -LO https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
sudo mkdir -p /usr/local/lib/systemd/system/
sudo mv containerd.service /usr/local/lib/systemd/system/
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo sed -i 's#sandbox_image = ".*"#sandbox_image = "registry.k8s.io/pause:3.10"#g' /etc/containerd/config.toml
sudo systemctl daemon-reload
sudo systemctl enable --now containerd

# runc v1.2.5
curl -LO https://github.com/opencontainers/runc/releases/download/v1.2.5/runc.amd64
sudo install -m 755 runc.amd64 /usr/local/sbin/runc

# CNI plugins v1.6.2
curl -LO https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.6.2.tgz

# kubeadm/kubelet/kubectl v1.33.1
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet=1.33.1-1.1 kubeadm=1.33.1-1.1 kubectl=1.33.1-1.1 --allow-change-held-packages
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet

# crictl
sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
```

## Step 6: HAProxy — on haproxy-lb Only

```
sudo apt-get update
sudo apt-get install -y haproxy

sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'EOF'
global
    log /dev/log local0
    maxconn 2000

defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s

frontend kubernetes-frontend
    bind *:6443
    mode tcp
    default_backend kubernetes-backend

backend kubernetes-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server control-plane-1 control-plane-1:6443 check fall 3 rise 2
    server control-plane-2 control-plane-2:6443 check fall 3 rise 2
    server control-plane-3 control-plane-3:6443 check fall 3 rise 2

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /
    stats refresh 10s
EOF

sudo systemctl restart haproxy
sudo systemctl enable haproxy
sudo systemctl status haproxy --no-pager | head -5
```

*CP2/CP3 backends will show DOWN until they join — expected.*

## Step 7: kubeadm init on control-plane-1

```
export CP1_PRIVATE_IP=$(hostname -I | awk '{print $1}')

sudo kubeadm init \
  --control-plane-endpoint="k8s-lb:6443" \
  --upload-certs \
  --apiserver-advertise-address=$CP1_PRIVATE_IP \
  --pod-network-cidr=192.168.0.0/16 \
  --node-name=control-plane-1 \
  --cri-socket=unix:///var/run/containerd/containerd.sock \
  --v=5 \
  2>&1 | sudo tee /root/kubeadm-init.log
```

*Save both printed join commands (control-plane join with --certificate-key, and worker join).*

```
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl get nodes
```

*Note: --upload-certs certificate-key expires in 2 hours — join CP2/CP3 before then, or regenerate via sudo kubeadm init phase upload-certs --upload-certs.*

## Step 8: Join control-plane-2 and control-plane-3

On each:

```
export CPN_PRIVATE_IP=$(hostname -I | awk '{print $1}')

sudo kubeadm join k8s-lb:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key> \
  --apiserver-advertise-address=$CPN_PRIVATE_IP \
  --node-name=control-plane-2   # control-plane-3 on the third node
```

*From control-plane-1: kubectl get nodes — all 3 should appear. HAProxy stats page (http://<lb-public-ip>:8404/) should now show all 3 backends UP.*

## Step 9: Install Calico — from control-plane-1

```
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/tigera-operator.yaml
curl https://raw.githubusercontent.com/projectcalico/calico/v3.30.2/manifests/custom-resources.yaml -O
kubectl apply -f custom-resources.yaml
kubectl get pods -A -w
# Ctrl+C once calico-system pods Running
```

## Step 10: Join Workers

On worker-1 and worker-2:

```
sudo kubeadm join k8s-lb:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name=worker-1   # worker-2 on the second
```

## Step 11: Post-Init Fixes

```
# From control-plane-1
kubectl patch ippool default-ipv4-ippool --type merge -p '{"spec":{"vxlanMode":"Always"}}'
kubectl rollout restart daemonset calico-node -n calico-system

# AWS console/CLI, on each of the 5 cluster instances (NOT the LB):
# Actions > Networking > Change source/destination check > Stop

# On all 5 cluster nodes (NOT the LB):
sudo ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
```

## Step 12: Full Verification

```
kubectl get nodes -o wide
# 3 control-plane + 2 worker, all Ready

sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key -w table

kubectl get lease -n kube-system kube-controller-manager -o yaml | grep holderIdentity
kubectl get lease -n kube-system kube-scheduler -o yaml | grep holderIdentity

kubectl create deployment nginx-test --image=nginx:alpine --replicas=4
kubectl expose deployment nginx-test --port=80 --type=NodePort
kubectl get pods -o wide
```

# Lab 4: kube-controller-manager Leader Election Failover

*Your baseline already shows something worth pausing on: all 3 control-plane nodes run a kube-controller-manager static pod, 
but only control-plane-1's copy is doing anything. The other two are idle standbys, waiting. This lab makes that failover 
mechanism visible and provable, not theoretical.*

## Mental Model: Why Leader Election Exists

```
kube-apiserver:
  All 3 instances are ACTIVE-ACTIVE simultaneously.
  Any of them can serve any request — that's what HAProxy is
  round-robining across right now. No leader needed here.

kube-controller-manager / kube-scheduler:
  Exactly ONE instance may be ACTIVE at a time — active-PASSIVE.
  Why: if 2 KCM instances both ran the ReplicaSet controller
  simultaneously, both could see "want 4, have 3" and BOTH create
  a pod — a race condition producing 5 pods instead of 4.
  Same problem for scheduler: 2 schedulers could both assign the
  same pod to two different nodes.

The fix: client-go's leaderelection library, backed by a
Lease object (coordination.k8s.io/v1) in kube-system:

  kube-controller-manager Lease fields:
    holderIdentity:      "control-plane-1_c63fc80f-..."
    leaseDurationSeconds: 15   (how long a lease is valid once claimed)
    renewTime:            <updated every ~2s while holder is healthy>
    acquireTime:          <when current holder first won leadership>

  While healthy, the leader renews (PATCHes) this Lease well
  before it expires. Standbys watch it and do nothing as long
  as renewTime keeps advancing. If renewTime stalls past
  leaseDurationSeconds, standbys race to acquire it — the first
  one whose write succeeds (etcd's compare-and-swap on
  resourceVersion prevents two winners) becomes the new leader.
```

*This is precisely the mechanism you're about to watch fail over live.*

## Stage A: Pre-Lab Verification

You already have the key baseline fact: control-plane-1 holds both leases. Let's get the full picture before breaking anything.

*On control-plane-1:*

```
# Full lease object — see every field, not just holderIdentity
kubectl get lease -n kube-system kube-controller-manager -o yaml

kubectl get lease -n kube-system kube-scheduler -o yaml

# Confirm all 3 nodes are ACTUALLY running the KCM static pod
kubectl get pods -n kube-system -o wide | grep controller-manager
kubectl get pods -n kube-system -o wide | grep scheduler
# All 3 should show Running — this proves the OTHER 2 aren't crashed,
# they're intentionally idle standbys

# Confirm reconciliation is currently working — scale a test
kubectl scale deployment nginx-test --replicas=5
kubectl get pods -o wide -w
# Ctrl+C once you see 5 Running
kubectl scale deployment nginx-test --replicas=4

# Backup the manifest we're about to break
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /root/kube-controller-manager.yaml.bak

# Note the exact renewTime right before the break — your T+0 reference
kubectl get lease -n kube-system kube-controller-manager \
  -o jsonpath='{.spec.renewTime}'
echo
date
```

## Stage B: Break — Kill the Active Leader

*SSH into control-plane-1 (the current holder) — this is the important part, killing the active leader specifically, not a random replica:*

```
# === ON CONTROL-PLANE-1 ===

sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /root/kcm-manifest-removed.yaml

echo "KCM leader killed at: $(date)"

# Confirm the container is actually gone
sudo crictl ps -a | grep controller-manager
```

## Stage C: Observe the Failover in Real Time

*From any control-plane node (kubectl works everywhere via HAProxy):*

```
# Watch the lease directly — this is the live failover happening
watch -n1 'kubectl get lease -n kube-system kube-controller-manager \
  -o custom-columns=HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime'
```

*Predict before watching: holderIdentity should stay control-plane-1_... for roughly 15-20 seconds after the kill 
(the last valid lease hasn't expired yet — standbys respect it even though the real process is dead), then flip 
to control-plane-2 or control-plane-3.*

**Once you see the flip, Ctrl+C and confirm:**

```
# Full lease detail after failover
kubectl get lease -n kube-system kube-controller-manager -o yaml | \
  grep -E "holderIdentity|acquireTime|renewTime"

# Compare acquireTime — this is a NEW leadership term, not a renewal
```

**Prove reconciliation actually continues — this is the real point of the lab, not just watching a field change:**

```
kubectl scale deployment nginx-test --replicas=6
kubectl get pods -o wide -w
# Ctrl+C once 6 are Running — proves the NEW leader's ReplicaSet
# controller is actively reconciling, not just holding an idle lease

kubectl scale deployment nginx-test --replicas=4
```

## Stage D: Diagnose — Find the Evidence Trail

```
# WHICH node won? Extract just the hostname from holderIdentity
kubectl get lease -n kube-system kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}'
echo
```

*SSH into whichever node won — confirm its logs show the actual election event:*

```
# === ON THE NEW LEADER NODE ===
KCM_ID=$(sudo crictl ps --name kube-controller-manager -q)
sudo crictl logs $KCM_ID 2>&1 | grep -i "leader" | tail -10
# Expected line: "successfully acquired lease kube-system/kube-controller-manager"
```

*SSH into the third node (never was leader, still a standby) — confirm it's still patiently waiting:*

```
# === ON THE REMAINING STANDBY ===
KCM_ID=$(sudo crictl ps --name kube-controller-manager -q)
sudo crictl logs $KCM_ID 2>&1 | grep -i "leader" | tail -5
# Expected: no "acquired" message — it's still watching, still idle
```

*Back on control-plane-1, confirm what actually happened there:*

```
sudo crictl ps -a | grep controller-manager
# Shows nothing, or Exited — kubelet has nothing to restart since
# the manifest itself is gone (this is voluntary removal, not a crash)
```

## Stage E: Recovery — and the Insight Most People Get Wrong

```
# === ON CONTROL-PLANE-1 ===
sudo cp /root/kube-controller-manager.yaml.bak \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

echo "KCM restored on control-plane-1 at: $(date)"

sudo crictl ps | grep controller-manager
# Running again — but watch what it does next
```

*From any control-plane node:*

```
watch -n1 'kubectl get lease -n kube-system kube-controller-manager \
  -o custom-columns=HOLDER:.spec.holderIdentity'
```

**Prediction check:** 

does leadership move back to control-plane-1 now that it's healthy again?

**No.** 

Leader election has no concept of a "preferred" or "original" leader. 
Whoever currently holds a valid, actively-renewed lease keeps it indefinitely — 
control-plane-1 rejoins purely as a third standby. This is deliberate: preferring 
a specific node would mean unnecessary leadership churn (and a brief reconciliation gap) 
every time a node that happens to be labeled "primary" recovers from any blip. Confirm it:

```
kubectl get lease -n kube-system kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}'
echo
# Still shows whichever node won in Stage C — NOT control-plane-1
```

## Stage F: Bonus — Negative Control (Kill a Non-Leader)

This is the test that proves it's specifically about the leader, not KCM-in-general. Pick whichever node is currently a standby (not the current holder):

```
# === ON A STANDBY NODE (not the current leader) ===
sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /root/kcm-standby-removed.yaml
```

*From any control-plane node:*

```
kubectl get lease -n kube-system kube-controller-manager \
  -o jsonpath='{.spec.holderIdentity}'
echo
# UNCHANGED — the active leader never noticed, nothing failed over
```

```
kubectl scale deployment nginx-test --replicas=5
kubectl get pods -o wide -w
# Still reconciles fine — zero impact
kubectl scale deployment nginx-test --replicas=4
```

*Restore it:*

```
# === ON THAT SAME STANDBY NODE ===
sudo cp /root/kcm-standby-removed.yaml \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
```

## Stage G: Full Verification

```
# All 3 KCM pods running again?
kubectl get pods -n kube-system -o wide | grep controller-manager

# Exactly one holder, lease actively renewing?
kubectl get lease -n kube-system kube-controller-manager \
  -o custom-columns=HOLDER:.spec.holderIdentity,RENEWED:.spec.renewTime

# Cluster fully healthy?
kubectl get nodes -o wide
kubectl get pods -o wide
curl -s http://localhost:$(kubectl get svc nginx-test -o jsonpath='{.spec.ports[0].nodePort}') | grep "<title>"
```

## Interview Debrief

**Q: kube-apiserver runs on all 3 control-plane nodes with no leader election. kube-controller-manager and kube-scheduler do use it. Why the difference?**

apiserver is stateless per-request — every instance reads/writes the same etcd, so serving the same request from any of 3 instances is safe and is exactly what makes HA possible. KCM and scheduler run continuous reconciliation loops that make independent decisions (create this pod, assign that node) — two instances acting simultaneously would race and produce duplicate or conflicting actions. Leader election makes only one instance ever active.

**Q: How does the Lease mechanism guarantee exactly one winner, never two?**

The Lease is a normal Kubernetes object stored in etcd. Acquiring it means successfully writing to it with a specific resourceVersion precondition — etcd's compare-and-swap semantics mean if two candidates race to write simultaneously, only one write can succeed against a given resourceVersion; the other is rejected and must retry against the new state. It's the same optimistic-concurrency mechanism that protects any Kubernetes object from concurrent-write races, just applied to a Lease specifically for this purpose.

**Q: You killed the active leader. How long until a new one takes over, and why not instant?**

Bounded by leaseDurationSeconds (15s default) plus the standby's retryPeriod polling interval (2s default) — so roughly 15-20 seconds in practice. This delay is intentional: a brief network blip that recovers in 3 seconds shouldn't trigger a full leadership transfer and reconciliation-state rebuild. Tuning it shorter buys faster failover at the cost of risking leadership thrashing under transient load; tuning it longer buys stability at the cost of longer reconciliation gaps during a genuine failure.

**Q: After the failed node comes back healthy, does it reclaim leadership?**

No — there's no preemption or "preferred leader" concept. Whoever holds a validly-renewed lease keeps it indefinitely, regardless of which node originally started as leader. The recovered node rejoins purely as a standby. This avoids unnecessary reconciliation-state disruption every time a previously-leader node blips and recovers.

**Q: What's actually lost during the ~15-20 second failover window?**

New reconciliation decisions pause — a Deployment scale-up you trigger during that window won't create pods until the new leader takes over and catches up (which it does immediately upon winning, reading current cluster state fresh). Pods already running are completely unaffected — kubelet manages those independently of KCM. kubectl get/describe/apply for non-controller-dependent resources still works fine, since that's apiserver + etcd, unrelated to KCM's leader state.













