# Failure Scenarios

## Failure Injection (Testing Recovery Behavior)

Failure injection is supported through environment variables on the backup and restore Jobs.

- Backup Job: `FAIL_BEFORE_COPY`, `FAIL_AFTER_COPY`, `SLEEP_BEFORE_COPY_SECONDS`
- Restore Job: `FAIL_BEFORE_RESTORE`, `FAIL_AFTER_RESTORE_COPY`, `SLEEP_BEFORE_RESTORE_SECONDS`

Defaults are non-disruptive (`false` and `0`), so normal behavior is unchanged.

### Example 1: backup failure before copy

Edit `k8s/backup-job.yaml` and set:

```yaml
- name: FAIL_BEFORE_COPY
  value: "true"
```

Then run:

```bash
kubectl -n backup-recovery-demo delete job backup-data-job --ignore-not-found
kubectl apply -f k8s/backup-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=failed job/backup-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/backup-data-job
```

### Example 2: restore failure after copy

Edit `k8s/restore-job.yaml` and set:

```yaml
- name: FAIL_AFTER_RESTORE_COPY
  value: "true"
```

Then run:

```bash
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=failed job/restore-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/restore-data-job
```

After testing failure scenarios, reset the environment variables back to `"false"` to restore normal behavior.

## Failure Scenarios to Test

### A) Data loss

This simulates application-level data loss while persistent backup files still exist.

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n backup-recovery-demo exec "$POD" -- sh -c ': > /data/data.jsonl'
curl -s http://localhost:8080/read
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/restore-data-job --timeout=60s
curl -s http://localhost:8080/read
```

Expected outcome: read output is empty after truncation, then previous data returns after restore.

### B) Pod restart

This simulates runtime pod failure while PVC-backed data remains intact.

```bash
kubectl -n backup-recovery-demo delete pod -l app=backup-recovery-demo-app
kubectl -n backup-recovery-demo wait --for=condition=Ready pod -l app=backup-recovery-demo-app --timeout=120s
curl -s http://localhost:8080/read
```

Expected outcome: a new pod is created and data is still present because it is stored on the PVC.

### C) Backup corruption

This simulates tampered backup content to validate checksum-based integrity detection.

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
LATEST_BACKUP=$(kubectl -n backup-recovery-demo exec "$POD" -- sh -c "ls -1 /backup/data-*.jsonl 2>/dev/null | sort -r | head -n 1")
kubectl -n backup-recovery-demo exec "$POD" -- sh -c "echo 'corruption' >> \"$LATEST_BACKUP\""
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=failed job/restore-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/restore-data-job
```

Expected outcome: restore fails and logs show checksum mismatch.

### D) Missing backup

This simulates a restore attempt when backup artifacts are missing.

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n backup-recovery-demo exec "$POD" -- sh -c 'rm -f /backup/data-*.jsonl /backup/metadata-*.json'
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=failed job/restore-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/restore-data-job
```

Expected outcome: restore fails because no backup files are available.
