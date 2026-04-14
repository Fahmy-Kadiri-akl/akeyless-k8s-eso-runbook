# Kubernetes Manifests

Ready-to-apply Kubernetes manifests for the Akeyless + ESO integration.

## Directory Structure

```
manifests/
├── rke/                              # RKE/Rancher-specific resources
│   ├── token-reviewer-role.yaml      # ClusterRoleBinding for TokenReview
│   └── token-reviewer-user.yaml      # ServiceAccount + long-lived token Secret
├── gke/                              # GKE-specific resources
│   ├── gateway-token-reviewer-sa.yaml    # ServiceAccount + ClusterRoleBinding
│   └── gateway-token-reviewer-secret.yaml # Long-lived token Secret
└── eso/                              # ESO resources (cluster-agnostic)
    ├── cluster-secret-store.yaml     # ClusterSecretStore for Akeyless
    ├── external-secret-static.yaml   # Example: static secret
    ├── external-secret-dynamic.yaml  # Example: dynamic secret
    └── external-secret-rotated.yaml  # Example: rotated secret
```

## Usage

### 1. Cluster Preparation (choose one)

**For RKE/Rancher clusters:**

```bash
kubectl apply -f manifests/rke/token-reviewer-user.yaml
kubectl apply -f manifests/rke/token-reviewer-role.yaml
```

**For GKE clusters:**

```bash
kubectl apply -f manifests/gke/gateway-token-reviewer-sa.yaml
kubectl apply -f manifests/gke/gateway-token-reviewer-secret.yaml
```

### 2. ESO Configuration

After installing ESO and creating the Akeyless auth method, edit and apply the ClusterSecretStore:

```bash
# Edit the file to replace placeholders
vim manifests/eso/cluster-secret-store.yaml

# Apply
kubectl apply -f manifests/eso/cluster-secret-store.yaml
```

### 3. Create ExternalSecrets

Copy and customize the example templates for your applications:

```bash
# Edit placeholders
cp manifests/eso/external-secret-static.yaml my-app-secret.yaml
vim my-app-secret.yaml

# Apply
kubectl apply -f my-app-secret.yaml
```

## Placeholder Reference

All manifests use `<REPLACE_ME>` style placeholders. Replace them before applying:

| Placeholder | Description | Example |
|---|---|---|
| `<GATEWAY_URL>` | Akeyless Gateway hostname | `gateway.example.com` |
| `<AUTH_METHOD_ACCESS_ID>` | Access ID from auth method creation | `p-xxxxxxxxxx` |
| `<CLUSTER_NAME>` | Cluster identifier | `prod-rke-us-east` |
| `<APP_NAME>` | Application name | `my-app` |
| `<NAMESPACE>` | Target K8s namespace | `my-app` |
| `<SECRET_PATH_*>` | Akeyless secret path | `/production/my-app/db-password` |
