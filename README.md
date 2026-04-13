# Kubernetes Backup & Recovery Demo

## Goal

Explore backup and recovery in Kubernetes with emphasis on **data consistency**, **failure scenarios**, and **system recovery**—what breaks, what must be preserved, and how to validate that a restore is trustworthy.

## Inspiration

Inspired by real-world challenges around data consistency, failure handling, and recovery in distributed systems.

## Problem

Distributed systems fail in layered ways: pods restart, nodes drain or die, storage misbehaves, and application state diverges from what operators assume is on disk. Backups are not useful unless we can **restore state reliably** when those failures occur.

> How do we reliably restore system state and data?

## Approach (MVP)

Initial scope:

- Run a **stateful workload** in Kubernetes with data that survives pod restarts only if the volume does.
- Use a **PersistentVolume** (or equivalent CSI-backed volume) as the source of truth for application data.
- Implement a **backup** as a **Kubernetes Job** that snapshots or copies data from the volume to external storage.
- Define an explicit **restore workflow** (new volume, restore data, reattach, verify) rather than ad-hoc `kubectl` steps.

## Architecture (initial)

```text
App (stateful)
    ↓
Persistent Volume
    ↓
Backup Job (Kubernetes Job)
    ↓
External Storage (simulated)
```

**Restore flow (conceptual):** provision a clean volume (or reset the data path), run a restore Job or init step that pulls from external storage into the volume, then start the app and run checks (read-back, checksums, or application-level assertions) to confirm consistency.

## Key Questions to Explore

- What consistency model does the app assume (e.g. crash consistency vs application-quiesced)?
- When is the backup taken relative to ongoing writes, and what does that imply for restore?
- Behavior of backups **during active writes** (open files, fs cache, database semantics if applicable).
- Separation of **data vs metadata** (Kubernetes objects, PVC bindings, secrets vs bytes on disk).
- How to prove a restore succeeded (verification criteria, not just “pod is Running”).
- Failure modes to design for: node loss, partial backup, corrupt archive, wrong PVC bound to a pod.

## Future Extensions

- Incremental backups and retention policy.
- Scheduling backups with **CronJob** and operational runbooks.
- Multi-component systems (e.g. Kafka, Postgres) and ordering/coordination of backups.
- Controlled **failure injection** to exercise restore under realistic conditions.
- Custom **controller/operator** to automate backup/restore lifecycle and status reporting.

## Status

MVP implemented — backup and restore workflow with checksum verification is functional.

Future work will focus on deeper consistency guarantees, failure scenarios, and recovery validation.

## Backup Consistency Modes

This demo supports two backup modes:

- `crash-consistent`: copy data without coordinating with the app.
- `application-consistent`: call `POST /freeze`, run backup, then call `POST /unfreeze`.

Application-consistent mode matters during active writes because it prevents new writes while the backup copy is taken, reducing the chance of inconsistent snapshots.

## How to Run & Demo

### 1) Build and load image

```bash
docker build -t kubernetes-backup-recovery-demo-app:latest ./app
kind load docker-image kubernetes-backup-recovery-demo-app:latest
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

To test application-consistent mode, change `BACKUP_MODE` in `k8s/backup-job.yaml` from `crash-consistent` to `application-consistent` before applying the Job.

Expected log includes: `backup completed: /data/data.jsonl -> /backup/data.jsonl`.

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

### 9) Observability hints

```bash
kubectl -n backup-recovery-demo get pods
kubectl -n backup-recovery-demo logs deploy/backup-recovery-demo-app
kubectl -n backup-recovery-demo describe job backup-data-job
kubectl -n backup-recovery-demo describe job restore-data-job
```
