# Lab 6: Admission Webhook Lockout

This is the most dangerous failure mode in the entire lab series. It's dangerous because it looks like nothing is wrong — the control plane is healthy, etcd is fine, nodes are Ready — yet nothing can be created or updated anywhere in the cluster. 
And the fix, if you don't know the escape hatch, is non-obvious under pressure.

## Mental Model: The Admission Pipeline

Every API request goes through this pipeline before etcd persistence:

```
kubectl apply -f pod.yaml
       │
       ▼
Authentication (who are you?)
       │
       ▼
Authorization (are you allowed?)
       │
       ▼
Mutating Admission Webhooks    ← webhook called HERE (can modify object)
       │
       ▼
Schema Validation              ← OpenAPI schema check
       │
       ▼
Validating Admission Webhooks  ← webhook called HERE (can only allow/deny)
       │
       ▼
Persist to etcd ✅
```

**The lockout mechanics:**

```
ValidatingWebhookConfiguration exists with failurePolicy: Fail
       │
       ├── Webhook pod: RUNNING
       │     → requests flow through normally ✅
       │
       └── Webhook pod: DEAD / CRASHLOOPING
             → apiserver tries to call webhook Service
             → gets connection refused / timeout
             → failurePolicy: Fail → REQUEST DENIED ❌
             → EVERY matched request fails
             → cluster is locked

The self-sealing trap:
  └── You try to create a new webhook pod to fix it
        → that CREATE request goes through admission
        → admission calls the dead webhook
        → webhook unreachable → Fail → DENIED
        → you cannot create the replacement pod
        → deadlock
```

*This is exactly what happened at several large companies in production — including cases where a Gatekeeper or Kyverno upgrade went wrong and locked engineers out of their own cluster for hours.*

## Stage A: Pre-Lab Setup — Build the Webhook Infrastructure

Unlike previous labs we need to build something before we can break it. We'll create a minimal real webhook that actually validates requests — then kill it.

**Step 1: Create webhook namespace and deployment**

```
# Create dedicated namespace for our webhook
kubectl create namespace webhook-system

# Label it so we can use namespaceSelector later
kubectl label namespace webhook-system \
  lab=chaos-webhook

# Verify
kubectl get namespace webhook-system --show-labels
```

## Step 2: Generate TLS certs for the webhook server

Webhooks MUST use HTTPS. The apiserver will reject HTTP webhooks:

```
# Create a working directory
mkdir -p /root/webhook-lab && cd /root/webhook-lab

# Generate CA key and cert
openssl genrsa -out ca.key 2048

openssl req -new -x509 \
  -key ca.key \
  -out ca.crt \
  -days 365 \
  -subj "/CN=webhook-ca"

# Generate webhook server key
openssl genrsa -out webhook.key 2048

# Generate CSR with correct SAN
# The CN and SAN must match the Service DNS name
cat > webhook-csr.conf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = webhook-service.webhook-system.svc
DNS.2 = webhook-service.webhook-system.svc.cluster.local
EOF

openssl req -new \
  -key webhook.key \
  -out webhook.csr \
  -subj "/CN=webhook-service.webhook-system.svc" \
  -config webhook-csr.conf

# Sign with our CA
openssl x509 -req \
  -in webhook.csr \
  -CA ca.crt \
  -CAkey ca.key \
  -CAcreateserial \
  -out webhook.crt \
  -days 365 \
  -extensions v3_req \
  -extfile webhook-csr.conf

# Verify the cert has correct SANs
openssl x509 -in webhook.crt -noout -text | \
  grep -A3 "Subject Alternative Name"

echo "Certs generated successfully"
ls -la /root/webhook-lab/
```

## Step 3: Store certs as a Kubernetes Secret

```
kubectl create secret tls webhook-tls \
  --cert=/root/webhook-lab/webhook.crt \
  --key=/root/webhook-lab/webhook.key \
  -n webhook-system

# Verify
kubectl get secret webhook-tls -n webhook-system
```

## Step 4: Deploy the webhook server

We'll use a simple nginx-based webhook that returns allowed: true for everything — the point is not the policy logic, it's the failure behaviour:

