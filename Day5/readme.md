# Lab 3: Static Pod Manifest Corruption

*Same framework* — mental model first, then break, observe, diagnose, recover, debrief. 
This lab has a twist: **the primary debugging tool is NOT kubectl.**
You'll work entirely from the node using journalctl and crictl — which is exactly what a real incident looks like when a control plane component is down.

## Mental Model: Two Distinct Failure Modes

This is the key insight that most engineers miss. 
Static pod manifest corruption has **two completely different failure signatures** depending on what's broken:

```
FAILURE MODE 1: Invalid YAML syntax
─────────────────────────────────────
kubelet reads manifest file
  → YAML parse fails
  → kubelet logs: "failed to parse manifest"
  → NO container is ever created
  → crictl ps | grep scheduler → returns NOTHING
  → kubectl get pods -n kube-system → mirror pod disappears entirely

FAILURE MODE 2: Valid YAML, bad flag/value
──────────────────────────────────────────
kubelet reads manifest file
  → YAML parses fine
  → Container is created and started
  → Process starts, reads its own flags
  → Unknown flag → process exits with code 1
  → kubelet sees exit → restarts container
  → CrashLoopBackOff
  → crictl ps -a | grep scheduler → shows Exited repeatedly
  → kubectl get pods -n kube-system → shows CrashLoopBackOff
```

This distinction matters enormously during diagnosis — the investigation path is completely different for each.

We'll do both in this lab. First the scheduler (safest component to break — cluster stays partially functional), then optionally the controller-manager.

**Why the Scheduler Is the Safest Component to Break**

```
kube-scheduler goes down:

New pods       → stay Pending forever (no one assigns nodeName)
Existing pods  → KEEP RUNNING (scheduler only assigns, never manages running pods)
kubectl        → WORKS (apiserver + etcd unaffected)
Services       → WORK (kube-proxy unaffected)
etcd           → WORKS
apiserver      → WORKS

Recovery urgency: Medium (existing workloads fine, new deployments blocked)
```

## Stage A: Pre-Lab Verification

On your control plane node:

```
# 1. Confirm cluster fully healthy after Lab 1 recovery
kubectl get nodes
kubectl get pods -n kube-system

# 2. Confirm scheduler is running
kubectl get pod -n kube-system | grep scheduler
# Expected: kube-scheduler-k8s-control-plane   1/1   Running

# 3. Inspect the real scheduler manifest — understand it before breaking it
sudo cat /etc/kubernetes/manifests/kube-scheduler.yaml

# 4. Note the exact image and flags being used
sudo grep -E "image:|command:|--" /etc/kubernetes/manifests/kube-scheduler.yaml

# 5. Verify new pod scheduling works RIGHT NOW
kubectl run pre-lab3-test --image=nginx:alpine
kubectl get pod pre-lab3-test -w
# Wait until Running, then:
kubectl delete pod pre-lab3-test

# 6. Backup the manifest — this is your recovery file
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml \
  /root/kube-scheduler.yaml.bak

# Verify backup is valid YAML
sudo python3 -c "import yaml; yaml.safe_load(open('/root/kube-scheduler.yaml.bak'))" \
  && echo "YAML valid" || echo "YAML invalid"

# 7. Checksum for verification later
sudo md5sum /etc/kubernetes/manifests/kube-scheduler.yaml
```

## Part 1: Bad Flag (CrashLoopBackOff Path)

**Stage B1: Inject a Bad Flag**

We inject an unknown flag into the scheduler command. The YAML stays valid — this is the sneaky failure mode that's harder to spot:

```
# View current scheduler command flags
sudo grep "\-\-" /etc/kubernetes/manifests/kube-scheduler.yaml

# Inject a nonexistent flag into the manifest
# We'll add --invalid-flag=chaos-test after the last real flag
sudo sed -i \
  '/- kube-scheduler/a\    - --invalid-flag=chaos-test' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# Verify the injection looks correct
sudo grep -A5 "- kube-scheduler" /etc/kubernetes/manifests/kube-scheduler.yaml
```

*Expected result in the manifest:*

```
containers:
  - command:
    - kube-scheduler
    - --invalid-flag=chaos-test    ← injected here
    - --authentication-kubeconfig=...
    - --authorization-kubeconfig=...
```

