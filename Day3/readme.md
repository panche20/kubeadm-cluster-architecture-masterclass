# Kubernetes ETCD Backup & Restore Guide

This guide walks you through installing the required tools, backing up the ETCD database on a kubeadm-managed cluster, and performing a safe restore.

To choose the correct version of etcdctl and etcdutl, you should always match the version of the utilities to the exact version of ETCD currently running inside your cluster.
Because kubeadm deploys ETCD as a static pod, the easiest way to find this is by checking the image tag of your running ETCD pod.
Here is the step-by-step process to find your version and decide which one to install:

## Phase 1 : ETCD BACKUP

### Step 1: Check your Running ETCD Version

Run the following command on your master node to inspect the ETCD container image:

```
kubectl get pod -n kube-system -l component=etcd -o jsonpath='{.items[0].spec.containers[0].image}'
```

*Expected Output Example:*

```
registry.k8s.io/etcd:3.5.21-0
```

### Step 2: Decide the Utility Version
You should download the etcd release binary that matches the major and minor version of your output (and ideally the exact patch version).

If your cluster runs 3.5.15, set ETCD_VER=v3.5.15.

If your cluster runs 3.6.2, set ETCD_VER=v3.6.2.

⚠️ Important Architecture Note for etcdutl:
The separate etcdutl binary was introduced in ETCD v3.6.

If your version is v3.6+: You will have two distinct binaries (etcdctl and etcdutl).

If your version is v3.5 or older: etcdutl does not exist as a separate file. Instead, etcdctl handles everything (including restores).

**Install etcdctl for v3.5.21**

Run this on your master node to download and install the exact matching version:

```
# Set version to match your pod
ETCD_VER=v3.5.21

# Download and extract the archive
curl -LO https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz

# Move etcdctl to your system binary path
sudo mv etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/

# Verify the version
etcdctl version

# Clean up installer files
rm -rf etcd-${ETCD_VER}-linux-amd64*
```

### Step 3 : The Backup

**Verify ETCD Pod Health**

Before taking a snapshot, let's verify that the ETCD pod is healthy and running.

```
kubectl get pods -n kube-system -l component=etcd
```

What to look for: Ensure the status says *Running* and the restarts count is stable.

### Step 4 : Create the Backup Directory & Take the Snapshot
We will use etcdctl to securely connect to the local ETCD instance using the cluster's internal certificates and save a snapshot to /tmp/etcd-backup.db.

```
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /tmp/etcd-backup.db
```

### Step 5 : Verify Snapshot Integrity
Never assume a backup file is healthy just because it exists. Let's verify its internal database status:

```
sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /tmp/etcd-backup.db
```

*What to look for*: 

You should see a table displaying the Revision, Total Keys, and Total Size. If you see this table, your backup is valid and safe.

## Phase 2: The Restore

### Step 6 : Stop the Kubelet
To safely swap the database underneath Kubernetes without causing conflicts, we must temporarily stop the kubelet service.

```
sudo systemctl stop kubelet
```

### Step 7 : Backup the Existing Data Directory
Move the current active data directory out of the way. We rename it rather than deleting it so we have a rollback option if needed.

```
sudo mv /var/lib/etcd /var/lib/etcd-old
```

### Step 8 : Restore the Snapshot (Using ETCD v3.5 syntax)
Now, we initialize a brand new data directory at /var/lib/etcd using the snapshot file we created in Step 2.

```
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-backup.db \
  --data-dir=/var/lib/etcd
```

### Step 8 : Restart Kubelet
Now that the new data directory is ready, restart the kubelet. It will automatically spin up the ETCD static pod using the restored data.

```
sudo systemctl start kubelet
```

### Step 9 : Verify Cluster Recovery
It takes about 1–2 minutes for the control plane components to fully restart and sync up. Run these commands to verify everything is back online:

```
# Check if all system pods come back to a Running state
kubectl get pods -n kube-system

# Verify your nodes are Ready
kubectl get nodes
```

**Just to be 100% certain everything is completely back to normal, it's always a good habit to run one final check on the core Kubernetes API health:**

```
kubectl get componentstatuses
```

***************************************************************************************************************************************************

# Automate ETCD Backup

To back up ETCD automatically, we will create a standard Linux Cron Job on your master node that runs a shell script at a regular interval (e.g., every day at midnight).

Here is the step-by-step setup to implement an automated, timestamped ETCD backup.

## Step 1: Create the Backup Script
First, we will create a script that takes the snapshot and names the file with the current date and time so backups don't overwrite each other.

**Open a new file using nano:**

```
sudo nano /usr/local/bin/etcd-backup.sh
```

**Paste the following script into the file:**

```
#!/bin/bash

# Define backup directory and timestamp
BACKUP_DIR="/var/lib/etcd-backups"
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
BACKUP_FILE="${BACKUP_DIR}/etcd-backup-${TIMESTAMP}.db"

# Ensure backup directory exists
mkdir -p ${BACKUP_DIR}

# Run the etcdctl snapshot command
ETCDCTL_API=3 /usr/local/bin/etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save ${BACKUP_FILE}

# Optional: Delete backups older than 7 days to save disk space
find ${BACKUP_DIR} -type f -name "etcd-backup-*.db" -mtime +7 -delete
```

**Save and exit (Ctrl+O, Enter, then Ctrl+X).**

## Step 2: Make the Script Executable

Give the script the correct permissions so the system can run it:

```
sudo chmod +x /usr/local/bin/etcd-backup.sh
```

**Test the script manually:**

Run it once to make sure it works without errors:

```
sudo /usr/local/bin/etcd-backup.sh
```

*Verify the backup file was created:*

```
sudo ls -lh /var/lib/etcd-backups
```

## Step 3: Configure the Cron Job
Now we will schedule this script to run automatically using the root user's crontab (since ETCD backup requires root privileges to read the certificates).

**Open the crontab editor:**

```
sudo crontab -e
```

**Add the following line at the very bottom of the file:**

```
0 0 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

**Save and exit (Ctrl+O, Enter, then Ctrl+X).**

**How this scheduling works:**

```
Value                                Meaning
0 0 * * *                            Runs every day at exactly midnight (00:00).
/usr/local/bin/...                   Executes your automated backup script.
>> /var/log/...                      Redirects all output and errors to a log file so you can check if it's succeeding.
```

If you ever want to check if your automated backups are running fine, you can simply view the log file using:

```
sudo cat /var/log/etcd-backup.log
```

