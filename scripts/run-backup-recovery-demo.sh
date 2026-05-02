#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-backup-recovery-demo}"
NAMESPACE="${NAMESPACE:-backup-recovery-demo}"
IMAGE_NAME="${IMAGE_NAME:-kubernetes-backup-recovery-demo-app:latest}"
KEEP_CLUSTER="${KEEP_CLUSTER:-false}"
PORT_FORWARD_PORT="${PORT_FORWARD_PORT:-8080}"
APP_URL="${APP_URL:-http://localhost:${PORT_FORWARD_PORT}}"
SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO="${SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO:-3}"
BACKUP_START_MIN_RECORDS="${BACKUP_START_MIN_RECORDS:-25}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="compare"
CREATED_CLUSTER=false
PF_PID=""
KUBECONFIG_TMP=""

usage() {
  cat <<'EOF'
Usage:
  ./scripts/run-backup-recovery-demo.sh --application-consistent
  ./scripts/run-backup-recovery-demo.sh --crash-consistent
  ./scripts/run-backup-recovery-demo.sh --compare
  ./scripts/run-backup-recovery-demo.sh --help

Default mode is --compare.

Environment:
  BACKUP_START_MIN_RECORDS  Minimum records to create before warm-up reaches the backup boundary (default: 25)
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

cluster_exists() {
  kind get clusters 2>/dev/null | awk -v want="$CLUSTER_NAME" '$0 == want {found=1} END {exit(found?0:1)}'
}

# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?
  if [[ -n "$PF_PID" ]] && kill -0 "$PF_PID" 2>/dev/null; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  if [[ -n "$KUBECONFIG_TMP" ]] && [[ -f "$KUBECONFIG_TMP" ]]; then
    rm -f "$KUBECONFIG_TMP"
  fi
  if [[ "$CREATED_CLUSTER" == "true" ]] && [[ "$KEEP_CLUSTER" != "true" ]]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  fi
  exit "$exit_code"
}

read_summary_value() {
  local key="$1"
  local file="$2"
  awk -F= -v key="$key" '$1 == key {print substr($0, index($0, "=")+1); exit}' "$file"
}

print_single_summary() {
  local label="$1"
  local summary_file="$2"
  echo "$label backup scenario complete"
  echo "records at backup boundary: $(read_summary_value records_at_backup_boundary "$summary_file")"
  echo "writes rejected during freeze: $(read_summary_value writes_rejected_during_freeze "$summary_file")"
  echo "records added while backup was in progress: $(read_summary_value records_added_while_backup_was_in_progress "$summary_file")"
  echo "records captured in backup: $(read_summary_value records_captured_in_backup "$summary_file")"
  echo "restored records after restore: $(read_summary_value restored_records_after_restore "$summary_file")"
  echo "backup_status=$(read_summary_value backup_status "$summary_file")"
  echo "restore_status=$(read_summary_value restore_status "$summary_file")"
  echo "restore_verification_result=$(read_summary_value restore_verification_result "$summary_file")"
}

run_consistency_mode() {
  local mode="$1"
  local summary_file="$2"
  DEMO_MODE="$mode" \
    NAMESPACE="$NAMESPACE" \
    APP_URL="$APP_URL" \
    SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO="$SLEEP_BEFORE_COPY_SECONDS_FOR_DEMO" \
    BACKUP_START_MIN_RECORDS="$BACKUP_START_MIN_RECORDS" \
    SUMMARY_FILE="$summary_file" \
    "$REPO_ROOT/scripts/run-consistency-demo.sh"
}

for arg in "$@"; do
  case "$arg" in
    --application-consistent) MODE="application-consistent" ;;
    --crash-consistent) MODE="crash-consistent" ;;
    --compare) MODE="compare" ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage
      fail "unknown argument: $arg"
      ;;
  esac
done

trap cleanup EXIT

require_cmd kind
require_cmd kubectl
require_cmd docker
require_cmd curl
require_cmd python3

if cluster_exists; then
  echo "Reusing existing kind cluster: $CLUSTER_NAME"
else
  echo "Creating kind cluster: $CLUSTER_NAME"
  kind create cluster --name "$CLUSTER_NAME"
  CREATED_CLUSTER=true
fi

KUBECONFIG_TMP="$(mktemp "${TMPDIR:-/tmp}/kind-demo-kubeconfig.XXXXXX")"
export KUBECONFIG="$KUBECONFIG_TMP"
kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig="$KUBECONFIG_TMP"

cd "$REPO_ROOT"

echo "Building demo image: $IMAGE_NAME"
docker build -t "$IMAGE_NAME" ./app >/dev/null
echo "Loading image into kind..."
kind load docker-image "$IMAGE_NAME" --name "$CLUSTER_NAME" >/dev/null

echo "Applying Kubernetes manifests..."
kubectl apply -f k8s/namespace.yaml >/dev/null
kubectl apply -f k8s/pvc.yaml >/dev/null
kubectl apply -f k8s/backup-pvc.yaml >/dev/null
echo "Updating backup/restore scripts ConfigMap from jobs/"
kubectl -n "$NAMESPACE" create configmap backup-restore-scripts \
  --from-file=backup.sh=jobs/backup.sh \
  --from-file=restore.sh=jobs/restore.sh \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -f k8s/app-deployment.yaml >/dev/null
kubectl apply -f k8s/app-service.yaml >/dev/null

echo "Waiting for app deployment..."
kubectl -n "$NAMESPACE" rollout status deployment/backup-recovery-demo-app --timeout=180s >/dev/null

kubectl -n "$NAMESPACE" port-forward svc/backup-recovery-demo-app "${PORT_FORWARD_PORT}:8080" >/dev/null 2>&1 &
PF_PID=$!

