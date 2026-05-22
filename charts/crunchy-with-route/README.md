# Crunchy PostgreSQL Cluster for BCGSDI Staging

This Helm chart deploys a highly available PostgreSQL cluster using the Crunchy PostgreSQL Operator with automated backups, connection pooling, and PostGIS support.

## Features

- **High Availability**: 2 PostgreSQL instances (primary + replica) with automatic failover
- **Dual Backup Strategy**: 
  - **repo1**: Local PVC-based backups for fast recovery
  - **repo2**: S3-based backups for offsite disaster recovery
- **Connection Pooling**: PgBouncer for improved performance and scalability
- **PostGIS Support**: Geographic information system extension
- **Automated Backups**: Scheduled full and incremental backups
- **Point-in-Time Recovery**: Restore to any point in time from backups

## Backup Configuration

The cluster is configured with two backup repositories:

### Repository 1 (repo1) - PVC Backup

- **Purpose**: Local backup copy stored on persistent volume for fast recovery
- **Storage**: 10Gi on `netapp-file-backup` storage class
- **Retention**: 7 full backups (configurable via `pgBackRest.repo1Retention`)
- **Schedule**:
  - Full backup: Daily at 8:00 AM UTC (`0 8 * * *`)
  - Incremental backup: Every 4 hours at 12:00 AM, 4:00 AM, 12:00 PM, 4:00 PM, 8:00 PM UTC (`0 0,4,12,16,20 * * *`)

### Repository 2 (repo2) - S3 Backup

- **Purpose**: Offsite backup for disaster recovery
- **Storage**: S3-compatible object storage at `nrs.objectstore.gov.bc.ca`
- **Retention**: 30 full backups (configurable via `pgBackRest.repo2Retention`)
- **Schedule**:
  - Full backup: Daily at 9:00 AM UTC (`0 9 * * *`)
  - Incremental backup: Every 4 hours at 1:00 AM, 5:00 AM, 1:00 PM, 5:00 PM, 9:00 PM UTC (`0 1,5,13,17,21 * * *`)

**Note:** S3 backup schedules are offset by 1 hour from PVC schedules to avoid resource conflicts.

## Verifying PVC Backups

### 1. Check Backup Repository Pod

The PVC backup repository is managed by the `repo-host` pod:

```bash
# List all pods in the namespace
kubectl get pods -n <namespace>

# Find the repo-host pod
kubectl get pods -n <namespace> | grep repo-host

# Example output:
# bcgsdi-staging-geochem-crunchy-postgres-repo-host-0   2/2     Running   0          1h
```

### 2. Access the Backup PVC

The backup files are stored in a persistent volume claim (PVC):

```bash
# List PVCs
kubectl get pvc -n <namespace>

# Find the backup PVC
kubectl get pvc -n <namespace> | grep pgbackrest

# Example output:
# bcgsdi-staging-geochem-crunchy-postgres-repo1   Bound    pvc-xxxxx   10Gi       RWO            netapp-file-backup   1h
```

### 3. Verify Backup Files Exist

You can exec into the repo-host pod to verify backup files:

```bash
# Access the repo-host pod
kubectl exec -it bcgsdi-staging-geochem-crunchy-postgres-repo-host-0 -n <namespace> -c pgbackrest -- bash

# Navigate to the backup repository directory
cd /pgbackrest/repo1

# List backup files
ls -lh

# View backup info
pgbackrest info --stanza=db --repo=1

# Example output:
# stanza: db
#     status: ok
#     cipher: none
#
#     db (current)
#         wal archive min/max (18): 000000010000000000000001/000000010000000000000008
#
#         full backup: 20260219-080000F
#             timestamp start/stop: 2026-02-19 08:00:00 / 2026-02-19 08:05:23
#             wal start/stop: 000000010000000000000002 / 000000010000000000000002
#             database size: 25.3MB, database backup size: 25.3MB
```

### 4. Check Backup Status via PostgresCluster

You can also check the backup status through the PostgresCluster custom resource:

```bash
# Get backup status
kubectl describe postgrescluster bcgsdi-staging-geochem-crunchy-postgres -n <namespace>

# Look for the "Pgbackrest" section in the status output
```

### 5. View Backup Logs

Check the logs of the repo-host pod for backup activity:

```bash
# View recent logs
kubectl logs bcgsdi-staging-geochem-crunchy-postgres-repo-host-0 -n <namespace> -c pgbackrest

# Follow logs in real-time
kubectl logs -f bcgsdi-staging-geochem-crunchy-postgres-repo-host-0 -n <namespace> -c pgbackrest
```

## Configuration Options

### Persistent Volume Configuration

The PVC backup volume is configured in `values.yaml`:

```yaml
pgBackRest:
  repos:
    volume:
      accessModes: "ReadWriteOnce"
      storage: 10Gi
      storageClassName: netapp-file-backup
```

