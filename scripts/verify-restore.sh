#!/usr/bin/env bash
# Restore verification: writes known records, runs backup → wipe → restore, then
# verifies via GET /read. Proves the recovery path, not only Job completion.
set -euo pipefail

NAMESPACE="${NAMESPACE:-backup-recovery-demo}"
APP_URL="${APP_URL:-http://localhost:8080}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

echo "Restore verification (Kubernetes)"
echo "  namespace: ${NAMESPACE}"
echo "  app URL:   ${APP_URL}"

require_cmd kubectl
require_cmd curl
require_cmd python3

if ! kubectl cluster-info >/dev/null 2>&1; then
  fail "kubectl cannot reach a cluster. Configure kubeconfig (Kind, minikube, Docker Desktop Kubernetes, etc.)."
fi

echo "Checking application health..."
curl -fsS "${APP_URL}/health" >/dev/null ||
  fail "cannot reach ${APP_URL} — try: kubectl -n ${NAMESPACE} port-forward svc/backup-recovery-demo-app 8080:8080"

POD="$(kubectl -n "${NAMESPACE}" get pod -l app=backup-recovery-demo-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${POD}" ]]; then
  fail "no app pod in namespace ${NAMESPACE} (label app=backup-recovery-demo-app). Apply the Quick Start manifests first."
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/verify-restore.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

echo "Resetting live data for a clean run..."
kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c ': > /data/data.jsonl'

echo "Writing test records..."
for i in 1 2 3; do
  curl -fsS -X POST "${APP_URL}/write" \
    -H 'Content-Type: application/json' \
    -d "{\"data\":{\"verify\":\"restore-verify\",\"seq\":${i},\"marker\":\"known-${i}\"}}"
done

echo "Capturing expected application state..."
curl -fsS "${APP_URL}/read" > "${TMP_DIR}/expected.json"

python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("count")==3, d' "${TMP_DIR}/expected.json" ||
  fail "expected 3 records after writes"

echo "Running backup..."
kubectl -n "${NAMESPACE}" delete job backup-data-job --ignore-not-found >/dev/null
kubectl apply -f "${REPO_ROOT}/k8s/backup-job.yaml" >/dev/null
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete job/backup-data-job --timeout=120s >/dev/null; then
  kubectl -n "${NAMESPACE}" logs job/backup-data-job 2>&1 || true
  fail "backup job did not complete within 120s"
fi

echo "Clearing live data (simulating data loss)..."
kubectl -n "${NAMESPACE}" exec "${POD}" -- sh -c ': > /data/data.jsonl'

echo "Verifying live data is empty before restore..."
curl -fsS "${APP_URL}/read" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("count")==0, d'

echo "Restoring backup..."
kubectl -n "${NAMESPACE}" delete job restore-data-job --ignore-not-found >/dev/null
kubectl apply -f "${REPO_ROOT}/k8s/restore-job.yaml" >/dev/null
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete job/restore-data-job --timeout=120s >/dev/null; then
  kubectl -n "${NAMESPACE}" logs job/restore-data-job 2>&1 || true
  fail "restore job did not complete within 120s"
fi

echo "Verifying restored data via application API..."
curl -fsS "${APP_URL}/read" > "${TMP_DIR}/actual.json"

if ! python3 -c 'import json,sys; e=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); sys.exit(0 if e==a else 1)' \
  "${TMP_DIR}/expected.json" "${TMP_DIR}/actual.json"; then
  echo "Expected:" >&2
  cat "${TMP_DIR}/expected.json" >&2
  echo "Actual:" >&2
  cat "${TMP_DIR}/actual.json" >&2
  fail "restored GET /read payload does not match pre-backup baseline"
fi

COUNT="$(python3 -c 'import json; print(json.load(open(sys.argv[1]))["count"])' "${TMP_DIR}/expected.json")"
echo "PASS: restored data matches expected records (count=${COUNT})"
exit 0
