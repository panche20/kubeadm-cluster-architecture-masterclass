# Lab 8: Full Control-Plane Node Loss

This is the capstone lab — it combines everything you've already proven individually 
(etcd quorum math from Lab 1, leader election failover from Lab 4) into one realistic 
event: an entire EC2 instance disappearing, not just a process on it. We'll simulate 
this the most realistic way available to us — actually stopping the instance via AWS, 
not just killing a static pod manifest.

## Mental Model: What "Losing a Node" Actually Means Here

A single control-plane EC2 instance going down isn't one failure — it's four simultaneous failures that happen to share a blast radius:

```
Stop control-plane-N:
  │
  ├── etcd member N           → unreachable (Raft: 2/3 remain = quorum intact)
  ├── apiserver instance N    → unreachable (HAProxy: 2/3 backends remain)
  ├── KCM instance N          → dead (if it held the lease → failover, per Lab 4)
  ├── scheduler instance N    → dead (if it held the lease → failover, per Lab 4)
  │
  └── kubelet on control-plane-N → stops heartbeating
        → node controller eventually taints it (same NotReady mechanics as Lab 5)
        → irrelevant for scheduling (control-plane nodes are already
          NoSchedule-tainted), but the Node object itself still reflects it
```

*The whole point: with proper HA (3 CP nodes), this should be a non-event from the cluster's perspective — kubectl keeps 
working, workloads keep running, nothing pages you. 
We're going to prove that, then push past it to show you exactly where it stops being a non-event (losing a 2nd node too).*

## Stage A: Pre-Lab Baseline — Know Exactly What You're About to Kill

Run this from any control-plane node:

```
# Node status
kubectl get nodes -o wide

# etcd membership AND which one is the Raft leader (a separate concept
# from the KCM/scheduler lease leader — check both)
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table
# Note the IS LEADER column

# KCM / scheduler lease holders — from your Lab 4 run, this may have moved
kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}'; echo
kubectl get lease -n kube-system kube-scheduler -o jsonpath='{.spec.holderIdentity}'; echo

# Confirm cluster fully healthy and workload serving
kubectl get pods -o wide
export NODEPORT=$(kubectl get svc nginx-test -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://localhost:$NODEPORT | grep "<title>"
```

**From your local machine — HAProxy's own view of backend health:**

```
curl -s 'http://<haproxy-lb-public-ip>:8404/;csv' | \
  grep '^kubernetes-backend,' | \
  awk -F',' '$2 != "BACKEND" {print $2, $18}'
```

**Decide your target now, from the etcd table above.** 

For maximum teaching value, target whichever node shows IS LEADER: true on etcd — this way Stage C lets you observe an etcd Raft election and a KCM/scheduler lease failover and an HAProxy backend drop, all from one action. Set it as a variable for the rest of this lab:

```
export TARGET_NODE=control-plane-2   # replace with your actual etcd leader
```

*Get its instance ID (from your local machine):*

```
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=$TARGET_NODE" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text
export TARGET_INSTANCE_ID=<output>
```

## Stage B: The Break — Actually Stop the EC2 Instance

Run this from your local machine, not from inside any SSH session — you're about to cut off a node's power, not politely ask a process to exit:

```
echo "Stopping $TARGET_NODE ($TARGET_INSTANCE_ID) at: $(date)"
aws ec2 stop-instances --instance-ids $TARGET_INSTANCE_ID

# Watch it actually go down
watch -n5 "aws ec2 describe-instances --instance-ids $TARGET_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' --output text"
# Ctrl+C once it shows 'stopped'
```

*This kills kubelet, containerd, etcd, apiserver, KCM, and scheduler on that node simultaneously and totally — 
the EBS root volume is preserved (we used gp3, not instance-store), so no data is lost, but the node itself 
is gone from the cluster's point of view until restarted.*

**Important gotcha for later:** 

*stopping (not rebooting) an EC2 instance without an Elastic IP means it gets a new public IP on restart. 
The private IP stays the same (that's what the cluster actually uses internally — /etc/hosts, etcd peer 
URLs, HAProxy backends), so cluster networking is unaffected, but you'll need to re-fetch the public IP 
to SSH back in later.*

## Stage C: Observe — From a Surviving Control-Plane Node

SSH into one of the two remaining CP nodes (not the one you just stopped):

