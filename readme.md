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

## What happens when you run kubectl apply -f manifest.yaml?

When you run kubectl apply -f manifest.yaml, Kubernetes transforms your declarative text file into a live, running infrastructure component. 
This lifecycle spans three major environments: *the client machine, the control plane, and the worker nodes.*
The exact sequence of operations occurs in the following order:

**Phase 1: Client-Side Preparation (The kubectl Binary)** 

Before any data reaches your cluster, your local command-line interface processes the instructions:

- Local Validation: kubectl parses your YAML syntax. It downloads the cluster's OpenAPI schema to ensure your resource names and properties are valid.
- Serialization: The validated YAML is converted into a standard JSON payload.
- HTTP Request: The client targets your active context (defined in your kubeconfig file) and dispatches an asynchronous HTTPS request to the cluster.

**Phase 2: The Control Plane (The kube-apiserver Doorway)**

The kube-apiserver acts as the front gate for the cluster, routing the payload through three foundational security and structural gates:

[Incoming Request] ──> [1. Authentication] ──> [2. Authorization] ──> [3. Admission Control] ──> [etcd Storage]

**Authentication:**

The cluster determines your identity via client certificates, bearer tokens, or OIDC identity providers.

**Authorization:**

The server evaluates Role-Based Access Control (RBAC) rules to see if your identity has permissions to create or update that resource.

**Admission Control:** 

