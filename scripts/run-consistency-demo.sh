#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-backup-recovery-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"
WRITE_INTERVAL_SECONDS="${WRITE_INTERVAL_SECONDS:-0.1}"
MAX_WRITES="${MAX_WRITES:-1000}"
DEMO_MODE="${DEMO_MODE:-}"
APP_BACKUP_JOB_FILE="${APP_BACKUP_JOB_FILE:-k8s/backup-job.yaml}"
APP_RESTORE_JOB_FILE="${APP_RESTORE_JOB_FILE:-k8s/restore-job.yaml}"
SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO="${SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO:-0}"
BACKUP_START_MIN_RECORDS="${BACKUP_START_MIN_RECORDS:-25}"
SUMMARY_FILE="${SUMMARY_FILE:-}"

case "$MAX_WRITES" in
  ''|*[!0-9]*)
    echo "invalid MAX_WRITES=$MAX_WRITES (must be a non-negative integer)" >&2
    exit 1
    ;;
esac

case "$SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO" in
  ''|*[!0-9]*)
    echo "invalid SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO=$SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO (must be a non-negative integer)" >&2
    exit 1
    ;;
esac

case "$BACKUP_START_MIN_RECORDS" in
  ''|*[!0-9]*)
    echo "invalid BACKUP_START_MIN_RECORDS=$BACKUP_START_MIN_RECORDS (must be a non-negative integer)" >&2
    exit 1
    ;;
esac

case "$WRITE_INTERVAL_SECONDS" in
  ''|*[!0-9.]*|*.*.*|.)
    echo "invalid WRITE_INTERVAL_SECONDS=$WRITE_INTERVAL_SECONDS" >&2
    exit 1
    ;;
esac

if [ -z "$DEMO_MODE" ]; then
  echo "DEMO_MODE is required (crash-consistent or application-consistent)" >&2
  exit 1
fi
if [ "$DEMO_MODE" != "crash-consistent" ] && [ "$DEMO_MODE" != "application-consistent" ]; then
  echo "invalid DEMO_MODE=$DEMO_MODE (expected crash-consistent or application-consistent)" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "/tmp/consistency-demo.XXXXXX")"
WRITE_LOG="$TMP_DIR/write-loop.log"
BACKUP_LOG="$TMP_DIR/backup-job.log"
RESTORE_LOG="$TMP_DIR/restore-job.log"
BACKUP_STATUS_FILE="$TMP_DIR/backup-status.json"
RESTORE_STATUS_FILE="$TMP_DIR/restore-status.json"
READ_OUTPUT_FILE="$TMP_DIR/read-output.json"
BACKUP_JOB_TMP="$TMP_DIR/backup-job.yaml"
RESTORE_JOB_TMP="$TMP_DIR/restore-job.yaml"

WRITER_PID=""
PREFROZEN=0