```
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chaos-webhook
  namespace: webhook-system
  labels:
    app: chaos-webhook
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chaos-webhook
  template:
    metadata:
      labels:
        app: chaos-webhook
    spec:
      containers:
      - name: webhook
        image: python:3.11-alpine
        command:
        - python3
        - -c
        - |
          import ssl, json
          from http.server import HTTPServer, BaseHTTPRequestHandler

          class WebhookHandler(BaseHTTPRequestHandler):
            def do_POST(self):
              length = int(self.headers['Content-Length'])
              body = json.loads(self.rfile.read(length))
              uid = body['request']['uid']
              print(f"Admitting request uid={uid}")
              response = {
                "apiVersion": "admission.k8s.io/v1",
                "kind": "AdmissionReview",
                "response": {
                  "uid": uid,
                  "allowed": True
                }
              }
              payload = json.dumps(response).encode()
              self.send_response(200)
              self.send_header('Content-Type', 'application/json')
              self.send_header('Content-Length', len(payload))
              self.end_headers()
              self.wfile.write(payload)
            def log_message(self, format, *args):
              print(format % args)

          ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
          ctx.load_cert_chain('/tls/tls.crt', '/tls/tls.key')
          server = HTTPServer(('0.0.0.0', 8443), WebhookHandler)
          server.socket = ctx.wrap_socket(server.socket, server_side=True)
          print("Webhook server listening on :8443")
          server.serve_forever()
        ports:
        - containerPort: 8443
        volumeMounts:
        - name: tls
          mountPath: /tls
          readOnly: true
      volumes:
      - name: tls
        secret:
          secretName: webhook-tls
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-service
  namespace: webhook-system
spec:
  selector:
    app: chaos-webhook
  ports:
  - port: 443
    targetPort: 8443
EOF

# Wait for webhook pod to be Running
kubectl rollout status deployment/chaos-webhook \
  -n webhook-system --timeout=120s

# Verify it's actually running
kubectl get pods -n webhook-system -o wide
```

## Step 5: Register the ValidatingWebhookConfiguration

This is the object that tells the apiserver to call our webhook for every pod creation across the cluster:

```
# Get base64-encoded CA bundle for the webhook config
CA_BUNDLE=$(base64 -w0 /root/webhook-lab/ca.crt)
echo "CA bundle length: ${#CA_BUNDLE} chars"

cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: chaos-lab-webhook
webhooks:
- name: chaos-validator.lab.io
  admissionReviewVersions: ["v1"]
  clientConfig:
    service:
      name: webhook-service
      namespace: webhook-system
      path: "/validate"
    caBundle: $CA_BUNDLE
  rules:
  - apiGroups:   [""]
    apiVersions: ["v1"]
    operations:  ["CREATE", "UPDATE"]
    resources:   ["pods"]
    scope:       "Namespaced"
  failurePolicy: Fail        # ← THE BOMB
  sideEffects: None
  timeoutSeconds: 5
EOF

# Verify webhook is registered
kubectl get validatingwebhookconfigurations
kubectl describe validatingwebhookconfigurations chaos-lab-webhook
```

## Step 6: Verify webhook is working correctly

```
# Test: create a pod — it should go through the webhook and succeed
kubectl run webhook-test-pod --image=nginx:alpine
kubectl get pod webhook-test-pod
# Should be Running or ContainerCreating — webhook allowed it

# Check webhook server received the request
kubectl logs -n webhook-system \
  -l app=chaos-webhook --tail=10
# Should show: "Admitting request uid=..."

# Clean up test pod
kubectl delete pod webhook-test-pod
```

**Cluster is now in the armed state.** 

Webhook is live, failurePolicy: Fail, and intercepting all pod CREATE/UPDATE calls.

## Stage B: The Break — Kill the Webhook Server

```
# Document the webhook pod name
WEBHOOK_POD=$(kubectl get pod -n webhook-system \
  -l app=chaos-webhook \
  -o jsonpath='{.items[0].metadata.name}')
echo "Killing: $WEBHOOK_POD"

# Scale the deployment to 0 — webhook server is dead
kubectl scale deployment chaos-webhook \
  -n webhook-system --replicas=0

# Verify pod is gone
kubectl get pods -n webhook-system
# No pods running

echo "Webhook server killed at: $(date)"
```

## Stage C: Observe the Blast Radius

