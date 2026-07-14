# Lab 7: cgroup Driver Mismatch

```
This is the lab you'll actually use in your career.
Every time someone patches containerd, reimages a node, or upgrades the OS,
this is the failure waiting to happen — and it's uniquely tricky because the node often stays Ready.
Nothing looks wrong at the node level. Only container creation silently fails.
```

## Mental Model: The Two Cgroup Managers Problem

```
Ubuntu 22.04 boots with systemd as PID 1
       │
       └── systemd manages cgroups v2 (unified hierarchy) natively
             /sys/fs/cgroup/system.slice/
             /sys/fs/cgroup/kubepods.slice/

Now two more processes ALSO want to manage cgroups for containers:

kubelet          → creates cgroup structure for pod QoS classes
containerd/runc  → creates cgroup structure for individual containers

If kubelet says "systemd" and containerd says "systemd" too:
  → Both delegate cgroup creation to systemd via dbus calls
  → ONE authority manages the hierarchy → stable

If kubelet says "systemd" but containerd says "cgroupfs":
  → containerd tries to write raw paths directly to /sys/fs/cgroup/
  → systemd (which owns the unified hierarchy) doesn't know about these
  → systemd can rewrite/reset paths containerd just created
  → TWO managers fighting over the same resource → instability

This is THE real production trigger:
  apt upgrade containerd.io
    → package upgrade OVERWRITES /etc/containerd/config.toml
    → your manually-set SystemdCgroup=true is WIPED
    → reverts to default: SystemdCgroup=false
    → kubelet config (separate file) is untouched, still says systemd
    → MISMATCH — and nobody touched Kubernetes at all
```

**The critical diagnostic insight:** 

the node keeps heartbeating fine (kubelet process itself is healthy) — only container creation on that node starts failing. 
This looks completely different from Lab 5's NotReady scenario.

## Pre-Lab Baseline — Adapted to Your Actual Node Names

```
# Confirm current effective state
sudo containerd config dump 2>/dev/null | grep "SystemdCgroup" \
  || grep "SystemdCgroup" /etc/containerd/config.toml
# Expected: SystemdCgroup = true

grep cgroupDriver /var/lib/kubelet/config.yaml
# Expected: cgroupDriver: systemd

# Backup both — your recovery path
sudo cp /etc/containerd/config.toml /root/containerd-config.toml.bak
sudo cp /var/lib/kubelet/config.yaml /root/kubelet-config.yaml.bak
```

*From the control plane (master), confirm cluster health and deploy the test workload if you haven't already:*

```
kubectl get nodes -o wide
kubectl create deployment nginx-test --image=nginx:alpine --replicas=4
kubectl expose deployment nginx-test --port=80 --type=NodePort
kubectl get pods -o wide
```

## Stage B: Break worker-2

Get the NodePort first, from master:

```
export NODEPORT=$(kubectl get svc nginx-test -o jsonpath='{.spec.ports[0].nodePort}')
echo "NodePort: $NODEPORT"

curl -s http://172.31.35.201:$NODEPORT | grep "<title>"
# Confirm worker-2 is serving traffic before we touch anything
```

*Now SSH into worker-2 and flip the driver:*

```
# === ON WORKER-2 ===

sudo grep "SystemdCgroup" /etc/containerd/config.toml
# Confirm: SystemdCgroup = true (baseline)

sudo sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' /etc/containerd/config.toml

grep "SystemdCgroup" /etc/containerd/config.toml
# Now shows: SystemdCgroup = false

sudo systemctl restart containerd

# Verify via the effective dump — your containerd 1.7.28 always reflects
# the static file directly here, no schema ambiguity this time
sudo containerd config dump | grep "SystemdCgroup"
# Must show: false

sudo systemctl status containerd --no-pager | head -5
# Still Active — containerd starts fine regardless of the setting

echo "Mismatch created at: $(date)"
```

*kubelet on worker-2 is untouched — still cgroupDriver: systemd. Mismatch is live.*

## Stage C: Observe (from master)

