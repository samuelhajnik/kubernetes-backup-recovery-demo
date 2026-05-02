#!/bin/sh
set -eu

# Defaults match the Kubernetes Job mount layout; override for local/CI scenario tests.
BACKUP_ROOT="${BACKUP_ROOT:-/backup}"
TARGET_FILE="${TARGET_FILE:-/data/data.jsonl}"
STATUS_FILE="${STATUS_FILE:-$BACKUP_ROOT/backup-status.json}"
FAIL_BEFORE_RESTORE="${FAIL_BEFORE_RESTORE:-false}"
FAIL_AFTER_RESTORE_COPY="${FAIL_AFTER_RESTORE_COPY:-false}"
SLEEP_BEFORE_RESTORE_SECONDS="${SLEEP_BEFORE_RESTORE_SECONDS:-0}"
STATUS_MESSAGE="restore failed"
CHECKSUM_VALID=false
START_TIME_SEC="$(date +%s)"

checksum_sha256() {
  file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
    return 0
  fi
  echo "ERROR: neither sha256sum nor shasum is available; cannot verify backup checksum" >&2
  return 1
}

cleanup() {
  exit_code="$1"
  end_time_sec="$(date +%s)"
  duration_ms="$(( (end_time_sec - START_TIME_SEC) * 1000 ))"
  status_timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  if [ "$exit_code" -eq 0 ]; then
    STATUS_VALUE="success"
    MESSAGE="$STATUS_MESSAGE"
  else
    STATUS_VALUE="failure"
    MESSAGE="$STATUS_MESSAGE"
  fi

  printf '{"operation":"restore","status":"%s","timestamp":"%s","message":"%s","duration_ms":%s,"restored_file":"%s","checksum_valid":%s}\n' \
    "$STATUS_VALUE" "$status_timestamp" "$MESSAGE" "$duration_ms" "$TARGET_FILE" "$CHECKSUM_VALID" > "$STATUS_FILE"
}

trap 'cleanup $?' EXIT

case "$SLEEP_BEFORE_RESTORE_SECONDS" in
  ''|*[!0-9]*)
    echo "restore failed: invalid SLEEP_BEFORE_RESTORE_SECONDS=$SLEEP_BEFORE_RESTORE_SECONDS" >&2
    exit 1
    ;;
esac

if [ "$SLEEP_BEFORE_RESTORE_SECONDS" -gt 0 ]; then
  echo "failure injection: sleeping before restore for $SLEEP_BEFORE_RESTORE_SECONDS seconds"
  sleep "$SLEEP_BEFORE_RESTORE_SECONDS"
fi

if [ "$FAIL_BEFORE_RESTORE" = "true" ]; then
  STATUS_MESSAGE="failure injection: FAIL_BEFORE_RESTORE=true"
  echo "$STATUS_MESSAGE" >&2
  exit 1
fi

BACKUP_FILE="$(
  find "$BACKUP_ROOT" -maxdepth 1 -type f -name 'data-*.jsonl' -print 2>/dev/null \
    | sort -r \
    | head -n 1
)"

if [ -z "$BACKUP_FILE" ]; then
  STATUS_MESSAGE="no versioned backup files found in $BACKUP_ROOT"
  echo "restore failed: no versioned backup files found in $BACKUP_ROOT" >&2
  exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
  STATUS_MESSAGE="selected backup file does not exist"
  echo "restore failed: selected backup file does not exist" >&2
  exit 1
fi

METADATA_FILE="$BACKUP_ROOT/metadata-$(basename "$BACKUP_FILE" | sed 's/^data-//; s/\.jsonl$//').json"

if [ ! -f "$METADATA_FILE" ]; then
  STATUS_MESSAGE="metadata file not found at $METADATA_FILE"
  echo "restore failed: metadata file not found at $METADATA_FILE" >&2
  exit 1
fi

EXPECTED_CHECKSUM="$(sed -n 's/.*"checksum":"\([a-f0-9]\{64\}\)".*/\1/p' "$METADATA_FILE")"
if [ -z "$EXPECTED_CHECKSUM" ]; then
  STATUS_MESSAGE="checksum missing or invalid in $METADATA_FILE"
  echo "restore failed: checksum missing or invalid in $METADATA_FILE" >&2
  exit 1
fi

cp "$BACKUP_FILE" "$TARGET_FILE"

if [ "$FAIL_AFTER_RESTORE_COPY" = "true" ]; then
  STATUS_MESSAGE="failure injection: FAIL_AFTER_RESTORE_COPY=true"
  echo "$STATUS_MESSAGE" >&2
  exit 1
fi

ACTUAL_CHECKSUM="$(checksum_sha256 "$TARGET_FILE")" || exit 1

if [ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
  STATUS_MESSAGE="checksum mismatch (expected=$EXPECTED_CHECKSUM actual=$ACTUAL_CHECKSUM)"
  echo "restore verification failed: checksum mismatch (expected=$EXPECTED_CHECKSUM actual=$ACTUAL_CHECKSUM)" >&2
  exit 1
fi

CHECKSUM_VALID=true
STATUS_MESSAGE="restore completed and checksum verified"

echo "restore using latest backup file: $BACKUP_FILE"
echo "restore completed: $BACKUP_FILE -> $TARGET_FILE"
echo "verification successful: checksum $ACTUAL_CHECKSUM"
