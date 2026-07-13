# Lab 5: Worker Node Network Partition

**Mental Model: The Eviction Timeline**

This is the most important thing to burn into memory before breaking anything:

```
T+0s    iptables rules applied — worker-1 isolated from control plane
         │
         ├── worker-1 kubelet: tries to heartbeat apiserver → CONNECTION REFUSED
         ├── apiserver: tries to reach worker-1 kubelet → CONNECTION REFUSED  
         └── worker-1 PODS: still running, still serving traffic (unaffected)

T+10s   kubelet misses first heartbeat window (--node-status-update-frequency=10s)

T+40s   node-monitor-grace-period expires (default: 40s)
         │
         ├── node condition: Ready → Unknown
         ├── automatic taint added: node.kubernetes.io/unreachable:NoExecute
         └── kubectl get nodes → worker-1 shows NotReady

T+40s–5m  pods on worker-1 are TOLERATING the taint
           (DefaultTolerationSeconds admission controller injected
            tolerationSeconds:300 into every pod automatically)
           │
           └── pods still running on worker-1
               new pods from deployment NOT yet scheduled elsewhere

T+5m    tolerationSeconds expires for pods on worker-1
         │
         ├── node controller sends eviction requests
         ├── deployment controller creates replacement pods on worker-2
         └── old pods on worker-1 → Terminating (but can't actually stop
             because kubelet is unreachable — they hang as Terminating)

T+?     network partition removed (Stage E recovery)
         │
         ├── worker-1 kubelet reconnects to apiserver
         ├── kubelet receives termination orders for evicted pods → stops them
         ├── node taint removed
         └── node → Ready again
```

**The most important insight:** 

pods don't evict instantly. The 5-minute toleration window exists specifically to prevent mass rescheduling during transient network blips. 
A 30-second outage causes zero pod movement.

**Architecture of the Break**

We use iptables to surgically block only the control plane communication ports — not all traffic. 
This is realistic because real network partitions (misconfigured Security Groups, routing table changes, NACLs) often affect specific paths, not everything:

```
WHAT WE BLOCK (on worker-1):
  Outbound → CP:6443   (kubelet can't heartbeat apiserver)
  Inbound  ← CP:10250  (apiserver can't reach kubelet API)

WHAT WE LEAVE OPEN:
  NodePort traffic (30000-32767) → pods still serve requests
  Pod-to-pod within node → containers still communicate
  Internet → node can still pull images (irrelevant here)
```

## Stage A: Pre-Lab Verification

*On the control plane node:*

```
# 1. Confirm clean cluster state
kubectl get nodes -o wide
# All 3 nodes Ready

# 2. Get private IPs — you'll need these for iptables rules
kubectl get nodes -o wide | awk '{print $1, $6}'
# Note: INTERNAL-IP column for each node

# Set variables (use your actual IPs)
export CP_IP=$(kubectl get node k8s-control-plane \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
export W1_IP=$(kubectl get node k8s-worker-1 \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
export W2_IP=$(kubectl get node k8s-worker-2 \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

echo "Control Plane: $CP_IP"
echo "Worker 1:      $W1_IP"
echo "Worker 2:      $W2_IP"

# 3. Check current pod distribution across workers
kubectl get pods -o wide
# Note which pods are on worker-1 vs worker-2

# 4. Check default tolerations on a pod — this is what gives the 5min window
kubectl get pod -l app=nginx-test -o jsonpath=\
'{.items[0].spec.tolerations}' | python3 -m json.tool
# Look for: node.kubernetes.io/not-ready and node.kubernetes.io/unreachable
# Both should have tolerationSeconds: 300

# 5. Check node controller settings on kube-controller-manager
sudo grep -E "node-monitor|eviction|pod-eviction" \
  /etc/kubernetes/manifests/kube-controller-manager.yaml
# If these flags aren't present — defaults apply:
# --node-monitor-grace-period=40s
# --node-monitor-period=5s

# 6. Confirm nginx serving from BOTH workers
export NODEPORT=$(kubectl get svc nginx-test \
  -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODEPORT"

curl -s http://$W1_IP:$NODEPORT | grep "<title>"
curl -s http://$W2_IP:$NODEPORT | grep "<title>"
# Both should return: <title>Welcome to nginx!</title>

# 7. Document baseline pod distribution
kubectl get pods -o wide > ~/lab5-baseline-pods.txt
sudo mv ~/lab5-baseline-pods.txt /root/lab5-baseline-pods.txt
sudo cat /root/lab5-baseline-pods.txt
```

