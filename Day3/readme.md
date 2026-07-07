# Master Lab Guide: etcd Failure and Restore

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

If your cluster runs 3.5.15, set ETCD_VER=v3.5.15.

If your cluster runs 3.6.2, set ETCD_VER=v3.6.2.

⚠️ Important Architecture Note for etcdutl:
The separate etcdutl binary was introduced in ETCD v3.6.

If your version is v3.6+: You will have two distinct binaries (etcdctl and etcdutl).

If your version is v3.5 or older: etcdutl does not exist as a separate file. Instead, etcdctl handles everything (including restores).

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

Run this command to find your exact etcd member name, host IP, and data directory:

```
sudo cat /etc/kubernetes/manifests/etcd.yaml | grep -E "\--name=|\--initial-cluster=|\--data-dir="
```

**Critical Info to Write Down:**

- My Node/Member Name (--name=) is: ___________ (e.g., master or ip-172-31-38-12)
- My Initial Cluster String (--initial-cluster=) is: ___________
- My Host IP address inside that string is: ___________

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

**2. Break the Control Plane**

Move the etcd manifest completely out of the static pods folder. Kubelet will instantly kill the container.

```
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd.yaml.bak
```

## Phase 3: Observe the Blast Radius

*Wait 10 seconds, then observe what happens when the control plane loses its database:*

- kubectl get nodes → Hangs and times out (API Server is blind).
- sudo crictl ps | grep etcd → Returns empty (Container is terminated).
- curl -s http://localhost:$NODEPORT → Still succeeds! (Existing data plane pods stay running autonomously).

## Phase 4: The Atomic Restoration Procedure

**Step 1: Stop the API Server**

To prevent configuration corruption or data conflicts during the swap, remove the API server first:

```
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
sleep 5
```

**Step 2: Clean the Directory and Run the Restore**

Wipe the old directory completely. Then, use the exact Name and IP variables you discovered in Phase 1 to run the restore:

```
# 1. Clear out the live database path
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

**1. Bring up etcd First**

Copy your backup manifest file straight back into the active manifests folder:

```
sudo cp /root/etcd.yaml.bak /etc/kubernetes/manifests/etcd.yaml
```

Monitor etcd until its status turns back to Running:

```
watch -n 1 "sudo crictl ps | grep etcd"
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

**3. Bring up the API Server**

Now that the database is certified healthy, restore the API server manifest:

```
sudo mv /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

Wait 20 seconds for the API Server to boot up, parse certificates, and sync its internal RBAC rules.

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

## 💡 Pro-Tip Checklist :

- The Name Mismatch Trap: The --name and the prefix string inside --initial-cluster must be completely identical.

- The Blind Fresh Database Trap: If you pass values to snapshot restore that mismatch the parameters in your etcd.yaml, etcd will ignore your backup completely       and create a blank database, giving you Forbidden RBAC errors. ALWAYS match your original configuration parameters exactly.