cleanup() {
  if [ -n "$WRITER_PID" ]; then
    kill "$WRITER_PID" 2>/dev/null || true
    wait "$WRITER_PID" 2>/dev/null || true
  fi
  if [ "$PREFROZEN" -eq 1 ]; then
    curl -fsS -X POST "$APP_URL/unfreeze" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if ! curl -fsS "$APP_URL/health" >/dev/null; then
  echo "failed to reach app at $APP_URL (check port-forward/service reachability)" >&2
  exit 1
fi

POD="$(kubectl -n "$NAMESPACE" get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')"
echo "==> Resetting application data for scenario: $DEMO_MODE"
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c ': > /data/data.jsonl' >/dev/null
kubectl -n "$NAMESPACE" exec "$POD" -- sh -c 'rm -f /backup/data-*.jsonl /backup/metadata-*.json /backup/backup-status.json' >/dev/null

cp "$APP_BACKUP_JOB_FILE" "$BACKUP_JOB_TMP"
cp "$APP_RESTORE_JOB_FILE" "$RESTORE_JOB_TMP"

KEEP_FROZEN_AFTER_BACKUP_VALUE="false"
if [ "$DEMO_MODE" = "application-consistent" ]; then
  KEEP_FROZEN_AFTER_BACKUP_VALUE="true"
fi

awk -v mode="$DEMO_MODE" -v sleepv="$SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO" -v keepfrozen="$KEEP_FROZEN_AFTER_BACKUP_VALUE" '
  /name: BACKUP_MODE/ {print; getline; print "              value: \"" mode "\""; next}
  /name: SLEEP_BEFORE_COPY_SECONDS/ {print; getline; print "              value: \"" sleepv "\""; next}
  /name: KEEP_FROZEN_AFTER_BACKUP/ {print; getline; print "              value: \"" keepfrozen "\""; next}
  {print}
' "$BACKUP_JOB_TMP" > "$BACKUP_JOB_TMP.tmp" && mv "$BACKUP_JOB_TMP.tmp" "$BACKUP_JOB_TMP"

APP_URL="$APP_URL" WRITE_INTERVAL_SECONDS="$WRITE_INTERVAL_SECONDS" MAX_WRITES="$MAX_WRITES" ./scripts/write-loop.sh >"$WRITE_LOG" 2>&1 &
WRITER_PID=$!

echo "==> Waiting until at least ${BACKUP_START_MIN_RECORDS} records exist before backup"
RECORDS_PRESENT_BEFORE_BACKUP=""
for _ in $(seq 1 30); do
  RECORDS_PRESENT_BEFORE_BACKUP="$(curl -s "$APP_URL/read" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo "0")"
  if [ "$RECORDS_PRESENT_BEFORE_BACKUP" -ge "$BACKUP_START_MIN_RECORDS" ]; then
    break
  fi
  sleep 1
done

if [ -z "$RECORDS_PRESENT_BEFORE_BACKUP" ] || [ "$RECORDS_PRESENT_BEFORE_BACKUP" -lt "$BACKUP_START_MIN_RECORDS" ]; then
  echo "failed to reach BACKUP_START_MIN_RECORDS=$BACKUP_START_MIN_RECORDS within 30s (current=${RECORDS_PRESENT_BEFORE_BACKUP:-0})" >&2
  exit 1
fi

if [ "$DEMO_MODE" = "crash-consistent" ]; then
  RECORDS_AT_BACKUP_BOUNDARY="$RECORDS_PRESENT_BEFORE_BACKUP"
  echo "==> Starting crash-consistent backup without freezing writes: records_at_backup_boundary=$RECORDS_AT_BACKUP_BOUNDARY"
else
  curl -fsS -X POST "$APP_URL/freeze" >/dev/null
  PREFROZEN=1
  RECORDS_AT_BACKUP_BOUNDARY="$(curl -s "$APP_URL/read" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' 2>/dev/null || echo "0")"
  echo "==> Application freeze active: records_at_backup_boundary=$RECORDS_AT_BACKUP_BOUNDARY"
  echo "==> Starting application-consistent backup from frozen application state"
fi

kubectl -n "$NAMESPACE" delete job backup-data-job --ignore-not-found >/dev/null
kubectl apply -f "$BACKUP_JOB_TMP" >/dev/null
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/backup-data-job --timeout=120s >/dev/null; then
  kubectl -n "$NAMESPACE" logs job/backup-data-job >"$BACKUP_LOG" 2>&1 || true
  curl -s "$APP_URL/backup-status" >"$BACKUP_STATUS_FILE" || true
  echo "backup job did not complete successfully" >&2
  echo "  write_log: $WRITE_LOG" >&2
  echo "  backup_log: $BACKUP_LOG" >&2
  echo "  restore_log: $RESTORE_LOG" >&2
  echo "  backup_status_file: $BACKUP_STATUS_FILE" >&2
  echo "  restore_status_file: $RESTORE_STATUS_FILE" >&2
  echo "  read_output_file: $READ_OUTPUT_FILE" >&2
  exit 1
fi
kubectl -n "$NAMESPACE" logs job/backup-data-job >"$BACKUP_LOG" 2>&1
curl -s "$APP_URL/backup-status" >"$BACKUP_STATUS_FILE"

kill "$WRITER_PID" 2>/dev/null || true
wait "$WRITER_PID" 2>/dev/null || true
WRITER_PID=""

if [ "$DEMO_MODE" = "application-consistent" ]; then
  curl -fsS -X POST "$APP_URL/unfreeze" >/dev/null
  PREFROZEN=0
fi

WRITES_REJECTED_DURING_FREEZE="$(awk 'index($0, "status=409") > 0 {c++} END {print c+0}' "$WRITE_LOG")"

kubectl -n "$NAMESPACE" exec "$POD" -- sh -c ': > /data/data.jsonl' >/dev/null

kubectl -n "$NAMESPACE" delete job restore-data-job --ignore-not-found >/dev/null
kubectl apply -f "$RESTORE_JOB_TMP" >/dev/null
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/restore-data-job --timeout=120s >/dev/null; then
  kubectl -n "$NAMESPACE" logs job/restore-data-job >"$RESTORE_LOG" 2>&1 || true
  curl -s "$APP_URL/backup-status" >"$RESTORE_STATUS_FILE" || true
  echo "restore job did not complete successfully" >&2
  echo "  write_log: $WRITE_LOG" >&2
  echo "  backup_log: $BACKUP_LOG" >&2
  echo "  restore_log: $RESTORE_LOG" >&2
  echo "  backup_status_file: $BACKUP_STATUS_FILE" >&2
  echo "  restore_status_file: $RESTORE_STATUS_FILE" >&2
  echo "  read_output_file: $READ_OUTPUT_FILE" >&2
  exit 1
fi
kubectl -n "$NAMESPACE" logs job/restore-data-job >"$RESTORE_LOG" 2>&1
curl -s "$APP_URL/backup-status" >"$RESTORE_STATUS_FILE"
curl -s "$APP_URL/read" >"$READ_OUTPUT_FILE"

BACKUP_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","unknown"))' "$BACKUP_STATUS_FILE" 2>/dev/null || echo "unknown")"
RECORDS_CAPTURED_IN_BACKUP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("records_captured",0))' "$BACKUP_STATUS_FILE" 2>/dev/null || echo "0")"
RESTORE_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","unknown"))' "$RESTORE_STATUS_FILE" 2>/dev/null || echo "unknown")"
RESTORE_CHECKSUM_VALID="$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("checksum_valid"); print("true" if v is True else "false")' "$RESTORE_STATUS_FILE" 2>/dev/null || echo "false")"
RESTORED_RECORDS_AFTER_RESTORE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("count",0))' "$READ_OUTPUT_FILE" 2>/dev/null || echo "0")"
RECORDS_ADDED_WHILE_BACKUP_WAS_IN_PROGRESS=$((RECORDS_CAPTURED_IN_BACKUP - RECORDS_AT_BACKUP_BOUNDARY))
if [ "$RESTORE_STATUS" = "success" ] && [ "$RESTORE_CHECKSUM_VALID" = "true" ]; then
  RESTORE_VERIFICATION_RESULT="pass"
