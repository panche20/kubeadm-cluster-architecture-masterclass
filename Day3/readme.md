# Master Lab Guide: etcd Failure and Restore

**Mental Model: What etcd Failure Actually Means**

```
Single etcd member goes down:

apiserver ──────────────> etcd (DEAD)
   │                         ✗ no reads
   │                         ✗ no writes
   │
   ├── kubectl get pods      ✗ FAILS (apiserver can't serve)
   ├── new pod scheduling    ✗ FAILS (scheduler can't write)
   ├── controller reconcile  ✗ FAILS (KCM can't read/write)
   │
   └── EXISTING pods         ✅ KEEP RUNNING
       (kubelet is autonomous — doesn't need apiserver for already-running pods)
```

*This is the single most important thing to understand: the data plane survives the control plane going blind. 
Your nginx pods will still serve traffic after etcd dies. 
Only the ability to observe or change cluster state is lost.*

**Step A: Check your Running ETCD Version**

Run the following command on your master node to inspect the ETCD container image:

```
kubectl get pod -n kube-system -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'
```

*Expected Output Example:*

```
registry.k8s.io/etcd:3.5.21-0
```

**Step B: Decide the Utility Version**
You should download the etcd release binary that matches the major and minor version of your output (and ideally the exact patch version).

```
If your cluster runs 3.5.15, set ETCD_VER=v3.5.15.
If your cluster runs 3.6.2, set ETCD_VER=v3.6.2.
```

*⚠️ Important Architecture Note for etcdutl:*

```
The separate etcdutl binary was introduced in ETCD v3.6.
If your version is v3.6+: You will have two distinct binaries (etcdctl and etcdutl).
If your version is v3.5 or older: etcdutl does not exist as a separate file. Instead, etcdctl handles everything (including restores).
```

**Install etcdctl for v3.5.21**

Run this on your master node to download and install the exact matching version:

```
# Set version to match your pod
ETCD_VER=v3.5.21

# Download and extract the archive
curl -LO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz

# Move etcdctl to your system binary path
sudo mv etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/

# Verify the version
etcdctl version

# Clean up installer files
rm -rf etcd-${ETCD_VER}-linux-amd64*
```

**Verify ETCD Pod Health**

Before taking a snapshot, let's verify that the ETCD pod is healthy and running.

```
kubectl get pods -n kube-system -l component=etcd
```

What to look for: Ensure the status says *Running* and the restarts count is stable.


## Phase 1: Pre-Lab Discovery & Baseline (Do Not Skip)

Before breaking anything, you must discover the exact configuration parameters kubeadm used for your unique cluster.

**1. Extract the Hidden Cluster Variables**

### Verify health of ETCD:

```
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Run this command to find your exact etcd member name, host IP, and data directory:

```
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "\--name=|\--initial-cluster=|\--data-dir="
```

**Critical Info to Write Down:**

```
- My Node/Member Name (--name=) is: ___________ (e.g., master or ip-172-31-38-12)
- My Initial Cluster String (--initial-cluster=) is: ___________
- My Host IP address inside that string is: ___________
```

**2. Capture the NodePort & Verify Application Health**

```
export NODEPORT=$(kubectl get svc nginx-test -o jsonpath='{.spec.ports[0].nodePort}')
echo "Your NodePort is: $NODEPORT"

# Test that the app responds normally
curl -s http://localhost:$NODEPORT | grep "<title>"
```

## Phase 2: Take a Backup & Break the Cluster

**1. Save a Valid Snapshot**

```
sudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

*Verify that the backup is healthy and readable:*

```
sudo ETCDCTL_API=3 etcdctl snapshot status /root/etcd-backup-$(date +%F).db -w table
```

**2. Freeze the Master Management Layer**

```
# Stop the kubelet daemon
sudo systemctl stop kubelet

# Force stop the underlying containers so they instantly drop their file locks
sudo crictl stop $(sudo crictl ps -q --name etcd) 2>/dev/null
sudo crictl stop $(sudo crictl ps -q --name kube-apiserver) 2>/dev/null
```

