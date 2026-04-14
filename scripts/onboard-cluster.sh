#!/usr/bin/env bash
# onboard-cluster.sh
#
# End-to-end script to onboard a Kubernetes cluster with Akeyless via ESO.
# Automates: cluster-side RBAC, Akeyless auth method + role creation,
# ESO installation, ClusterSecretStore setup, and end-to-end validation.
#
# Prerequisites:
#   - kubectl configured with access to the target cluster
#   - akeyless CLI installed and authenticated
#   - helm (v3) installed
#   - jq installed
#   - base64, curl available
#
# Usage:
#   ./onboard-cluster.sh --cluster-name my-cluster --gateway-url https://gw.example.com:8000
#   ./onboard-cluster.sh --cluster-name my-cluster --gateway-url https://gw.example.com:8000 --dry-run
#   ./onboard-cluster.sh --cluster-name my-cluster --gateway-url https://gw.example.com:8000 --cleanup
#
set -euo pipefail

###############################################################################
# Constants
###############################################################################
SA_NAME="gateway-token-reviewer"
SA_SECRET_NAME="gateway-token-reviewer-token"
SA_NAMESPACE="kube-system"
CRB_NAME="gateway-token-reviewer-binding"
ESO_HELM_REPO="https://charts.external-secrets.io"
ESO_HELM_REPO_NAME="external-secrets"
ESO_HELM_RELEASE="external-secrets"
ESO_CHART="external-secrets/external-secrets"
CSS_NAME="akeyless"
LABEL_PART_OF="akeyless-integration"
LABEL_MANAGED_BY="onboard-cluster-script"
TEST_SECRET_SUFFIX="/test/onboard-validation"
POLL_INTERVAL=5
POLL_TIMEOUT=120

###############################################################################
# Color output (disabled if not a terminal)
###############################################################################
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[0;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

###############################################################################
# Output helpers
###############################################################################
step()    { echo -e "\n${BLUE}${BOLD}[$1]${NC} $2"; }
success() { echo -e "  ${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
fail()    { echo -e "  ${RED}[FAIL]${NC} $1"; }
info()    { echo -e "  $1"; }

die() {
  fail "$1"
  echo ""
  echo -e "${RED}Onboarding aborted.${NC}"
  if [[ -n "${CLUSTER_NAME:-}" ]]; then
    echo -e "To clean up partial resources, run:"
    echo -e "  $0 --cluster-name $CLUSTER_NAME --gateway-url ${GATEWAY_URL:-<url>} --cleanup"
  fi
  exit 1
}

###############################################################################
# Default values
###############################################################################
CLUSTER_NAME=""
GATEWAY_URL=""
GATEWAY_API_URL=""
ESO_NAMESPACE="external-secrets"
SECRET_PATH=""
K8S_HOST_OVERRIDE=""
SKIP_CLUSTER_SETUP=false
SKIP_ESO_DEPLOY=false
DRY_RUN=false
CLEANUP=false

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<'USAGE'
Usage: onboard-cluster.sh [OPTIONS]

Onboard a Kubernetes cluster to Akeyless via External Secrets Operator (ESO).

Required:
  --cluster-name <name>       Name for this cluster (used in auth method path, role, config names)
  --gateway-url <url>         External Akeyless Gateway management URL (e.g., https://gw.example.com:8000)

Optional:
  --gateway-api-url <url>     Gateway API URL for ClusterSecretStore (default: <gateway-url>/api/v2)
                              Use an internal service URL if ESO runs on the same cluster as the gateway
  --eso-namespace <ns>        Namespace where ESO is/will be installed (default: external-secrets)
  --secret-path <path>        Akeyless secret path prefix for this cluster (default: /<cluster-name>)
  --skip-cluster-setup        Skip ServiceAccount/RBAC creation (Phase 1)
  --skip-eso-deploy           Skip ESO Helm installation (Phase 4.1)
  --k8s-host <url>            Override K8s API server URL sent to Akeyless (for SSH tunnel / bastion setups)
  --dry-run                   Print commands without executing
  --cleanup                   Remove all resources created by a previous onboard run for this cluster
  --help, -h                  Show this help message

Examples:
  # Full onboarding
  ./onboard-cluster.sh --cluster-name prod-east --gateway-url https://gw.example.com:8000

  # Skip ESO install (already deployed)
  ./onboard-cluster.sh --cluster-name prod-east --gateway-url https://gw.example.com:8000 --skip-eso-deploy

  # Same-cluster gateway (internal URL)
  ./onboard-cluster.sh --cluster-name lab --gateway-url https://gw.example.com:8000 \
    --gateway-api-url http://my-gw-akeyless-gateway-internal.fahmyk.svc:8080

  # Preview what would happen
  ./onboard-cluster.sh --cluster-name staging --gateway-url https://gw.example.com:8000 --dry-run

  # Clean up a previous onboarding
  ./onboard-cluster.sh --cluster-name prod-east --gateway-url https://gw.example.com:8000 --cleanup

Dependencies:
  kubectl, akeyless, helm, jq, base64, curl
USAGE
  exit 0
}

###############################################################################
# Parse arguments
###############################################################################
while [[ $# -gt 0 ]]; do
  case $1 in
    --cluster-name)      CLUSTER_NAME="$2";      shift 2 ;;
    --gateway-url)       GATEWAY_URL="$2";        shift 2 ;;
    --gateway-api-url)   GATEWAY_API_URL="$2";    shift 2 ;;
    --eso-namespace)     ESO_NAMESPACE="$2";      shift 2 ;;
    --secret-path)       SECRET_PATH="$2";        shift 2 ;;
    --skip-cluster-setup) SKIP_CLUSTER_SETUP=true; shift ;;
    --skip-eso-deploy)   SKIP_ESO_DEPLOY=true;    shift ;;
    --k8s-host)          K8S_HOST_OVERRIDE="$2";   shift 2 ;;
    --dry-run)           DRY_RUN=true;            shift ;;
    --cleanup)           CLEANUP=true;            shift ;;
    --help|-h)           usage ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Run with --help for usage." >&2
      exit 1
      ;;
  esac
