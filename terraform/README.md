# Terraform -- Akeyless K8s Auth Module

Terraform module and examples for automating Akeyless Kubernetes authentication setup.

## Module: `akeyless-k8s-auth`

The module in `modules/akeyless-k8s-auth/` creates:

1. An **Akeyless Kubernetes auth method** configured with the cluster's API server, CA certificate, and token reviewer JWT.
2. An **Akeyless role** with read/list access to specified secret paths.
3. A **role-auth-method association** linking the two, with optional sub-claims.

### Inputs

| Variable | Type | Required | Description |
|---|---|---|---|
| `cluster_name` | `string` | Yes | Unique identifier for the cluster |
| `k8s_api_server` | `string` | Yes | K8s API server URL (https://) |
| `k8s_ca_cert` | `string` | Yes | Base64-encoded cluster CA certificate |
| `token_reviewer_jwt` | `string` | Yes | Long-lived JWT for TokenReview |
| `gateway_url` | `string` | Yes | Akeyless Gateway API URL |
| `bound_namespaces` | `list(string)` | No | Allowed K8s namespaces (default: `["external-secrets"]`) |
| `bound_sa_names` | `list(string)` | No | Allowed ServiceAccount names |
| `secret_access_paths` | `list(string)` | Yes | Akeyless secret paths (supports wildcards) |
| `sub_claims` | `map(string)` | No | Optional sub-claims for fine-grained control |

### Outputs

| Output | Description |
|---|---|
| `auth_method_access_id` | Access ID for the ClusterSecretStore |
| `auth_method_path` | Auth method path for `k8sConfName` |
| `role_name` | Created role path |

## Examples

### Single Cluster

```bash
cd examples/single-cluster
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan
terraform apply
```

### Multi-Cluster

```bash
cd examples/multi-cluster
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with all cluster configurations
terraform init
terraform plan
terraform apply
```

## Authentication

The Akeyless Terraform provider authenticates via environment variables:

```bash
export AKEYLESS_ACCESS_ID="p-xxxxxxxxxx"
export AKEYLESS_ACCESS_KEY="<your-access-key>"
```

Or configure them in the provider block (not recommended for production).

## State Management

For team usage, configure a remote backend in the `terraform` block. Supported backends include GCS, S3, Azure Blob, or Terraform Cloud.