```
# Node status — predict, then check
kubectl get nodes
# worker-2 almost certainly still Ready

# Existing pods on worker-2 — did they survive?
kubectl get pods -o wide | grep worker-2
curl -s http://172.31.35.201:$NODEPORT | grep "<title>"
# Should still respond — existing containers' cgroups were already
# established before the break; only NEW container creation is affected

# Force a NEW pod onto worker-2 specifically
kubectl run mismatch-test --image=nginx:alpine \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}'

kubectl get pod mismatch-test -w
# Pending → ContainerCreating → stuck
# Ctrl+C after ~20 seconds

kubectl describe pod mismatch-test | grep -A15 "Events:"
```

*Control test on worker-1 to prove it's node-specific:*

```
kubectl run control-test --image=nginx:alpine \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-1"}}}'
kubectl get pod control-test -o wide
# Running — confirms cluster-wide health is fine, only worker-2 is broken
```

*Ideally, this should stuck (kubectl get pod mismatch-test)*

**The Short Answer**

The mismatch direction we created — kubelet: systemd, containerd/runc: cgroupfs — usually does not crash pod creation. 
It silently succeeds with a broken cgroup hierarchy. The loud "FailedCreatePodSandBox / unable to apply cgroup configuration"
failure I described earlier is real, but it's much more reliably triggered in the opposite direction. I oversimplified the 
mechanism — let me explain precisely why, then show you how to prove the damage is still there even though the pod says Running.

**Why It Doesn't Crash**

Two separate things are happening:

**1. The old "hard crash" you were expecting was a dockershim artifact, not a containerd/CRI thing.**

Every GitHub issue with the loud error misconfiguration: kubelet cgroup driver: "X" is different from docker cgroup driver: "Y" — the classic hard-fail signature — comes from dockershim. Dockershim explicitly queried Docker's own reported cgroup driver at kubelet startup and refused to boot on a mismatch. Dockershim was removed in Kubernetes 1.24. Your cluster talks to containerd directly via CRI, and plain CRI has no equivalent startup cross-check — kubelet just uses its own static cgroupDriver setting and never asks containerd what it's actually configured for. (Kubernetes v1.34 finally closes this gap with an official CRI RuntimeConfig auto-detection feature, now GA — but that requires containerd v2.0+, and you're on containerd 1.7.28 with cluster v1.33, so it doesn't apply here.)

**2. runc's cgroupfs manager doesn't validate the path — it just creates a directory.**

When kubelet is set to systemd, it hands containerd a cgroup parent formatted as a systemd unit name, like kubepods-besteffort-pod<uid>.slice. With SystemdCgroup = false, runc's cgroupfs manager treats that string as a literal directory name and does a raw mkdir — it doesn't know or care that it looks like a systemd slice name. mkdir succeeds. The pod runs.

What you get instead is exactly what the official Kubernetes docs describe for this scenario: "the system gets two different cgroup managers... two different views of the available and in-use resources... nodes configured this way become unstable under resource pressure." Not a crash — a slow-motion, load-dependent corruption. Arguably worse in production, because nothing pages you until things get bad under load.

**Let's Prove the Damage Is Actually There**

*On master, get both pods' UIDs:*

```
kubectl get pod mismatch-test control-test \
  -o custom-columns=NAME:.metadata.name,UID:.metadata.uid,NODE:.spec.nodeName
```

*On worker-2, find what containerd actually requested vs what actually landed on disk:*

```
# What kubelet TOLD containerd to use as the cgroup parent
sudo crictl inspectp $(sudo crictl pods --name mismatch-test -q) | \
  python3 -m json.tool | grep -i cgroup

# What ACTUALLY got created on the filesystem — search broadly,
# use just the first chunk of the UID so it matches regardless of formatting
sudo find /sys/fs/cgroup -maxdepth 6 -iname "*<first-8-chars-of-uid>*" 2>/dev/null
```

*Then check whether systemd — the one true cgroup manager on this box — even knows this cgroup exists:*

```
systemctl status "kubepods*" 2>&1 | head -20
# Try the exact slice name find turned up above:
systemctl status "<slice-name-you-found>"
```

If it's the raw-mkdir'd path, systemd will say the unit doesn't exist — even though the directory is sitting right there in /sys/fs/cgroup and the pod is happily Running. That gap between "systemd's view" and "what's actually on disk" is the entire bug. This is the demonstrable proof, not a crash log.