```
echo "Bad flag injected at: $(date)"

# kubelet detects manifest change within ~5 seconds
# Watch what happens
watch sudo crictl ps -a | grep scheduler
# You'll see: Created → Exited → Created → Exited (CrashLoop)
# Ctrl+C after 20 seconds
```

## Stage C1: Diagnose Bad Flag Failure

Run these in order — build the instinct for what each tool tells you:

```
# TOOL 1: kubectl — what does it show?
kubectl get pods -n kube-system | grep scheduler
# CrashLoopBackOff or Error

# TOOL 2: kubectl describe — more detail
kubectl describe pod -n kube-system \
  kube-scheduler-k8s-control-plane 2>&1 | \
  grep -A20 "Events:"
# Look for: Back-off restarting failed container

# TOOL 3: kubectl logs — can you get logs?
kubectl logs -n kube-system kube-scheduler-k8s-control-plane 2>&1
# This actually WORKS for bad-flag scenario because container starts
# then immediately exits — kubelet captures the output

# TOOL 4: crictl — raw container view
sudo crictl ps -a | grep scheduler
# Note: multiple Exited entries = crash loop evidence

# Get the container ID of most recent attempt
SCHED_ID=$(sudo crictl ps -a --name kube-scheduler -q | head -1)
echo "Most recent scheduler container: $SCHED_ID"

# TOOL 5: crictl logs — exact exit message
sudo crictl logs $SCHED_ID 2>&1 | tail -20
# THIS IS THE KEY OUTPUT
# Expected:
# unknown flag: --invalid-flag
# Usage: kube-scheduler [flags]
# ...
# Error: failed to run Scheduler

# TOOL 6: journalctl — kubelet's perspective
sudo journalctl -u kubelet --since "3 minutes ago" --no-pager | \
  grep -iE "scheduler|error|failed|backoff" | tail -20
# Shows kubelet seeing the container exit and restarting it

# TOOL 7: Prove scheduler impact — new pod stays Pending
kubectl run scheduler-test --image=nginx:alpine
kubectl get pod scheduler-test
# STATUS: Pending (no scheduler to assign it to a node)

kubectl describe pod scheduler-test | grep -A5 "Events:"
# Events: (no events at all, or "no nodes available to schedule pods")

# But existing pods still run:
kubectl get pods -o wide | grep nginx-test
# nginx-test pods: Still Running on workers
```

**What you just proved:**

<img width="846" height="302" alt="image" src="https://github.com/user-attachments/assets/61d8974c-5b8d-45ee-9846-4f4d65ab1f9a" />

## Stage D1: Recover from Bad Flag

```
# Restore the clean backup
sudo cp /root/kube-scheduler.yaml.bak \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# Verify the bad flag is gone
sudo grep "invalid-flag" /etc/kubernetes/manifests/kube-scheduler.yaml \
  && echo "FLAG STILL THERE - DO NOT PROCEED" \
  || echo "Flag removed - manifest clean"

# Verify YAML is still valid
sudo python3 -c \
  "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-scheduler.yaml'))" \
  && echo "YAML valid" || echo "YAML invalid - fix before proceeding"

# Watch scheduler recover
watch kubectl get pods -n kube-system | grep scheduler
# Goes from CrashLoopBackOff → Running
# Ctrl+C

echo "Scheduler recovered at: $(date)"
```

*Verify scheduling works again:*

```
# That pending pod from earlier should now get scheduled
kubectl get pod scheduler-test -w
# Should transition: Pending → ContainerCreating → Running

kubectl delete pod scheduler-test
```

## Part 2: Invalid YAML Syntax (The Harder Failure Mode)

This is more dangerous because kubectl shows you nothing — the mirror pod completely disappears and most engineers don't know where to look next.

**Stage B2: Inject Invalid YAML**

```
# Backup current (clean) manifest first
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml \
  /root/kube-scheduler.yaml.bak

# CORRUPT THE YAML with invalid indentation/syntax
# We'll add a line that breaks YAML structure
sudo sed -i \
  '1a this is not valid yaml: [broken: {syntax' \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# Verify it's actually broken
sudo python3 -c \
  "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-scheduler.yaml'))" \
  2>&1
# Expected: yaml.scanner.ScannerError: ...

echo "YAML corrupted at: $(date)"
```