**Storage Class**: The `netapp-file-backup` storage class is used for backup volumes. This is a file-based storage suitable for backup repositories that require ReadWriteOnce access.

### Backup Schedule Customization

You can customize backup schedules in `values.yaml`:

**PVC Backups (repo1):**
```yaml
pgBackRest:
  repos:
    schedules:
      full: 0 8 * * *  # Daily full backup at 8:00 AM UTC
      incremental: 0 0,4,12,16,20 * * *  # Incremental every 4 hours
```

**S3 Backups (repo2):**
```yaml
pgBackRest:
  s3:
    fullSchedule: "0 9 * * *"  # Daily full backup at 9:00 AM UTC
    incrementalSchedule: "0 1,5,13,17,21 * * *"  # Incremental every 4 hours
```

### Retention Policy

Adjust backup retention in `values.yaml`:

```yaml
pgBackRest:
  repo1Retention: "7"   # Keep 7 full backups on PVC
  repo2Retention: "30"  # Keep 30 full backups on S3
  retentionFullType: count  # 'count' or 'time'
```

## Disaster Recovery

### Restore from PVC Backup (repo1)

To restore from the local PVC backup:

```yaml
# In values.yaml
restoreFromBackup:
  enabled: true
  fromRepoName: repo1  # Use PVC backups for faster restore
  targetDatetime: '2026-02-19 08:00:00-08:00'
```

**Note:** PVC backups (repo1) provide faster restore times but have limited retention (7 full backups retained).

### Restore from S3 Backup (repo2)

To restore from S3 backup:

```yaml
# In values.yaml
restoreFromBackup:
  enabled: true
  fromRepoName: repo2  # Use S3 backups for longer retention
  targetDatetime: '2026-02-19 08:00:00-08:00'
```

**Note:** S3 backups (repo2) offer longer retention (30 full backups) but may be slower to restore.

### Bootstrap New Cluster from Backup

To create a new cluster from an existing backup:

```yaml
# In values.yaml
bootstrapFromBackup:
  enabled: true
  fromRepoName: repo2  # Use repo2 for S3 or repo1 for PVC
  stanza: db
```

**Backup Source Options:**
- `repo1`: Bootstrap from PVC backups (faster, 7 full backups available)
- `repo2`: Bootstrap from S3 backups (recommended - 30 full backups available)

## Infrastructure Requirements

### Persistent Volume Provisioner

The PVC backups require a storage provisioner that supports:
- **Access Mode**: ReadWriteOnce (RWO)
- **Storage Class**: `netapp-file-backup` (or another file-based storage class)
- **Dynamic Provisioning**: The storage class should support dynamic PVC provisioning

### Storage Class Verification

Verify the storage class exists in your cluster:

```bash
# List available storage classes
kubectl get storageclass

# Check if netapp-file-backup exists
kubectl get storageclass netapp-file-backup -o yaml
```

If the storage class doesn't exist, you'll need to:
1. Configure a storage provisioner (e.g., NetApp Trident)
2. Create the storage class with appropriate parameters
3. Ensure it supports ReadWriteOnce access mode

## Monitoring and Alerts

### Check Backup Job Status

Monitor backup jobs through CronJobs:

```bash
# List backup CronJobs
kubectl get cronjobs -n <namespace>

# View CronJob details
kubectl describe cronjob bcgsdi-staging-geochem-crunchy-postgres-repo1-full-cronjob -n <namespace>

# View recent jobs
kubectl get jobs -n <namespace> --sort-by=.metadata.creationTimestamp
```

### Backup Failure Alerts

Monitor for backup failures by checking:
1. CronJob execution status
2. Repo-host pod logs
3. PostgresCluster status conditions

## Troubleshooting

### Backup PVC Not Created

If the backup PVC is not created:
1. Verify the storage class exists and supports dynamic provisioning
2. Check the operator logs for errors
3. Verify RBAC permissions for the operator

### Backup Jobs Not Running

If scheduled backups are not executing:
1. Check if CronJobs are created: `kubectl get cronjobs -n <namespace>`
2. Verify the schedule syntax in values.yaml
3. Check operator logs for errors
4. Ensure the repo-host pod is running

### Insufficient Storage

If backups fail due to insufficient storage:
1. Increase `pgBackRest.repos.volume.storage` in values.yaml
2. The PVC will need to be resized (requires storage class with `allowVolumeExpansion: true`)
3. Or adjust retention policy to keep fewer backups

## Additional Resources

- [Crunchy PostgreSQL Operator Documentation](https://access.crunchydata.com/documentation/postgres-operator/latest/)
- [pgBackRest Documentation](https://pgbackrest.org/user-guide.html)
- [PostgreSQL Backup Best Practices](https://www.postgresql.org/docs/current/backup.html)
