# Observability and Status Endpoint

## Runtime Observability

For this demo, lightweight command-based observability is enough:

```bash
kubectl -n backup-recovery-demo get pods
kubectl -n backup-recovery-demo logs deploy/backup-recovery-demo-app
kubectl -n backup-recovery-demo describe job backup-data-job
kubectl -n backup-recovery-demo describe job restore-data-job
curl -s http://localhost:8080/backup-status
```

## `/backup-status` Endpoint

`/backup-status` returns the latest known backup or restore result (operation details such as mode, file name, checksum, and success/failure message), or `status: unknown` if no operation has run yet.

The application exposes a `/backup-status` endpoint that returns information about the latest backup or restore operation.

Common fields:
- `operation` (`backup`/`restore`)
- `status` (`success`/`failure`/`unknown`)
- `timestamp`
- `message`
- `duration_ms`

Backup-specific fields:
- `mode` (`crash-consistent`/`application-consistent`)
- `backup_file`
- `checksum`
- `bytes_written`

Restore-specific fields:
- `restored_file`
- `checksum_valid`

Example successful backup response:

```json
{
  "operation": "backup",
  "status": "success",
  "timestamp": "2026-04-13T20:15:42Z",
  "mode": "crash-consistent",
  "backup_file": "data-2026-04-13T20-15-42Z.jsonl",
  "checksum": "8c58d1570f8ea1e4268259c1d2697f1771495f07f937bf84b67fde7a2f9f26eb",
  "message": "backup completed",
  "duration_ms": 2000,
  "bytes_written": 245
}
```

These fields make it easier to reason about backup and restore health, runtime, and data movement without adding a full metrics stack.