## Phase 3: Observe the Blast Radius

*Wait 10 seconds, then observe what happens when the control plane loses its database:*

```
- kubectl get nodes → Hangs and times out (API Server is blind).
- sudo crictl ps | grep etcd → Returns empty (Container is terminated).
- curl -s http://localhost:$NODEPORT → Still succeeds! (Existing data plane pods stay running autonomously).
```

## Phase 4: The Atomic Restoration Procedure

**Step 1: Clean the Directory and Run the Restore**

Wipe the old directory completely. Then, use the exact Name and IP variables you discovered in Phase 1 to run the restore:

```
# 1. Corrected step: Remove the directory entirely so etcdctl can re-provision it cleanly
sudo rm -rf /var/lib/etcd

# 2. Restore using your specific cluster variables
sudo ETCDCTL_API=3 etcdctl snapshot restore /root/etcd-backup-$(date +%F).db \
  --data-dir=/var/lib/etcd \
  --name=<YOUR_DISCOVERED_NAME> \
  --initial-cluster=<YOUR_DISCOVERED_CLUSTER_STRING> \
  --initial-advertise-peer-urls=https://<YOUR_DISCOVERED_IP>:2380
```

**Step 3: Set Strict Permissions**

If etcd cannot read the restored directories due to wrong ownership permissions, it will start up completely blank. Fix this explicitly:

```
sudo chown -R root:root /var/lib/etcd
```

**Step 4: Verify the Restored Data Keys**

Before bringing anything back online, verify that the data keys actually exist inside the restored directory:

```
sudo ls -lh /var/lib/etcd/member/snap/db
```

*(The file size must be greater than 0 KB).*

## Phase 5: Sequential Cluster Startup

**1. Unfreeze the Master Layer**

Since we didn't touch or move the manifest files, all you have to do is turn the Kubelet service back on. It will immediately pick up the restored database state:

```
sudo systemctl start kubelet
sudo systemctl restart kubelet
```

*(Press Ctrl+C to exit the watch once it runs).*

**2. Verify Database Internal Health**

Run a quick health check to ensure the keys are accessible:

```
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

Must Return: ... healthy: successfully committed proposal

## Phase 6: Final Verification

Run these commands in order to confirm full cluster restoration:

```
# Check cluster access and nodes
kubectl get nodes

# Check system health
kubectl get pods -n kube-system

# Run a write test to prove database isn't read-only
kubectl run recovery-test --image=nginx:alpine
kubectl delete pod recovery-test
```

## Phase 7 : Force Networking Plane Reconciliation

Back on the master node, once kubectl get nodes returns a clean Ready status, execute a rolling restart of your cluster's proxy engine and internal DNS routers to align the data plane:

```
# 1. Refresh Kube-Proxy routing tables
kubectl rollout restart daemonset kube-proxy -n kube-system

# 2. Refresh internal CoreDNS routing entries
kubectl rollout restart deployment coredns -n kube-system