For comparison, run the same three commands against control-test on worker-1, where the driver matches. There, systemctl status will find the slice properly, since containerd's systemd manager created it through systemd's own dbus API instead of raw mkdir.

**To See the Loud Crash**

The direction that's much more likely to hard-fail is the reverse: kubelet: cgroupfs, containerd/runc: systemd. There, runc's systemd manager takes whatever plain path string kubelet hands it and tries to register it as a systemd transient unit via dbus — and a raw cgroupfs-style path (with slashes, no .slice suffix) is not a valid systemd unit name, so the dbus call itself fails. That failure surfaces through containerd as exactly the OCI runtime create failed: unable to apply cgroup configuration error from the original lab writeup.
Want to run that direction next, on worker-2, after we restore it from your .bak files? That'll give you both failure modes side by side — which is honestly the more useful lesson than either one alone.


**What the systemctl status Command Was Actually Checking**

Quick plain-language answer to your second question first: systemctl status <name> asks systemd — the one true cgroup authority on the machine — "do you have a record of managing a cgroup by this name?" If containerd created the cgroup through systemd (via its dbus API, which is what SystemdCgroup = true does), systemd knows about it and systemctl status shows it as a real unit. If containerd instead did a raw mkdir directly on the filesystem (which is what SystemdCgroup = false does), the directory exists, but systemd was never told — systemctl status says "could not be found" even though ls on the same path shows it right there. That gap — filesystem says yes, systemd says no — is the corruption. It's the concrete, provable version of "two cgroup managers with two different views of the system" that the Kubernetes docs warn about. That was the point of checking it. But I skipped the step of actually finding the real name first, so let's fix that now.

**Finding Ground Truth Instead of Guessing**

On worker-2, run these in order — each one feeds the next, no placeholders:

```
# STEP 1: Get the sandbox ID for mismatch-test
POD_ID=$(sudo crictl pods --name mismatch-test -q)
echo "Sandbox ID: $POD_ID"

# STEP 2: Ask containerd what cgroup parent kubelet actually told it to use
# (this string is generated by kubelet's OWN driver setting — fixed, regardless
#  of what containerd's SystemdCgroup is set to)
sudo crictl inspectp $POD_ID | grep -i cgroup_parent
```

Paste that output — it'll look something like *kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice.* 
That's the exact string we need for everything downstream, and I don't want to guess its exact format again.

```
# STEP 3: Get the actual container ID (different from the pod/sandbox ID)
sudo crictl ps -a --name mismatch-test
```

Copy the CONTAINER column value from that output.

```
# STEP 4: Search WITHOUT depth limits or narrow filters this time —
# cast a wide net using fragments from steps 2 and 3
sudo find /sys/fs/cgroup -iname "*besteffort*" 2>/dev/null
sudo find /sys/fs/cgroup -iname "*mismatch*" 2>/dev/null

# STEP 5: If step 4 finds nothing at the top level, containerd's own process
# is likely confined under its own systemd-delegated cgroup, and everything
# it creates lands INSIDE that — not at /sys/fs/cgroup root. Check there:
sudo find /sys/fs/cgroup/system.slice/containerd.service -maxdepth 5 2>/dev/null
```

That last one is my actual best guess for why your first search came up empty — cgroups v2 delegation means a process (containerd) generally can only create sub-cgroups within its own current cgroup, not wherever it wants at the root. If SystemdCgroup=false made runc try to create a systemd-style name as a literal directory, it likely landed nested inside containerd's own slice rather than as a top-level kubepods.slice sibling.

Run these five steps and paste the output of each — I'd rather work from what your actual node shows than keep predicting the exact path from memory. Once we see where it really landed (or confirm it truly doesn't exist anywhere), we'll know precisely what broke and can run the matching systemctl status check against the real name.

**What You Actually Found**

Look closely at the two different results from your two find commands. They're not duplicates — they're two separate cgroups for the same pod, created by two different, uncoordinated actors:

```
CORRECT-LOOKING ONE (kubelet created this):
/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice

MALFORMED ORPHAN (containerd/runc created this):
/sys/fs/cgroup/system.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice:cri-containerd:422f014a8a6a969823e699f603000dafdfc19c6d5df9b487ccda2e4a4649405b
/sys/fs/cgroup/system.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice:cri-containerd:14b3eb60b39107fe31edcd5096a17885591f33257f39cf1b9998641cabf67901
```