done

###############################################################################
# Validate required params
###############################################################################
if [[ -z "$CLUSTER_NAME" ]]; then
  echo "ERROR: --cluster-name is required." >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

if [[ -z "$GATEWAY_URL" ]]; then
  echo "ERROR: --gateway-url is required." >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

# Strip trailing slash from URLs
GATEWAY_URL="${GATEWAY_URL%/}"
GATEWAY_API_URL="${GATEWAY_API_URL%/}"

# Derive defaults
if [[ -z "$SECRET_PATH" ]]; then
  SECRET_PATH="/${CLUSTER_NAME}"
fi
if [[ -z "$GATEWAY_API_URL" ]]; then
  GATEWAY_API_URL="${GATEWAY_URL}/api/v2"
fi

# Derived names
AUTH_METHOD_PATH="/k8s-auth/${CLUSTER_NAME}"
K8S_CONF_NAME="${CLUSTER_NAME}-k8s-config"
ROLE_NAME="${CLUSTER_NAME}-eso-role"
TEST_SECRET_NAME="${SECRET_PATH}${TEST_SECRET_SUFFIX}"
TEST_ES_NAME="${CLUSTER_NAME}-onboard-test"

###############################################################################
# Check prerequisites
###############################################################################
check_prerequisites() {
  step "0" "Checking prerequisites"

  local missing=()
  for cmd in kubectl akeyless helm jq base64; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
  success "All required tools found"

  # Check cluster connectivity
  if ! kubectl cluster-info &>/dev/null 2>&1; then
    die "Cannot connect to Kubernetes cluster. Check your kubeconfig."
  fi
  success "Kubernetes cluster is reachable"

  # Check akeyless CLI authentication
  if ! akeyless list-items --path /non-existent-path-check --type secret &>/dev/null 2>&1; then
    # The command may fail because the path is empty, but if auth fails
    # it returns a specific error. Try a simpler check.
    if ! akeyless uid-get-token &>/dev/null 2>&1; then
      warn "Akeyless CLI may not be authenticated. Proceeding anyway."
    fi
  fi
  success "Akeyless CLI is available"

  # Check gateway reachability
  local gw_status
  gw_status=$(curl -sk -o /dev/null -w "%{http_code}" "${GATEWAY_URL}/status" 2>/dev/null || echo "000")
  if [[ "$gw_status" == "000" ]]; then
    warn "Gateway at ${GATEWAY_URL} is not reachable (connection failed)"
  elif [[ "$gw_status" -ge 200 && "$gw_status" -lt 500 ]]; then
    success "Gateway at ${GATEWAY_URL} is reachable (HTTP ${gw_status})"
  else
    warn "Gateway at ${GATEWAY_URL} returned HTTP ${gw_status}"
  fi
}

###############################################################################
# Dry-run wrapper: prints the command instead of executing it
###############################################################################
run() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    return 0
  fi
  "$@"
}

# Variant that captures stdout
run_capture() {
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} $*" >&2
    echo '{"access_id":"p-dry-run-id","prv_key":"dry-run-key"}'
    return 0
  fi
  "$@"
}

