# Demo Guide

## Recommended local reviewer workflow

The main way to run the full backup-strategy comparison on a local cluster is:

```bash
./scripts/run-backup-recovery-demo.sh --compare
```

This script creates or reuses a `kind` cluster, builds and loads the demo image, runs both crash-consistent and application-consistent scenarios under active writes, restores from backup, verifies recovery through the application API, and prints a side-by-side comparison summary. See the repository [README](../README.md) for field definitions and expected behavior.

The step-by-step sections below are a **manual** path: they walk through `kubectl` and `curl` for lower-level exploration and learning. They are not the primary reviewer workflow.

## How to Run & Demo (manual path)

### Manual path prerequisites

The manual steps assume:

- Docker is running
- `kind` is installed
- `kubectl` is installed
- A local kind cluster named `backup-recovery-demo` exists
- `kubectl` is configured to use that cluster (context `kind-backup-recovery-demo`)

If you need to create the cluster:

```bash
kind create cluster --name backup-recovery-demo
kubectl config use-context kind-backup-recovery-demo
kubectl cluster-info
```

### 1) Build and load image

```bash
docker build -t kubernetes-backup-recovery-demo-app:latest ./app
kind load docker-image kubernetes-backup-recovery-demo-app:latest --name backup-recovery-demo
```

### 2) Deploy everything

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/pvc.yaml
kubectl apply -f k8s/backup-pvc.yaml
kubectl apply -f k8s/app-deployment.yaml
kubectl apply -f k8s/app-service.yaml
kubectl apply -f k8s/scripts-configmap.yaml
```

```bash
kubectl -n backup-recovery-demo get pods,pvc,svc
```

### 3) Generate data

```bash
kubectl -n backup-recovery-demo rollout status deployment/backup-recovery-demo-app --timeout=180s
kubectl -n backup-recovery-demo wait --for=condition=Ready pod -l app=backup-recovery-demo-app --timeout=180s
kubectl -n backup-recovery-demo port-forward svc/backup-recovery-demo-app 8080:8080
```

In a second terminal:

```bash
curl -s -X POST http://localhost:8080/write -H 'Content-Type: application/json' -d '{"data":{"id":1,"msg":"alpha"}}'
curl -s -X POST http://localhost:8080/write -H 'Content-Type: application/json' -d '{"data":{"id":2,"msg":"beta"}}'
curl -s -X POST http://localhost:8080/write -H 'Content-Type: application/json' -d '{"data":{"id":3,"msg":"gamma"}}'
```

### 4) Verify data

```bash
curl -s http://localhost:8080/read
```

Confirm `count` is greater than `0` and `items` contains the written records.

### 5) Run backup

```bash
kubectl -n backup-recovery-demo delete job backup-data-job --ignore-not-found
kubectl apply -f k8s/backup-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/backup-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/backup-data-job
```

The backup Job is currently configured to use `crash-consistent` mode. You can switch to `application-consistent` to compare behavior during active writes.

Expected log includes: `backup completed: /data/data.jsonl -> /backup/data-<timestamp>.jsonl`.

### 6) Simulate failure

Overwrite the app data file in the running pod:

```bash
POD=$(kubectl -n backup-recovery-demo get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n backup-recovery-demo exec "$POD" -- sh -c ': > /data/data.jsonl'
curl -s http://localhost:8080/read
```

Confirm `count` is `0`.

### 7) Run restore

```bash
kubectl -n backup-recovery-demo delete job restore-data-job --ignore-not-found
kubectl apply -f k8s/restore-job.yaml
kubectl -n backup-recovery-demo wait --for=condition=complete job/restore-data-job --timeout=60s
kubectl -n backup-recovery-demo logs job/restore-data-job
```

### 8) Verify recovery

```bash
curl -s http://localhost:8080/read
```

Confirm the previous records are back.

## Scheduled Backups

This demo also includes a Kubernetes CronJob for periodic backups in `k8s/backup-cronjob.yaml`.

The CronJob runs every 2 minutes for demo purposes, uses `crash-consistent` mode by default to avoid interfering with application writes, and reuses the same backup script.

## Backup Versioning

Backups are stored as versioned backup files (for example `data-2026-04-10T18-30-00Z.jsonl`) with matching versioned metadata files (`metadata-2026-04-10T18-30-00Z.json`), so multiple backups are retained.

Restore automatically selects the latest backup and verifies it using the checksum from the matching metadata file.

Backups are not automatically pruned in this demo. Real systems require retention policies, for example keeping the last N backups or using time-based retention windows.

## What These Scenarios Demonstrate

- Backups are only useful when restore is validated end-to-end.
- Checksum verification is required to detect silent corruption.
- PVC-backed data survives pod restarts, but not application-level data loss.
- Restore workflows must fail clearly on missing or invalid backup artifacts.
- Operational confidence comes from regularly exercising failure and recovery paths.

## Consistency helper (lower-level, single mode)

`scripts/run-consistency-demo.sh` is a **lower-level helper** invoked by `run-backup-recovery-demo.sh`. It is not the main user-facing entry point. Use it when you already have a cluster, port-forward, and matching manifests loaded, and you want to **debug one mode in isolation** (for example a single crash-consistent or application-consistent run) without the full kind orchestration.

For the full two-strategy comparison, prefer `./scripts/run-backup-recovery-demo.sh --compare` (see the top of this guide).

Crash-consistent (helper only; requires app reachable as for the manual path above):

```bash
DEMO_MODE=crash-consistent ./scripts/run-consistency-demo.sh
```

Application-consistent:

```bash
DEMO_MODE=application-consistent SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO=3 ./scripts/run-consistency-demo.sh
```

Extending `SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO` increases freeze-window visibility in fast local environments.
