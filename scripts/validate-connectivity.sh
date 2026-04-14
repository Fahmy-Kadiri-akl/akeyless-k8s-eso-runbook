#!/usr/bin/env bash
# validate-connectivity.sh
#
# Validates the Akeyless + ESO integration is working end-to-end.
# Checks ClusterSecretStore health, creates a test ExternalSecret,
# verifies the sync, and cleans up.
#
# Prerequisites:
#   - kubectl configured with access to the target cluster
#   - ESO installed and running
#   - ClusterSecretStore 'akeyless' created
#   - A test secret exists in Akeyless at /test/pipeline-validation
#     (create with: akeyless create-secret --name /test/pipeline-validation --value test-value)
#
# Usage:
#   ./validate-connectivity.sh
#   ./validate-connectivity.sh --store-name akeyless --test-secret /test/pipeline-validation
#
set -euo pipefail

# Defaults
STORE_NAME="${STORE_NAME:-akeyless}"
TEST_SECRET_PATH="${TEST_SECRET_PATH:-/test/pipeline-validation}"
TEST_ES_NAME="eso-validation-test-$(date +%s)"
TEST_NAMESPACE="default"
TIMEOUT_SECONDS=60
POLL_INTERVAL=5

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' NC=''
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --store-name)
      STORE_NAME="$2"
      shift 2
      ;;
    --test-secret)
      TEST_SECRET_PATH="$2"
      shift 2
      ;;
    --namespace)
      TEST_NAMESPACE="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --store-name <name>    ClusterSecretStore name (default: akeyless)"
      echo "  --test-secret <path>   Akeyless secret path for testing (default: /test/pipeline-validation)"
      echo "  --namespace <ns>       Namespace for test resources (default: default)"
      echo "  --timeout <seconds>    Timeout for sync wait (default: 60)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

pass() { echo -e "${GREEN}PASS${NC}: $1"; }
fail() { echo -e "${RED}FAIL${NC}: $1"; }
warn() { echo -e "${YELLOW}WARN${NC}: $1"; }
info() { echo "INFO: $1"; }

ERRORS=0

cleanup() {
  info "Cleaning up test resources..."
  kubectl delete externalsecret "$TEST_ES_NAME" -n "$TEST_NAMESPACE" --ignore-not-found=true &>/dev/null || true
  kubectl delete secret "$TEST_ES_NAME" -n "$TEST_NAMESPACE" --ignore-not-found=true &>/dev/null || true
}
trap cleanup EXIT

# -------------------------------------------------------
# Test 1: ESO pods are running
# -------------------------------------------------------
info "Checking ESO pods..."
ESO_PODS=$(kubectl get pods -n external-secrets --no-headers 2>/dev/null | wc -l | tr -d ' ')
ESO_READY=$(kubectl get pods -n external-secrets --no-headers 2>/dev/null | grep -c "Running" || true)

if [[ "$ESO_PODS" -eq 0 ]]; then
  fail "No ESO pods found in namespace 'external-secrets'"
  ERRORS=$((ERRORS + 1))
elif [[ "$ESO_READY" -lt "$ESO_PODS" ]]; then
  warn "Some ESO pods are not running ($ESO_READY/$ESO_PODS ready)"
  kubectl get pods -n external-secrets
  ERRORS=$((ERRORS + 1))
else
  pass "ESO pods are running ($ESO_READY/$ESO_PODS)"
fi

# -------------------------------------------------------
# Test 2: ClusterSecretStore is ready
# -------------------------------------------------------
info "Checking ClusterSecretStore '$STORE_NAME'..."
CSS_EXISTS=$(kubectl get clustersecretstore "$STORE_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')

if [[ "$CSS_EXISTS" -eq 0 ]]; then
  fail "ClusterSecretStore '$STORE_NAME' does not exist"
  ERRORS=$((ERRORS + 1))
else
  CSS_READY=$(kubectl get clustersecretstore "$STORE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

  if [[ "$CSS_READY" == "True" ]]; then
    pass "ClusterSecretStore '$STORE_NAME' is ready"
  else
    fail "ClusterSecretStore '$STORE_NAME' is not ready (status: $CSS_READY)"
    kubectl describe clustersecretstore "$STORE_NAME" 2>/dev/null | tail -20
    ERRORS=$((ERRORS + 1))
  fi
fi

# -------------------------------------------------------
# Test 3: Create test ExternalSecret and verify sync
# -------------------------------------------------------
info "Creating test ExternalSecret '$TEST_ES_NAME'..."

kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${TEST_ES_NAME}
  namespace: ${TEST_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: akeyless-integration
    app.kubernetes.io/component: validation-test
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: ${STORE_NAME}
    kind: ClusterSecretStore
  target:
    name: ${TEST_ES_NAME}
    creationPolicy: Owner
  data:
    - secretKey: test-value
      remoteRef:
        key: ${TEST_SECRET_PATH}
EOF

info "Waiting for ExternalSecret to sync (timeout: ${TIMEOUT_SECONDS}s)..."
ELAPSED=0
SYNCED=false

while [[ $ELAPSED -lt $TIMEOUT_SECONDS ]]; do
  STATUS=$(kubectl get externalsecret "$TEST_ES_NAME" -n "$TEST_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

  if [[ "$STATUS" == "True" ]]; then
    SYNCED=true
    break
  fi

  sleep "$POLL_INTERVAL"
  ELAPSED=$((ELAPSED + POLL_INTERVAL))
done

if [[ "$SYNCED" == "true" ]]; then
  pass "ExternalSecret synced successfully in ${ELAPSED}s"

  # Verify the K8s Secret was created
  SECRET_EXISTS=$(kubectl get secret "$TEST_ES_NAME" -n "$TEST_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$SECRET_EXISTS" -eq 1 ]]; then
    pass "K8s Secret created successfully"
  else
    fail "K8s Secret was not created despite ExternalSecret showing Ready"
    ERRORS=$((ERRORS + 1))
  fi
else
  fail "ExternalSecret did not sync within ${TIMEOUT_SECONDS}s"
  kubectl describe externalsecret "$TEST_ES_NAME" -n "$TEST_NAMESPACE" 2>/dev/null | tail -20
  ERRORS=$((ERRORS + 1))
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "========================================="
if [[ $ERRORS -eq 0 ]]; then
  pass "All validation tests passed"
  echo "========================================="
  exit 0
else
  fail "$ERRORS test(s) failed"
  echo "========================================="
  exit 1
fi