## Stage B: The Break — Partition Worker-1

*SSH into worker-1 for this stage. Keep a second terminal on the control plane for observation.*

```
# === ON WORKER-1 ===

# First confirm current iptables state (should be clean)
sudo iptables -L OUTPUT -n | grep DROP
sudo iptables -L INPUT -n | grep DROP
# Both should return nothing

# Save current iptables rules — your rollback
sudo iptables-save | sudo tee /root/iptables-backup-pre-lab5.rules > /dev/null
echo "iptables backup saved"

# NOW APPLY THE PARTITION RULES

# Rule 1: Block worker-1 outbound to apiserver (kills heartbeat)
sudo iptables -A OUTPUT \
  -d $CP_IP \
  -p tcp \
  --dport 6443 \
  -j DROP

# Rule 2: Block inbound from CP to kubelet API (kills exec/logs/metrics)
sudo iptables -A INPUT \
  -s $CP_IP \
  -p tcp \
  --dport 10250 \
  -j DROP

echo "Network partition applied at: $(date)"
echo "Blocking: $W1_IP <-> $CP_IP on ports 6443 and 10250"

# Verify rules are in place
sudo iptables -L OUTPUT -n | grep DROP
sudo iptables -L INPUT -n | grep DROP

# Confirm: kubelet can no longer reach apiserver
curl -sk --max-time 3 https://$CP_IP:6443/healthz 2>&1
# Expected: connection timed out (not refused — DROP silently drops packets)

# Confirm: pods STILL running locally on worker-1
sudo crictl ps | grep -v pause | grep -v "CONTAINER"
# All containers still Running — partition doesn't affect local pods
```

## Stage C: Observe the Timeline — Control Plane View

*Back on control plane. Open TWO terminal tabs here — run the watch commands in parallel:*

**Terminal 1: Watch node status in real time**

```
# Watch node status — keep this running for the entire observation period
kubectl get nodes -w
```

**Terminal 2: Run the diagnosis sequence with timestamps**

```
# T+0: Immediate state — node still Ready (grace period not expired)
echo "=== T+0 ===" && date
kubectl get nodes
# worker-1 still shows Ready — grace period hasn't expired yet

# Wait 45 seconds for grace period to expire
echo "Waiting 45 seconds for node-monitor-grace-period..."
sleep 45

# T+45s: Node should now show NotReady/Unknown
echo "=== T+45s ===" && date
kubectl get nodes
# worker-1: NotReady

# Check what conditions the node controller set
kubectl describe node k8s-worker-1 | grep -A20 "Conditions:"
# Look for:
# Ready: False or Unknown
# Reason: NodeStatusUnknown or KubeletNotReady
# Message: Kubelet stopped posting node status

# Check automatic taints applied by node controller
kubectl describe node k8s-worker-1 | grep -A5 "Taints:"
# Expected:
# node.kubernetes.io/unreachable:NoExecute
# node.kubernetes.io/not-ready:NoSchedule

# Check node events
kubectl get events -A --field-selector reason=NodeNotReady
kubectl get events -A --field-selector reason=NodeStatusUnknown

# Pod status — still running, tolerating the taint
echo "=== Pod status at T+45s ===" && date
kubectl get pods -o wide
# Pods on worker-1: still Running (toleration window active)
# No new pods created yet on worker-2

# Watch for the 5-minute eviction window
echo "Waiting for tolerationSeconds window (5 min from partition start)..."
echo "Watch the pod statuses change in Terminal 1"
```

**The 5-minute mark — watch carefully**

```
# After ~5 minutes from partition start:
echo "=== T+5min ===" && date

# Watch pod status
kubectl get pods -o wide
# Pods on worker-1: Terminating (eviction sent, kubelet unreachable)
# NEW pods: ContainerCreating on worker-2 (deployment controller acting)

# Watch events for eviction evidence
kubectl get events -A | grep -iE "evict|eviction|kill" | tail -10

# Check the node controller sent eviction
kubectl describe node k8s-worker-1 | grep -A5 "Events:"

# Can you still reach nginx from worker-1's IP? (pods still physically running)
curl -s --max-time 3 http://$W1_IP:$NODEPORT | grep "<title>"
# YES — pods physically still running even though Kubernetes thinks they're Terminating

# Can you reach nginx from worker-2?
curl -s --max-time 3 http://$W2_IP:$NODEPORT | grep "<title>"
# YES — new pods rescheduled here are serving traffic
```

