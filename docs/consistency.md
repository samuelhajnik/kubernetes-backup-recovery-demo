# Consistency Model

## Backup Consistency Modes

This demo supports two backup modes:

- `crash-consistent`: copy data without coordinating with the app
- `application-consistent`: call `POST /freeze`, run backup, then call `POST /unfreeze`

Application-consistent mode provides a cleaner coordinated restore point during active writes because the backup is taken while writes are temporarily blocked.

In this demo, the manual backup Job defaults to `crash-consistent`, while `application-consistent` mode is available for comparison and validation.

## Write-Loop Helper

Use the write-loop helper to generate continuous writes:

```bash
APP_URL=http://localhost:8080 WRITE_INTERVAL_SECONDS=0.1 MAX_WRITES=50 ./scripts/write-loop.sh
```

## Consistency Comparison Scenario

**Recommended:** to compare both strategies in one run with restore verification and a printed summary, use:

```bash
./scripts/run-backup-recovery-demo.sh --compare
```

That is the primary local reviewer workflow (see the repository [README](../README.md)).

The subsections **A** and **B** below are an **advanced, manual** walkthrough. They are useful for step-by-step exploration with `kubectl` and `curl` when you want to control each step yourself. They are not the default path for comparing strategies.

At a high level:

- Crash-consistent mode captures storage state without coordinating with the app.
- Application-consistent mode coordinates backup with the app by freezing writes briefly.

### A) Crash-consistent under active writes

1. Start port-forward:

```bash
kubectl -n backup-recovery-demo port-forward svc/backup-recovery-demo-app 8080:8080
```

2. In a second terminal, run continuous writes:

```bash
APP_URL=http://localhost:8080 WRITE_INTERVAL_SECONDS=0.1 MAX_WRITES=1000 ./scripts/write-loop.sh
```

3. Ensure `k8s/backup-job.yaml` has `BACKUP_MODE=crash-consistent`, then trigger backup:

```bash
kubectl -n backup-recovery-demo delete job backup-data-job --ignore-not-found
kubectl apply -f k8s/backup-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/backup-data-job --timeout=60s
```

4. Observe and compare writer output, backup logs, and `/backup-status`:

```bash
kubectl -n backup-recovery-demo logs job/backup-data-job
curl -s http://localhost:8080/backup-status
```

5. Truncate live app data before restore to prove recovery comes from backup:

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n backup-recovery-demo exec "$POD" -- sh -c ': > /data/data.jsonl'
curl -s http://localhost:8080/read
```

6. Run restore and compare restored `/read` output:

```bash
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/restore-data-job --timeout=60s
curl -s http://localhost:8080/read
```

### B) Application-consistent under active writes

1. Keep port-forward running and restart the write loop:

```bash
APP_URL=http://localhost:8080 WRITE_INTERVAL_SECONDS=0.1 MAX_WRITES=1000 ./scripts/write-loop.sh
```

2. Set `k8s/backup-job.yaml` to `BACKUP_MODE=application-consistent`, then trigger backup:

```bash
kubectl -n backup-recovery-demo delete job backup-data-job --ignore-not-found
kubectl apply -f k8s/backup-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/backup-data-job --timeout=60s
```

3. Observe and compare writer output, backup logs, and `/backup-status` (during freeze, some write-loop requests may return HTTP `409`, which is expected):

```bash
kubectl -n backup-recovery-demo logs job/backup-data-job
curl -s http://localhost:8080/backup-status
```

4. Truncate live app data before restore to prove recovery comes from backup:

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n backup-recovery-demo exec "$POD" -- sh -c ': > /data/data.jsonl'
curl -s http://localhost:8080/read
```

5. Run restore and compare restored `/read` output:

```bash
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/restore-data-job --timeout=60s
curl -s http://localhost:8080/read
```

In a fast local environment, the freeze window may be too short to observe clearly.

Use either:

- `SLEEP_BEFORE_COPY_SECONDS=3` in `k8s/backup-job.yaml`, or
- the lower-level helper (single mode, with cluster and port-forward already set up):  
  `DEMO_MODE=application-consistent SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO=3 ./scripts/run-consistency-demo.sh`

`run-consistency-demo.sh` is a focused debugging helper, not a replacement for `./scripts/run-backup-recovery-demo.sh --compare` when you want the full automated comparison.
