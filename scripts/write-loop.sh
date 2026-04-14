#!/bin/sh
set -eu

APP_URL="${APP_URL:-http://localhost:8080}"
WRITE_INTERVAL_SECONDS="${WRITE_INTERVAL_SECONDS:-0.2}"
MAX_WRITES="${MAX_WRITES:-100}"
START_ID="${START_ID:-1}"

case "$MAX_WRITES" in
  ''|*[!0-9]*)
    echo "invalid MAX_WRITES=$MAX_WRITES" >&2
    exit 1
    ;;
esac

case "$START_ID" in
  ''|*[!0-9]*)
    echo "invalid START_ID=$START_ID" >&2
    exit 1
    ;;
esac

case "$WRITE_INTERVAL_SECONDS" in
  ''|*[!0-9.]*|*.*.*|.)
    echo "invalid WRITE_INTERVAL_SECONDS=$WRITE_INTERVAL_SECONDS" >&2
    exit 1
    ;;
esac

i=0
while [ "$i" -lt "$MAX_WRITES" ]; do
  id=$((START_ID + i))
  payload=$(printf '{"data":{"id":%s,"msg":"stream-%s"}}' "$id" "$id")
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  status_code="$(curl -sS -o /dev/null -w "%{http_code}" \
    -X POST "$APP_URL/write" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null || echo "000")"

  echo "$ts id=$id status=$status_code"

  i=$((i + 1))
  if [ "$i" -lt "$MAX_WRITES" ]; then
    sleep "$WRITE_INTERVAL_SECONDS"
  fi
done
