# Phase 13: kubeadm Internals — How the Cluster Actually Gets Built

**The Why**

Before kubeadm, you either hand-wrote every cert and unit file ("Kubernetes the Hard Way") or used heavyweight Ansible playbooks (kubespray). 
Both were error-prone and non-reproducible. kubeadm encodes Kubernetes SIG best-practice into two commands while deliberately staying a 
low-level "building block" rather than a fully managed control plane — that's the gap EKS/GKE fill instead.

**Deep-Dive Mechanics**

*kubeadm init* runs as a sequence of discrete phases — you can run them individually for debugging:

```
kubeadm init phase --help

preflight          # swap check, port availability, container runtime present
certs              # generates entire PKI tree from Phase 3
kubeconfig         # writes admin.conf, kubelet.conf, controller-manager.conf, scheduler.conf
control-plane      # writes the 3 static pod manifests
etcd               # writes etcd static pod manifest (local) or configures external
upload-config      # writes ClusterConfiguration + KubeletConfiguration as ConfigMaps
upload-certs       # OPTIONAL: encrypts PKI into kubeadm-certs Secret (2hr TTL)
mark-control-plane # applies node-role label + NoSchedule taint
bootstrap-token    # creates Secret + RBAC enabling future kubeadm join
addon              # installs kube-proxy DaemonSet + CoreDNS Deployment
```

