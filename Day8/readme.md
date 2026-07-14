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


