Here's why both exist: kubelet manages a top-level QoS cgroup independently of the container runtime. It uses its own systemd driver setting to create kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-podXXX.slice for tracking and eviction purposes — that happens correctly, because kubelet's setting was never wrong.

Separately, containerd's runc shim gets the cgroup parent string from the CRI sandbox config (/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod...slice) and appends its own suffix for the actual container: <parent>:cri-containerd:<container-id>. With the systemd driver, runc would parse those colons as a structured instruction and register a proper transient unit inside that parent slice via dbus. With cgroupfs — what we broke it to — runc has no idea that colon-joined string means anything special. It just does a literal mkdir using the whole string, colons included, as one flat directory name. Since runc/containerd don't control where it lands relative to the intended hierarchy, it falls back to wherever it can write — a sibling under system.slice, nowhere near kubepods.slice at all.

**So there are now two cgroups claiming to represent the same pod, created by two managers that never talked to each other.**

That's not a guess — it's exactly what your find output shows.

**The Question That Actually Matters: Where Does the Real Process Live?**

```
# Get the real container's PID
sudo crictl inspect 14b3eb60b3910 | grep -m1 '"pid"'
```

Then check which cgroup that PID is actually in:

```
cat /proc/<PID-from-above>/cgroup
```

I'd bet on the malformed system.slice/... path, not the "correct-looking" kubepods.slice one. Confirm it directly by checking which directory actually holds the process:

```
echo "--- kubelet's cgroup (the one it THINKS the pod is in) ---"
sudo cat "/sys/fs/cgroup/kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice/cgroup.procs"

echo "--- containerd's actual cgroup (where the process REALLY is) ---"
sudo cat "/sys/fs/cgroup/system.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice:cri-containerd:14b3eb60b39107fe31edcd5096a17885591f33257f39cf1b9998641cabf67901/cgroup.procs"
```

**Why This Matters — the Real Consequence**

If the first cgroup.procs comes back empty and the second one has the actual PID, here's what that means in production terms: kubelet's eviction manager, kubectl top pod, and cAdvisor all read resource usage from the kubepods.slice hierarchy — the one kubelet itself manages. If the real container process is living in the orphaned system.slice cgroup instead, then as far as Kubernetes' own resource accounting is concerned, this pod is using zero CPU and zero memory, no matter how much it's actually consuming. Memory pressure eviction thresholds, requests/limits enforcement expectations, and kubectl top all go blind for this specific pod. That's the "two cgroup managers, two views of the system" line from the official docs — except now you have the exact filesystem paths proving it on your own node instead of trusting the sentence.

**Closing the Loop on systemctl status**

Now that we have the real path, this will make sense:

```
systemctl status "kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice"
```

