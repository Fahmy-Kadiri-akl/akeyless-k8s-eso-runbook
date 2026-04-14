# Cluster Setup -- RKE / Rancher

This document covers the preparation steps required for RKE and Rancher-managed Kubernetes clusters before integrating with Akeyless via ESO.

## Overview

Akeyless Kubernetes authentication requires:

1. A **ServiceAccount** with permissions to call the TokenReview API
2. A **long-lived token** for that ServiceAccount (used by the Akeyless Gateway to validate pod tokens)
3. The **cluster CA certificate** (used by the Gateway to trust the K8s API server's TLS)

RKE clusters (both RKE1 and RKE2) run a standard Kubernetes API server, so the setup is straightforward.

## Choosing Your Approach

There are two validated approaches for Rancher-managed clusters:

| Approach | When to Use | Pros | Cons |
|---|---|---|---|
| **Standard K8s** (Steps 1-5 below) | Gateway has direct network access to the K8s API server | Simple, portable, uses native K8s primitives | Requires direct API server access |
| **Rancher-Native** (Appendix A below) | Gateway does NOT have direct API access, or you prefer Rancher management plane | Works through Rancher proxy, managed via Rancher UI/API | More complex, API key has 90-day default TTL |

For most deployments, the **Standard K8s approach** is recommended. Use the Rancher-Native approach when the Akeyless Gateway cannot reach the cluster's K8s API server directly (e.g., private clusters behind NAT).

## Step 1: Create the Token Reviewer ServiceAccount

This ServiceAccount will be used by the Akeyless Gateway to validate tokens from ESO.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gateway-token-reviewer
  namespace: kube-system
  labels:
    app.kubernetes.io/part-of: akeyless-integration
    app.kubernetes.io/component: token-reviewer
EOF
```

**Expected output:**
```
serviceaccount/gateway-token-reviewer created
```

## Step 2: Bind the Token Reviewer Role

Grant the ServiceAccount permission to perform token reviews:

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gateway-token-reviewer-binding
  labels:
    app.kubernetes.io/part-of: akeyless-integration
    app.kubernetes.io/component: token-reviewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: gateway-token-reviewer
    namespace: kube-system
EOF
```

**Expected output:**
```
clusterrolebinding.rbac.authorization.k8s.io/gateway-token-reviewer-binding created
```

> **Note:** The `system:auth-delegator` ClusterRole is a built-in Kubernetes role that grants permission to submit TokenReview and SubjectAccessReview requests. This is the minimum privilege needed.

## Step 3: Create a Long-Lived Token

Kubernetes 1.24+ no longer auto-generates long-lived tokens for ServiceAccounts. Create one explicitly:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: gateway-token-reviewer-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: gateway-token-reviewer
  labels:
    app.kubernetes.io/part-of: akeyless-integration
    app.kubernetes.io/component: token-reviewer
type: kubernetes.io/service-account-token
EOF
```

**Expected output:**
```
secret/gateway-token-reviewer-token created
```

Wait a few seconds for the token controller to populate the token, then verify:

```bash
kubectl get secret gateway-token-reviewer-token -n kube-system -o jsonpath='{.data.token}' | base64 -d
```

**Expected output:** A long JWT string starting with `eyJ...`.

## Step 4: Extract the Cluster CA Certificate

```bash
kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

Alternatively, extract from the kubeconfig:

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > cluster-ca.crt
```

Verify the certificate:

```bash
openssl x509 -in cluster-ca.crt -noout -subject -issuer -dates
```

**Expected output:** Certificate details showing the cluster's CA subject and valid dates.

## Step 5: Get the API Server URL

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'
```

**Expected output:** The API server URL, e.g., `https://10.0.1.100:6443`

> **Warning:** K3s and Rancher-managed clusters may return `https://127.0.0.1:6443` as the API server URL. This is the loopback address and cannot be used by an external Akeyless Gateway. You must use one of:
> - The node's actual IP/hostname: `https://<node-ip>:6443`
> - The Rancher proxy URL: `https://<rancher-url>/k8s/clusters/<cluster-id>` (see Appendix A)
> - A load balancer URL (for multi-node RKE2 clusters)

> **Warning (RKE1):** If the API server URL is an internal/private IP, the Akeyless Gateway must have network access to that IP. For Rancher-managed clusters, do NOT use the Rancher proxy URL (`https://rancher.example.com/k8s/clusters/c-xxxxx`) -- the Gateway needs direct access to the K8s API server.

> **Warning (RKE2):** RKE2 clusters may use a load balancer in front of multiple control plane nodes. Use the load balancer URL for the API server address.

## Step 6: Verify Token Reviewer Permissions

Test that the ServiceAccount can perform token reviews:

```bash
# Get the token
TOKEN=$(kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)

# Get the API server URL
API_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

# Perform a self-review (should succeed even though the token isn't for a pod)
curl -sk "$API_SERVER/apis/authentication.k8s.io/v1/tokenreviews" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"apiVersion\": \"authentication.k8s.io/v1\",
    \"kind\": \"TokenReview\",
    \"spec\": {
      \"token\": \"$TOKEN\"
    }
  }" | jq '.status'
```

**Expected output:**
```json
{
  "authenticated": true,
  "user": {
    "username": "system:serviceaccount:kube-system:gateway-token-reviewer",
    ...
  }
}
```

## Collected Parameters

After completing these steps, you should have:

| Parameter | How to get it | Store it |
|---|---|---|
| **API Server URL** | `kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'` | Terraform variable or pipeline secret |
| **CA Certificate (base64)** | `kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'` | Terraform variable or pipeline secret |
| **Token Reviewer JWT** | `kubectl get secret gateway-token-reviewer-token -n kube-system -o jsonpath='{.data.token}' \| base64 -d` | Store in Akeyless as a static secret |

> **Tip:** Store the token reviewer JWT in Akeyless itself as a static secret (e.g., `/infrastructure/k8s/<cluster-name>/token-reviewer-jwt`). This keeps it auditable and allows rotation.

## RKE-Specific Considerations

### Rancher Project Isolation

If you use Rancher Projects for namespace isolation, ESO should be installed in a system project or a dedicated infrastructure project that has cross-namespace access.

### RKE1 vs RKE2

| Feature | RKE1 | RKE2 |
|---|---|---|
| Default API server port | 6443 | 6443 (or 9345 for registration) |
| Token auto-creation (pre-1.24) | Yes | No (uses K3s-style) |
| CA cert location on nodes | `/etc/kubernetes/ssl/kube-ca.pem` | `/var/lib/rancher/rke2/server/tls/server-ca.crt` |
| kubectl config | `$HOME/.kube/config` or Rancher-generated | `/etc/rancher/rke2/rke2.yaml` |

### Air-Gapped Clusters

For air-gapped RKE clusters:
- Pre-pull the ESO container images into your private registry
- Configure Helm to use your private chart repository
- Ensure the Akeyless Gateway is deployed within the air-gapped network

## Applying Manifests from This Repository

The `manifests/rke/` directory contains ready-to-apply versions of the resources created above:

```bash
kubectl apply -f manifests/rke/token-reviewer-role.yaml
kubectl apply -f manifests/rke/token-reviewer-user.yaml
```

## Next Steps

- [Akeyless Auth Configuration](05-akeyless-auth-config.md) -- create the K8s auth method in Akeyless using the collected parameters

## Appendix A: Rancher-Native Approach

This approach uses the Rancher management plane instead of direct K8s API access. Use it when the Akeyless Gateway cannot reach the cluster's K8s API server directly.

### Step A1: Create a Token Reviewer Global Role

Via Rancher API:

```bash
RANCHER_URL="https://<RANCHER_URL>"
RANCHER_TOKEN="<ADMIN_BEARER_TOKEN>"

curl -sk "${RANCHER_URL}/v3/globalRoles" \
  -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Token Reviewer",
    "description": "Allows creating TokenReview requests for Akeyless K8s auth",
    "rules": [
      {
        "apiGroups": ["authentication.k8s.io"],
        "resources": ["tokenreviews"],
        "verbs": ["create"]
      }
    ]
  }'
```

Or via the Rancher UI:
1. Go to **Users & Authentication > Role Templates**
2. Click **Create Global Role**
3. Name: `Token Reviewer`
4. Add rule: API Group `authentication.k8s.io`, Resource `tokenreviews`, Verb `create`
5. Click **Create**

### Step A2: Create an Akeyless Service User

```bash
curl -sk "${RANCHER_URL}/v3/users" \
  -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "akeyless-token-reviewer",
    "password": "<GENERATE_RANDOM_PASSWORD>",
    "mustChangePassword": false,
    "enabled": true
  }'
```

Note the `id` field from the response (e.g., `user-xxxxx`).

### Step A3: Bind the Global Role to the User

```bash
curl -sk "${RANCHER_URL}/v3/globalRoleBindings" \
  -H "Authorization: Bearer ${RANCHER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "globalRoleId": "<TOKEN_REVIEWER_ROLE_ID>",
    "userId": "<USER_ID_FROM_STEP_A2>"
  }'
```

### Step A4: Generate an API Key

Login as the new user and generate an API key:

```bash
# Login as the service user
LOGIN_RESPONSE=$(curl -sk "${RANCHER_URL}/v3-public/localProviders/local?action=login" \
  -H "Content-Type: application/json" \
  -d '{"username":"akeyless-token-reviewer","password":"<PASSWORD_FROM_STEP_A2>"}')

USER_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

# Create an API key (no scope = access to all clusters)
curl -sk "${RANCHER_URL}/v3/tokens" \
  -H "Authorization: Bearer ${USER_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "description": "Akeyless Gateway token reviewer",
    "ttl": 0
  }'
```

> **Warning:** Setting `ttl: 0` does NOT create a permanent token — Rancher defaults to 90 days (7,776,000,000ms). Plan for API key rotation or set a longer TTL via Rancher settings.

Note the `token` field from the response — this is the bearer token for Akeyless.

### Step A5: Collect Parameters for Akeyless

When using the Rancher-native approach, the parameters differ:

| Parameter | Value | Notes |
|---|---|---|
| **API Server URL** | `https://<rancher-url>/k8s/clusters/<cluster-id>` | Use `local` for the local cluster, or the cluster ID from Rancher |
| **Bearer Token** | Rancher API key from Step A4 | NOT a K8s ServiceAccount token |
| **CA Certificate** | Rancher server's TLS certificate | NOT the K8s cluster CA — use `openssl s_client -connect <rancher-host>:443` to extract |

Extract the Rancher TLS CA certificate:

```bash
openssl s_client -connect <RANCHER_HOST>:443 </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > rancher-ca.crt
```

> **Important:** When configuring the Akeyless K8s auth method with `gateway-create-k8s-auth-config`, use:
> - `--k8s-host`: The Rancher proxy URL (e.g., `https://rancher.example.com/k8s/clusters/local`)
> - `--k8s-ca-cert`: Base64-encoded Rancher TLS certificate (NOT the K8s cluster CA)
> - `--token-reviewer-jwt`: The Rancher API key bearer token (NOT a K8s SA JWT)
