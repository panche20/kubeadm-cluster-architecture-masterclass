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

**1a. kube-apiserver.yaml — Deep Dive**

```
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.29.x
    command:
    - kube-apiserver
    # === AUTHENTICATION ===
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    # === AUTHORIZATION ===
    - --authorization-mode=Node,RBAC
    # === ETCD CONNECTION ===
    - --etcd-servers=https://127.0.0.1:2379
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    # === ADMISSION ===
    - --enable-admission-plugins=NodeRestriction
    # === SERVICE NETWORK ===
    - --service-cluster-ip-range=10.96.0.0/12
    # === HA SPECIFIC ===
    - --advertise-address=<THIS_NODE_IP>
    - --etcd-servers=https://etcd1:2379,https://etcd2:2379,https://etcd3:2379
    # === AUDIT ===
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    volumeMounts:
    - mountPath: /etc/kubernetes/pki
      name: k8s-certs
      readOnly: true
    - mountPath: /etc/ssl/certs
      name: ca-certs
      readOnly: true
  hostNetwork: true          # Uses node network namespace
  priorityClassName: system-node-critical
  volumes:
  - hostPath:
      path: /etc/kubernetes/pki
    name: k8s-certs
```

**Critical flags to understand deeply**

<img width="810" height="496" alt="image" src="https://github.com/user-attachments/assets/afcc2456-287a-410d-8ce2-9a8a94ed1893" />

**What happens when kube-apiserver crashes?**

- Existing pods keep running (kubelet is autonomous)
- No new pod scheduling
- No kubectl commands work
- Controllers cannot reconcile
- Service discovery still works for existing endpoints (kube-proxy cached rules)

**1b. kube-controller-manager.yaml — Deep Dive**

```
command:
- kube-controller-manager
- --bind-address=127.0.0.1
- --cluster-cidr=192.168.0.0/16       # Pod network CIDR
- --cluster-name=kubernetes
- --cluster-signing-cert-file=/etc/kubernetes/pki/ca.crt
- --cluster-signing-key-file=/etc/kubernetes/pki/ca.key
- --controllers=*,bootstrapsigner,tokencleaner
- --kubeconfig=/etc/kubernetes/controller-manager.conf
- --leader-elect=true                  # CRITICAL for HA
- --root-ca-file=/etc/kubernetes/pki/ca.crt
- --service-account-private-key-file=/etc/kubernetes/pki/sa.key
- --use-service-account-credentials=true
- --node-monitor-grace-period=40s      # Before marking node NotReady
- --pod-eviction-timeout=5m0s          # Before evicting pods from NotReady node
```

*The KCM is not one controller — it runs ~30 reconciliation loops in a single binary:*

```
ReplicaSet Controller     → ensures desired pod count
Deployment Controller     → manages ReplicaSet rollouts
StatefulSet Controller    → ordered pod lifecycle
DaemonSet Controller      → one pod per node
Job/CronJob Controller    → batch workloads
Node Controller           → marks nodes NotReady, triggers eviction
Service Account Controller → creates default SAs in new namespaces
Endpoint Controller       → populates Endpoints objects from Pods+Services
Namespace Controller      → handles namespace lifecycle
PV/PVC Controller         → binds volumes to claims
GC Controller             → removes orphaned objects
```

**The Leader Election Mechanism (HA critical):**
In an HA cluster, 3 KCM instances run but only ONE is active at a time. They use a Lease object in *kube-system*:

```
kubectl get lease -n kube-system kube-controller-manager
```

The active leader holds the lease and refreshes it every *--leader-elect-renew-deadline* (10s default). If it misses *--leader-elect-retry-period* (2s default), a standby acquires the lease. This prevents split-brain — two KCMs acting on the same objects simultaneously.

**1c. kube-scheduler.yaml — Deep Dive**

```
command:
- kube-scheduler
- --authentication-kubeconfig=/etc/kubernetes/scheduler.conf
- --authorization-kubeconfig=/etc/kubernetes/scheduler.conf
- --bind-address=127.0.0.1
- --kubeconfig=/etc/kubernetes/scheduler.conf
- --leader-elect=true
- --config=/etc/kubernetes/scheduler-config.yaml  # For custom profiles
```

**Scheduling Pipeline — The Two Phases:**

```
FILTERING (Predicates)          SCORING (Priorities)
─────────────────────          ────────────────────
NodeUnschedulable               LeastRequested
PodFitsResources                BalancedAllocation
PodFitsHostPorts                NodeAffinity
NodeAffinity (hard)             TaintToleration
TaintToleration (NoSchedule)    InterPodAffinity
VolumeZone                      ImageLocality
NodeLabel                       NodeResourcesFit
```

The scheduler watches for *pods.spec.nodeName == "" (unbound pods)*, runs them through the pipeline, and writes *nodeName* back. That's the entire job.

**Custom Scheduler Profile (KubeSchedulerConfiguration):**

```
# /etc/kubernetes/scheduler-config.yaml
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    score:
      disabled:
      - name: NodeResourcesBalancedAllocation
      enabled:
      - name: NodeResourcesFit
        weight: 2
```

**1d. etcd.yaml — Deep Dive**

```
command:
- etcd
- --advertise-client-urls=https://10.0.1.10:2379
- --cert-file=/etc/kubernetes/pki/etcd/server.crt
- --client-cert-auth=true
- --data-dir=/var/lib/etcd
- --experimental-initial-corrupt-check=true
- --initial-advertise-peer-urls=https://10.0.1.10:2380
- --initial-cluster=master1=https://10.0.1.10:2380,master2=https://10.0.1.11:2380,master3=https://10.0.1.12:2380
- --initial-cluster-state=existing     # vs 'new' for bootstrap
- --initial-cluster-token=etcd-cluster-1
- --key-file=/etc/kubernetes/pki/etcd/server.key
- --listen-client-urls=https://127.0.0.1:2379,https://10.0.1.10:2379
- --listen-metrics-urls=http://127.0.0.1:2381
- --listen-peer-urls=https://10.0.1.10:2380
- --name=master1
- --peer-cert-file=/etc/kubernetes/pki/etcd/peer.crt
- --peer-client-cert-auth=true
- --peer-key-file=/etc/kubernetes/pki/etcd/peer.key
- --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
- --snapshot-count=10000
- --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.crt
```
