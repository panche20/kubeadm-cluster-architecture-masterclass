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
