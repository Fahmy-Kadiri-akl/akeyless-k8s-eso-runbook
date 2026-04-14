#!/usr/bin/env bash
# extract-cluster-params.sh
#
# Extracts Kubernetes cluster parameters needed for Akeyless K8s auth method
# configuration. Outputs a JSON object with all required values.
#
# Prerequisites:
#   - kubectl configured with access to the target cluster
#   - gateway-token-reviewer ServiceAccount and Secret created
#     (apply manifests/rke/ or manifests/gke/ first)
#   - jq installed
#
# Usage:
#   ./extract-cluster-params.sh
#   ./extract-cluster-params.sh --namespace kube-system  # custom namespace
#
# Output:
#   JSON object with cluster_name, k8s_api_server, k8s_ca_cert_base64, token_reviewer_jwt
#
set -euo pipefail

# Defaults
NAMESPACE="${NAMESPACE:-kube-system}"
SA_SECRET_NAME="${SA_SECRET_NAME:-gateway-token-reviewer-token}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace|-n)
      NAMESPACE="$2"
      shift 2
      ;;
    --secret-name|-s)
      SA_SECRET_NAME="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--namespace <ns>] [--secret-name <name>]"
      echo ""
      echo "Options:"
      echo "  --namespace, -n    Namespace where the token reviewer secret lives (default: kube-system)"
      echo "  --secret-name, -s  Name of the token reviewer secret (default: gateway-token-reviewer-token)"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Check prerequisites
for cmd in kubectl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed." >&2
    exit 1
  fi
done

# Verify cluster connectivity
if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot connect to Kubernetes cluster. Check your kubeconfig." >&2
  exit 1
fi

# Extract cluster name from context
CLUSTER_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")

# Extract API server URL
K8S_API_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
if [[ -z "$K8S_API_SERVER" ]]; then
  echo "ERROR: Could not determine K8s API server URL." >&2
  exit 1
fi

# Extract CA certificate (base64)
K8S_CA_CERT_BASE64=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null)
if [[ -z "$K8S_CA_CERT_BASE64" ]]; then
  echo "WARN: Could not extract CA cert from kubeconfig, trying from secret..." >&2
  K8S_CA_CERT_BASE64=$(kubectl get secret "$SA_SECRET_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}' 2>/dev/null || true)
fi

if [[ -z "$K8S_CA_CERT_BASE64" ]]; then
  echo "ERROR: Could not extract K8s CA certificate." >&2
  echo "Checked secret '$SA_SECRET_NAME' in namespace '$NAMESPACE'." >&2
  exit 1
fi

# Extract token reviewer JWT
TOKEN_REVIEWER_JWT=$(kubectl get secret "$SA_SECRET_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -z "$TOKEN_REVIEWER_JWT" ]]; then
  echo "ERROR: Could not extract token reviewer JWT." >&2
  echo "Make sure the gateway-token-reviewer ServiceAccount and Secret exist." >&2
  echo "Apply manifests/rke/token-reviewer-user.yaml or manifests/gke/ first." >&2
  exit 1
fi

# Output as JSON
jq -n \
  --arg cluster_name "$CLUSTER_NAME" \
  --arg k8s_api_server "$K8S_API_SERVER" \
  --arg k8s_ca_cert_base64 "$K8S_CA_CERT_BASE64" \
  --arg token_reviewer_jwt "$TOKEN_REVIEWER_JWT" \
  '{
    cluster_name: $cluster_name,
    k8s_api_server: $k8s_api_server,
    k8s_ca_cert_base64: $k8s_ca_cert_base64,
    token_reviewer_jwt: $token_reviewer_jwt
  }'