The control plane looks completely healthy. Watch what happens when you try to do anything:

```
# ATTEMPT 1: Create a simple pod
kubectl run blast-test --image=nginx:alpine 2>&1
# Expected: Error from server (InternalError):
# error when creating "STDIN": Internal Server Error
# (or: failed calling webhook "chaos-validator.lab.io": ... connection refused)

# ATTEMPT 2: Create in a different namespace — same result
kubectl run blast-test \
  --image=nginx:alpine \
  -n kube-system 2>&1
# Same error — webhook intercepts ALL namespaces

# ATTEMPT 3: Try to scale our nginx deployment
kubectl scale deployment nginx-test --replicas=6 2>&1
# ALSO BLOCKED — UPDATE operations are intercepted too

# ATTEMPT 4: Try to create the replacement webhook pod directly
kubectl run webhook-replacement \
  --image=python:3.11-alpine \
  -n webhook-system 2>&1
# ALSO BLOCKED — this is the self-sealing trap
# You cannot create the replacement because creating it
# goes through the same dead webhook

# ATTEMPT 5: Check if existing pods are affected
kubectl get pods -o wide
# Existing pods: STILL RUNNING (admission only gates new requests)

# ATTEMPT 6: Can you READ things?
kubectl get nodes
kubectl get pods -A
kubectl get deployments
# All reads WORK — admission only affects writes

# ATTEMPT 7: What does the exact error say?
kubectl run error-capture --image=nginx:alpine 2>&1 | cat
# Full error message — capture this for the debrief

# ATTEMPT 8: Verbose output shows the webhook being called
kubectl run verbose-test --image=nginx:alpine -v=6 2>&1 | tail -30
# Shows: POST /apis/... → 500
# Reason: webhook timeout/connection refused
```

**Observations checklist:**

<img width="867" height="456" alt="image" src="https://github.com/user-attachments/assets/838fee0e-8181-427f-b543-4c7e1ee94f0f" />

## Stage D: Diagnose — Find the Root Cause

```
# DIAGNOSIS 1: Check admission webhook configurations
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
# chaos-lab-webhook is listed — this is your suspect

# DIAGNOSIS 2: Describe the webhook — find the failurePolicy
kubectl describe validatingwebhookconfigurations chaos-lab-webhook
# Look for:
# Failure Policy: Fail     ← confirmed root cause mechanism
# Service: webhook-system/webhook-service  ← target service

# DIAGNOSIS 3: Is the target service healthy?
kubectl get svc -n webhook-system webhook-service
# Service exists but...

kubectl get endpoints -n webhook-system webhook-service
# Endpoints: <none>   ← NO pods backing this service
# This confirms: service exists, no pods = connection refused

# DIAGNOSIS 4: Are there any pods in webhook-system?
kubectl get pods -n webhook-system
# No resources found — deployment scaled to 0

# DIAGNOSIS 5: Check apiserver logs for webhook errors
sudo crictl logs \
  $(sudo crictl ps --name kube-apiserver -q) \
  2>&1 | grep -i "webhook\|admission" | tail -20
# Shows: failed calling webhook "chaos-validator.lab.io"
# connection refused / context deadline exceeded

# DIAGNOSIS 6: Try to create something with --dry-run
# Dry-run STILL goes through admission webhooks
kubectl run dryrun-test --image=nginx:alpine \
  --dry-run=server 2>&1
# Same error — confirms it's admission, not etcd or apiserver

# DIAGNOSIS 7: Client-side dry-run bypasses admission
kubectl run dryrun-test --image=nginx:alpine \
  --dry-run=client 2>&1
# This WORKS — client-side dry-run never hits the apiserver
# Confirms: apiserver itself is healthy, problem is in admission pipeline
```

**Root cause confirmed:**

```
ValidatingWebhookConfiguration "chaos-lab-webhook"
  failurePolicy: Fail
  → target service has no endpoints (webhook pods dead)
  → every CREATE/UPDATE request fails
  → cluster write operations completely blocked
  → cannot create replacement pods (self-sealing)
```

## Stage E: Recovery — The Escape Hatch

There are three recovery paths in order of preference. Know all three cold.

**Recovery Path 1: Delete the WebhookConfiguration (Fastest)**