**The actual config object** (what you'd pass via --config):

```
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.29.0
controlPlaneEndpoint: "k8s-api-vip.internal:6443"   # The NLB/HAProxy VIP — critical for HA
networking:
  podSubnet: "192.168.0.0/16"
  serviceSubnet: "10.96.0.0/12"
etcd:
  local:
    dataDir: /var/lib/etcd
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "10.0.1.10"
  bindPort: 6443
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
```

**Adding a second control-plane node — the part most engineers can't explain:**

The kubeadm-certs Secret holds your entire PKI tree, encrypted at rest with a one-time symmetric key (--certificate-key). 
When you ran kubeadm init --upload-certs, it printed this key. A new control-plane node joins like this:

```
kubeadm join k8s-api-vip.internal:6443 \
  --token <bootstrap-token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <key-from-upload-certs>
```

Internally this runs two extra phases beyond a worker join:

- control-plane-prepare: downloads and decrypts the PKI material from the kubeadm-certs Secret using the key, writes the static pod manifests
- control-plane-join: calls the etcd Member API against an existing healthy etcd member to register itself (MemberAdd), then starts its own etcd static pod, which joins the Raft cluster as a new voting member

*The bootstrap token RBAC* (this is the actual security mechanism, not magic):

```
kubectl get clusterrolebinding kubeadm:get-nodes
kubectl get clusterrole system:bootstrappers  # Actually a Group, not a Role
```

A bootstrap token Secret in kube-system (type bootstrap.kubernetes.io/token) is what lets an unauthenticated node prove it's allowed to start the CSR process — the system:bootstrappers group is bound to a ClusterRole permitting only CSR creation, nothing else.

**The Alternative Landscape**

<img width="887" height="457" alt="image" src="https://github.com/user-attachments/assets/531cb822-1194-457c-94dc-4297671bb94e" />

**Interview POV & Gotchas**

- "Walk me through adding a control-plane node to an HA cluster" → expects the --certificate-key/upload-certs flow, not just kubeadm join.
- Gotcha: the --certificate-key expires after 2 hours. If you wait too long, you regenerate it: kubeadm init phase upload-certs --upload-certs.
- Gotcha: bootstrap tokens expire in 24h by default (kubeadm token list / kubeadm token create --ttl 0 for non-expiring, generally discouraged).

**Evolution**

Cluster API (CAPI) treats clusters themselves as Kubernetes objects (Cluster, KubeadmControlPlane, MachineDeployment) reconciled by controllers — you git push a cluster spec and CAPI provisions it on AWS/Azure/bare-metal. This is how platform teams manage fleets of 50+ clusters declaratively instead of running kubeadm init by hand each time. Talos Linux goes further — no SSH, no shell, the entire OS is API-driven and immutable, eliminating the OS-bootstrap problem kubeadm still depends on.


# Phase 14: Container Runtime Interface (CRI)

**The Why**

Kubernetes originally had Docker hard-coded into kubelet. Every runtime innovation (containerd, CRI-O, gVisor) required forking kubelet itself. CRI decoupled kubelet from any specific runtime via a standard gRPC contract. Docker support (dockershim) was fully removed in v1.24 — this is why containerd is now the default everywhere, including your kubeadm setup.

**Deep-Dive Mechanics**

```
kubelet ──CRI gRPC──> containerd (unix:///run/containerd/containerd.sock)
                          │
                          ├── RuntimeService: RunPodSandbox, CreateContainer, StartContainer
                          └── ImageService: PullImage, ListImages
                                  │
                          containerd-shim-runc-v2 (one shim PROCESS per pod)
                                  │
                                runc ──> creates namespaces, cgroups (OCI runtime spec)
```

**Critical detail: the pause container creates the network namespace first.**

Every other container in the pod joins it via --net=container:<pause-id> — this is why containers in a pod share localhost and an IP.

**containerd's config (/etc/containerd/config.toml):**

```
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true       # MUST match kubelet's cgroupDriver: systemd

[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "registry.k8s.io/pause:3.9"
```

**Gotcha that breaks more clusters than anything else:**

if SystemdCgroup in containerd doesn't match cgroupDriver in kubelet's config, pods will fail to start with cryptic cgroup errors after any kernel/OS upgrade. Always verify both sides agree.

**The Alternative Landscape**

<img width="880" height="370" alt="image" src="https://github.com/user-attachments/assets/099befc7-d91c-46c6-a92b-e861299a6038" />

RuntimeClass lets you select per-workload: runtimeClassName: gvisor for untrusted code, runc (default) for everything else.

**Interview POV & Gotchas**

- "Why was dockershim removed?" → maintenance burden on the Kubernetes project; CRI standardized the interface so any runtime works without touching kubelet code.
- "When would you use gVisor/Kata over plain runc?" → multi-tenant SaaS platforms running untrusted customer code — runc shares the host kernel, gVisor/Kata don't.

**Evolution**

WebAssembly (Wasm) runtimes via a containerd shim (spin, wasmtime) are emerging as a lighter alternative to full OCI containers for specific stateless workloads — sub-millisecond cold starts, much smaller footprint than even a minimal container.

# Phase 15: API Server Internals

**The Why**

If every controller polled etcd directly, you'd have thousands of clients hammering etcd simultaneously — it doesn't scale. The watch/informer pattern lets the apiserver maintain one efficient connection to etcd and fan out changes to every interested client.

**Deep-Dive Mechanics**

**Watch cache**: 

apiserver keeps an in-memory cache synced from etcd via a long-lived gRPC watch stream. List/Watch requests from clients are served from this cache, not from etcd directly — this is what lets thousands of controllers watch the cluster without overwhelming etcd.

**resourceVersion** 

is etcd's global revision counter. Every write increments it. Clients track their last-seen resourceVersion so a dropped watch connection can resume exactly where it left off without missing events or re-listing everything.

**Informers (client-go)** 

— the pattern every controller and operator is built on:

```
Reflector (List + Watch) → local Store/Indexer (cache) → workqueue → Reconcile loop
```

This is the mental model for understanding ArgoCD, Karpenter, cert-manager, Gatekeeper — they're all just informers watching specific resource types and reconciling.

**API Priority and Fairness (APF)** replaced the old blunt --max-requests-inflight flag:

```
kubectl get flowschemas
kubectl get prioritylevelconfigurations
```

Requests are classified into priority levels (system, leader-election, workload-high, workload-low, catch-all) with fair queuing within each. This is exactly what prevents a runaway controller from starving kubelet heartbeats or your kubectl session during an incident.

**Encryption at rest** 

— a fact that surprises most engineers: Kubernetes Secrets are NOT encrypted by default, only base64-encoded (trivially reversible). You must explicitly configure:

```
# /etc/kubernetes/enc/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: ["secrets"]
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-32-byte-key>
  - identity: {}
```

Referenced via --encryption-provider-config on kube-apiserver. Production AWS setups typically use kms provider type pointing at AWS KMS instead of a static local key.
**Bound Service Account Tokens (modern) vs legacy SA tokens:**

<img width="885" height="257" alt="image" src="https://github.com/user-attachments/assets/17df8108-c799-4050-b8ca-7dd29a5f88e1" />

This is controlled via --service-account-issuer and --service-account-signing-key-file on the apiserver.

**Interview POV & Gotchas**

- "Are Kubernetes Secrets secure at rest?" → No by default — a known trap question. Requires EncryptionConfiguration or an external secrets manager (Vault, AWS Secrets Manager via External Secrets Operator).
- "How would you debug an apiserver under heavy load?" → check apiserver_flowcontrol_* metrics (APF queue rejections), etcd latency metrics, and audit logs for hot resource types.
- "What stops a misbehaving controller from taking down the apiserver for everyone else?" → APF fair queuing isolates priority levels.

**Evolution**

Rather than relying on raw Secrets at all, production fintech stacks typically use External Secrets Operator syncing from AWS Secrets Manager or Vault, with EncryptionConfiguration as defense-in-depth rather than the primary control.

# Phase 16: Admission Control — The Full Chain

**The Why**

RBAC answers "can this user perform this verb on this resource type." It cannot answer "must all images come from our approved ECR registry" or "must every Deployment have resource limits set." Admission control is the policy-enforcement hook between authorization and persistence that lets you encode arbitrary business/security rules.

**Deep-Dive Mechanics**

The real, complete pipeline (more granular than what's usually taught):

```
Authentication → Authorization (RBAC) 
  → Mutating Admission (in-tree plugins, THEN MutatingWebhookConfigurations)
  → Object Schema Validation (OpenAPI schema check)
  → Validating Admission (in-tree plugins, THEN ValidatingWebhookConfigurations)
  → Persist to etcd
```

Mutating webhooks run before validating webhooks deliberately — mutations can change the object, so validation needs to see the final state.
Webhooks return AdmissionReview responses, with mutating webhooks able to return a JSON patch:

```
{
  "response": {
    "allowed": true,
    "patchType": "JSONPatch",
    "patch": "<base64 JSON patch adding default labels/resources>"
  }
}
```

This is exactly the mechanism OPA Gatekeeper and Kyverno register into — they ship as ValidatingWebhookConfiguration/MutatingWebhookConfiguration objects pointing at their in-cluster webhook Service.

**The single most important production gotcha in this entire section:**

```
failurePolicy: Fail   # vs Ignore
```

If your webhook pod crashes and failurePolicy: Fail, no objects matching its rules can be created or updated cluster-wide — including the webhook's own replacement pod, unless you've explicitly excluded kube-system via namespaceSelector. This is a real, common way to lock yourself entirely out of a cluster.

**The Alternative Landscape**

<img width="862" height="282" alt="image" src="https://github.com/user-attachments/assets/8d5c305d-9727-4a25-922b-67937569cb89" />

**Gatekeeper vs Kyverno:**

Gatekeeper uses Rego (OPA's policy language — powerful, steep learning curve). Kyverno expresses policies as native Kubernetes YAML — far easier for teams already fluent in manifests, less expressive for very complex logic.

**Interview POV & Gotchas**

- "Your cluster is completely locked — no pods schedule anywhere." → first suspect: a ValidatingWebhookConfiguration with failurePolicy: Fail pointing at a dead webhook Service.
- "Difference between Gatekeeper and Kyverno?" → Rego vs native YAML, as above.

**Evolution**

ValidatingAdmissionPolicy (CEL-based, GA since 1.30) eliminates the webhook server entirely for straightforward policies — the policy logic runs in-process inside the apiserver as CEL expressions defined directly as Kubernetes objects. No separate Deployment to run, no network hop, no failurePolicy lockout risk. This is rapidly becoming the default choice for simple "require this label" / "block this image registry" rules, with Gatekeeper/Kyverno reserved for genuinely complex policy logic.

# Phase 17: Aggregation Layer

**The Why**

Kubernetes needs APIs that aren't core resources (metrics.k8s.io, cloud-provider-specific APIs) without bloating the core apiserver binary or requiring a fork for every extension.

**Deep-Dive Mechanics**

APIService objects register a URL prefix (e.g. /apis/metrics.k8s.io/v1beta1) that the main apiserver proxies to a separate, dedicated extension-apiserver Deployment.

```
kubectl get apiservices | grep metrics
v1beta1.metrics.k8s.io   metrics-server/metrics-server   True
```

This is what the front-proxy certs from Phase 3 actually do: the main apiserver authenticates the original client normally, then re-authenticates itself to the extension apiserver using front-proxy-client.crt, passing identity via a trusted X-Remote-User header signed by front-proxy-ca.
metrics-server is the canonical example — kubectl top and the HorizontalPodAutoscaler controller both query metrics.k8s.io, which isn't compiled into kube-apiserver at all; it's a fully separate aggregated API server.

**The Alternative Landscape**

<img width="857" height="240" alt="image" src="https://github.com/user-attachments/assets/a58c5340-f860-4251-80c3-8b27099e015c" />

Most "I need a custom API" needs today are solved with CRDs, not the aggregation layer — CRDs don't require running and securing a separate apiserver binary.

**Interview POV & Gotchas**

"kubectl top shows nothing, HPA isn't scaling — where do you look?" → kubectl get apiservices for metrics.k8s.io showing Available: False, then metrics-server pod logs — frequently a TLS trust failure between metrics-server and kubelet's serving certs (fix: proper cert chain, or --kubelet-insecure-tls as a stopgap, not for production).

**Evolution**

CRDs + operator pattern has effectively replaced the aggregation layer for nearly all new use cases — it's dramatically simpler to ship. Aggregation layer is now reserved for the rare case needing true apiserver-grade performance (like real-time metrics) that a CRD+controller can't deliver.

APIService objects register a URL prefix (e.g. /apis/metrics.k8s.io/v1beta1) that the main apiserver proxies to a separate, dedicated extension-apiserver Deployment.

# Phase 18: Node Lifecycle Automation

**The Why**

In a cluster with hundreds of nodes, manual intervention on every network blip is unworkable. The node controller automates marking nodes unhealthy and evicting workloads — without overreacting to transient noise.

**Deep-Dive Mechanics**

```
kubelet heartbeat (NodeStatus, every 10s)
  → node controller monitors (--node-monitor-period=5s)
  → no heartbeat within --node-monitor-grace-period (40s default)
  → node Condition Ready flips to Unknown
  → taint applied: node.kubernetes.io/unreachable:NoExecute
```

Pods don't get evicted instantly on this flip — the DefaultTolerationSeconds admission controller automatically adds a tolerationSeconds: 300 toleration for these taints to every pod, giving transient blips 5 minutes to self-heal before mass rescheduling kicks in.

**Eviction rate limiting** 

— the part that prevents cascading failure during a zone-wide network partition:

```
--node-eviction-rate=0.1               # nodes evicted per second, normal conditions
--unhealthy-zone-threshold=0.55        # if >55% of a zone's nodes go unhealthy simultaneously...
--secondary-node-eviction-rate=0.01    # ...drastically throttle eviction
```

If most nodes in a zone go unhealthy at once, the node controller assumes a network partition (not real node failure) and refuses to mass-evict — avoiding a self-inflicted cascading outage.

**kubectl drain, step by step:**

```
1. cordon          → spec.unschedulable: true (no new pods land here)
2. filter pods     → skip DaemonSet-managed and static/mirror pods (can't be evicted)
3. evict           → uses the Eviction subresource (not kubectl delete) — 
                      respects PodDisruptionBudgets, retries with backoff if blocked
4. wait            → terminationGracePeriodSeconds honored
5. node empty      → safe for maintenance
```

**Interview POV & Gotchas**

- "Cluster Autoscaler wants to drain a node but it's stuck — why?" → a PodDisruptionBudget with minAvailable equal to current replica count makes eviction mathematically impossible without violating the PDB. Also check for bare pods (no controller) requiring --force, or local emptyDir data requiring --delete-emptydir-data.
- "A zone loses network connectivity, 60% of nodes go unreachable simultaneously — does the cluster mass-evict everything?" → No — unhealthy-zone-threshold logic detects this pattern and throttles eviction specifically to prevent that cascade.

**Evolution**

Karpenter's consolidation + interruption handling (which you've already built) is the modern evolution of this exact space — proactive, cost-aware node lifecycle management instead of purely reactive eviction.

# Phase 19: Control-Plane Observability & Governance

**The Why**

Senior SREs are expected to debug a sick control plane without kubectl working at all — that requires knowing exactly where logs live and how the control plane protects itself from resource starvation.

**Deep-Dive Mechanics**

Static pod logs behave like any pod's logs since kubelet still reports them as mirror pods:

```
kubectl logs -n kube-system kube-apiserver-master1
# Underlying files: /var/log/pods/... symlinked from /var/log/containers/...
```

kubelet itself is NOT a container — it's a systemd unit. This trips up almost everyone the first time a node won't join:

```
journalctl -u kubelet -f      # The actual first command when kubeadm join hangs
                                # kubectl logs won't work — there's no cluster membership yet
```

**Audit logging** 

— --audit-policy-file defines Level (None, Metadata, Request, RequestResponse) per resource/verb/user combination. Senior-level skill is writing a targeted policy:

```
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse        # full body — secrets access, RBAC changes
  resources:
  - group: ""
    resources: ["secrets"]
- level: Metadata                 # who/when only — routine reads
  resources:
  - group: ""
    resources: ["pods"]
- level: None                     # noise — skip entirely
  users: ["system:kube-proxy"]
```

Too verbose floods disk; too sparse leaves no forensic trail during an incident.

**Control-plane resource governance**: 

static pods run with priorityClassName: system-node-critical / system-cluster-critical, which makes kubelet treat them as essentially exempt from eviction — this is specifically what stops the apiserver from being OOM-killed under node memory pressure, even before any of your workload pods get evicted.

*cgroup hierarchy*, for tracing OOM-kills precisely:

```
kubepods.slice/
├── kubepods-burstable.slice/    # pods with requests < limits
├── kubepods-besteffort.slice/   # pods with no requests/limits
└── per-pod cgroups, organized by QoS class
```

**Interview POV & Gotchas**

"kubeadm join is hanging on a new node — first thing you check?" → journalctl -u kubelet, not kubectl (there's no cluster membership to query yet).
"How would you investigate who deleted a production Secret?" → the audit log filtered on verb=delete, resource=secrets, cross-referenced against the user field — only possible if your audit policy actually captured that event at sufficient detail, which is why policy design matters before an incident, not during one.

**Evolution**

Shipping audit logs to a centralized SIEM and feeding Falco (which you've already covered) for real-time runtime anomaly detection closes the loop between "logged" and "actually alerted on" — static log files alone don't get you woken up at 3am.

