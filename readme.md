# Expert Roadmap: Every Element of a kubeadm HA Cluster

This is your SME blueprint. Master this and you can answer any CKA troubleshooting question or Staff-level interview question about Kubernetes internals cold.

## The Mental Model First : Request Flow Through the Cluster

*Before diving into each component, burn this flow into your brain. Every component's purpose becomes obvious once you understand the lifecycle of a single kubectl apply:*

```
kubectl → kube-apiserver (authn/authz/admission) → etcd (persist)
       ↓
   kube-controller-manager (reconcile desired vs actual)
       ↓
   kube-scheduler (assign pod to node)
       ↓
   kubelet on target node (pull image, create container)
       ↓
   kube-proxy (update iptables/ipvs for Service routing)
       ↓
   CNI plugin (wire up pod networking)
```

*Everything in your cluster exists to serve this loop.*

## Phase 1: Control Plane Static Pod Manifests

**The Why (The Problem)**

Before static pods, if the kubelet crashed, you had no way to self-heal the control plane — the control plane itself needed to be running to schedule pods, but kubelet needed the API server to know what to run. Classic chicken-and-egg. Static pods break this: *kubelet watches a directory and manages pods without needing an API server*. This is how the control plane bootstraps itself.

**Deep-Dive Mechanics**

Location: */etc/kubernetes/manifests/*
The kubelet has a *--pod-manifest-path* (or *staticPodPath* in *kubelet-config.yaml*) pointing to this directory. It polls this directory and creates/deletes pods based on what's there. These pods appear in *kubectl get pods -n kube-system* as mirror pods (read-only representations), but they are owned by the node, not the scheduler.

**The 4 static pod manifests:**

```
/etc/kubernetes/manifests/
├── kube-apiserver.yaml
├── kube-controller-manager.yaml
├── kube-scheduler.yaml
└── etcd.yaml
```
