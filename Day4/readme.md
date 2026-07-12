# Lab 2: apiserver TLS Certificate Corruption

**Mental Model: What a Bad Cert Actually Breaks**

```
Certificate chain for apiserver:

/etc/kubernetes/pki/
├── ca.crt              ← Root of trust (everyone trusts this)
├── apiserver.crt       ← What we're breaking today
├── apiserver.key       ← Private key
└── apiserver-kubelet-client.crt  ← apiserver → kubelet auth

When apiserver.crt is corrupted:

kubectl ──TLS handshake──> apiserver presents CORRUPTED cert
                               │
                               └── TLS handshake FAILS
                                   kubectl sees: x509 certificate error
                                   NOT a timeout — an immediate hard reject

kubelet ──────────────────> apiserver (still tries to heartbeat)
                               └── kubelet gets x509 error too
                                   nodes eventually go NotReady

etcd ─────────────────────> NOT affected (uses its own CA)

Existing pods ────────────> STILL RUNNING (same reason as Lab 1)
```

**Key difference from Lab 1**: 

```
etcd failure = apiserver hangs/times out. Cert failure = immediate hard TLS rejection. 
The error message is completely different and diagnosis path is different.
```


## Stage A: Pre-Lab Verification

**On control plane node:**

```
# 1. Confirm cluster is healthy after Lab 1 recovery
kubectl get nodes
kubectl get pods -n kube-system | grep -E "apiserver|etcd|scheduler|controller"

# 2. Inspect the current apiserver cert — note expiry and SANs
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -text | grep -A5 "Subject Alternative Name"

# Expected SANs — you'll need these for recovery verification:
# DNS:kubernetes
# DNS:kubernetes.default
# DNS:kubernetes.default.svc
# DNS:kubernetes.default.svc.cluster.local
# DNS:k8s-control-plane
# IP:10.96.0.1          (first IP of service CIDR)
# IP:10.0.x.x           (CP node private IP)

# 3. Note the cert expiry
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -enddate

# 4. Check all cert expiries (baseline)
sudo kubeadm certs check-expiration

# 5. Confirm nginx still serving
export NODEPORT=$(kubectl get svc nginx-test \
  -o jsonpath='{.spec.ports[0].nodePort}')
curl -s http://localhost:$NODEPORT | grep "<title>"

# 6. Take a checksum of the cert — we'll compare after recovery
sudo md5sum /etc/kubernetes/pki/apiserver.crt
sudo md5sum /etc/kubernetes/pki/apiserver.key
```

## Stage B: Break the apiserver Certificate

We corrupt the cert by overwriting it with garbage. 
This is more realistic than deleting it — a real corruption (disk error, partial write) leaves a file present but unreadable, which produces different errors than "file not found."

```
# Backup the real cert first (not in pki dir — keep it safe)
sudo cp /etc/kubernetes/pki/apiserver.crt /root/apiserver.crt.bak
sudo cp /etc/kubernetes/pki/apiserver.key /root/apiserver.key.bak

# Verify backup is valid
sudo openssl x509 -in /root/apiserver.crt.bak -noout -text | grep "Subject:"

# NOW corrupt the cert — overwrite with random bytes
sudo dd if=/dev/urandom of=/etc/kubernetes/pki/apiserver.crt bs=1024 count=1

echo "Certificate corrupted at: $(date)"

# Verify it's actually corrupted
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text 2>&1
# Expected: unable to load certificate error
```

*Now force the apiserver to reload by restarting its static pod:*

```
# Move manifest out — kubelet kills the apiserver container
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak

# Wait 5 seconds for container to die
sleep 5
sudo crictl ps | grep apiserver   # Should show nothing

# Restore manifest — kubelet will try to start apiserver with corrupted cert
sudo mv /root/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml

echo "apiserver restarting with corrupted cert at: $(date)"
```

## Stage C: Observe the Blast Radius

This is where you build the diagnostic instinct. Run each command and note the exact error — every error message is a clue.