```
# etcd — is quorum intact? (2 of 3 should still be reachable)
sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
# One endpoint should show unhealthy/unreachable — the OTHER TWO should
# show healthy, confirming quorum (2/3) is intact

sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key -w table
# All 3 members STILL LISTED — etcd doesn't remove a member just because
# it's unreachable; membership and liveness are separate concepts

# kubectl — does the API still fully work?
kubectl get nodes
# $TARGET_NODE should still show Ready initially, then flip to
# NotReady after ~40s (node-monitor-grace-period, same mechanic as Lab 5)

kubectl get pods -o wide
# Existing pods on worker-1/worker-2 — completely unaffected, as always

# THE data plane test
curl -s http://localhost:$NODEPORT | grep "<title>"

# Did leader election fail over? (only meaningful if TARGET_NODE held a lease)
kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}'; echo
kubectl get lease -n kube-system kube-scheduler -o jsonpath='{.spec.holderIdentity}'; echo
# Should now point at one of the two SURVIVING nodes if TARGET_NODE was leader

# Prove reconciliation is actually still happening, not just a lease flip
kubectl scale deployment nginx-test --replicas=6
kubectl get pods -o wide -w
# Ctrl+C once 6 Running
kubectl scale deployment nginx-test --replicas=4
```

*From your local machine — confirm HAProxy noticed:*

```
curl -s 'http:<haproxy-lb-public-ip>/;csv' | \
  grep '^kubernetes-backend,' | \
  awk -F',' '$2 != "BACKEND" {print $2, $18}'
# $TARGET_NODE should show DOWN — the other two UP
# HAProxy's "check fall 3 rise 2" means it takes 3 consecutive failed
# health checks before marking a backend down — expect a short delay
```

## Stage D: Diagnose — Confirm the Full Picture

```
# Etcd's own perspective on the missing member
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key -w table 2>&1
# The dead member's row will show a connection error instead of data —
# note there's now a (possibly NEW) IS LEADER among the 2 survivors,
# if the original leader was the one you killed — a real Raft election
# just happened, same mechanism as any etcd leader failover

# Node controller's view
kubectl describe node $TARGET_NODE | grep -A10 "Conditions:"
kubectl describe node $TARGET_NODE | grep -A5 "Taints:"
# Same NotReady + unreachable taint mechanics as Lab 5 — this proves
# control-plane nodes get the identical node-health treatment as workers
```

## Stage E: Recovery — Restart and Watch It Self-Heal

```
# From your local machine
aws ec2 start-instances --instance-ids $TARGET_INSTANCE_ID

watch -n5 "aws ec2 describe-instances --instance-ids $TARGET_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].State.Name' --output text"
# Ctrl+C once 'running'

# Get its NEW public IP (private IP is unchanged, but public IP rotated)
aws ec2 describe-instances --instance-ids $TARGET_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

*SSH back in using the new public IP. You do not need to run kubeadm join again — nothing was wiped, only powered off. Every cert, kubeconfig, and static pod manifest is still sitting on the EBS volume exactly as it was:*

```
# === ON THE RECOVERED NODE ===
sudo systemctl status kubelet --no-pager | head -5
sudo crictl ps | grep -E "etcd|apiserver|controller|scheduler"
# kubelet auto-starts on boot (enabled earlier), reads the still-present
# static pod manifests, and brings everything back up on its own
```

*From a surviving control-plane node, watch the recovery unfold:*

```
watch kubectl get nodes
# $TARGET_NODE: NotReady → Ready
# Ctrl+C

sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
# All 3 healthy again — the returning etcd member automatically
# catches up on the Raft log it missed, since it was never removed
# from cluster membership, only unreachable
```

*From your local machine:*

```
curl -s 'http://<haproxy-lb-public-ip>/;csv' | \
  grep '^kubernetes-backend,' | \
  awk -F',' '$2 != "BACKEND" {print $2, $18}'
# $TARGET_NODE flips back to UP once health checks pass again — automatic,
# no HAProxy config change needed
```

*Confirm leadership did NOT move back (same rule as Lab 4 — no preemption):*

```
kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}'; echo
# Still whichever survivor won in Stage C, not necessarily TARGET_NODE
```

## Stage F: Bonus — Actually Break Quorum (2 of 3 Down)

*This finally completes what was scoped all the way back at the very start of this lab series and never executed — genuine etcd quorum loss on real multi-node Raft. Recovery from this is categorically different from Stage B/E.*

```
# Pick a SECOND node (different from the one you just recovered)
export TARGET2_NODE=control-plane-3   # whichever you haven't touched yet
export TARGET2_INSTANCE_ID=<its-instance-id>