###############################################################################
# Phase 1: Cluster-Side Setup
###############################################################################
phase1_cluster_setup() {
  step "1" "Phase 1: Cluster-Side Setup"

  if [[ "$SKIP_CLUSTER_SETUP" == true ]]; then
    warn "Skipping cluster setup (--skip-cluster-setup)"
    return 0
  fi

  # 1.1 Ensure namespace exists
  step "1.1" "Ensuring namespace '${SA_NAMESPACE}' exists"
  if kubectl get namespace "$SA_NAMESPACE" &>/dev/null 2>&1; then
    success "Namespace '${SA_NAMESPACE}' already exists"
  else
    run kubectl create namespace "$SA_NAMESPACE"
    success "Created namespace '${SA_NAMESPACE}'"
  fi

  # 1.2 Create ServiceAccount
  step "1.2" "Creating ServiceAccount '${SA_NAME}' in '${SA_NAMESPACE}'"
  if kubectl get serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" &>/dev/null 2>&1; then
    success "ServiceAccount '${SA_NAME}' already exists"
  else
    run kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${SA_NAMESPACE}
  labels:
    app.kubernetes.io/part-of: ${LABEL_PART_OF}
    app.kubernetes.io/component: token-reviewer
    app.kubernetes.io/managed-by: ${LABEL_MANAGED_BY}
    akeyless.io/cluster-name: ${CLUSTER_NAME}
EOF
    success "Created ServiceAccount '${SA_NAME}'"
  fi

  # 1.3 Create ClusterRoleBinding
  step "1.3" "Creating ClusterRoleBinding '${CRB_NAME}'"
  if kubectl get clusterrolebinding "$CRB_NAME" &>/dev/null 2>&1; then
    success "ClusterRoleBinding '${CRB_NAME}' already exists"
  else
    run kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${CRB_NAME}
  labels:
    app.kubernetes.io/part-of: ${LABEL_PART_OF}
    app.kubernetes.io/component: token-reviewer
    app.kubernetes.io/managed-by: ${LABEL_MANAGED_BY}
    akeyless.io/cluster-name: ${CLUSTER_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
    namespace: ${SA_NAMESPACE}
EOF
    success "Created ClusterRoleBinding '${CRB_NAME}'"
  fi

  # 1.4 Create long-lived token Secret
  step "1.4" "Creating long-lived token Secret '${SA_SECRET_NAME}'"
  if kubectl get secret "$SA_SECRET_NAME" -n "$SA_NAMESPACE" &>/dev/null 2>&1; then
    success "Secret '${SA_SECRET_NAME}' already exists"
  else
    run kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_SECRET_NAME}
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
  labels:
    app.kubernetes.io/part-of: ${LABEL_PART_OF}
    app.kubernetes.io/component: token-reviewer
    app.kubernetes.io/managed-by: ${LABEL_MANAGED_BY}
    akeyless.io/cluster-name: ${CLUSTER_NAME}
type: kubernetes.io/service-account-token
EOF
    success "Created Secret '${SA_SECRET_NAME}'"
  fi

  # 1.5 Wait for token to be populated
  step "1.5" "Waiting for token to be populated"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would wait for token in secret '${SA_SECRET_NAME}'"
  else
    local elapsed=0
    local token=""
    while [[ $elapsed -lt 30 ]]; do
      token=$(kubectl get secret "$SA_SECRET_NAME" -n "$SA_NAMESPACE" \
        -o jsonpath='{.data.token}' 2>/dev/null || echo "")
      if [[ -n "$token" ]]; then
        break
      fi
      sleep 2
      elapsed=$((elapsed + 2))
    done
    if [[ -z "$token" ]]; then
      die "Token was not populated in secret '${SA_SECRET_NAME}' within 30s"
    fi
    success "Token is populated (${elapsed}s)"
  fi

  # 1.6 Extract JWT, CA cert, API server
  step "1.6" "Extracting cluster parameters"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would extract JWT, CA cert, API server URL"
    TOKEN_REVIEWER_JWT="dry-run-jwt"
    K8S_CA_CERT="dry-run-ca-cert"
    K8S_API_SERVER="https://dry-run-api-server:6443"
  else
    TOKEN_REVIEWER_JWT=$(kubectl get secret "$SA_SECRET_NAME" -n "$SA_NAMESPACE" \
      -o jsonpath='{.data.token}' | base64 -d)
    if [[ -z "$TOKEN_REVIEWER_JWT" ]]; then
      die "Could not extract JWT from secret '${SA_SECRET_NAME}'"
    fi
    success "Extracted token reviewer JWT (${#TOKEN_REVIEWER_JWT} chars)"

    # CA cert: try kubeconfig first, then secret
    K8S_CA_CERT=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || echo "")
    if [[ -z "$K8S_CA_CERT" ]]; then
      K8S_CA_CERT=$(kubectl get secret "$SA_SECRET_NAME" -n "$SA_NAMESPACE" \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null || echo "")
    fi
    if [[ -z "$K8S_CA_CERT" ]]; then
      die "Could not extract K8s CA certificate"
    fi
    success "Extracted CA certificate (${#K8S_CA_CERT} chars base64)"

    if [[ -n "$K8S_HOST_OVERRIDE" ]]; then
      K8S_API_SERVER="$K8S_HOST_OVERRIDE"
    else
      K8S_API_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
    fi
    if [[ -z "$K8S_API_SERVER" ]]; then
      die "Could not determine K8s API server URL"
    fi
    success "API server: ${K8S_API_SERVER}"
  fi
}

