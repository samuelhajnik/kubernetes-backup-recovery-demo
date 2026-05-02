#!/usr/bin/env bash
# No-cluster restore scenario tests: runs jobs/restore.sh with temp dirs.
# From repo root: ./scripts/test-restore-scenarios.sh  or  bash scripts/test-restore-scenarios.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESTORE_JOB="$REPO_ROOT/jobs/restore.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

run_restore() {
  env BACKUP_ROOT="$1" TARGET_FILE="$2" STATUS_FILE="$3" \
    SLEEP_BEFORE_RESTORE_SECONDS=0 \
    FAIL_BEFORE_RESTORE=false \
    FAIL_AFTER_RESTORE_COPY=false \
    sh "$RESTORE_JOB"
}

echo "=== restore job scenario tests (temp dirs, no cluster) ==="

require_cmd sh
require_cmd find
require_cmd sed

case_success() {
  echo "--- case: valid backup + metadata, checksum matches ---"
  local root backup data status ts sum
  root="$(mktemp -d "${TMPDIR:-/tmp}/trv-ok.XXXXXX")"
  backup="$root/backup"
  data="$root/data"
  mkdir -p "$backup" "$data"
  status="$backup/backup-status.json"
  ts="2020-01-01T00-00-00Z"
  printf '{"demo":1,"tag":"ok"}\n' >"$backup/data-$ts.jsonl"
  sum="$(sha256_file "$backup/data-$ts.jsonl")"
  printf '{"timestamp":"%s","source_file":"/data/data.jsonl","backup_file":"data-%s.jsonl","checksum":"%s"}\n' \
    "$ts" "$ts" "$sum" >"$backup/metadata-$ts.json"

  set +e
  out="$(run_restore "$backup" "$data/data.jsonl" "$status" 2>&1)"
  ec=$?
  set -e
  if [[ "$ec" -ne 0 ]]; then
    echo "$out" >&2
    fail "expected exit 0 for valid checksum, got $ec"
  fi
  if [[ "$out" != *"verification successful"* ]]; then
    echo "$out" >&2
    fail "expected output to mention verification successful"
  fi
  rm -rf "$root"
}

case_checksum_mismatch() {
  echo "--- case: checksum mismatch ---"
  local root backup data status ts sum bad out ec
  root="$(mktemp -d "${TMPDIR:-/tmp}/trv-badsum.XXXXXX")"
  backup="$root/backup"
  data="$root/data"
  mkdir -p "$backup" "$data"
  status="$backup/backup-status.json"
  ts="2020-01-02T00-00-00Z"
  printf '{"x":1}\n' >"$backup/data-$ts.jsonl"
  sum="$(sha256_file "$backup/data-$ts.jsonl")"
  bad="0000000000000000000000000000000000000000000000000000000000000000"
  if [[ "$sum" == "$bad" ]]; then
    bad="1111111111111111111111111111111111111111111111111111111111111111"
  fi
  printf '{"timestamp":"%s","checksum":"%s"}\n' "$ts" "$bad" >"$backup/metadata-$ts.json"

  set +e
  out="$(run_restore "$backup" "$data/data.jsonl" "$status" 2>&1)"
  ec=$?
  set -e
  if [[ "$ec" -eq 0 ]]; then
    echo "$out" >&2
    fail "expected non-zero exit for checksum mismatch"
  fi
  if ! echo "$out" | grep -qi 'checksum' || ! echo "$out" | grep -qi 'mismatch'; then
    echo "$out" >&2
    fail "expected stderr to mention checksum mismatch"
  fi
  rm -rf "$root"
}

case_missing_backup() {
  echo "--- case: no versioned backup files ---"
  local root backup data status out ec
  root="$(mktemp -d "${TMPDIR:-/tmp}/trv-nobak.XXXXXX")"
  backup="$root/backup"
  data="$root/data"
  mkdir -p "$backup" "$data"
  status="$backup/backup-status.json"

  set +e
  out="$(run_restore "$backup" "$data/data.jsonl" "$status" 2>&1)"
  ec=$?
  set -e
  if [[ "$ec" -eq 0 ]]; then
    echo "$out" >&2
    fail "expected non-zero exit when backup dir has no data-*.jsonl"
  fi
  if [[ "$out" != *"no versioned backup"* ]]; then
    echo "$out" >&2
    fail "expected message about missing versioned backup files"
  fi
  rm -rf "$root"
}

case_missing_metadata() {
  echo "--- case: backup file present but metadata missing ---"
  local root backup data status ts out ec
  root="$(mktemp -d "${TMPDIR:-/tmp}/trv-nometa.XXXXXX")"
  backup="$root/backup"
  data="$root/data"
  mkdir -p "$backup" "$data"
  status="$backup/backup-status.json"
  ts="2020-01-03T00-00-00Z"
  printf '{}\n' >"$backup/data-$ts.jsonl"

  set +e
  out="$(run_restore "$backup" "$data/data.jsonl" "$status" 2>&1)"
  ec=$?
  set -e
  if [[ "$ec" -eq 0 ]]; then
    echo "$out" >&2
    fail "expected non-zero exit when metadata file is missing"
  fi
  if [[ "$out" != *"metadata file not found"* ]]; then
    echo "$out" >&2
    fail "expected clear metadata missing message"
  fi
  rm -rf "$root"
}

case_success
case_checksum_mismatch
case_missing_backup
case_missing_metadata

echo "PASS: all restore job scenario checks succeeded"