## Stage C2: Diagnose Invalid YAML — No kubectl Help

This is where it gets hard. Run these in order:

```
# TOOL 1: kubectl — mirror pod is just GONE
kubectl get pods -n kube-system | grep scheduler
# Returns NOTHING — no mirror pod exists because
# kubelet couldn't parse the manifest into a pod spec

# TOOL 2: crictl — no container either
sudo crictl ps -a | grep scheduler
# Returns NOTHING — no container was ever created

# This is the dangerous moment: both kubectl AND crictl show nothing
# A junior engineer concludes: "scheduler was never installed"
# A senior engineer knows: check kubelet logs immediately

# TOOL 3: journalctl — THIS IS WHERE THE TRUTH IS
sudo journalctl -u kubelet --since "3 minutes ago" --no-pager | \
  grep -iE "scheduler|manifest|error|parse|failed" | tail -20
# EXPECTED KEY LINE:
# "Failed to process manifest" kube-scheduler.yaml
# "couldn't parse as pod(yaml: line X: did not find expected key)"

# TOOL 4: Check the manifest directory directly
sudo ls -la /etc/kubernetes/manifests/
# kube-scheduler.yaml IS there (file exists, content is just invalid)

# TOOL 5: Validate the manifest manually
sudo python3 -c \
  "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-scheduler.yaml'))" \
  2>&1
# Exact error + line number of the YAML problem

# TOOL 6: More detailed YAML lint
sudo cat -n /etc/kubernetes/manifests/kube-scheduler.yaml | head -20
# See the corrupted line with line numbers
# The broken line is visible at the top

# TOOL 7: Prove impact (same as bad flag — scheduling dead)
kubectl run yaml-test --image=nginx:alpine
kubectl get pod yaml-test
# Pending — no scheduler
kubectl delete pod yaml-test
```

*The critical diagnostic distinction:*

```
Bad Flag:                     Invalid YAML:
─────────────────────────     ─────────────────────────
kubectl → CrashLoopBackOff    kubectl → pod MISSING entirely
crictl  → Exited repeatedly   crictl  → NO containers at all
logs    → "unknown flag: X"   logs    → NOT AVAILABLE (no container)
fix     → edit manifest flag  fix     → fix YAML structure

Both diagnosed via: journalctl -u kubelet
```

## Stage D2: Recover from Invalid YAML

**Path 1 — Restore from backup (fastest):**

```
# Restore clean backup
sudo cp /root/kube-scheduler.yaml.bak \
  /etc/kubernetes/manifests/kube-scheduler.yaml

# Validate immediately
sudo python3 -c \
  "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-scheduler.yaml'))" \
  && echo "YAML valid — kubelet will pick this up" \
  || echo "Still broken — do not proceed"
```

**Path 2 — Fix in-place (when no backup — real incident scenario):**

```
# See the corrupted line
sudo cat -n /etc/kubernetes/manifests/kube-scheduler.yaml | head -10

# Remove the bad first line we injected
sudo sed -i '2d' /etc/kubernetes/manifests/kube-scheduler.yaml
# Note: line 2 because our sed -i '1a' inserted after line 1

# Validate
sudo python3 -c \
  "import yaml; yaml.safe_load(open('/etc/kubernetes/manifests/kube-scheduler.yaml'))" \
  && echo "YAML valid" || echo "Still broken"
```

**Watch recovery:**

```
# kubelet detects the valid manifest within 5-10 seconds
watch kubectl get pods -n kube-system | grep scheduler
# Nothing → Pending → Running
# Ctrl+C

echo "Scheduler recovered at: $(date)"
```

## Troubleshooting :

At this stage, your scheduler pods won't show up now.

**Please run below command:**

```
sudo journalctl -u kubelet --since "5 minutes ago" --no-pager | grep -iE "scheduler|manifest|parse|error" | tail -n 20
```

*Please analyze the logs & you'll find the kube-scheduler yaml has syntax missing*

*Please add Kind: Pod*