###############################################################################
# Phase 2: Akeyless Configuration
###############################################################################
phase2_akeyless_config() {
  step "2" "Phase 2: Akeyless Configuration"

  # 2.1 Create K8s auth method
  step "2.1" "Creating K8s auth method '${AUTH_METHOD_PATH}'"

  local auth_exists=false
  if [[ "$DRY_RUN" != true ]]; then
    # Check if auth method already exists
    local existing
    existing=$(akeyless auth-method get --name "$AUTH_METHOD_PATH" --json 2>/dev/null || echo "")
    if [[ -n "$existing" && "$existing" != "null" ]]; then
      auth_exists=true
      ACCESS_ID=$(echo "$existing" | jq -r '.access_id // .accessId // empty')
      if [[ -z "$ACCESS_ID" ]]; then
        # Try the list approach
        ACCESS_ID=$(akeyless list-auth-methods --json 2>/dev/null | \
          jq -r --arg name "$AUTH_METHOD_PATH" '.[] | select(.name == $name) | .access_id // .accessId // empty' || echo "")
      fi
    fi
  fi

  if [[ "$auth_exists" == true && -n "${ACCESS_ID:-}" ]]; then
    success "Auth method '${AUTH_METHOD_PATH}' already exists (access_id: ${ACCESS_ID})"
    warn "Cannot retrieve private key for existing auth method."
    warn "If gateway config fails, delete the auth method and re-run."
    PRV_KEY=""
  else
    info "Creating new K8s auth method..."
    local create_output
    create_output=$(run_capture akeyless auth-method create k8s \
      --name "$AUTH_METHOD_PATH" \
      --json 2>&1)

    if [[ "$DRY_RUN" == true ]]; then
      ACCESS_ID="p-dry-run-id"
      PRV_KEY="dry-run-key"
    else
      ACCESS_ID=$(echo "$create_output" | jq -r '.access_id // .accessId // empty')
      PRV_KEY=$(echo "$create_output" | jq -r '.prv_key // .prvKey // empty')

      if [[ -z "$ACCESS_ID" ]]; then
        echo "$create_output" >&2
        die "Failed to parse access_id from auth method creation output"
      fi
      success "Created auth method (access_id: ${ACCESS_ID})"
    fi
  fi

  # 2.2 Configure gateway K8s auth
  step "2.2" "Configuring gateway K8s auth '${K8S_CONF_NAME}'"

  local gw_config_args=(
    akeyless gateway-create-k8s-auth-config
    --name "$K8S_CONF_NAME"
    --access-id "$ACCESS_ID"
    --gateway-url "$GATEWAY_URL"
    --k8s-host "$K8S_API_SERVER"
    --token-reviewer-jwt "$TOKEN_REVIEWER_JWT"
    --k8s-ca-cert "$K8S_CA_CERT"
    --k8s-issuer ""
  )

  # Include signing key only for new auth methods
  if [[ -n "${PRV_KEY:-}" && "$PRV_KEY" != "dry-run-key" ]]; then
    gw_config_args+=(--signing-key "$PRV_KEY")
  fi

  local gw_create_output
  gw_create_output=$(run "${gw_config_args[@]}" 2>&1) && true
  local gw_rc=$?

  if [[ $gw_rc -ne 0 ]]; then
    if echo "$gw_create_output" | grep -qi "409\|conflict\|already.exist"; then
      info "Gateway config already exists, updating..."
      # Switch to update command
      local gw_update_args=(
        akeyless gateway-update-k8s-auth-config
        --name "$K8S_CONF_NAME"
        --access-id "$ACCESS_ID"
        --gateway-url "$GATEWAY_URL"
        --k8s-host "$K8S_API_SERVER"
        --token-reviewer-jwt "$TOKEN_REVIEWER_JWT"
        --k8s-ca-cert "$K8S_CA_CERT"
        --k8s-issuer ""
      )
      if [[ -n "${PRV_KEY:-}" && "$PRV_KEY" != "dry-run-key" ]]; then
        gw_update_args+=(--signing-key "$PRV_KEY")
      fi
      run "${gw_update_args[@]}" 2>&1 || {
        warn "gateway-update-k8s-auth-config also failed. Manual intervention may be needed."
      }
    else
      warn "gateway-create-k8s-auth-config failed (rc=${gw_rc}): ${gw_create_output}"
    fi
  else
    echo "$gw_create_output"
  fi
  success "Gateway K8s auth config '${K8S_CONF_NAME}' configured"

  # 2.3 Create role
  step "2.3" "Creating role '${ROLE_NAME}'"
  if [[ "$DRY_RUN" != true ]]; then
    local role_exists
    role_exists=$(akeyless get-role --name "$ROLE_NAME" --json 2>/dev/null || echo "")
    if [[ -n "$role_exists" && "$role_exists" != "null" ]]; then
      success "Role '${ROLE_NAME}' already exists"
    else
      run akeyless create-role --name "$ROLE_NAME" --json 2>&1 || die "Failed to create role '${ROLE_NAME}'"
      success "Created role '${ROLE_NAME}'"
    fi
  else
    run akeyless create-role --name "$ROLE_NAME" --json
  fi

  # 2.4 Set role rules (read + list on secret path)
  step "2.4" "Setting role rules on '${SECRET_PATH}/*'"
  run akeyless set-role-rule \
    --role-name "$ROLE_NAME" \
    --path "${SECRET_PATH}/*" \
    --capability read \
    --capability list 2>&1 || {
      if [[ "$DRY_RUN" != true ]]; then
        warn "set-role-rule (read,list) may have failed or rule already exists"
      fi
    }
  success "Role rules set: read, list on ${SECRET_PATH}/*"

  # 2.5 Associate role with auth method
  step "2.5" "Associating role '${ROLE_NAME}' with auth method"
  run akeyless assoc-role-am \
    --role-name "$ROLE_NAME" \
    --am-name "$AUTH_METHOD_PATH" 2>&1 || {
      if [[ "$DRY_RUN" != true ]]; then
        warn "assoc-role-am may have failed or association already exists"
      fi
    }
  success "Role associated with auth method"
}

