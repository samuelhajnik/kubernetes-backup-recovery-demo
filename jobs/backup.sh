#!/bin/sh
set -eu

SOURCE_FILE="/data/data.jsonl"
BACKUP_MODE="${BACKUP_MODE:-crash-consistent}"
APP_BASE_URL="${APP_BASE_URL:-http://backup-recovery-demo-app.backup-recovery-demo.svc.cluster.local:8080}"
FAIL_BEFORE_COPY="${FAIL_BEFORE_COPY:-false}"
FAIL_AFTER_COPY="${FAIL_AFTER_COPY:-false}"
SLEEP_BEFORE_COPY_SECONDS="${SLEEP_BEFORE_COPY_SECONDS:-0}"
FROZEN=0
TIMESTAMP="$(date -u +"%Y-%m-%dT%H-%M-%SZ")"
BACKUP_FILE="/backup/data-$TIMESTAMP.jsonl"
METADATA_FILE="/backup/metadata-$TIMESTAMP.json"
STATUS_FILE="/backup/backup-status.json"
BACKUP_FILE_NAME="$(basename "$BACKUP_FILE")"
CHECKSUM=""
STATUS_MESSAGE="backup failed"
BYTES_WRITTEN=0
START_TIME_SEC="$(date +%s)"

post_endpoint() {
  endpoint="$1"
  wget -q -O /dev/null --post-data='' "$APP_BASE_URL/$endpoint"
}

cleanup() {
  exit_code="$1"
  end_time_sec="$(date +%s)"
  duration_ms="$(( (end_time_sec - START_TIME_SEC) * 1000 ))"
  status_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ "$exit_code" -eq 0 ]; then
    STATUS_VALUE="success"
    if [ -n "$STATUS_MESSAGE" ]; then
      MESSAGE="$STATUS_MESSAGE"
    else
      MESSAGE="backup completed"
    fi
  else
    STATUS_VALUE="failure"
    MESSAGE="$STATUS_MESSAGE"
  fi

  if [ -f "$BACKUP_FILE" ]; then
    BYTES_WRITTEN="$(wc -c < "$BACKUP_FILE" | awk '{print $1}')"
  fi

  printf '{"operation":"backup","status":"%s","timestamp":"%s","mode":"%s","backup_file":"%s","checksum":"%s","message":"%s","duration_ms":%s,"bytes_written":%s}\n' \
    "$STATUS_VALUE" "$status_timestamp" "$BACKUP_MODE" "$BACKUP_FILE_NAME" "$CHECKSUM" "$MESSAGE" "$duration_ms" "$BYTES_WRITTEN" > "$STATUS_FILE"

  if [ "$FROZEN" -eq 1 ]; then
    echo "attempting unfreeze after backup flow"
    if post_endpoint "unfreeze"; then
      echo "app unfreeze completed"
      FROZEN=0
    else
      echo "failed to unfreeze app at $APP_BASE_URL/unfreeze" >&2
    fi
  fi
}

trap 'cleanup $?' EXIT

echo "backup mode: $BACKUP_MODE"

echo "backup started: $SOURCE_FILE -> $BACKUP_FILE"

if [ "$BACKUP_MODE" = "application-consistent" ]; then
  echo "requesting app freeze at $APP_BASE_URL/freeze"
  post_endpoint "freeze"
  FROZEN=1
  echo "app freeze completed"
elif [ "$BACKUP_MODE" != "crash-consistent" ]; then
  STATUS_MESSAGE="unsupported BACKUP_MODE=$BACKUP_MODE"
  echo "backup failed: $STATUS_MESSAGE" >&2
  exit 1
fi

if [ ! -f "$SOURCE_FILE" ]; then
  STATUS_MESSAGE="source file not found at $SOURCE_FILE"
  echo "backup failed: $STATUS_MESSAGE" >&2
  exit 1
fi

case "$SLEEP_BEFORE_COPY_SECONDS" in
  ''|*[!0-9]*)
    STATUS_MESSAGE="invalid SLEEP_BEFORE_COPY_SECONDS=$SLEEP_BEFORE_COPY_SECONDS"
    echo "backup failed: $STATUS_MESSAGE" >&2
    exit 1
    ;;
esac

if [ "$SLEEP_BEFORE_COPY_SECONDS" -gt 0 ]; then
  echo "failure injection: sleeping before copy for $SLEEP_BEFORE_COPY_SECONDS seconds"
  sleep "$SLEEP_BEFORE_COPY_SECONDS"
fi

if [ "$FAIL_BEFORE_COPY" = "true" ]; then
  STATUS_MESSAGE="failure injection: FAIL_BEFORE_COPY=true"
  echo "$STATUS_MESSAGE" >&2
  exit 1
fi

cp "$SOURCE_FILE" "$BACKUP_FILE"

if [ "$FAIL_AFTER_COPY" = "true" ]; then
  STATUS_MESSAGE="failure injection: FAIL_AFTER_COPY=true"
  echo "$STATUS_MESSAGE" >&2
  exit 1
fi

CHECKSUM="$(sha256sum "$SOURCE_FILE" | awk '{print $1}')"

printf '{"timestamp":"%s","source_file":"%s","backup_file":"%s","checksum":"%s"}\n' \
  "$TIMESTAMP" "$SOURCE_FILE" "$BACKUP_FILE" "$CHECKSUM" > "$METADATA_FILE"

echo "backup completed: $SOURCE_FILE -> $BACKUP_FILE"
echo "backup file created: $BACKUP_FILE"
echo "backup metadata written: $METADATA_FILE"
echo "backup checksum: $CHECKSUM"
STATUS_MESSAGE="backup completed"

if [ "$FROZEN" -eq 1 ]; then
  echo "requesting app unfreeze at $APP_BASE_URL/unfreeze"
  post_endpoint "unfreeze"
  FROZEN=0
  echo "app unfreeze completed"
fi