# 3. Refresh CNI Engine (Uncomment the one your cluster runs)
# For Calico:
# kubectl rollout restart daemonset calico-node -n kube-system
# For Cilium:
# kubectl rollout restart daemonset cilium -n kube-system
```

## 💡 Pro-Tip Checklist :

- The Name Mismatch Trap: The --name and the prefix string inside --initial-cluster must be completely identical.

- The Blind Fresh Database Trap: If you pass values to snapshot restore that mismatch the parameters in your etcd.yaml, etcd will ignore your backup completely       and create a blank database, giving you Forbidden RBAC errors. ALWAYS match your original configuration parameters exactly.

Given the depth here, want to turn this into a hands-on lab sequence next — deliberately breaking things on your existing HA cluster (kill etcd quorum, corrupt a cert, simulate a webhook lockout) so you build muscle memory for diagnosing each failure mode under pressure? --- yes we should do this. Please guide me step by stepArchitected comprehensive chaos engineering curriculum with safety protocols and interactive checkpointsArchitected comprehensive chaos engineering curriculum with safety protocols and interactive checkpointsGood. Chaos engineering principle: order labs by blast radius, smallest first, and always build a rollback path before you break anything. Since this is EC2 (not ephemeral), that gives you a luxury managed clusters don't — instance-level snapshots as a true undo button.
The Full Lab Sequence (your roadmap)
LabWhat you breakWhat it teaches0Nothing yet — safety netetcd backup + EBS snapshots before any chaos1etcd quorum (2 of 3 members)Quorum math, read/write degradation, recovery2apiserver TLS certCert chain diagnosis, renewal under pressure3Static pod manifest (bad flag)kubelet crashloop diagnosis without kubectl logs4Active KCM leaderLeader election failover via Lease object5Node network partitionNotReady timeline, taints, eviction throttling6Admission webhook lockoutfailurePolicy: Fail cluster-wide lockout + escape hatch7cgroup driver mismatchNode bootstrap failure, the #1 real-world outage cause8Full control-plane node lossNLB failover, etcd re-join, kubeadm join --control-plane9CoreDNS outageService discovery failure isolated from everything else
We'll do these one at a time — you execute, report what you see, then we diagnose together before moving on. That's where the muscle memory actually forms, not from reading commands.

Lab 0: Safety Net (do this before anything else)
etcd backup, from any control-plane node:
bashsudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

sudo ETCDCTL_API=3 etcdctl snapshot status /root/etcd-backup-$(date +%F).db -w table
EBS snapshots of all 3 control-plane root volumes (your true undo button — if a lab goes sideways you can restore the volume):
bashfor id in <master1-instance-id> <master2-instance-id> <master3-instance-id>; do
  vol=$(aws ec2 describe-instances --instance-ids $id \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
  aws ec2 create-snapshot --volume-id $vol --description "pre-chaos-lab-$id"
done
Document current healthy state so you have a known-good baseline to diff against:
bashkubectl get nodes -o wide > /root/baseline-nodes.txt
kubectl get pods -A -o wide > /root/baseline-pods.txt
kubeadm certs check-expiration > /root/baseline-certs.txt
sudo ETCDCTL_API=3 etcdctl endpoint status --cluster -w table \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
That last command shows you all 3 etcd members, who's leader, and their raft term/index — note which node is currently the leader, you'll need this for Lab 1.

Lab 1: etcd Quorum Loss
Stage A — lose 1 of 3 (cluster should survive, this proves HA actually works):
Predict first: with 3 members, quorum is 2. Losing 1 leaves 2 — still quorum. What do you expect kubectl get nodes to do?
Pick the etcd member that is not currently the leader (from your baseline output). On that node, stop its etcd static pod by moving the manifest out:
bashsudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
# kubelet will terminate the static pod within seconds
Now observe, from any other control-plane node:
bashkubectl get nodes                    # does this still work?
sudo ETCDCTL_API3=3 etcdctl endpoint health --cluster \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
Report back what you see, then we'll move to Stage B (killing a 2nd member to actually lose quorum) and walk through recovery together.
Run Lab 0 and Lab 1 Stage A now, and paste back what kubectl get nodes and the etcd health check show.Can we do this using Kubeadm cluster setup using 1 control plane node and 2 worker nodes or should we continue doing this using kind cluster?Weighed kubeadm versus kind tradeoffs across lab requirementsWeighed kubeadm versus kind tradeoffs across lab requirementsGreat question to clarify before spending money on EC2. Here's the honest trade-off so you make the right call.
The Core Problem with kind for These Labs
kind runs control-plane and workers as Docker containers, not real Linux nodes. This breaks the realism for exactly the things we're trying to learn:
What we're breakingkindkubeadm EC2etcd quorum (Lab 1)Partial — no real multi-node quorum✅ Real Raft, real quorum mathapiserver TLS cert (Lab 2)✅ Works✅ WorksStatic pod manifest (Lab 3)✅ Works✅ WorksKCM leader election (Lab 4)❌ Needs HA (3 CP nodes)✅ Only with HANode network partition (Lab 5)❌ Docker networking ≠ real iptables between nodes✅ Real EC2 networkWebhook lockout (Lab 6)✅ Works✅ Workscgroup driver mismatch (Lab 7)❌ No real systemd in kind✅ Real systemd + containerdFull CP node loss (Lab 8)❌ Needs HA✅ Only with HACoreDNS outage (Lab 9)✅ Works✅ Works
Bottom line: kind is fine for Labs 2, 3, 6, 9 (pure Kubernetes API-level chaos). It completely misses the OS-level, network-level, and HA mechanics of Labs 1, 4, 5, 7, 8 — which are exactly the ones senior SREs get grilled on.

My Recommendation: Tiered Setup
Split the labs across two cluster types based on what they actually need:
Tier 1: kind cluster (free, already running on EC2)
  → Labs 6, 9 (webhook lockout, CoreDNS)
  → No cost, spin up/down in 2 minutes

Tier 2: 1 CP + 2 Workers kubeadm on EC2 (3 instances)
  → Labs 2, 3, 5, 7 (cert, static pod, network partition, cgroup)
  → ~$0.05/hr per t3.medium = ~$3.60/day total
  → Spin UP before lab, DOWN after — don't leave running

Tier 3: 3 CP + 2 Workers kubeadm on EC2 (your existing HA cluster)
  → Labs 1, 4, 8 (etcd quorum, KCM leader election, CP node loss)
  → Only spin up for these 3 labs specifically
  → ~$0.05/hr × 5 nodes = ~$6/day — do all 3 labs in one session

The Practical Plan
This week — Start with Tier 1 (kind, free):
Labs 6 and 9 on kind teach admission control lockout and DNS failure which are high-frequency interview topics and need zero EC2 spend.
Next — Tier 2 (1 CP + 2 workers, cheap):
This is the sweet spot — 3 nodes, real kubeadm, real systemd, costs almost nothing if you stop instances between sessions. Setup takes 20 minutes. Covers Labs 2, 3, 5, 7.
Finally — Tier 3 (HA cluster, your existing build):
You've already built this. Spin it back up for one dedicated 3-4 hour session and run Labs 1, 4, 8 back to back. Then tear it down.

Cost Estimate
kind (Labs 6, 9)       → $0 (runs on existing EC2)
1 CP + 2 workers       → ~3 hrs × $0.15 = ~$0.45 per lab session
3 CP + 2 workers (HA)  → ~4 hrs × $0.25 = ~$1.00 one-time session
────────────────────────────────────────────
Total for entire lab sequence: < $5

Decision
Start with kind right now for Lab 6 (webhook lockout). It's the highest-frequency interview scenario, zero setup cost, and teaches the most dangerous failure mode in production clusters. Then we build the 1 CP + 2 workers cluster for the OS-level labs.
Should I give you the kubeadm setup commands for the 1 CP + 2 workers cluster first, or do you want to start on Lab 6 (webhook lockout on kind) right now?Leave it we should do the practicals using Kubeadm cluster setup on EC2 instances, 1 Control plane and 2 worker nodes. Would this be sufficient to do these labs? If yes, then let's start with itEvaluated cluster sufficiency and mapped setup strategyEvaluated cluster sufficiency and mapped setup strategyHonest Assessment First
Lab1 CP + 2 WorkersNotesLab 0: Safety net✅Full backup/snapshotLab 1: etcd failure✅ AdaptedSingle-member etcd failure + restore (quorum math needs HA — cover that conceptually)Lab 2: apiserver cert corruption✅PerfectLab 3: Static pod manifest✅PerfectLab 4: KCM leader election❌Needs 3 CP nodes — skip or defer to HA sessionLab 5: Node network partition✅Worker node isolation via iptablesLab 6: Webhook lockout✅PerfectLab 7: cgroup driver mismatch✅Real systemd + containerdLab 8: Full CP node loss❌Needs HA — skip or deferLab 9: CoreDNS outage✅Perfect
7 of 9 labs work fully. Labs 4 and 8 need HA — we'll note them and defer. This is the right call. Let's build the cluster now.

Step 1: AWS Infrastructure Setup
Security Group — Create one SG, apply to all 3 nodes
bash# Create the SG
aws ec2 create-security-group \
  --group-name k8s-chaos-lab-sg \
  --description "Kubernetes chaos lab security group" \
  --vpc-id <your-vpc-id>

# Save the SG ID
export SG_ID=<output-sg-id>

# Allow all traffic between nodes in the same SG (intra-cluster)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol all \
  --source-group $SG_ID

# SSH from your IP
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr <your-ip>/32

# kubectl from your IP
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 6443 \
  --cidr <your-ip>/32

# NodePort range (for testing services)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 30000-32767 \
  --cidr 0.0.0.0/0
Launch 3 EC2 Instances
bash# Ubuntu 22.04 LTS, t3.medium (2vCPU, 4GB) — minimum viable for kubeadm
# Run this 3 times with different names

for role in control-plane worker-1 worker-2; do
  aws ec2 run-instances \
    --image-id ami-0c7217cdde317cfec \   # Ubuntu 22.04 us-east-1 — verify latest AMI
    --instance-type t3.medium \
    --key-name <your-key-pair> \
    --security-group-ids $SG_ID \
    --subnet-id <your-subnet-id> \
    --associate-public-ip-address \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=k8s-$role}]" \
    --count 1
done
Save the 3 private IPs and public IPs — you'll need both:
bashaws ec2 describe-instances \
  --filters "Name=tag:Name,Values=k8s-*" \
  --query 'Reservations[*].Instances[*].[Tags[?Key==`Name`].Value|[0],PrivateIpAddress,PublicIpAddress]' \
  --output table

Step 2: Common Setup — Run on ALL 3 Nodes
SSH into each node and run everything below. I recommend 3 terminal tabs open simultaneously.
bashssh -i <key.pem> ubuntu@<public-ip>
2a. System Prerequisites
bash# Disable swap — Kubernetes requires this
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Verify swap is off
free -h   # Swap line should show 0

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Verify modules loaded
lsmod | grep -E "overlay|br_netfilter"

# Kernel networking params — critical for pod networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
2b. Install containerd
bash# Install dependencies
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release

# Add Docker's official GPG key (containerd ships with Docker repo)
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list

sudo apt-get update
sudo apt-get install -y containerd.io

# Generate default config
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml

# CRITICAL: Set SystemdCgroup = true — must match kubelet cgroupDriver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Verify the change
grep SystemdCgroup /etc/containerd/config.toml   # Must show: true

sudo systemctl restart containerd
sudo systemctl enable containerd
sudo systemctl status containerd   # Must show: active (running)
2c. Install kubeadm, kubelet, kubectl
bash# Add Kubernetes apt repo (v1.29)
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update

# Pin to specific version — prevents accidental upgrades
sudo apt-get install -y kubelet=1.29.0-1.1 kubeadm=1.29.0-1.1 kubectl=1.29.0-1.1
sudo apt-mark hold kubelet kubeadm kubectl

# Verify
kubeadm version
kubelet --version
kubectl version --client

Step 3: Control Plane Init — Run ONLY on CP Node
bash# Set your CP private IP
export CP_PRIVATE_IP=$(hostname -I | awk '{print $1}')
echo $CP_PRIVATE_IP   # confirm this is the right IP

sudo kubeadm init \
  --apiserver-advertise-address=$CP_PRIVATE_IP \
  --pod-network-cidr=192.168.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version=v1.29.0 \
  --node-name=k8s-control-plane \
  2>&1 | tee /root/kubeadm-init.log
This takes 2-3 minutes. When it finishes you'll see:
Your Kubernetes control-plane has initialized successfully!
...
kubeadm join 10.x.x.x:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
Save that join command immediately.
Configure kubectl
bashmkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify control plane is up (nodes will show NotReady until CNI installed)
kubectl get nodes
kubectl get pods -n kube-system
Install Calico CNI
bashkubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Watch pods come up — wait until coredns pods are Running
watch kubectl get pods -n kube-system
# Ctrl+C when all Running

Step 4: Join Worker Nodes — Run on EACH Worker
Take the join command from Step 3 output and run it on both workers:
bash# On worker-1 AND worker-2 (the exact command from your kubeadm init output)
sudo kubeadm join <CP_PRIVATE_IP>:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --node-name=k8s-worker-1    # change to k8s-worker-2 on second worker
Verify from CP Node
bashkubectl get nodes -o wide
Expected output:
NAME                STATUS   ROLES           AGE   VERSION
k8s-control-plane   Ready    control-plane   5m    v1.29.0
k8s-worker-1        Ready    <none>          2m    v1.29.0
k8s-worker-2        Ready    <none>          1m    v1.29.0
All three nodes Ready = cluster is healthy and ready for chaos.

Step 5: Deploy a Test Workload (your sanity check target)
This gives you something meaningful to observe breaking and recovering across all labs:
bash# Deploy nginx across both workers
kubectl create deployment nginx-test \
  --image=nginx:alpine \
  --replicas=4

# Expose it
kubectl expose deployment nginx-test \
  --port=80 \
  --type=NodePort

# Verify pods spread across both workers
kubectl get pods -o wide

# Note the NodePort
kubectl get svc nginx-test

Step 6: Lab 0 — Safety Net
Run this now, before any chaos:
bash# etcd backup
sudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify backup
sudo ETCDCTL_API=3 etcdctl snapshot status \
  /root/etcd-backup-$(date +%F).db -w table

# Document baseline
kubectl get nodes -o wide > /root/baseline-nodes.txt
kubectl get pods -A -o wide > /root/baseline-pods.txt
kubeadm certs check-expiration > /root/baseline-certs.txt

# etcd health
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# EBS snapshot — from your local machine, not the EC2 nodes
for name in k8s-control-plane k8s-worker-1 k8s-worker-2; do
  INSTANCE_ID=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=$name" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
  VOL_ID=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)
  aws ec2 create-snapshot \
    --volume-id $VOL_ID \
    --description "pre-chaos-$name-$(date +%F)"
  echo "Snapshot created for $name ($VOL_ID)"
done

When your cluster shows all 3 nodes Ready, test deployment is running across both workers, and Lab 0 safety net is in place — paste the output of these two commands:
bashkubectl get nodes -o wide
kubectl get pods -A
Then we immediately start Lab 1: etcd failure and restore.Lab 1: etcd failure and restoreArchitected comprehensive etcd failure simulation and recovery lab structureArchitected comprehensive etcd failure simulation and recovery lab structureLab 1: etcd Failure and Restore
Before we break anything, let's understand exactly what we have and what will happen. This mental model first approach is what separates SREs from script followers.

Mental Model: What etcd Failure Actually Means
Single etcd member goes down:

apiserver ──────────────> etcd (DEAD)
   │                         ✗ no reads
   │                         ✗ no writes
   │
   ├── kubectl get pods      ✗ FAILS (apiserver can't serve)
   ├── new pod scheduling    ✗ FAILS (scheduler can't write)
   ├── controller reconcile  ✗ FAILS (KCM can't read/write)
   │
   └── EXISTING pods         ✅ KEEP RUNNING
       (kubelet is autonomous — doesn't need apiserver for already-running pods)
This is the single most important thing to understand: the data plane survives the control plane going blind. Your nginx pods will still serve traffic after etcd dies. Only the ability to observe or change cluster state is lost.

Stage A: Pre-Lab Verification
Run these on the control plane node. This is your baseline — every recovery verification will diff against this.
bash# 1. Confirm etcd is healthy and note current leader
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table
Expected output — note the RAFT INDEX and DB SIZE values:
+------------------------+------------------+---------+---------+-----------+
|        ENDPOINT        |        ID        | VERSION | DB SIZE | IS LEADER |
+------------------------+------------------+---------+---------+-----------+
| https://127.0.0.1:2379 | 8e9e05c52164694d |  3.5.x  |  5.8 MB |      true |
+------------------------+------------------+---------+---------+-----------+
bash# 2. Confirm all nodes Ready
kubectl get nodes -o wide

# 3. Confirm test workload running
kubectl get pods -o wide
kubectl get svc nginx-test

# 4. Note the NodePort number
export NODEPORT=$(kubectl get svc nginx-test \
  -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODEPORT"

# 5. Confirm nginx is serving (from CP node)
curl -s http://localhost:$NODEPORT | grep "<title>"
# Expected: <title>Welcome to nginx!</title>

# 6. Note the etcd static pod manifest checksum before we touch it
sudo md5sum /etc/kubernetes/manifests/etcd.yaml
Paste this output before proceeding — I want to confirm your baseline is clean.

Stage B: Break etcd
We break it by removing the static pod manifest. This is the cleanest, most reversible failure simulation — kubelet will terminate the etcd container the moment the manifest disappears.
bash# First: verify the backup from Lab 0 exists
ls -lh /root/etcd-backup-*.db
sudo ETCDCTL_API=3 etcdctl snapshot status \
  /root/etcd-backup-$(date +%F).db -w table

# NOW break it — move the manifest out of staticPodPath
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak

echo "etcd manifest moved at: $(date)"
kubelet detects the manifest is gone within ~5 seconds and kills the etcd container.

Stage C: Observe the Blast Radius
Run these commands in sequence and note exactly what you see and when. This is the exam and interview content — not just "it broke" but the precise failure behaviour of each component.
bash# IMMEDIATELY after moving manifest:

# 1. Can kubectl still talk to the cluster?
kubectl get nodes
# What do you see? Does it fail immediately or hang?

# 2. Watch the exact error message
kubectl get pods -n kube-system 2>&1
# Note the exact error text — this tells you WHERE the failure is

# 3. Is the apiserver process itself still running?
sudo crictl ps | grep apiserver
# apiserver container should still be RUNNING (it's alive, just blind)

# 4. Is the etcd container gone?
sudo crictl ps | grep etcd
# Should show nothing or Exited

# 5. THE CRITICAL TEST — do existing pods still run?
# From your local machine or worker node:
# First get worker-1's public IP
curl -s http://<worker-1-public-ip>:$NODEPORT
# Does nginx still respond? THIS IS THE KEY INSIGHT

# 6. Can kubelet still operate independently?
# SSH into worker-1 and run:
sudo crictl ps | grep nginx
# Worker kubelet manages its pods without needing apiserver

# 7. Watch the apiserver logs — it's actively trying to reconnect to etcd
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q) 2>&1 | tail -30
# You'll see: "etcdserver: request timed out"
Expected observations — predict these before running:
ComponentExpected StateWhykubectl get nodesHangs then times outapiserver can't serve reads without etcdapiserver containerRunningProcess alive, waiting for etcdetcd containerGonekubelet removed it when manifest disappearednginx pods on workersStill serving traffickubelet autonomous, doesn't need control planeCoreDNS podsStill runningSame reasonNew pod creationImpossibleapiserver can't write to etcd

Stage D: Restore from Snapshot
This is the CKA exam procedure. Every step matters — in the wrong order, you get a corrupted cluster.
Step 1: Stop the apiserver first
bash# Move apiserver manifest out too — prevents it from hammering
# a partially-restored etcd during the restore process
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# Verify both containers are gone
sudo crictl ps | grep -E "etcd|apiserver"
# Should return nothing
Step 2: Restore the snapshot to a NEW data directory
bash# NEVER restore into the live data dir while etcd might be running
# Always restore to a fresh path

sudo ETCDCTL_API=3 etcdctl snapshot restore \
  /root/etcd-backup-$(date +%F).db \
  --data-dir=/var/lib/etcd-restored \
  --name=k8s-control-plane \
  --initial-cluster=k8s-control-plane=https://127.0.0.1:2380 \
  --initial-advertise-peer-urls=https://127.0.0.1:2380

# Verify the restore created the directory
ls -la /var/lib/etcd-restored/
sudo ls -la /var/lib/etcd-restored/member/

# Fix ownership — etcd runs as root but let's be explicit
sudo chown -R root:root /var/lib/etcd-restored
Step 3: Update etcd manifest to use restored data directory
bash# Edit the backed-up manifest to point to new data dir
sudo cp /root/etcd.yaml.bak /root/etcd.yaml.restored

sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-restored|g' /root/etcd.yaml.restored

# Verify the change
grep "data-dir\|etcd-restored" /root/etcd.yaml.restored
Expected lines after edit:
- --data-dir=/var/lib/etcd-restored
  path: /var/lib/etcd-restored
Step 4: Restore both manifests
bash# Restore etcd manifest first
sudo cp /root/etcd.yaml.restored /etc/kubernetes/manifests/etcd.yaml

# Watch kubelet bring etcd back
watch sudo crictl ps | grep etcd
# Wait until you see etcd container STATUS = Running
# Ctrl+C
bash# Verify etcd is healthy before restoring apiserver
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Expected: https://127.0.0.1:2379 is healthy: successfully committed proposal
Only after etcd is confirmed healthy:
bash# Restore apiserver manifest
sudo mv /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

# Watch apiserver come back
watch sudo crictl ps | grep apiserver
# Wait for Running status
# Ctrl+C

Stage E: Verify Full Recovery
Run these in order — each one confirms a deeper layer of recovery:
bash# Layer 1: Control plane components healthy?
kubectl get pods -n kube-system
# All Running — especially etcd, apiserver, controller-manager, scheduler

# Layer 2: Nodes still registered?
kubectl get nodes -o wide
# All 3 nodes Ready

# Layer 3: Workloads survived?
kubectl get pods -o wide
kubectl get svc nginx-test
# nginx-test pods still running, same IPs as baseline

# Layer 4: etcd data integrity — does it match pre-failure state?
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table
# Compare RAFT INDEX with your Stage A baseline

# Layer 5: Can we create NEW objects? (proves writes work)
kubectl run recovery-test --image=nginx:alpine
kubectl get pod recovery-test
kubectl delete pod recovery-test

# Layer 6: nginx still serving traffic?
curl -s http://localhost:$NODEPORT | grep "<title>"

Stage F: Cleanup (Restore Original Data Dir)
bash# Optional but recommended — revert to original etcd data dir
# so future labs start from a clean state

# Take a fresh snapshot first
sudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-post-lab1.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Remove the restored directory
sudo rm -rf /var/lib/etcd-restored

**Interview Debrief — What You Just Proved**

### Q: If etcd goes down, does your application stop serving traffic?

Answer you can give from experience: No. Existing pods keep running because kubelet is autonomous. 
Only control-plane operations fail — kubectl, scheduling, and controller reconciliation. 
The data plane is independent of the control plane.

### Q: What's the correct order for etcd restore?

```
1. Stop apiserver (prevent writes to partially-restored etcd)
2. Restore snapshot to NEW directory (never overwrite live data)
3. Update etcd manifest --data-dir to point to new directory
4. Start etcd, verify healthy
5. Start apiserver
```

### Q: Why restore to a new directory instead of overwriting /var/lib/etcd?

If restore fails mid-way and you've already deleted the original, you have nothing to fall back to. New directory = safe atomic swap.

### Q: What data is lost after an etcd restore?

Everything written between snapshot time and the failure — any deployments, config changes, secrets created in that window are gone. This is why etcd backup frequency matters: in production, you'd want snapshots every 30 minutes at minimum.