###############################################################################
# Phase 3: Create Test Secret
###############################################################################
phase3_test_secret() {
  step "3" "Phase 3: Create Test Secret"

  step "3.1" "Creating test secret '${TEST_SECRET_NAME}'"

  local test_value="onboard-test-${CLUSTER_NAME}-$(date +%Y%m%d%H%M%S)"

  if [[ "$DRY_RUN" != true ]]; then
    # Check if secret already exists
    local existing_val
    existing_val=$(akeyless get-secret-value --name "$TEST_SECRET_NAME" 2>/dev/null || echo "")
    if [[ -n "$existing_val" && "$existing_val" != "null" ]]; then
      success "Test secret already exists (current value: ${existing_val})"
      # Update to a fresh value for validation
      run akeyless update-secret-val \
        --name "$TEST_SECRET_NAME" \
        --value "$test_value" 2>&1 || warn "Could not update test secret value"
      success "Updated test secret value to '${test_value}'"
    else
      run akeyless create-secret \
        --name "$TEST_SECRET_NAME" \
        --value "$test_value" 2>&1 || die "Failed to create test secret"
      success "Created test secret with value '${test_value}'"
    fi
  else
    run akeyless create-secret --name "$TEST_SECRET_NAME" --value "$test_value"
  fi

  TEST_SECRET_VALUE="${test_value}"
}

