#!/bin/sh
set -eu

BACKUP_FILE="/backup/data.jsonl"
TARGET_FILE="/data/data.jsonl"
METADATA_FILE="/backup/metadata.json"

if [ ! -f "$BACKUP_FILE" ]; then
  echo "restore failed: backup file not found at $BACKUP_FILE" >&2
  exit 1
fi

if [ ! -f "$METADATA_FILE" ]; then
  echo "restore failed: metadata file not found at $METADATA_FILE" >&2
  exit 1
fi

EXPECTED_CHECKSUM="$(sed -n 's/.*"checksum":"\([a-f0-9]\{64\}\)".*/\1/p' "$METADATA_FILE")"
if [ -z "$EXPECTED_CHECKSUM" ]; then
  echo "restore failed: checksum missing or invalid in $METADATA_FILE" >&2
  exit 1
fi

cp "$BACKUP_FILE" "$TARGET_FILE"
ACTUAL_CHECKSUM="$(sha256sum "$TARGET_FILE" | awk '{print $1}')"

if [ "$ACTUAL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]; then
  echo "restore verification failed: checksum mismatch (expected=$EXPECTED_CHECKSUM actual=$ACTUAL_CHECKSUM)" >&2
  exit 1
fi

echo "restore completed: $BACKUP_FILE -> $TARGET_FILE"
echo "verification successful: checksum $ACTUAL_CHECKSUM"
