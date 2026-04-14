# Cluster Setup -- GKE

This document covers the preparation steps required for Google Kubernetes Engine (GKE) clusters before integrating with Akeyless via ESO.

## Overview

GKE clusters require the same fundamental setup as any Kubernetes cluster:

1. A **ServiceAccount** with TokenReview permissions
2. A **long-lived token** for that ServiceAccount
3. The **cluster CA certificate** and **API server URL**

However, GKE has some specifics around API server access (especially for private clusters) and Workload Identity that require additional consideration.

## Step 1: Connect to the GKE Cluster

```bash
gcloud container clusters get-credentials <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID>
```

**Expected output:**
```
Fetching cluster endpoint and auth data.
kubeconfig entry generated for <CLUSTER_NAME>.
```

Verify connectivity:

```bash
kubectl cluster-info
```

## Step 2: Create the Token Reviewer ServiceAccount

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

## Step 3: Bind the Token Reviewer Role

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

## Step 4: Create a Long-Lived Token

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

Retrieve the token:

```bash
kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d
```

**Expected output:** A JWT string starting with `eyJ...`.

## Step 5: Extract the Cluster CA Certificate

For GKE, the CA certificate can be extracted from the token secret or from the `gcloud` CLI:

**Option A -- From the token secret:**

```bash
kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > cluster-ca.crt
```

**Option B -- From gcloud:**

```bash
gcloud container clusters describe <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID> \
  --format='value(masterAuth.clusterCaCertificate)' | base64 -d > cluster-ca.crt
```

Verify:

```bash
openssl x509 -in cluster-ca.crt -noout -subject -issuer -dates
```

## Step 6: Get the API Server URL

```bash
gcloud container clusters describe <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID> \
  --format='value(endpoint)'
```

This returns the IP address. The full API server URL is `https://<IP>:443`.

Alternatively:

```bash
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}'
```

## GKE-Specific Considerations

### Private Clusters

GKE private clusters have a private API server endpoint that is not publicly accessible. The Akeyless Gateway must be able to reach this endpoint for TokenReview validation.

**Options for Gateway-to-API-Server connectivity:**

| Option | Description | Complexity |
|---|---|---|
| **Gateway in same VPC** | Deploy the Akeyless Gateway in the same GCP VPC as the GKE cluster | Low |
| **VPC Peering** | Peer the Gateway's VPC with the GKE cluster's VPC | Medium |
| **Authorized Networks** | Add the Gateway's IP to the cluster's authorized networks (for public endpoint with authorized networks) | Low |
| **Cloud NAT + Private Google Access** | Route through Cloud NAT if the Gateway is outside GCP | High |

To add an authorized network:

```bash
gcloud container clusters update <CLUSTER_NAME> \
  --region <REGION> \
  --project <PROJECT_ID> \
  --enable-master-authorized-networks \
  --master-authorized-networks <GATEWAY_IP>/32
```

### Workload Identity

If your GKE cluster uses Workload Identity, the ESO controller's ServiceAccount can optionally be bound to a Google Service Account (GSA). However, for Akeyless integration, ESO uses the Akeyless K8s auth method -- not GCP IAM -- so Workload Identity is **not required** for this integration.

> **Note:** Workload Identity does not interfere with the Akeyless K8s auth flow. The TokenReview mechanism works independently of Workload Identity.

### Autopilot Clusters

GKE Autopilot clusters have restrictions on what can be deployed in `kube-system`. If you encounter permission issues:

1. Create the ServiceAccount and Secret in a dedicated namespace instead:

```bash
kubectl create namespace akeyless-system
```

2. Apply the ServiceAccount, Secret, and ClusterRoleBinding using `namespace: akeyless-system` instead of `kube-system`.

3. Update the Akeyless auth method configuration to reference the correct namespace.

### GKE Release Channels

GKE clusters on the **Rapid** release channel may get Kubernetes upgrades that change API behavior. Test your integration in a staging cluster on the same channel before production deployment.

## Step 7: Verify Token Reviewer Permissions

```bash
TOKEN=$(kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)

API_SERVER=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.server}')

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

> **Warning:** If you are running this from outside the cluster (e.g., your local machine via `gcloud`), the `curl` test may fail due to private endpoint restrictions. Run the test from within the cluster network or use `kubectl` directly.

## Collected Parameters

| Parameter | How to get it |
|---|---|
| **API Server URL** | `gcloud container clusters describe ... --format='value(endpoint)'` (prefix with `https://`) |
| **CA Certificate (base64)** | `gcloud container clusters describe ... --format='value(masterAuth.clusterCaCertificate)'` |
| **Token Reviewer JWT** | `kubectl get secret gateway-token-reviewer-token -n kube-system -o jsonpath='{.data.token}' \| base64 -d` |
| **Cluster Name** | Your chosen identifier for this cluster in Akeyless |

## Applying Manifests from This Repository

The `manifests/gke/` directory contains ready-to-apply versions of the resources created above:

```bash
kubectl apply -f manifests/gke/gateway-token-reviewer-sa.yaml
kubectl apply -f manifests/gke/gateway-token-reviewer-secret.yaml
```

> **Note:** The GKE manifests are functionally identical to the RKE manifests. They are separated for organizational clarity and to allow for GKE-specific annotations in the future (e.g., Workload Identity annotations).

## Next Steps

- [Akeyless Auth Configuration](05-akeyless-auth-config.md) -- create the K8s auth method in Akeyless using the collected parameters