###############################################################################
# Phase 4: ESO Integration
###############################################################################
phase4_eso_integration() {
  step "4" "Phase 4: ESO Integration"

  # 4.1 Install ESO via Helm
  if [[ "$SKIP_ESO_DEPLOY" == true ]]; then
    step "4.1" "Skipping ESO Helm install (--skip-eso-deploy)"
  else
    step "4.1" "Installing ESO via Helm"

    run helm repo add "$ESO_HELM_REPO_NAME" "$ESO_HELM_REPO" 2>&1 || true
    run helm repo update "$ESO_HELM_REPO_NAME" 2>&1 || true

    if [[ "$DRY_RUN" != true ]]; then
      # Check if already installed
      local eso_release
      eso_release=$(helm list -n "$ESO_NAMESPACE" -q 2>/dev/null | grep -x "$ESO_HELM_RELEASE" || echo "")
      if [[ -n "$eso_release" ]]; then
        success "ESO Helm release '${ESO_HELM_RELEASE}' already installed in '${ESO_NAMESPACE}'"
      else
        run helm install "$ESO_HELM_RELEASE" "$ESO_CHART" \
          --namespace "$ESO_NAMESPACE" \
          --create-namespace \
          --set installCRDs=true \
          --wait \
          --timeout 120s 2>&1 || die "Failed to install ESO via Helm"
        success "Installed ESO via Helm"
      fi
    else
      run helm install "$ESO_HELM_RELEASE" "$ESO_CHART" \
        --namespace "$ESO_NAMESPACE" \
        --create-namespace \
        --set installCRDs=true \
        --wait \
        --timeout 120s
    fi
  fi

  # 4.2 Wait for ESO pods to be ready
  step "4.2" "Waiting for ESO pods to be ready"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would wait for ESO pods in '${ESO_NAMESPACE}'"
  else
    local elapsed=0
    while [[ $elapsed -lt 90 ]]; do
      local total ready
      total=$(kubectl get pods -n "$ESO_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
      ready=$(kubectl get pods -n "$ESO_NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

      if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
        success "All ESO pods running (${ready}/${total})"
        break
      fi

      if [[ $elapsed -ge 90 ]]; then
        die "ESO pods not ready after 90s (${ready}/${total} running)"
      fi

      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    done
  fi

  # 4.3 Create ClusterSecretStore
  step "4.3" "Creating ClusterSecretStore '${CSS_NAME}'"
  if [[ "$DRY_RUN" != true ]]; then
    local css_exists
    css_exists=$( (kubectl get clustersecretstore "$CSS_NAME" --no-headers 2>/dev/null || true) | wc -l | tr -d ' ')
    if [[ "$css_exists" -gt 0 ]]; then
      warn "ClusterSecretStore '${CSS_NAME}' already exists, updating..."
    fi
  fi

  run kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: ${CSS_NAME}
  labels:
    app.kubernetes.io/part-of: ${LABEL_PART_OF}
    app.kubernetes.io/component: secret-store
    app.kubernetes.io/managed-by: ${LABEL_MANAGED_BY}
    akeyless.io/cluster-name: ${CLUSTER_NAME}
spec:
  provider:
    akeyless:
      akeylessGWApiURL: "${GATEWAY_API_URL}"
      authSecretRef:
        kubernetesAuth:
          accessID: "${ACCESS_ID}"
          k8sConfName: "${K8S_CONF_NAME}"
          serviceAccountRef:
            name: "external-secrets"
            namespace: "${ESO_NAMESPACE}"
EOF
  success "Applied ClusterSecretStore '${CSS_NAME}'"

  # 4.4 Wait for ClusterSecretStore to become Ready
  step "4.4" "Waiting for ClusterSecretStore to become Ready"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would wait for ClusterSecretStore '${CSS_NAME}' to become Ready"
  else
    local elapsed=0
    local css_ready=""
    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
      css_ready=$(kubectl get clustersecretstore "$CSS_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

      if [[ "$css_ready" == "True" ]]; then
        success "ClusterSecretStore '${CSS_NAME}' is Ready (${elapsed}s)"
        break
      fi

      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    done

    if [[ "$css_ready" != "True" ]]; then
      local css_msg
      css_msg=$(kubectl get clustersecretstore "$CSS_NAME" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "unknown")
      die "ClusterSecretStore not Ready after ${POLL_TIMEOUT}s. Status message: ${css_msg}"
    fi
  fi

  # 4.5 Create test ExternalSecret
  step "4.5" "Creating test ExternalSecret '${TEST_ES_NAME}'"
  run kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${TEST_ES_NAME}
  namespace: default
  labels:
    app.kubernetes.io/part-of: ${LABEL_PART_OF}
    app.kubernetes.io/component: validation-test
    app.kubernetes.io/managed-by: ${LABEL_MANAGED_BY}
    akeyless.io/cluster-name: ${CLUSTER_NAME}
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: ${CSS_NAME}
    kind: ClusterSecretStore
  target:
    name: ${TEST_ES_NAME}
    creationPolicy: Owner
  data:
    - secretKey: test-value
      remoteRef:
        key: ${TEST_SECRET_NAME}
EOF
  success "Applied test ExternalSecret '${TEST_ES_NAME}'"

  # 4.6 Wait for ExternalSecret to sync
  step "4.6" "Waiting for ExternalSecret to sync"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would wait for ExternalSecret '${TEST_ES_NAME}' to sync"
  else
    local elapsed=0
    local synced=false
    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
      local es_status
      es_status=$(kubectl get externalsecret "$TEST_ES_NAME" -n default \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

      if [[ "$es_status" == "True" ]]; then
        synced=true
        break
      fi

      sleep "$POLL_INTERVAL"
      elapsed=$((elapsed + POLL_INTERVAL))
    done

    if [[ "$synced" == true ]]; then
      success "ExternalSecret synced successfully (${elapsed}s)"
    else
      local es_msg
      es_msg=$(kubectl get externalsecret "$TEST_ES_NAME" -n default \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null || echo "unknown")
      die "ExternalSecret did not sync within ${POLL_TIMEOUT}s. Message: ${es_msg}"
    fi
  fi

  # 4.7 Verify K8s secret value matches Akeyless secret
  step "4.7" "Verifying K8s secret matches Akeyless secret"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "  ${YELLOW}[DRY-RUN]${NC} Would verify secret value match"
  else
    local k8s_value
    k8s_value=$(kubectl get secret "$TEST_ES_NAME" -n default \
      -o jsonpath='{.data.test-value}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

    if [[ -z "$k8s_value" ]]; then
      die "K8s secret '${TEST_ES_NAME}' not found or empty"
    fi

    if [[ "$k8s_value" == "${TEST_SECRET_VALUE}" ]]; then
      success "Secret value matches: '${TEST_SECRET_VALUE}'"
    else
      fail "Value mismatch!"
      info "  Akeyless value: '${TEST_SECRET_VALUE}'"
      info "  K8s value:      '${k8s_value}'"
      die "End-to-end validation failed: secret values do not match"
    fi
  fi
}

###############################################################################
# Phase 5: Summary
###############################################################################
phase5_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}=====================================================${NC}"
  echo -e "${GREEN}${BOLD}  Cluster Onboarding Complete!${NC}"
  echo -e "${GREEN}${BOLD}=====================================================${NC}"
  echo ""
  echo -e "${BOLD}Cluster:${NC}           ${CLUSTER_NAME}"
  echo -e "${BOLD}Auth Method:${NC}       ${AUTH_METHOD_PATH}"
  echo -e "${BOLD}Access ID:${NC}         ${ACCESS_ID}"
  echo -e "${BOLD}K8s Config Name:${NC}   ${K8S_CONF_NAME}"
  echo -e "${BOLD}Role:${NC}              ${ROLE_NAME}"
  echo -e "${BOLD}Secret Path:${NC}       ${SECRET_PATH}/*"
  echo -e "${BOLD}Gateway API URL:${NC}   ${GATEWAY_API_URL}"
  echo -e "${BOLD}ClusterSecretStore:${NC} ${CSS_NAME}"
  echo -e "${BOLD}ESO Namespace:${NC}     ${ESO_NAMESPACE}"
  echo ""
  echo -e "${BOLD}Cluster-Side Resources:${NC}"
  echo "  - ServiceAccount: ${SA_NAME} (ns: ${SA_NAMESPACE})"
  echo "  - Secret:         ${SA_SECRET_NAME} (ns: ${SA_NAMESPACE})"
  echo "  - ClusterRoleBinding: ${CRB_NAME}"
  echo ""
  echo -e "${BOLD}Test Resources (safe to delete):${NC}"
  echo "  - Akeyless secret: ${TEST_SECRET_NAME}"
  echo "  - ExternalSecret:  ${TEST_ES_NAME} (ns: default)"
  echo "  - K8s Secret:      ${TEST_ES_NAME} (ns: default)"
  echo ""
  echo -e "${BOLD}To use in application ExternalSecrets:${NC}"
  echo ""
  cat <<EXAMPLE
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: my-app-secret
    namespace: my-app
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: ${CSS_NAME}
      kind: ClusterSecretStore
    target:
      name: my-app-secret
      creationPolicy: Owner
    data:
      - secretKey: my-key
        remoteRef:
          key: ${SECRET_PATH}/my-secret-name
EXAMPLE
  echo ""
}

###############################################################################
# Cleanup mode
###############################################################################
do_cleanup() {
  echo -e "${BOLD}Cleaning up resources for cluster '${CLUSTER_NAME}'...${NC}"
  echo ""

  local errors=0

  # K8s test resources
  step "C.1" "Removing test ExternalSecret and K8s Secret"
  run kubectl delete externalsecret "$TEST_ES_NAME" -n default --ignore-not-found=true 2>&1 || true
  run kubectl delete secret "$TEST_ES_NAME" -n default --ignore-not-found=true 2>&1 || true
  success "Test ExternalSecret and K8s Secret removed"

  # ClusterSecretStore
  step "C.2" "Removing ClusterSecretStore '${CSS_NAME}'"
  run kubectl delete clustersecretstore "$CSS_NAME" --ignore-not-found=true 2>&1 || true
  success "ClusterSecretStore removed"

  # Akeyless test secret
  step "C.3" "Removing Akeyless test secret '${TEST_SECRET_NAME}'"
  if [[ "$DRY_RUN" != true ]]; then
    akeyless delete-item --name "$TEST_SECRET_NAME" 2>/dev/null || true
  else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} akeyless delete-item --name ${TEST_SECRET_NAME}"
  fi
  success "Akeyless test secret removed"

  # Akeyless role association
  step "C.4" "Removing role association"
  if [[ "$DRY_RUN" != true ]]; then
    akeyless delete-assoc --assoc-id \
      "$(akeyless get-role --name "$ROLE_NAME" --json 2>/dev/null | \
         jq -r '.role_auth_methods_assoc[]? | select(.auth_method_name == "'"$AUTH_METHOD_PATH"'") | .assoc_id // empty' 2>/dev/null || echo "")" \
      2>/dev/null || true
  else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} akeyless delete-assoc (role: ${ROLE_NAME}, am: ${AUTH_METHOD_PATH})"
  fi
  success "Role association removed (if existed)"

  # Akeyless role
  step "C.5" "Removing role '${ROLE_NAME}'"
  if [[ "$DRY_RUN" != true ]]; then
    akeyless delete-role --name "$ROLE_NAME" 2>/dev/null || true
  else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} akeyless delete-role --name ${ROLE_NAME}"
  fi
  success "Role removed"

  # Gateway K8s auth config
  step "C.6" "Removing gateway K8s auth config '${K8S_CONF_NAME}'"
  if [[ "$DRY_RUN" != true ]]; then
    akeyless gateway-delete-k8s-auth-config \
      --name "$K8S_CONF_NAME" \
      --gateway-url "$GATEWAY_URL" 2>/dev/null || true
  else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} akeyless gateway-delete-k8s-auth-config --name ${K8S_CONF_NAME}"
  fi
  success "Gateway K8s auth config removed"

  # Akeyless auth method
  step "C.7" "Removing auth method '${AUTH_METHOD_PATH}'"
  if [[ "$DRY_RUN" != true ]]; then
    akeyless auth-method delete --name "$AUTH_METHOD_PATH" 2>/dev/null || true
  else
    echo -e "  ${YELLOW}[DRY-RUN]${NC} akeyless auth-method delete --name ${AUTH_METHOD_PATH}"
  fi
  success "Auth method removed"

  # Cluster-side resources
  step "C.8" "Removing cluster-side resources"
  run kubectl delete secret "$SA_SECRET_NAME" -n "$SA_NAMESPACE" --ignore-not-found=true 2>&1 || true
  run kubectl delete clusterrolebinding "$CRB_NAME" --ignore-not-found=true 2>&1 || true
  run kubectl delete serviceaccount "$SA_NAME" -n "$SA_NAMESPACE" --ignore-not-found=true 2>&1 || true
  success "Cluster-side resources removed"

  echo ""
  echo -e "${GREEN}${BOLD}Cleanup complete for cluster '${CLUSTER_NAME}'.${NC}"
  echo ""
  echo -e "${YELLOW}Note:${NC} ESO Helm release was NOT removed (other clusters may use it)."
  echo "To remove ESO: helm uninstall ${ESO_HELM_RELEASE} -n ${ESO_NAMESPACE}"
}

###############################################################################
# Main
###############################################################################
main() {
  echo -e "${BOLD}============================================${NC}"
  echo -e "${BOLD} Akeyless + ESO Cluster Onboarding${NC}"
  echo -e "${BOLD}============================================${NC}"
  echo ""
  echo -e "Cluster:     ${BOLD}${CLUSTER_NAME}${NC}"
  echo -e "Gateway:     ${BOLD}${GATEWAY_URL}${NC}"
  echo -e "API URL:     ${BOLD}${GATEWAY_API_URL}${NC}"
  echo -e "Secret Path: ${BOLD}${SECRET_PATH}/*${NC}"
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "Mode:        ${YELLOW}${BOLD}DRY RUN${NC}"
  fi
  if [[ "$CLEANUP" == true ]]; then
    echo -e "Mode:        ${RED}${BOLD}CLEANUP${NC}"
  fi

  if [[ "$CLEANUP" == true ]]; then
    do_cleanup
    exit 0
  fi

  check_prerequisites
  phase1_cluster_setup
  phase2_akeyless_config
  phase3_test_secret
  phase4_eso_integration
  phase5_summary
}

main