kubectl can still read and delete objects — deletion doesn't go through the same webhook rules we configured (we only intercepted CREATE/UPDATE on pods):

```
# DELETE the webhook configuration entirely
# This immediately removes the admission intercept
kubectl delete validatingwebhookconfigurations chaos-lab-webhook

echo "Webhook configuration deleted at: $(date)"

# Immediately verify — can you create pods now?
kubectl run recovery-test --image=nginx:alpine
kubectl get pod recovery-test
# Should work immediately

kubectl delete pod recovery-test
```

**This is Path 1 because:** 

deletion of the ValidatingWebhookConfiguration itself isn't intercepted by our pod-level webhook. The apiserver processes the delete directly.

## Recovery Path 2: Bypass Webhook at apiserver Level

If the webhook configuration intercepted DELETE operations too (more aggressive webhook), or if you can't reach the apiserver normally, you can patch the webhook to use failurePolicy: Ignore as an intermediate step:

```
# First re-create the webhook (for demonstration)
cat <<EOF | kubectl apply -f -
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: chaos-lab-webhook
webhooks:
- name: chaos-validator.lab.io
  admissionReviewVersions: ["v1"]
  clientConfig:
    service:
      name: webhook-service
      namespace: webhook-system
      path: "/validate"
    caBundle: $(base64 -w0 /root/webhook-lab/ca.crt)
  rules:
  - apiGroups:   [""]
    apiVersions: ["v1"]
    operations:  ["CREATE", "UPDATE", "DELETE"]   # Now blocks DELETE too
    resources:   ["pods", "validatingwebhookconfigurations"]  # Blocks self-deletion
    scope:       "Namespaced"
  failurePolicy: Fail
  sideEffects: None
  timeoutSeconds: 5
EOF

# Now you can't delete it either
kubectl delete validatingwebhookconfigurations chaos-lab-webhook 2>&1
# Error — DELETE is also intercepted

# PATH 2: Patch failurePolicy to Ignore
kubectl patch validatingwebhookconfigurations chaos-lab-webhook \
  --type='json' \
  -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
# Does PATCH go through? If patch is intercepted → still blocked

# If patch works:
kubectl get validatingwebhookconfigurations chaos-lab-webhook \
  -o jsonpath='{.webhooks[0].failurePolicy}'
# Ignore ← now webhook failures are non-fatal

# Now you can create the replacement pod
kubectl scale deployment chaos-webhook \
  -n webhook-system --replicas=1

# Then delete the webhook config properly
kubectl delete validatingwebhookconfigurations chaos-lab-webhook
```

## Recovery Path 3: Bypass via apiserver Direct Access

The nuclear option when kubectl is completely blocked. Access the Kubernetes API directly using the admin certificate, bypassing the standard kubectl path:

```
# Get apiserver address
APISERVER=$(kubectl config view \
  --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "API Server: $APISERVER"

# Use the admin cert directly with curl to delete the webhook
# This goes straight to the apiserver REST API
curl -X DELETE \
  --cacert /etc/kubernetes/pki/ca.crt \
  --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
  --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
  "$APISERVER/apis/admissionregistration.k8s.io/v1/\
validatingwebhookconfigurations/chaos-lab-webhook" \
  -H "Content-Type: application/json" \
  2>&1

# Verify via curl
curl -s \
  --cacert /etc/kubernetes/pki/ca.crt \
  --cert /etc/kubernetes/pki/apiserver-kubelet-client.crt \
  --key /etc/kubernetes/pki/apiserver-kubelet-client.key \
  "$APISERVER/apis/admissionregistration.k8s.io/v1/\
validatingwebhookconfigurations" | \
  python3 -m json.tool | grep '"name"'
# chaos-lab-webhook should NOT appear
```

## Stage F: Prevention — How to Never Let This Happen

This is the senior SRE knowledge that prevents the incident:

**Prevention 1: Always exclude critical namespaces via namespaceSelector**

```
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: safe-webhook
webhooks:
- name: safe-validator.lab.io
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values:
      - kube-system          # Control plane pods
      - webhook-system       # The webhook's OWN namespace
      - kube-public
      - kube-node-lease
  failurePolicy: Fail        # Safe now — webhook-system is excluded
  # ...
```

*This prevents the self-sealing trap* — 