That should find the kubelet-created one fine (kubelet used systemd's dbus API correctly). But the second, malformed path was never created through systemd at all — it was a raw mkdir by runc — so systemd has zero record of it, even though it's sitting right there on disk with a process running inside it. That mismatch between "what systemd knows about" and "what's actually on disk holding your container" is the entire bug, made concrete.

Run the PID check above and paste the result — that's the single command that turns this from a plausible theory into a confirmed finding on your actual cluster.

**Correcting My Own Instruction First**

crictl inspect's "pid": 1 is the process ID inside the container's own PID namespace — every container's main process is always PID 1 from its own point of view, by design. That's not the host PID. /proc/1/cgroup on the host is always systemd itself (init.scope), which is exactly what you saw — that command told us nothing about the container. My mistake for not catching that when I gave you the command.

Good news: we don't need it. You already captured the real, host-level ground truth two steps earlier:

```
--- containerd's actual cgroup (where the process REALLY is) ---
11040
11077
11078
```

Those are real host PIDs (nginx's master + worker processes). They're only listed in cgroup.procs for one cgroup — the malformed system.slice/...:cri-containerd:... one. The kubelet-managed kubepods.slice/... cgroup's cgroup.procs came back completely empty. That's already the proof, straight from the kernel.

**The Smoking Gun Is Actually in Your systemctl status Output**

*Look at this again closely:*

```
Active: active since Tue 2026-07-14 05:37:09 UTC; 24min ago
Tasks: 0
Memory: 0B (peak: 0B)
CPU: 0
CGroup: /kubepods.slice/kubepods-besteffort.slice/kubepods-besteffort-pod9b8ec925...slice
```

Read that literally: systemd created this slice correctly, has it loaded, marked Active, has been tracking it for 24 minutes — and it has held zero tasks, zero memory, zero CPU the entire time. Not because nginx isn't running — you just proved with cgroup.procs that it's very much running, with three live PIDs. It's because those PIDs were never placed inside this slice. They're living in the orphan cgroup under system.slice that systemd has no record of at all.

So there are, right now, two real things both claiming to represent this one pod:

```
kubepods.slice/.../kubepods-besteffort-pod...slice
  → systemd-managed, properly tracked, ACTIVE, EMPTY (0 tasks)

system.slice/kubepods-besteffort-pod...slice:cri-containerd:<id>
  → raw mkdir'd by runc, invisible to systemd, HOLDS THE ACTUAL RUNNING PROCESS
```

One quick final confirmation, straight from the kernel, using a real PID instead of the namespace-relative one:

```
cat /proc/11040/cgroup
```

That should print 0::/system.slice/kubepods-besteffort-pod9b8ec925_84c5_4850_8a55_04496020600d.slice:cri-containerd:14b3eb60b39107fe31edcd5096a17885591f33257f39cf1b9998641cabf67901 — the kernel's own authoritative answer to "which cgroup is PID 11040 actually in," independent of anything crictl or systemd report.

**Why This Is a Real Production Landmine**

kubelet's eviction manager, kubectl top pod, and cAdvisor all read resource usage by walking the kubepods.slice hierarchy — the one systemd is tracking, the one currently reporting Memory: 0B. If you have metrics-server installed, try it now:

```
kubectl top pod mismatch-test
```

I'd expect either 0m / 0Mi, or an error — because as far as the accounting path is concerned, this pod isn't consuming anything, no matter how much CPU or memory it's actually using in its real, orphaned cgroup. Memory-pressure eviction thresholds never trigger for it. Any resources.limits you'd set on this pod would be silently unenforced, since the enforcement mechanism (cgroup controllers) lives on the cgroup nobody's tracking. This is precisely the "two cgroup managers, two views of the system, unstable under resource pressure" language from the official Kubernetes docs — except now you have the exact paths and PIDs proving it on your own node, not just the sentence.

**Where To Go From Here**

You've now fully demonstrated the silent-corruption failure mode — arguably the more valuable of the two, since it's the one that actually bites people in production without warning. Two options:

- Recover worker-2 now and move on — restore from your .bak files, confirm mismatch-test gets properly re-created with a matching cgroup.
- Run the reverse direction (kubelet: cgroupfs, containerd/runc: systemd) to see the loud crash signature for contrast, before recovering.

Good — let's do this properly, in order: finish recovering Direction 1 cleanly first (so we're not stacking two experiments on top of unresolved state), then break Direction 2 with eyes open about the bigger blast radius this one carries.

**Part A: Recover Direction 1 (worker-2, containerd side)**

```
# === ON WORKER-2 ===

sudo cp /root/containerd-config.toml.bak /etc/containerd/config.toml
sudo systemctl restart containerd

sudo containerd config dump | grep "SystemdCgroup"
# Must show: true
```

The orphaned mismatch-test pod's sandbox was created while the mismatch was live — restarting containerd doesn't retroactively fix an already-split cgroup. The official guidance is explicit that restarting won't repair this; you delete and recreate:

```
# === ON MASTER ===
kubectl delete pod mismatch-test

kubectl run recovery-verify --image=nginx:alpine \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}'

kubectl get pod recovery-verify -o wide -w
# Ctrl+C once Running
```

Confirm it's a single, correctly-nested cgroup this time — no split:

```
# === ON WORKER-2 ===
POD_ID=$(sudo crictl pods --name recovery-verify -q)
sudo crictl inspectp $POD_ID | grep -i cgroup_parent
sudo crictl ps -a --name recovery-verify

# Should find exactly ONE match now, correctly under kubepods.slice
sudo find /sys/fs/cgroup -iname "*besteffort*" 2>/dev/null | grep -v -E "5807ccf4|36b7e596|d3e2cba5|23b4c409|14bfcea0|37f2bb7c"
```

```
systemctl status "kubepods-besteffort-pod<recovery-verify's-uid-with-underscores>.slice"
# Should now show real, non-zero Tasks/Memory/CPU
```

Sanity-check the original nginx-test replicas on worker-2 were never affected (they were created before the break, matching driver at creation time):

```
kubectl get pods -o wide | grep worker-2
curl -s http://172.31.35.201:$NODEPORT | grep "<title>"
```

Clean up:

```
kubectl delete pod recovery-verify control-test --ignore-not-found
```

**Part B: Reverse Direction — kubelet: cgroupfs, containerd: systemd**

Read this before running anything. Direction 1 only touched containerd — kubelet itself stayed healthy the whole time, so only new pod creation was affected. This experiment flips kubelet's own driver and restarts kubelet — the process managing every pod on the node, including your two live nginx-test replicas. The official Kubernetes docs explicitly warn that changing a joined node's cgroup driver "can cause errors when trying to re-create the Pod sandbox for existing pods" and that "restarting the kubelet may not solve such errors" — their stated fix is to replace the node. We're not going to need to replace anything (we have backups and full control), but go in expecting this one to be messier than Direction 1, not cleaner.

I also want to be upfront: unlike Direction 1, I don't have a verified-on-your-node answer for exactly how this fails yet. My best mechanical prediction is that runc's systemd manager will reject a plain cgroupfs-style path string via its dbus call, producing the OCI runtime create failed: unable to apply cgroup configuration signature — but let's actually watch it happen rather than assume, the way we did for Direction 1.

```
# === ON WORKER-2 ===

# Confirm clean baseline before this new break
sudo containerd config dump | grep SystemdCgroup
# true

grep cgroupDriver /var/lib/kubelet/config.yaml
# systemd

# Flip KUBELET's driver this time
sudo sed -i 's/cgroupDriver: systemd/cgroupDriver: cgroupfs/' /var/lib/kubelet/config.yaml
grep cgroupDriver /var/lib/kubelet/config.yaml
# cgroupfs

echo "Restarting kubelet with mismatched driver at: $(date)"
sudo systemctl restart kubelet
```

**Watch immediately — this is the important window:**

```
sudo systemctl status kubelet --no-pager | head -10
sudo journalctl -u kubelet --since "1 minute ago" --no-pager | grep -iE "cgroup|error" | tail -30
```

From master, in parallel:

```
kubectl get nodes -w
# Ctrl+C once you see the outcome — Ready throughout, or a blip?
```

```
kubectl get pods -o wide | grep worker-2
# Did the existing nginx-test replicas survive the kubelet restart?
```

Now test new pod creation specifically:

```
kubectl run reverse-mismatch-test --image=nginx:alpine \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}'

kubectl get pod reverse-mismatch-test -w
# Ctrl+C after ~20 seconds
```

```
kubectl describe pod reverse-mismatch-test | grep -A15 "Events:"
```

Prediction confirmed exactly — and the blast radius is bigger than either of us initially framed it as. Let's read the evidence carefully before recovering, because there are two distinct failures stacked here, not one.

**Confirming the Predicted Mechanism**

```
runc create failed: expected cgroupsPath to be of format "slice:prefix:name"
for systemd cgroups, got "/kubepods/besteffort/pod<uid>/<container-id>" instead: unknown
```

Exactly as predicted: kubelet (now cgroupfs) generated a plain nested path string. runc, still configured SystemdCgroup = true on the containerd side, tried to parse it as a systemd unit name via dbus, and rejected it outright because it doesn't match slice:prefix:name. Clean, loud, immediate — the mirror image of Direction A's silent corruption.

**The Bigger Story: This Wasn't Just "New Pods Fail"**

Look at which pods appear in that log — not just reverse-mismatch-test, but pods that were already running:

```
nginx-test-69fbd4bd85-p56vx   (existing, was serving traffic)
nginx-test-69fbd4bd85-trgcx   (existing, was serving traffic)
csi-node-driver-bnqqr         (calico-system — the CNI's own pod)
whisker-79c9bbd75b-spv78      (calico-system)
```

When kubelet restarts with a different cgroup driver identity, it doesn't just apply the new driver going forward — it re-validates every pod it's supposed to be managing on that node, and every single one got hit with the same rejected-path error trying to recreate its sandbox. This is exactly the scenario the official docs warn about: "if the kubelet has created Pods using the semantics of one cgroup driver, changing the container runtime driver can cause errors when trying to re-create the Pod sandbox for existing pods... restarting the kubelet may not solve such errors." You just watched that sentence happen, with your own log lines as proof.

And this is why nginx-test-... shows 0/1 Completed, not CrashLoopBackOff: kubelet's per-pod worker backs off exponentially after repeated sync failures — pod_workers.go:1301 "Error syncing pod, skipping" in your log is that backoff kicking in. The container's last real exit (graceful shutdown before the doomed sandbox recreation attempt) was a clean exit 0, so that's the status frozen on screen between retries. It's not actually "done" — it's stuck, waiting to retry and fail again.

**The Real Damage: Calico Went Down Too — And Took the Node's Schedulability With It**

This is the part worth sitting with. Your reverse-mismatch-test didn't fail with FailedCreatePodSandBox — it failed with FailedScheduling:

```
1 node(s) had untolerated taint {node.kubernetes.io/network-unavailable: }
```

worker-2 now carries a network-unavailable taint. Here's the causal chain: csi-node-driver and whisker are Calico's own per-node agents — they also failed to get sandboxes recreated (same log evidence above). With Calico's node agent down, nothing can confirm this node's pod-route programming is healthy, so the node gets automatically tainted network-unavailable — which blocks scheduling of any new pod there, completely independent of the cgroup issue. The mismatch didn't just break application pods; it broke the CNI itself, which cascaded into full node-level scheduling lockout.

And notice: kubectl get nodes still shows worker-2  Ready. Same lesson as the very first cgroup lab, sharper this time — kubelet's heartbeat (Ready) and a node's actual ability to run workloads are two completely different signals. This node is Ready and simultaneously unable to run a single new pod or keep its existing ones alive.

## Recovery — In Order

**Step 1 — Revert kubelet's driver on worker-2:**

```
sudo cp /root/kubelet-config.yaml.bak /var/lib/kubelet/config.yaml
grep cgroupDriver /var/lib/kubelet/config.yaml
# systemd

sudo systemctl restart kubelet
```

**Step 2 — Watch it actually recover, don't assume:**

```
sudo journalctl -u kubelet -f
# Watch for CreatePodSandbox attempts succeeding now — Ctrl+C once they do
```

**Step 3 — From master, confirm the taint clears once Calico's own pods recover:**

```
kubectl get pods -n calico-system -o wide | grep worker-2
# csi-node-driver, whisker should transition back to Running

kubectl describe node worker-2 | grep -A5 Taints
# network-unavailable should be gone once Calico reports healthy
```

**Step 4 — Force-refresh the stuck nginx-test pods.**

They may not self-heal cleanly out of the backoff state; a delete lets the ReplicaSet create fresh ones with a correct sandbox from scratch:

```
kubectl get pods -o wide | grep worker-2
# check current state first — they may have already recovered on their own

kubectl delete pod nginx-test-69fbd4bd85-p56vx nginx-test-69fbd4bd85-trgcx \
  --force --grace-period=0 --ignore-not-found

kubectl get pods -o wide -w
# Ctrl+C once new replicas are Running
```

**Step 5 — Clean up the stuck test pod and verify a genuinely fresh pod schedules correctly:**

```
kubectl delete pod reverse-mismatch-test --ignore-not-found

kubectl run final-verify --image=nginx:alpine \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"worker-2"}}}'
kubectl get pod final-verify -o wide -w
```

**Step 6 — Full health check:**

```
kubectl get nodes -o wide
kubectl get pods -A -o wide | grep -v Running
curl -s http://172.31.35.201:$NODEPORT | grep "<title>"
kubectl delete pod final-verify
```