**On worker-1 — kubelet's perspective during partition**

```
# === ON WORKER-1 ===

# What is worker-1's kubelet seeing?
sudo journalctl -u kubelet --since "6 minutes ago" --no-pager | \
  grep -iE "error|apiserver|failed|refused|timeout" | tail -30

# Expected log lines:
# "Failed to update node status" err="...connection refused"
# "Error getting node" err="...context deadline exceeded"
# "Failed to patch status"

# Are the pods physically still running?
sudo crictl ps | grep -v pause
# ALL pods still Running — kubelet never killed them
# It's waiting for instructions from apiserver that never come

# iptables drop counter — confirms packets are being dropped
sudo iptables -L OUTPUT -n -v | grep DROP
sudo iptables -L INPUT -n -v | grep DROP
# pkts column shows increasing count = traffic being silently dropped
```

## Stage D: Deep Diagnosis — What Each Tool Tells You

```
# === ON CONTROL PLANE ===

# DIAGNOSIS 1: Node conditions — the authoritative state
kubectl get node k8s-worker-1 -o yaml | \
  grep -A100 "conditions:" | \
  grep -E "type:|status:|reason:|message:|lastTransition" | \
  head -40

# DIAGNOSIS 2: When did the node go NotReady?
kubectl describe node k8s-worker-1 | \
  grep -E "Ready|Last Heartbeat|Last Transition"
# Last Heartbeat Time shows exactly when kubelet stopped
# Last Transition Time shows when status flipped

# DIAGNOSIS 3: What taints were auto-applied and when?
kubectl get node k8s-worker-1 \
  -o jsonpath='{.spec.taints}' | python3 -m json.tool
# Shows: effect, key, timeAdded for each taint

# DIAGNOSIS 4: Which pods are stuck Terminating on the dead node?
kubectl get pods -o wide | grep "worker-1"
# These pods are in Terminating but can't actually stop
# because kubelet is unreachable — they're "zombie" pods

# DIAGNOSIS 5: Were new pods rescheduled on worker-2?
kubectl get pods -o wide | grep "worker-2"
# Deployment controller ensured desired replica count
# by creating new pods on the remaining healthy node

# DIAGNOSIS 6: Check the replica math
kubectl get deployment nginx-test
# READY should equal DESIRED even during worker-1 outage
# because new pods came up on worker-2 before old ones Terminated

# DIAGNOSIS 7: What would happen to a pod with NO deployment controller?
# (bare pod — no ReplicaSet parent)
kubectl run bare-pod-test --image=nginx:alpine \
  --overrides='{"spec":{"nodeName":"k8s-worker-1"}}'
kubectl get pod bare-pod-test -o wide
# Forced onto worker-1 — when eviction happens,
# this pod will be evicted and NEVER rescheduled (no controller)
# This is why you should NEVER run bare pods in production
```

## Stage E: Recovery — Remove the Partition

*On worker-1:*

```
# === ON WORKER-1 ===

# Method 1: Remove specific rules we added
sudo iptables -D OUTPUT \
  -d $CP_IP \
  -p tcp \
  --dport 6443 \
  -j DROP

sudo iptables -D INPUT \
  -s $CP_IP \
  -p tcp \
  --dport 10250 \
  -j DROP

# Verify rules are gone
sudo iptables -L OUTPUT -n | grep DROP   # Should return nothing
sudo iptables -L INPUT -n | grep DROP    # Should return nothing

# Method 2 (if Method 1 fails): Restore from backup
# sudo iptables-restore < /root/iptables-backup-pre-lab5.rules

echo "Partition removed at: $(date)"

# Immediately test kubelet can reach apiserver again
curl -sk --max-time 3 https://$CP_IP:6443/healthz
# Expected: ok
```

**Back on control plane — watch recovery:**