for _ in $(seq 1 60); do
  if curl -fsS "${APP_URL}/health" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS "${APP_URL}/health" >/dev/null 2>&1 || fail "application not reachable at ${APP_URL}/health"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/backup-recovery-demo.XXXXXX")"
trap 'rm -rf "$TMP_DIR"; cleanup' EXIT

if [[ "$MODE" == "application-consistent" ]]; then
  summary_file="$TMP_DIR/application-consistent.summary"
  run_consistency_mode "application-consistent" "$summary_file"
  print_single_summary "Application-consistent" "$summary_file"
  exit 0
fi

if [[ "$MODE" == "crash-consistent" ]]; then
  summary_file="$TMP_DIR/crash-consistent.summary"
  run_consistency_mode "crash-consistent" "$summary_file"
  print_single_summary "Crash-consistent" "$summary_file"
  exit 0
fi

crash_summary="$TMP_DIR/crash-consistent.summary"
app_summary="$TMP_DIR/application-consistent.summary"
run_consistency_mode "crash-consistent" "$crash_summary"
run_consistency_mode "application-consistent" "$app_summary"

crash_writes_rejected="$(read_summary_value writes_rejected_during_freeze "$crash_summary")"
crash_records_at_backup_boundary="$(read_summary_value records_at_backup_boundary "$crash_summary")"
crash_records_added_while_backup_was_in_progress="$(read_summary_value records_added_while_backup_was_in_progress "$crash_summary")"
crash_records_captured_in_backup="$(read_summary_value records_captured_in_backup "$crash_summary")"
crash_backup_status="$(read_summary_value backup_status "$crash_summary")"
crash_restore_status="$(read_summary_value restore_status "$crash_summary")"
crash_restore_checksum_valid="$(read_summary_value restore_checksum_valid "$crash_summary")"
crash_restored_records_after_restore="$(read_summary_value restored_records_after_restore "$crash_summary")"
crash_restore_verification_result="$(read_summary_value restore_verification_result "$crash_summary")"

app_writes_rejected="$(read_summary_value writes_rejected_during_freeze "$app_summary")"
app_records_at_backup_boundary="$(read_summary_value records_at_backup_boundary "$app_summary")"
app_records_added_while_backup_was_in_progress="$(read_summary_value records_added_while_backup_was_in_progress "$app_summary")"
app_records_captured_in_backup="$(read_summary_value records_captured_in_backup "$app_summary")"
app_backup_status="$(read_summary_value backup_status "$app_summary")"
app_restore_status="$(read_summary_value restore_status "$app_summary")"
app_restore_checksum_valid="$(read_summary_value restore_checksum_valid "$app_summary")"
app_restored_records_after_restore="$(read_summary_value restored_records_after_restore "$app_summary")"
app_restore_verification_result="$(read_summary_value restore_verification_result "$app_summary")"

echo "Backup strategy comparison complete"
echo
echo "Crash-consistent backup:"
echo "  records at backup boundary: $crash_records_at_backup_boundary"
echo "  records added while backup was in progress: $crash_records_added_while_backup_was_in_progress"
echo "  records captured in backup: $crash_records_captured_in_backup"
echo "  restored records after restore: $crash_restored_records_after_restore"
echo "  writes rejected during backup/freeze: $crash_writes_rejected"
echo "  restore verification result: $crash_restore_verification_result"
echo
echo "Application-consistent backup:"
echo "  records at backup boundary: $app_records_at_backup_boundary"
echo "  records added while backup was in progress: $app_records_added_while_backup_was_in_progress"
echo "  records captured in backup: $app_records_captured_in_backup"
echo "  restored records after restore: $app_restored_records_after_restore"
echo "  writes rejected during backup/freeze: $app_writes_rejected"
echo "  restore verification result: $app_restore_verification_result"
echo
echo "Conclusion:"
echo "  Both modes restore the records captured in the backup snapshot."
echo "  Crash-consistent mode does not freeze writes, so records can be added while the backup copy is in progress."
echo "  Application-consistent mode freezes writes before the backup copy, so the backup captures the frozen boundary state."
echo "  Application-consistent mode trades temporary write rejection for a cleaner recovery point."
echo
echo "crash_consistent_records_at_backup_boundary=$crash_records_at_backup_boundary"
echo "crash_consistent_writes_rejected_during_freeze=$crash_writes_rejected"
echo "crash_consistent_records_added_while_backup_was_in_progress=$crash_records_added_while_backup_was_in_progress"
echo "crash_consistent_records_captured_in_backup=$crash_records_captured_in_backup"
echo "crash_consistent_backup_status=$crash_backup_status"
echo "crash_consistent_restore_status=$crash_restore_status"
echo "crash_consistent_restore_checksum_valid=$crash_restore_checksum_valid"
echo "crash_consistent_restored_records_after_restore=$crash_restored_records_after_restore"
echo "crash_consistent_restore_verification_result=$crash_restore_verification_result"
echo "application_consistent_records_at_backup_boundary=$app_records_at_backup_boundary"
echo "application_consistent_writes_rejected_during_freeze=$app_writes_rejected"
echo "application_consistent_records_added_while_backup_was_in_progress=$app_records_added_while_backup_was_in_progress"
echo "application_consistent_records_captured_in_backup=$app_records_captured_in_backup"
echo "application_consistent_backup_status=$app_backup_status"
echo "application_consistent_restore_status=$app_restore_status"
echo "application_consistent_restore_checksum_valid=$app_restore_checksum_valid"
echo "application_consistent_restored_records_after_restore=$app_restored_records_after_restore"
echo "application_consistent_restore_verification_result=$app_restore_verification_result"
