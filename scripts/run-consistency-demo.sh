#!/bin/sh
set -eu

NAMESPACE="${NAMESPACE:-backup-recovery-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"
WRITE_INTERVAL_SECONDS="${WRITE_INTERVAL_SECONDS:-0.1}"
MAX_WRITES="${MAX_WRITES:-1000}"
DEMO_MODE="${DEMO_MODE:-}"
APP_BACKUP_JOB_FILE="${APP_BACKUP_JOB_FILE:-k8s/backup-job.yaml}"
APP_RESTORE_JOB_FILE="${APP_RESTORE_JOB_FILE:-k8s/restore-job.yaml}"
SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO="${SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO:-0}"

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

cleanup() {
  if [ -n "$WRITER_PID" ]; then
    kill "$WRITER_PID" 2>/dev/null || true
    wait "$WRITER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if ! curl -fsS "$APP_URL/health" >/dev/null; then
  echo "failed to reach app at $APP_URL (check port-forward/service reachability)" >&2
  exit 1
fi

cp "$APP_BACKUP_JOB_FILE" "$BACKUP_JOB_TMP"
cp "$APP_RESTORE_JOB_FILE" "$RESTORE_JOB_TMP"

awk -v mode="$DEMO_MODE" -v sleepv="$SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO" '
  /name: BACKUP_MODE/ {print; getline; print "              value: \"" mode "\""; next}
  /name: SLEEP_BEFORE_COPY_SECONDS/ {print; getline; print "              value: \"" sleepv "\""; next}
  {print}
' "$BACKUP_JOB_TMP" > "$BACKUP_JOB_TMP.tmp" && mv "$BACKUP_JOB_TMP.tmp" "$BACKUP_JOB_TMP"

APP_URL="$APP_URL" WRITE_INTERVAL_SECONDS="$WRITE_INTERVAL_SECONDS" MAX_WRITES="$MAX_WRITES" ./scripts/write-loop.sh >"$WRITE_LOG" 2>&1 &
WRITER_PID=$!

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

POD="$(kubectl -n "$NAMESPACE" get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}')"
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

kill "$WRITER_PID" 2>/dev/null || true
wait "$WRITER_PID" 2>/dev/null || true
WRITER_PID=""

COUNT_201="$(grep -c "status=201" "$WRITE_LOG" || true)"
COUNT_409="$(grep -c "status=409" "$WRITE_LOG" || true)"
BACKUP_STATUS="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$BACKUP_STATUS_FILE" | head -n 1)"
RESTORE_STATUS="$(sed -n 's/.*"status":"\([^"]*\)".*/\1/p' "$RESTORE_STATUS_FILE" | head -n 1)"

echo "consistency demo summary"
echo "  mode: $DEMO_MODE"
echo "  writes_201: $COUNT_201"
echo "  writes_409: $COUNT_409"
echo "  backup_status: ${BACKUP_STATUS:-unknown}"
echo "  restore_status: ${RESTORE_STATUS:-unknown}"
echo "  write_log: $WRITE_LOG"
echo "  backup_log: $BACKUP_LOG"
echo "  restore_log: $RESTORE_LOG"
echo "  backup_status_file: $BACKUP_STATUS_FILE"
echo "  restore_status_file: $RESTORE_STATUS_FILE"
echo "  read_output_file: $READ_OUTPUT_FILE"