```
# Watch node come back
kubectl get nodes -w
# worker-1: NotReady → Ready (takes ~10-20 seconds)

# Watch taints get removed
watch kubectl describe node k8s-worker-1 | grep -A3 "Taints:"
# Taints: <none>  ← when it heals
# Ctrl+C
```

## Stage F: Full Recovery Verification

```
# 1. All nodes Ready?
kubectl get nodes -o wide

# 2. Zombie Terminating pods cleaned up?
kubectl get pods -o wide
# Pods that were Terminating on worker-1 should now show Terminated/gone
# kubelet received the termination orders and executed them on reconnect

# 3. Pod distribution after recovery
kubectl get pods -o wide
# New pods that rescheduled to worker-2 stay on worker-2
# (Kubernetes doesn't move pods back — rebalancing requires manual drain/delete
#  or tools like Descheduler)

# 4. nginx serving from both workers again?
curl -s http://$W1_IP:$NODEPORT | grep "<title>"
curl -s http://$W2_IP:$NODEPORT | grep "<title>"

# 5. What happened to the bare pod?
kubectl get pod bare-pod-test
# Still Terminating OR gone — it was evicted and NOT rescheduled
# This is the production risk of bare pods

kubectl delete pod bare-pod-test --force \
  --grace-period=0 2>/dev/null || true

# 6. Events tell the full story
kubectl get events -A --sort-by='.lastTimestamp' | tail -30
# You'll see the full timeline:
# NodeNotReady → NodeStatusUnknown → Evicting → NodeReady
```

## Timeline Observation Summary

Fill this in from your actual observation — this is your incident report:

```
T+0s    Partition applied
T+___s  kubectl get nodes shows worker-1 NotReady  (your actual observation)
T+___s  Taints applied (kubectl describe node)      (your actual observation)
T+___s  Pods begin Terminating                      (your actual observation)
T+___s  New pods Running on worker-2                (your actual observation)
T+___s  Partition removed
T+___s  worker-1 back to Ready                      (your actual observation)
T+___s  Terminating pods cleaned up                 (your actual observation)
```

## Interview Debrief

*Q: A node shows NotReady. What's your immediate investigation sequence?*

```
# Step 1: When did it go NotReady?
kubectl describe node <node> | grep "Last Heartbeat"

# Step 2: What condition/reason?
kubectl describe node <node> | grep -A5 "Conditions:"
# NodeStatusUnknown = kubelet stopped heartbeating
# DiskPressure/MemoryPressure = resource exhaustion

# Step 3: Can you reach the node?
ssh <node>   # Can you get in?
ping <node-ip>  # Basic connectivity?

# Step 4: On the node — is kubelet running?
sudo systemctl status kubelet
sudo journalctl -u kubelet --since "10 minutes ago" | tail -30

# Step 5: Resource pressure?
df -h    # Disk
free -h  # Memory
```

**Q: Why do pods stay Terminating after a node comes back?**

When a node is unreachable and eviction is triggered, the API server marks pods as Terminating but can't actually deliver the SIGTERM — the kubelet is unreachable. The pod stays Terminating until either: the node comes back (kubelet gets the message and kills the pod) or you force-delete it with kubectl delete pod --force --grace-period=0.

**Q: A node has been NotReady for 10 minutes. Why are some pods still Terminating and not rescheduled?**

Two reasons: StatefulSet pods are NOT automatically rescheduled (they have sticky identity — the controller waits for the old pod to fully terminate before creating a new one). DaemonSet pods are also not rescheduled (they're per-node by design). Only Deployment/ReplicaSet pods get rescheduled automatically.

**Q: What's the risk of lowering pod-eviction-timeout to 30 seconds for faster recovery?**

A 30-second network blip (cloud provider transient issue, brief packet loss) would trigger a mass rescheduling event across your entire cluster simultaneously — potentially overloading remaining nodes and cascading the failure. The 5-minute default exists to absorb transient noise. Production tuning is usually 2-3 minutes at minimum, not seconds.

**Q: Why doesn't Kubernetes rebalance pods back to worker-1 after it recovers?**

By design — involuntary pod movement causes disruption. If your app was running fine on worker-2 after recovery, moving it back to worker-1 would cause another restart with zero benefit. Tools like Descheduler (a separate Kubernetes SIG project) can optionally rebalance by evicting pods from over-loaded nodes and letting the scheduler naturally rebalance — but it's opt-in, not default.