else
  RESTORE_VERIFICATION_RESULT="fail"
fi

if [ "$RESTORE_VERIFICATION_RESULT" = "pass" ] && [ "$RECORDS_CAPTURED_IN_BACKUP" != "$RESTORED_RECORDS_AFTER_RESTORE" ]; then
  echo "ERROR: restore verification invariant failed: records_captured_in_backup=$RECORDS_CAPTURED_IN_BACKUP restored_records_after_restore=$RESTORED_RECORDS_AFTER_RESTORE" >&2
  exit 1
fi
if [ "$DEMO_MODE" = "application-consistent" ] && [ "$RESTORE_VERIFICATION_RESULT" = "pass" ] && [ "$RECORDS_CAPTURED_IN_BACKUP" != "$RECORDS_AT_BACKUP_BOUNDARY" ]; then
  echo "ERROR: application-consistent invariant failed: records_at_backup_boundary=$RECORDS_AT_BACKUP_BOUNDARY records_captured_in_backup=$RECORDS_CAPTURED_IN_BACKUP" >&2
  exit 1
fi
if [ "$DEMO_MODE" = "application-consistent" ] && [ "$RESTORE_VERIFICATION_RESULT" = "pass" ] && [ "$RECORDS_ADDED_WHILE_BACKUP_WAS_IN_PROGRESS" -ne 0 ]; then
  echo "ERROR: application-consistent invariant failed: records_added_while_backup_was_in_progress=$RECORDS_ADDED_WHILE_BACKUP_WAS_IN_PROGRESS" >&2
  exit 1
fi

echo "demo summary"
echo "  mode: $DEMO_MODE"
echo "  writes_rejected_during_freeze: $WRITES_REJECTED_DURING_FREEZE"
echo "  records_at_backup_boundary: $RECORDS_AT_BACKUP_BOUNDARY"
echo "  records_added_while_backup_was_in_progress: $RECORDS_ADDED_WHILE_BACKUP_WAS_IN_PROGRESS"
echo "  records_captured_in_backup: $RECORDS_CAPTURED_IN_BACKUP"
echo "  restored_records_after_restore: $RESTORED_RECORDS_AFTER_RESTORE"
echo "  backup_status: ${BACKUP_STATUS:-unknown}"
echo "  restore_status: ${RESTORE_STATUS:-unknown}"
echo "  restore_checksum_valid: $RESTORE_CHECKSUM_VALID"
echo "  restore_verification_result: $RESTORE_VERIFICATION_RESULT"
echo "  write_log: $WRITE_LOG"
echo "  backup_log: $BACKUP_LOG"
echo "  restore_log: $RESTORE_LOG"
echo "  backup_status_file: $BACKUP_STATUS_FILE"
echo "  restore_status_file: $RESTORE_STATUS_FILE"
echo "  read_output_file: $READ_OUTPUT_FILE"

if [ -n "$SUMMARY_FILE" ]; then
  {
    echo "mode=$DEMO_MODE"
    echo "writes_rejected_during_freeze=$WRITES_REJECTED_DURING_FREEZE"
    echo "records_at_backup_boundary=$RECORDS_AT_BACKUP_BOUNDARY"
    echo "records_added_while_backup_was_in_progress=$RECORDS_ADDED_WHILE_BACKUP_WAS_IN_PROGRESS"
    echo "records_captured_in_backup=$RECORDS_CAPTURED_IN_BACKUP"
    echo "restored_records_after_restore=$RESTORED_RECORDS_AFTER_RESTORE"
    echo "backup_status=${BACKUP_STATUS:-unknown}"
    echo "restore_status=${RESTORE_STATUS:-unknown}"
    echo "restore_checksum_valid=$RESTORE_CHECKSUM_VALID"
    echo "restore_verification_result=$RESTORE_VERIFICATION_RESULT"
  } >"$SUMMARY_FILE"
fi