```
# 1. Immediate kubectl attempt — what's the error?
kubectl get nodes 2>&1
# PREDICT: what error do you expect? Timeout like Lab 1 or something different?

# 2. Try with verbose output — shows the TLS handshake failure detail
kubectl get nodes -v=6 2>&1 | tail -20
# Look for: x509, certificate, TLS handshake

# 3. Is the apiserver container even starting?
watch sudo crictl ps -a | grep apiserver
# Watch for: Created → Running → Exited → Created (crashloop)
# Ctrl+C after 20 seconds

# 4. Check apiserver logs — the container may crashloop
# Get the container ID (even Exited ones)
sudo crictl ps -a | grep apiserver

# Get logs from the most recent attempt
APISERVER_ID=$(sudo crictl ps -a --name kube-apiserver -q | head -1)
sudo crictl logs $APISERVER_ID 2>&1 | tail -30
# Look for: "TLS handshake error" or "failed to load certificate"

# 5. Check kubelet logs — kubelet reports WHY it can't start the static pod
sudo journalctl -u kubelet --since "2 minutes ago" | grep -i "apiserver\|error\|failed"

# 6. THE KEY TEST — does data plane still work?
curl -s http://localhost:$NODEPORT | grep "<title>"
# nginx still responds? Confirm the data plane isolation principle

# 7. Try to reach apiserver directly with curl
# This bypasses kubectl and shows raw TLS error
curl -k https://localhost:6443/healthz 2>&1
# With bad cert, you'll see connection refused (not started) or
# if it somehow started: SSL error

# 8. After ~2 minutes, check node status from worker perspective
# SSH into worker-1:
# sudo journalctl -u kubelet --since "3 minutes ago" | grep -i "error\|apiserver"
# Worker kubelet can't reach apiserver — what does IT report?
```

**The critical difference to internalize:**

<img width="855" height="262" alt="image" src="https://github.com/user-attachments/assets/365c76c1-bfe4-4599-a472-fadc3619dcf5" />

## Stage D: Diagnose the issue

This is the investigation flow you'd run in a real incident — no kubectl available, working only from the node:

```
# STEP 1: Is the process running at all?
sudo crictl ps -a | grep apiserver
# Running = cert loaded fine but TLS handshake fails client-side
# Exited/CrashLoopBackOff = cert invalid at startup

# STEP 2: Validate the cert file directly
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text 2>&1
# "unable to load certificate" = file is corrupted/garbage

# STEP 3: Validate cert-key pair match
# Compare modulus of cert and key — they MUST match
sudo openssl x509 -noout -modulus -in /etc/kubernetes/pki/apiserver.crt 2>/dev/null | md5sum
sudo openssl rsa -noout -modulus -in /etc/kubernetes/pki/apiserver.key 2>/dev/null | md5sum
# If hashes differ: cert and key don't belong together
# If cert is garbage: first command returns error

# STEP 4: Verify against CA
sudo openssl verify -CAfile /etc/kubernetes/pki/ca.crt \
  /etc/kubernetes/pki/apiserver.crt 2>&1
# "OK" = cert is valid and signed by the cluster CA
# Error = cert is self-signed, wrong CA, or corrupted

# STEP 5: Check SANs — a valid cert with wrong SANs also causes x509 errors
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -text 2>/dev/null | grep -A10 "Subject Alternative"

# STEP 6: Check expiry
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -enddate 2>/dev/null
# Expired cert = different error: "certificate has expired or is not yet valid"

# STEP 7: kubeadm's own check
sudo kubeadm certs check-expiration 2>&1
# This may also fail if apiserver cert is unreadable
```

*At this point you've confirmed:* 

**cert file is corrupted/invalid** . 

Now you have two recovery paths:

## Stage E: Recovery

*Path 1 — Restore from Backup (fastest, when backup exists)*

```
# Restore the backed-up cert and key
sudo cp /root/apiserver.crt.bak /etc/kubernetes/pki/apiserver.crt
sudo cp /root/apiserver.key.bak /etc/kubernetes/pki/apiserver.key

# Verify restored cert is valid
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep "Subject:"
sudo openssl verify -CAfile /etc/kubernetes/pki/ca.crt \
  /etc/kubernetes/pki/apiserver.crt
# Expected: /etc/kubernetes/pki/apiserver.crt: OK

# kubelet auto-detects the manifest file hasn't changed
# but the static pod is in a crashloop — force restart
sudo crictl stop $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>/dev/null || true

# Watch apiserver come back
watch sudo crictl ps | grep apiserver
# Wait for: Running
```

*Path 2 — Regenerate via kubeadm (when no backup — production scenario)*

This is the CKA/production path. The CA cert and key are still intact, so kubeadm can regenerate the apiserver cert signed by the same CA:

```
# First: move the corrupted cert out (kubeadm won't overwrite existing)
sudo mv /etc/kubernetes/pki/apiserver.crt /root/apiserver.crt.corrupted
sudo mv /etc/kubernetes/pki/apiserver.key /root/apiserver.key.corrupted

# Regenerate ONLY the apiserver cert (not the entire PKI)
sudo kubeadm init phase certs apiserver

# Verify the new cert
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | \
  grep -A10 "Subject Alternative Name"
sudo openssl verify -CAfile /etc/kubernetes/pki/ca.crt \
  /etc/kubernetes/pki/apiserver.crt
# Expected: OK

# Check new expiry — should be ~1 year from now
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate

# Force static pod restart
sudo crictl stop $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>/dev/null || true

# Force the kubelet to restart and scan the manifests folder
sudo systemctl restart kubelet

watch sudo crictl ps | grep apiserver
```

## Stage F: Full Recovery Verification

```
# 1. apiserver running?
sudo crictl ps | grep apiserver

# 2. kubectl works?
kubectl get nodes

# 3. All nodes Ready?
kubectl get nodes -o wide

# 4. Control plane pods healthy?
kubectl get pods -n kube-system

# 5. Cert valid and matches baseline SANs?
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt \
  -noout -text | grep -A10 "Subject Alternative Name"

# 6. Full cert check
sudo kubeadm certs check-expiration

# 7. Data plane never dropped?
curl -s http://localhost:$NODEPORT | grep "<title>"

# 8. Can create new objects?
kubectl run post-lab2-test --image=nginx:alpine
kubectl get pod post-lab2-test
kubectl delete pod post-lab2-test
```

**Bonus Break: Cert/Key Mismatch (5 minutes extra)**

This is a distinct failure mode from corruption — the cert is valid but paired with the wrong key. 
Happens in production when certs are rotated manually and files get mixed up:

```
# Generate a random key (valid RSA key, but not the apiserver's key)
sudo openssl genrsa -out /tmp/wrong.key 2048

# Swap in the wrong key — cert stays valid
sudo cp /etc/kubernetes/pki/apiserver.key /root/apiserver.key.real
sudo cp /tmp/wrong.key /etc/kubernetes/pki/apiserver.key

# Restart apiserver
sudo crictl stop $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>/dev/null || true
sleep 10

# What error do you see now?
sudo crictl logs $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>&1 | tail -20
# Different from corruption error:
# "tls: private key does not match public key"

# Diagnose it:
sudo openssl x509 -noout -modulus -in /etc/kubernetes/pki/apiserver.crt | md5sum
sudo openssl rsa -noout -modulus -in /etc/kubernetes/pki/apiserver.key | md5sum
# Hashes are DIFFERENT = mismatch confirmed

# Restore:
sudo cp /root/apiserver.key.real /etc/kubernetes/pki/apiserver.key
sudo crictl stop $(sudo crictl ps -a --name kube-apiserver -q | head -1) 2>/dev/null || true
watch sudo crictl ps | grep apiserver
```

## Interview Debrief

Q: apiserver is unreachable — how do you determine if it's a cert issue vs etcd issue vs process crash?

```
1. kubectl get nodes → timeout = etcd or network
                     → immediate x509 error = cert problem
                     → connection refused = process not running
2. crictl ps | grep apiserver → running or crashlooping?
3. crictl logs <id> → exact error message
4. openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text
   → tells you immediately if file is valid or garbage
```

Q: kubeadm certs renew apiserver — what does this actually do under the hood?

It reads the existing CA (ca.crt + ca.key), generates a new RSA key pair, creates a CSR with the correct SANs (pulled from kubeadm-config ConfigMap), signs it with the CA, and writes the new cert + key. The CA itself is NOT touched.

Q: What happens if the CA cert itself expires or is corrupted?

Far more catastrophic — every component's cert becomes unverifiable simultaneously. Recovery requires rebuilding the entire PKI from scratch and re-issuing every cert in the cluster. This is why ca.key should be stored offline in production (HSM or sealed Vault) once the cluster is bootstrapped — it's the nuclear key.

Q: After kubeadm certs renew, what else needs updating?

The kubeconfig files (admin.conf, controller-manager.conf, scheduler.conf) embed client certs. Run kubeadm certs renew all and then sudo cp /etc/kubernetes/admin.conf ~/.kube/config. If you only renew the apiserver serving cert, kubeconfig files are unaffected.
