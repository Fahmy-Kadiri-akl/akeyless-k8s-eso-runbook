# Prerequisites

Complete all items in this checklist before proceeding with the integration.

## Akeyless Account

- [ ] Akeyless account with access to create auth methods, roles, and access rules
- [ ] At least one Akeyless Gateway deployed and accessible from your Kubernetes clusters
- [ ] Gateway API URL noted (e.g., `https://gateway.example.com:8000/api/v2`)
- [ ] Akeyless CLI installed and authenticated

### Verify Akeyless CLI

```bash
akeyless --version
```

**Expected output:**
```
Akeyless CLI version X.Y.Z
```

Authenticate to your account:

```bash
akeyless auth --access-id p-xxxxxxxxxx --access-key <YOUR_ACCESS_KEY>
```

**Expected output:**
```
Authentication succeeded.
```

### Verify Gateway Connectivity

```bash
curl -s https://<GATEWAY_URL>:8000/status | jq .
```

**Expected output:**
```json
{
  "status": "running",
  ...
}
```

## Kubernetes Clusters

- [ ] `kubectl` access to each target cluster with `cluster-admin` privileges
- [ ] Cluster API server URL known and accessible from the Akeyless Gateway
- [ ] For RKE/Rancher: Rancher management access or direct `kubectl` to downstream clusters
- [ ] For GKE: `gcloud` CLI configured with appropriate project and credentials

### Verify kubectl Access

```bash
kubectl cluster-info
```

**Expected output:**
```
Kubernetes control plane is running at https://<API_SERVER_URL>
CoreDNS is running at ...
```

Verify you have cluster-admin:

```bash
kubectl auth can-i '*' '*' --all-namespaces
```

**Expected output:**
```
yes
```

## Helm

- [ ] Helm v3.x installed

```bash
helm version --short
```

**Expected output:**
```
v3.x.y+...
```

Add the External Secrets Operator Helm repository:

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
```

## Terraform (for automation tracks)

- [ ] Terraform >= 1.3 installed

```bash
terraform version
```

**Expected output:**
```
Terraform v1.3.x
...
```

## Network Requirements Checklist

| Source | Destination | Port | Protocol | Purpose |
|---|---|---|---|---|
| K8s cluster (ESO pods) | Akeyless Gateway | 8000 or 8080 | HTTPS/HTTP | API calls (auth + secret fetch) |
| Akeyless Gateway | K8s API server | 443 | HTTPS | TokenReview API (token validation) |
| Akeyless Gateway | api.akeyless.io | 443 | HTTPS | Akeyless SaaS backend |

> **Tip:** If you are using a private GKE cluster, the Akeyless Gateway must be added to the cluster's authorized networks, or you need to route through a bastion/proxy.

### Test Gateway-to-K8s-API Connectivity

From the machine running the Akeyless Gateway (or a pod in the same network):

```bash
curl -sk https://<K8S_API_SERVER>:443/healthz
```

**Expected output:**
```
ok
```

## Information to Gather

Before you begin, collect the following for each cluster you want to onboard:

| Parameter | Description | Example |
|---|---|---|
| `cluster_name` | Friendly name for the cluster | `prod-rke-us-east` |
| `k8s_api_server_url` | Kubernetes API server URL | `https://10.0.1.100:6443` |
| `k8s_ca_cert` | Base64-encoded CA certificate of the K8s API server | (see extraction script) |
| `gateway_url` | Akeyless Gateway API URL | `https://gateway.example.com:8000/api/v2` |
| `akeyless_access_id` | Access ID for Akeyless admin | `p-xxxxxxxxxx` |
| `token_reviewer_jwt` | Long-lived JWT for TokenReview API calls | (see cluster setup docs) |

> **Tip:** Use the `scripts/extract-cluster-params.sh` helper script to automatically extract cluster parameters. See [scripts/README.md](../scripts/README.md).

## Next Steps

- [Cluster Setup -- RKE](03-cluster-setup-rke.md) -- for RKE/Rancher clusters
- [Cluster Setup -- GKE](04-cluster-setup-gke.md) -- for GKE clusters