Special plugins inspect the request. *Mutating Admission Controllers* can change your manifest (e.g., automatically injecting sidecar containers or storage defaults). 
*Validating Admission Controllers* run a final policy check (e.g., verifying you aren't pulling from an unapproved image registry).

**Phase 3: The Reconciliation Magic & State Storage**

Once passed, Kubernetes must decide whether to create a new resource or update an existing one: 

*The Three-Way Merge*: 

If the resource already exists, Kubernetes computes the exact changes using a three-way merge. It compares the Local Object Config (your current YAML), the Live Object State (what is actively running), and the Last-Applied Configuration (saved as a JSON string inside the object's metadata.annotations array). This prevents your team's manual changes from being accidentally overwritten.

*Server-Side Apply (SSA)*

: In modern clusters, this tracking shifts to the server via managedFields. It explicitly monitors which tool (Helm, Argo CD, or kubectl) owns specific properties, triggering warnings if automated updates conflict.

*Persisting to etcd*: 

The cluster writes the calculated configuration into etcd, the distributed key-value storage system. The moment it saves to etcd, the API server responds to your terminal with deployment.apps/my-app configured (or created).

**Phase 4: Pod Scheduling and Node Deployment**

Even though your command line has finished execution, the cluster is still working in the background to fulfill your intent:

*Controller Reconciliation*: 

The kube-controller-manager notices the etcd change via a streaming watch. If you applied a Deployment, the Deployment Controller builds a ReplicaSet, which subsequently spins up Pod objects with a status of Pending.

*Scheduling*: 

The kube-scheduler discovers these unassigned Pods. It screens the physical resource demands (CPU/Memory), filters healthy nodes, and assigns each Pod to the most optimal host by updating its nodeName field.

*Local Node Execution*: 

The kubelet agent living on the chosen worker node notices the assignment. It interacts with the local Container Runtime (such as containerd or CRI-O) via the Container Runtime Interface. The runtime pulls the necessary images, spins up the Linux namespaces, and launches the container processes.

*Status Updates*: The kubelet monitors the health probes of the container and pushes the Running phase update back to the API server, which records the live status in etcd.

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

**Port breakdown:**

- 2379 — Client port (kube-apiserver talks here)
- 2380 — Peer port (etcd members talk to each other — Raft protocol)
- 2381 — Metrics port (Prometheus scrapes here)

## Phase 2: etcd Internals — The Brain

**The Why**

Before etcd, distributed systems struggled with consistent shared state. etcd solves the consensus problem: "How do multiple nodes agree on the same value when any of them can fail?"

**Deep-Dive Mechanics: Raft Consensus**

etcd uses the *Raft algorithm*. Here's exactly what happens when kube-apiserver writes a pod object:

```
1. apiserver sends write to etcd leader
2. Leader appends entry to its log (not committed yet)
3. Leader sends AppendEntries RPC to all followers in parallel
4. Each follower appends to its log, sends ACK
5. Once (N/2 + 1) nodes ACK → leader marks entry committed
6. Leader applies to state machine, responds to apiserver
7. Leader notifies followers to commit on next heartbeat
```

**Quorum math — the most important thing to know:**

<img width="877" height="255" alt="image" src="https://github.com/user-attachments/assets/0332994c-8321-4ce2-8225-962d9a736a12" />

**Why odd numbers? Even numbers don't increase fault tolerance and cost more**. 4-node etcd tolerates only 1 failure (same as 3-node) but costs an extra node.

**etcd data storage:**

All Kubernetes objects are stored under /registry/ in etcd. You can inspect raw etcd data:

```
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key \
  get /registry/pods/default/my-pod \
  --prefix --keys-only

# Decode the value (protobuf encoded)
get /registry/pods/default/my-pod | auger decode
```

**etcd storage key structure:**

```
/registry/pods/<namespace>/<name>
/registry/deployments/<namespace>/<name>
/registry/secrets/<namespace>/<name>
/registry/configmaps/<namespace>/<name>
/registry/services/specs/<namespace>/<name>
/registry/clusterroles/<name>
/registry/namespaces/<name>
```

**Backup and Restore (CKA critical):**

```
# Backup
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/peer.crt \
  --key=/etc/kubernetes/pki/etcd/peer.key

# Verify
etcdctl snapshot status /backup/etcd-snapshot.db -w table

# Restore (on all control plane nodes)
etcdctl snapshot restore /backup/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restore \
  --initial-cluster=master1=https://10.0.1.10:2380 \
  --initial-cluster-token=etcd-cluster-restored \
  --initial-advertise-peer-urls=https://10.0.1.10:2380 \
  --name=master1

# Update etcd.yaml --data-dir and --initial-cluster-token to match
# Then restart kubelet
```

**Compaction and Defragmentation:**

etcd keeps history of all revisions. Without compaction, it grows unboundedly:

```
# Compact to current revision
rev=$(etcdctl endpoint status --write-out=json | jq '.[] | .Status.header.revision')
etcdctl compact $rev

# Defragment (reclaims disk space)
etcdctl defrag --cluster

# Check DB size
etcdctl endpoint status -w table
```

**Phase 3: The PKI Certificate Infrastructure**

*The Why*

Every component in Kubernetes communicates over mTLS. Without this, any process on any node could impersonate the API server or etcd. The PKI is the trust foundation.

**Deep-Dive: The Complete Certificate Map**

```
/etc/kubernetes/pki/
├── ca.crt / ca.key                    # Kubernetes CA (root of trust)
├── apiserver.crt / apiserver.key      # API server TLS serving cert
├── apiserver-kubelet-client.crt/key   # apiserver → kubelet (client cert)
├── apiserver-etcd-client.crt/key      # apiserver → etcd (client cert)
├── front-proxy-ca.crt/key             # Front proxy CA (aggregation layer)
├── front-proxy-client.crt/key         # Aggregation layer client
├── sa.pub / sa.key                    # Service Account signing key pair
└── etcd/
    ├── ca.crt / ca.key               # etcd-specific CA
    ├── server.crt / server.key       # etcd server TLS
    ├── peer.crt / peer.key           # etcd peer-to-peer
    └── healthcheck-client.crt/key    # liveness probe client
```

**Who presents which cert to whom:**

```
kubelet → apiserver:        kubelet uses its node client cert (CN=system:node:<hostname>)
apiserver → etcd:           apiserver-etcd-client.crt
apiserver → kubelet:        apiserver-kubelet-client.crt (CN=kubernetes, O=system:masters)
controller-manager → api:   controller-manager.conf (embedded client cert)
scheduler → api:            scheduler.conf (embedded client cert)
kubectl → api:              admin.conf (embedded client cert, O=system:masters)
```

**Certificate Rotation:**

```
# Check expiry
kubeadm certs check-expiration

# Rotate all control plane certs
kubeadm certs renew all

# Rotate specific cert
kubeadm certs renew apiserver

# After renewal, restart static pods by moving/restoring manifests
# OR: kill the static pod process; kubelet will restart it
```

**Gotcha:**

After cert renewal, the kubeconfig files under /etc/kubernetes/*.conf also need to be regenerated because they embed client certs. 
Kubeadm certs renew handles this but you need to copy the new admin.conf to ~/.kube/config.

**Phase 4: The Kubeconfig Files**

These are how each component authenticates to the API server:

```
/etc/kubernetes/
├── admin.conf            # kubectl (O=system:masters → cluster-admin)
├── controller-manager.conf
├── scheduler.conf
└── kubelet.conf          # Per-node (CN=system:node:<nodename>)
```

**Structure of each kubeconfig:**

```
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: <base64 ca.crt>
    server: https://10.0.1.100:6443    # VIP for HA clusters
  name: kubernetes
users:
- name: kubernetes-admin
  user:
    client-certificate-data: <base64 client.crt>
    client-key-data: <base64 client.key>
contexts:
- context:
    cluster: kubernetes
    user: kubernetes-admin
  name: kubernetes-admin@kubernetes
current-context: kubernetes-admin@kubernetes
```

**In an HA cluster the server here points to the Load Balancer VIP or NLB DNS, not an individual node. This is a common exam gotcha.**

**Phase 5: kubelet — The Node Agent**

*The Why*

Something must translate the API server's desired state (PodSpec) into actual running containers on the node. That's kubelet. It's the only component that runs as a systemd service, not a static pod.

**Deep-Dive: kubelet Configuration**

*Service definition:*

```
/etc/systemd/system/kubelet.service.d/10-kubeadm.conf
```

```
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
```

**The main config file** /var/lib/kubelet/config.yaml:

```
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true         # Delegates authn to apiserver
authorization:
  mode: Webhook           # Delegates authz to apiserver
clusterDNS:
- 10.96.0.10             # CoreDNS Service ClusterIP
clusterDomain: cluster.local
containerRuntimeEndpoint: unix:///var/run/containerd/containerd.sock
staticPodPath: /etc/kubernetes/manifests   # THIS is how static pods work
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "10%"
  imagefs.available: "15%"
maxPods: 110
podCIDR: 192.168.1.0/24   # Assigned by controller-manager per node
rotateCertificates: true
serverTLSBootstrap: true
cgroupDriver: systemd      # MUST match containerd's cgroupDriver
```

**/var/lib/kubelet/kubeadm-flags.env:**

```
KUBELET_KUBEADM_ARGS="--container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --pod-infra-container-image=registry.k8s.io/pause:3.9"
```

**kubelet reconciliation loop:**

```
1. Watch apiserver for pods assigned to this node (spec.nodeName == self)
2. For each pod:
   a. Ensure pause (infra) container running → sets up network namespace
   b. CNI plugin called → assigns pod IP, sets up veth pair
   c. Init containers run to completion (ordered)
   d. App containers start
   e. Liveness/Readiness probes start
3. Report pod status back to apiserver
4. Enforce resource limits via cgroups v2
5. Garbage collect old images and dead containers
```

**Node Bootstrap Flow (first join):**

```
1. kubelet starts with bootstrap-kubelet.conf (has a bootstrap token)
2. kubelet creates a CertificateSigningRequest for a node client cert
3. controller-manager's CSR approver auto-approves (if NodeBootstrapper RBAC is set)
4. kubelet gets its cert, writes kubelet.conf, discards bootstrap token
```

**Phase 6: kube-proxy — Service Routing**

*Deep-Dive*

kube-proxy runs as a DaemonSet (not a static pod). It watches the apiserver for Service and Endpoint changes and programs the node's packet filter.

```
kubectl get daemonset -n kube-system kube-proxy
kubectl get configmap -n kube-system kube-proxy -o yaml
```

**The ConfigMap:**

```
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-proxy
  namespace: kube-system
data:
  config.conf: |
    apiVersion: kubeproxy.config.k8s.io/v1alpha1
    kind: KubeProxyConfiguration
    mode: "ipvs"              # iptables | ipvs | nftables
    ipvs:
      scheduler: "rr"         # rr | lc | dh | sh | sed | nq
    clusterCIDR: "192.168.0.0/16"
    iptables:
      masqueradeAll: false
```

**iptables mode (default in older clusters):**

```
# How a ClusterIP Service actually works
iptables -t nat -L KUBE-SERVICES -n    # Entry point for all Service traffic
iptables -t nat -L KUBE-SVC-XXXX -n   # Per-service chain (probabilistic load balancing)
iptables -t nat -L KUBE-SEP-XXXX -n   # Per-endpoint (DNAT to pod IP)
```

Every packet to ClusterIP goes: KUBE-SERVICES → KUBE-SVC-* → random KUBE-SEP-* → DNAT to pod IP.

**IPVS mode (preferred for >1000 services):**

```
ipvsadm -Ln          # Show virtual servers and real servers
```

IPVS uses a hash table (O(1) lookup) vs iptables' linear chain (O(n) lookup). Critical for large clusters.

*Gotcha*: 

kube-proxy doesn't handle pod-to-pod routing. That's the CNI's job. kube-proxy only handles Service VIP → pod IP translation.

**Phase 7: CNI Plugin — Pod Networking**

*Deep-Dive*

```
/etc/cni/net.d/          # CNI config files (kubeadm leaves this to you)
/opt/cni/bin/            # CNI plugin binaries
```

**What happens when kubelet creates a pod:**

```
1. kubelet creates pod network namespace: /var/run/netns/<pod-uid>
2. pause container starts, enters this netns
3. kubelet calls CNI plugin (via exec): /opt/cni/bin/calico (or flannel, etc.)
4. CNI plugin:
   a. Creates veth pair: eth0 (in pod netns) ↔ cali<hash> (on host)
   b. Assigns IP from the node's pod CIDR
   c. Sets up routes
5. Pod's eth0 has its IP, can communicate

Cross-node routing (Calico IPIP example):
Pod A (node1) → cali<x> → IPIP tunnel → cali<y> → Pod B (node2)
```

**Calico DaemonSet watches:**

```
kubectl get daemonset -n calico-system calico-node
kubectl get pod -n calico-system -l app=calico-node
```

**Phase 8: CoreDNS — Service Discovery**

*Deep-Dive*

```
kubectl get deployment -n kube-system coredns
kubectl get configmap -n kube-system coredns -o yaml
```

**The Corefile:**

```
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {        # Upstream DNS (AWS Route 53)
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

**DNS resolution path for a pod:**

```
Pod makes DNS query → /etc/resolv.conf → nameserver 10.96.0.10 (CoreDNS ClusterIP)
  → CoreDNS checks kubernetes plugin
  → "my-svc.my-ns.svc.cluster.local" → returns ClusterIP
  → "external.com" → forwards to upstream (/etc/resolv.conf on node → AWS VPC DNS)
```

**Pod's /etc/resolv.conf (injected by kubelet):**

```
nameserver 10.96.0.10
search default.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

*The ndots:5 gotcha: *

Any name with fewer than 5 dots gets search domain appended first, causing latency. curl google.com → tries google.com.default.svc.cluster.local first (fails), then google.com.svc.cluster.local (fails), then google.com.cluster.local (fails), then google.com (succeeds). Fix: use google.com. (trailing dot) or set ndots:1 in pod dnsConfig.

**Phase 9: HA-Specific Infrastructure**

*The Load Balancer / VIP Layer*

In your AWS EC2 HA setup, traffic to port 6443 must be distributed across all 3 API servers. You have two approaches:

**Option A: HAProxy + Keepalived (self-managed VIP)**

```
/etc/haproxy/haproxy.cfg:

frontend kubernetes-frontend
    bind *:6443
    mode tcp
    default_backend kubernetes-backend

backend kubernetes-backend
    mode tcp
    balance roundrobin
    option tcp-check
    server master1 10.0.1.10:6443 check fall 3 rise 2
    server master2 10.0.1.11:6443 check fall 3 rise 2
    server master3 10.0.1.12:6443 check fall 3 rise 2
```

Keepalived provides the floating VIP. If the HAProxy node fails, VIP migrates.

**Option B: AWS NLB (your actual setup)**

```
NLB (10.0.1.100 or DNS) → target group:
  - 10.0.1.10:6443
  - 10.0.1.11:6443
  - 10.0.1.12:6443
(health check: TCP:6443)
```

