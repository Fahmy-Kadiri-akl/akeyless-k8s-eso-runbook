# Scripts

Helper scripts for the Akeyless + ESO integration.

## `extract-cluster-params.sh`

Extracts Kubernetes cluster parameters needed for Akeyless K8s auth method configuration. Outputs a JSON object with all required values.

**Prerequisites:**
- `kubectl` configured with access to the target cluster
- `jq` installed
- `gateway-token-reviewer` ServiceAccount and Secret created (apply the manifests first)

**Usage:**

```bash
# Default (reads from kube-system namespace)
./scripts/extract-cluster-params.sh

# Custom namespace
./scripts/extract-cluster-params.sh --namespace akeyless-system

# Custom secret name
./scripts/extract-cluster-params.sh --secret-name my-token-reviewer-token
```

**Output:**

```json
{
  "cluster_name": "gke_my-project_us-central1_prod-cluster",
  "k8s_api_server": "https://35.202.100.50",
  "k8s_ca_cert_base64": "LS0tLS1CRUdJTi...",
  "token_reviewer_jwt": "eyJhbGciOiJSUz..."
}
```

## `validate-connectivity.sh`

Validates the end-to-end Akeyless + ESO integration. Checks ESO health, ClusterSecretStore readiness, and performs a live secret sync test.

**Prerequisites:**
- `kubectl` configured with access to the target cluster
- ESO installed and running
- ClusterSecretStore `akeyless` created and healthy
- A test secret in Akeyless at `/test/pipeline-validation`

**Create the test secret:**

```bash
akeyless create-secret --name /test/pipeline-validation --value "validation-test-value"
```

**Usage:**

```bash
# Default settings
./scripts/validate-connectivity.sh

# Custom ClusterSecretStore name
./scripts/validate-connectivity.sh --store-name my-akeyless-store

# Custom test secret path
./scripts/validate-connectivity.sh --test-secret /my-org/test/eso-validation

# Custom timeout
./scripts/validate-connectivity.sh --timeout 120
```

**Output (success):**

```
INFO: Checking ESO pods...
PASS: ESO pods are running (3/3)
INFO: Checking ClusterSecretStore 'akeyless'...
PASS: ClusterSecretStore 'akeyless' is ready
INFO: Creating test ExternalSecret 'eso-validation-test-1700000000'...
INFO: Waiting for ExternalSecret to sync (timeout: 60s)...
PASS: ExternalSecret synced successfully in 10s
PASS: K8s Secret created successfully

=========================================
PASS: All validation tests passed
=========================================
```

The script exits with code 0 on success and 1 on failure, making it suitable for CI/CD pipelines.