```
apiVersion: v1
kind: Pod          # <-- THIS WAS MISSING
metadata:
  creationTimestamp: null
  labels:
    component: kube-scheduler
    tier: control-plane
  name: kube-scheduler
  namespace: kube-system
spec:
  containers:
  - command:
    - kube-scheduler
...
```
## Stage E: Full Recovery Verification

```
# 1. Scheduler pod Running?
kubectl get pods -n kube-system | grep scheduler

# 2. Scheduling works?
kubectl run lab3-verify --image=nginx:alpine
kubectl get pod lab3-verify -w
# Pending → ContainerCreating → Running

# 3. Which node did scheduler pick?
kubectl get pod lab3-verify -o wide
# Should land on worker-1 or worker-2

# 4. Cleanup
kubectl delete pod lab3-verify

# 5. All system pods healthy?
kubectl get pods -n kube-system

# 6. Manifest checksum matches original?
sudo md5sum /etc/kubernetes/manifests/kube-scheduler.yaml
# Compare with Stage A baseline checksum
```

## Bonus: Break the controller-manager (Optional Extension)

If you want to go deeper right now — the KCM failure is more impactful and teaches reconciliation failure:

```
# Break KCM with a bad flag
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml \
  /root/kube-controller-manager.yaml.bak

sudo sed -i \
  '/- kube-controller-manager/a\    - --invalid-flag=chaos-test' \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

# Observe:
# 1. KCM goes CrashLoopBackOff
kubectl get pods -n kube-system | grep controller

# 2. Deploy a deployment and scale it
kubectl scale deployment nginx-test --replicas=8
kubectl get pods -o wide
# Pods stay at current count — KCM's ReplicaSet controller is dead
# New pods are NOT created because no one is reconciling desired vs actual

# 3. Restore
sudo cp /root/kube-controller-manager.yaml.bak \
  /etc/kubernetes/manifests/kube-controller-manager.yaml

# 4. Watch KCM recover and immediately reconcile
kubectl get pods -o wide -w
# Suddenly 8 pods appear — KCM catches up on missed reconciliation instantly

# 5. Scale back to 4
kubectl scale deployment nginx-test --replicas=4
```

## Interview Debrief

**Q: A control plane component is missing from kubectl get pods -n kube-system. Where do you look?**

```
1. journalctl -u kubelet | grep <component>
   → "failed to parse manifest" = invalid YAML
   → nothing = manifest file itself is missing

2. Check if manifest exists:
   ls /etc/kubernetes/manifests/

3. Validate manifest:
   python3 -c "import yaml; yaml.safe_load(open('<manifest>'))"

4. If YAML valid but component not showing:
   crictl ps -a | grep <component>
   → CrashLoopBackOff path = bad flag or bad config value
```

**Q: What's the difference between kubectl logs working and not working for a crashlooping static pod?**

Bad flag → container starts briefly, logs are captured before exit → kubectl logs works. Invalid YAML → no container ever created → no logs anywhere, not even in crictl → journalctl -u kubelet is the only source of truth.

**Q: Can you edit a static pod manifest with kubectl edit?**

No — kubectl edit pod kube-scheduler-k8s-control-plane -n kube-system edits the mirror pod which is read-only. Changes don't persist. You must edit the file directly in /etc/kubernetes/manifests/ on the node. This is a guaranteed CKA trap question.

**Q: How quickly does kubelet detect a manifest change?**

kubelet polls staticPodPath every --file-check-frequency seconds — default 20 seconds. So a manifest change takes up to 20 seconds to take effect. If recovery seems slow, this is why.

## Diagnostic Decision Tree for Control Plane Component Down

```
kubectl get pods -n kube-system shows component:

MISSING entirely?
  └── journalctl -u kubelet | grep <component>
        ├── "failed to parse manifest" → INVALID YAML → fix syntax
        └── no output → manifest file missing → restore from backup

CrashLoopBackOff?
  └── crictl logs <container-id>
        ├── "unknown flag" → bad flag → remove from manifest
        ├── "permission denied" → cert/file ownership issue
        ├── "connection refused" → dependency down (etcd?)
        └── "invalid configuration" → bad value in config file

Running but misbehaving?
  └── kubectl logs + metrics + audit log
```