the webhook pod itself lives in webhook-system which is excluded from admission, so it can always be recreated even if the webhook is down.

**Prevention 2: Run webhook with multiple replicas and PDB**

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chaos-webhook
  namespace: webhook-system
spec:
  replicas: 3              # Never single replica
  # ...
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: webhook-pdb
  namespace: webhook-system
spec:
  minAvailable: 2          # Always keep 2 running
  selector:
    matchLabels:
      app: chaos-webhook
```

## Prevention 3: Use failurePolicy: Ignore during initial rollout

```
# Phase 1: Deploy with Ignore — safe, no risk
failurePolicy: Ignore

# Phase 2: Monitor for 24h, confirm webhook is stable
# Phase 3: Switch to Fail only after proven stable
failurePolicy: Fail
```

## Prevention 4: Set aggressive timeoutSeconds

```
timeoutSeconds: 5    # Don't let a slow webhook block the cluster for 30s
                     # Default is 10s — 5s is safer
```

## Prevention 5: Use ValidatingAdmissionPolicy (CEL) instead of webhooks for simple rules

```
# No webhook server needed — runs inside apiserver
# No failurePolicy lockout risk
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingAdmissionPolicy
metadata:
  name: require-labels
spec:
  failurePolicy: Fail
  matchConstraints:
    resourceRules:
    - apiGroups:   ["apps"]
      apiVersions: ["v1"]
      operations:  ["CREATE", "UPDATE"]
      resources:   ["deployments"]
  validations:
  - expression: "object.metadata.labels.size() > 0"
    message: "Deployments must have at least one label"
```

No separate server, no TLS certs to manage, no lockout risk.

## Stage G: Full Recovery Verification

```
# 1. No webhook configurations blocking traffic
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations
# chaos-lab-webhook should be gone

# 2. Pod creation works again
kubectl run final-verify --image=nginx:alpine
kubectl get pod final-verify -w
# Pending → Running

kubectl delete pod final-verify

# 3. Scaling works again
kubectl scale deployment nginx-test --replicas=6
kubectl get pods -o wide
kubectl scale deployment nginx-test --replicas=4

# 4. All system pods healthy
kubectl get pods -A

# 5. Cleanup webhook infrastructure
kubectl delete namespace webhook-system
rm -rf /root/webhook-lab/
```

## Interview Debrief

**Q: Cluster is healthy (nodes Ready, etcd fine, apiserver running) but no one can create any pods. What do you check?**

```
# Step 1: Try to create with verbose output
kubectl run test --image=nginx -v=6 2>&1 | grep -iE "webhook|admission|500"

# Step 2: Check webhook configurations
kubectl get validatingwebhookconfigurations
kubectl get mutatingwebhookconfigurations

# Step 3: For each webhook — check failurePolicy and endpoint health
kubectl describe validatingwebhookconfigurations <name>
kubectl get endpoints -n <webhook-namespace> <webhook-service>

# Step 4: If endpoint has no pods → webhook is dead + failurePolicy:Fail = lockout
# Fix: kubectl delete validatingwebhookconfigurations <name>
```

**Q: You can't delete the ValidatingWebhookConfiguration either — it intercepts deletes too. Now what?**

Patch failurePolicy to Ignore first (allows operations while you fix the webhook pod), then restore the webhook pod, then switch back to Fail. If patching is also blocked, use direct curl with admin certificates against the apiserver REST API — this bypasses kubectl's standard path.

**Q: How do you design webhooks to be safe in production?**

Four rules: exclude the webhook's own namespace via namespaceSelector, run at minimum 3 replicas with a PDB, set timeoutSeconds: 5 or lower, and start with failurePolicy: Ignore for the first 24 hours of a new webhook rollout. For simple rules, use ValidatingAdmissionPolicy (CEL-based) instead — no server to crash.

**Q: What's the difference between Gatekeeper and Kyverno in terms of lockout risk?**

Both carry the same failurePolicy: Fail risk if their pods go down. Gatekeeper uses OPA/Rego (powerful but complex). Kyverno uses native Kubernetes YAML policies (simpler). Both ship with their critical namespaces pre-excluded in their default installation — the lockout usually happens when engineers manually tighten the namespaceSelector without understanding the consequence.