# From local machine — stop BOTH remaining non-control-plane-1 nodes
# (adjust to stop any 2 of the 3 — the point is only 1 of 3 survives)
aws ec2 stop-instances --instance-ids $TARGET_INSTANCE_ID $TARGET2_INSTANCE_ID
```

*From the one surviving control-plane node:*

```
kubectl get nodes 2>&1
# Hangs, then times out — SAME signature as Lab 1's single-node etcd
# failure, except now it's real: 1 of 3 etcd members cannot reach
# quorum (needs 2, has 1)

sudo ETCDCTL_API=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
# unhealthy: failed to commit proposal — the write path is dead,
# a lone etcd member can't unilaterally elect itself leader or commit
```

*This is unrecoverable by simply restarting one node — you need at least one of the two stopped nodes back to restore quorum (2 of 3), or you'd need the etcd disaster-recovery procedure from Lab 1 (--force-new-cluster) if the data was actually lost, which it isn't here.*

**Recover the simple way — restart just enough nodes to regain quorum:**

```
# From local machine — bring back just ONE of the two stopped nodes
aws ec2 start-instances --instance-ids $TARGET_INSTANCE_ID
```

```
# From the surviving node, watch quorum return the moment 2/3 are reachable
watch kubectl get nodes
```

*Once healthy, restart the last node too:*

```
aws ec2 start-instances --instance-ids $TARGET2_INSTANCE_ID
```

## Stage G: Full Recovery Verification

```
kubectl get nodes -o wide
# All 5 nodes Ready

sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key -w table

kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}'; echo
kubectl get lease -n kube-system kube-scheduler -o jsonpath='{.spec.holderIdentity}'; echo

kubectl get pods -o wide
curl -s http://localhost:$NODEPORT | grep "<title>"
```

*From local machine:*

```
curl -s 'http://<haproxy-lb-public-ip>:8404/;csv' | \
  grep '^kubernetes-backend,' | \
  awk -F',' '$2 != "BACKEND" {print $2, $18}'
# All 3 backends UP
```

## Interview Debrief

**Q: With 3 control-plane nodes, how many can you lose before the cluster stops functioning?**

Exactly 1, safely, transparently — because etcd quorum (⌊3/2⌋+1 = 2) is the binding constraint, not apiserver or HAProxy capacity. Lose 2 of 3 and you lose write quorum entirely, even though the math might suggest "1 node is still up, shouldn't that be enough?" It isn't — etcd requires a majority, not just any single live member.

**Q: Why does a stopped control-plane node's etcd member automatically catch up on restart, without you doing anything?**

It was never removed from etcd's membership list — member list showed all 3 throughout the outage, just with one unreachable. On restart, that member reconnects to the existing Raft group, and the current leader replays the log entries it missed since disconnection. This only works because the node returned before its data was purged or the cluster moved on to a disaster-recovery snapshot restore — there's a difference between "temporarily unreachable member" (self-heals) and "permanently lost member with new data volume" (needs member remove + member add with a fresh join).

**Q: If the etcd Raft leader is on the node you stop, what actually happens?**

A real Raft leader election triggers among the 2 remaining members — same underlying mechanism as the KCM/scheduler Lease failover you saw in Lab 4, but at the etcd layer instead of the Kubernetes API layer. It's a separate leader concept from the KCM/scheduler lease leader; they often happen to be the same node in a fresh cluster (since control-plane-1 bootstraps everything first) but drift apart over time exactly like you may have observed after Lab 4.

**Q: How does HAProxy know to stop routing to a dead backend, and how fast?**

option tcp-check with fall 3 rise 2 in your config means HAProxy actively probes port 6443 on each backend and needs 3 consecutive failures before marking it down (and 2 consecutive successes to mark it back up) — this hysteresis prevents a single transient blip from yanking a healthy backend out of rotation. It's the same design philosophy as Kubernetes' own node-monitor-grace-period: absorb brief noise, react to sustained failure.

**Q: What's the actual operational difference between losing 1 node (Stage B) and losing 2 (Stage F)?**

Losing 1: fully transparent, zero kubectl downtime, workloads never notice, only an alert-worthy-but-not-urgent HAProxy backend flap. Losing 2: complete write-path outage — no new pods, no scaling, no kubectl apply — until quorum is restored, even though the cluster's data plane (already-running pods) stays completely unaffected the entire time, the same isolation principle from Lab 1 held all the way through a real HA topology.







