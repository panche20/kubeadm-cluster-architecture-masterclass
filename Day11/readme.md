# Mental Model: Raft Election vs. the Lease Election From Lab 4

*These are genuinely two different mechanisms, at two different layers, and it's worth being precise about the distinction:*

```
Lab 4 (KCM/scheduler):
  Layer:      Kubernetes API object (a Lease, stored IN etcd)
  Mechanism:  client-go leaderelection library, optimistic-lock PATCH
  Visibility: kubectl get lease -n kube-system ...

Lab 8b (this lab) — etcd itself:
  Layer:      Raft consensus protocol, INSIDE etcd, below Kubernetes entirely
  Mechanism:  RequestVote RPCs between etcd peers over port 2380
  Visibility: etcdctl endpoint status -w table (IS LEADER, RAFT TERM columns)

The Lease mechanism only works BECAUSE etcd's Raft layer already
guarantees consistent, ordered writes underneath it. Raft election
is more fundamental — it's what makes etcd itself trustworthy.
```

**Raft leader election in one paragraph:**

every etcd member is a Follower, Candidate, or Leader. 
Followers expect periodic heartbeats from the Leader; if none arrive within a randomized election timeout, 
a Follower becomes a Candidate, increments a monotonically increasing term number (Raft's logical clock), 
and requests votes from peers. A Candidate becomes Leader only after receiving votes from a majority of 
the cluster — the same ⌊n/2⌋+1 quorum math from Lab 1. This term number is the key thing we're going to watch increment.

## Stage A: Baseline — Capture Term and Leader, Plus a Real Gotcha to Check

*From any control-plane node:*

```
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table
```

*Note both the IS LEADER column and the RAFT TERM column — term is the number we'll prove increments after election, exactly like acquireTime proved a new leadership term in Lab 4*

```
export RAFT_TARGET=control-plane-2   # whichever node shows IS LEADER: true
```

**Now check something that will directly predict what you're about to see** 

— how this node's own apiserver is configured to reach etcd:

```
# SSH into $RAFT_TARGET specifically
grep "etcd-servers" /etc/kubernetes/manifests/kube-apiserver.yaml
```

*This matters because kubeadm's stacked-etcd topology can configure an apiserver's 
--etcd-servers flag either as just its own localhost (https://127.0.0.1:2379) or 
as the full list of all 3 members. If it's localhost-only, killing etcd on this 
specific node will break that node's own apiserver too — even though the etcd 
cluster as a whole stays perfectly healthy on the other 2 members. Worth knowing 
before you break anything, not after.*

## Stage B: Break — Isolate Etcd Only (Not the Whole Node)

*This is the refinement over Lab 8: we use Lab 1's precise technique — pull just 
the etcd static pod manifest — so apiserver, kubelet, KCM, and scheduler on this 
node stay completely untouched. Any effect we observe is attributable to etcd alone.*

```
# === ON $RAFT_TARGET ===
sudo cp /etc/kubernetes/manifests/etcd.yaml /root/etcd-raft-lab.yaml.bak
sudo mv /etc/kubernetes/manifests/etcd.yaml /root/etcd-raft-lab-removed.yaml

echo "Raft leader's etcd isolated at: $(date)"
sudo crictl ps -a | grep etcd
```

## Stage C: Observe — Watch the Election Happen

*From a surviving control-plane node:*

```
watch -n1 'sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table'
```

*Watch for: the dead endpoint drops to a connection error, and 
— within roughly 1-2 seconds, well under etcd's default election 
timeout window — one of the two survivors' IS LEADER flips to true, 
with RAFT TERM higher than your Stage A baseline. Ctrl+C once you see it.*

```
# Confirm write-path is uninterrupted — 2/3 is still quorum
sudo ETCDCTL_API3=3 etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

kubectl get nodes
kubectl scale deployment nginx-test --replicas=6
kubectl get pods -o wide -w
# Ctrl+C once 6 Running — proves the write path never actually stalled
kubectl scale deployment nginx-test --replicas=4
```

**Now test the gotcha from Stage A**

*— run this several times in a row, since HAProxy round-robins across all 3 backends and you want to catch a request landing specifically on $RAFT_TARGET:*

```
for i in $(seq 1 10); do
  curl -sk --max-time 3 -o /dev/null -w "%{http_code}\n" https://k8s-lb:6443/livez
done
```

*If $RAFT_TARGET's apiserver was configured --etcd-servers=https://127.0.0.1:2379 (localhost-only), 
you should see occasional timeouts or non-200 codes mixed in with successes — because roughly 1 in 3 
requests get routed by HAProxy straight to the one apiserver whose local etcd is dead, and HAProxy's 
option tcp-check only verifies port 6443 accepts a TCP connection — it never checks /livez or /readyz. 
So a functionally broken apiserver that's still TCP-listening looks perfectly healthy to HAProxy and 
keeps receiving a third of the traffic. This is a real production gap in the HAProxy config we built 
— a TCP check isn't sufficient for an HTTP service with internal dependencies.*

## Stage D: Diagnose — Read the Actual Raft Election From etcd's Own Logs

*This is the strongest evidence available — the raw protocol messages, not just the summary table:*

```
# On EITHER surviving node
ETCD_ID=$(sudo crictl ps --name etcd -q)
sudo crictl logs $ETCD_ID 2>&1 | grep -iE "became candidate|became leader|elect|term" | tail -20
```

*Expected lines, in order:*

```
<id> is starting a new election at term N
<id> became candidate at term N+1
<id> received MsgVoteResp from <peer> at term N+1
<id> has received N votes and N vote rejections
<id> became leader at term N+1
```

*That's the majority-vote mechanism from the mental model, happening in real log lines on your actual cluster.*

## Stage E: Recovery — Restore, and Confirm No Preemption

```
# === ON $RAFT_TARGET ===
sudo cp /root/etcd-raft-lab.yaml.bak /etc/kubernetes/manifests/etcd.yaml

echo "etcd restored at: $(date)"
sudo crictl ps | grep etcd
```

```
# From any node — confirm it rejoined
sudo ETCDCTL_API=3 etcdctl endpoint status \
  --endpoints=https://control-plane-1:2379,https://control-plane-2:2379,https://control-plane-3:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  -w table
```

*Same lesson as Lab 4's Lease: $RAFT_TARGET rejoins as a Follower, not Leader — Raft has no preemption either. The RAFT TERM column will also now be identical across all 3 (the returning follower adopts the current term), which is worth noting explicitly — unlike IS LEADER, term isn't "whoever's oldest wins," it's a cluster-wide value everyone converges on.*

```
# Direct apiserver check on the recovered node confirms the gotcha is gone
curl -sk --max-time 3 https://127.0.0.1:6443/livez
```

## Stage F: Full Verification

```
kubectl get nodes -o wide
kubectl get pods -o wide
curl -s http://localhost:$NODEPORT | grep "<title>"

sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key -w table
```

## Interview Debrief

**Q: What is a Raft "term," and why does it matter that it only ever increases?**

A term is Raft's logical clock — every election attempt increments it, regardless of whether that attempt succeeds. It's how peers detect and reject stale information: a message carrying an old term number is automatically ignored, since anyone still on that term is behind. This is what makes it impossible for a partitioned-away former leader to come back and silently overwrite newer data — its term is provably lower, so current members reject it outright.

**Q: Why does Raft require a strict majority to elect a leader, not just "more votes than anyone else"?**

With n members split across a partition, only one side can possibly contain a majority (⌊n/2⌋+1) — the other side, by definition, cannot. Requiring majority rather than plurality guarantees at most one leader can ever exist for a given term, even under network partition, which is the core safety property that prevents split-brain writes.

**Q: How is this different from the KCM/scheduler Lease election from Lab 4?**

Raft election is a protocol-level mechanism internal to etcd, operating over dedicated peer ports (2380) with vote RPCs and terms. The Lease mechanism is application-level — it's just a Kubernetes object with a TTL, guarded by etcd's own optimistic-concurrency writes. The Lease approach is actually built on top of the guarantees Raft election provides underneath — you can't have safe leader election for KCM without a consistent, single-writer etcd already in place.

**Q: You configured HAProxy with a plain TCP health check. What's the actual risk of that, concretely?**

You just measured it directly: an apiserver whose local etcd dependency is down can still hold port 6443 open and accept TCP connections, while every actual request to it fails or times out. A TCP check sees that open port and calls it healthy. The fix in production is an HTTP-mode check against /livez or /readyz specifically (option httpchk GET /livez), which actually exercises the endpoint's real logic rather than just confirming a listener exists.





