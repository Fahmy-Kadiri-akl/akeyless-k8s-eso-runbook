# Troubleshooting

This document covers common issues encountered during the Akeyless + ESO integration and their resolution steps.

## Diagnostic Commands

Before diving into specific issues, gather diagnostic information:

```bash
# ESO controller logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=100

# ClusterSecretStore status
kubectl describe clustersecretstore akeyless

# ExternalSecret status (all namespaces)
kubectl get externalsecrets -A

# Detailed ExternalSecret status
kubectl describe externalsecret <NAME> -n <NAMESPACE>

# ESO controller events
kubectl get events -n external-secrets --sort-by='.lastTimestamp'

# Check ESO pod health
kubectl get pods -n external-secrets -o wide
```

## Issue: ClusterSecretStore Shows "Not Ready"

### Symptoms

```
NAME       AGE   STATUS   CAPABILITIES   READY
akeyless   5m    Error    ReadWrite      False
```

### Cause 1: Gateway Unreachable

**Check:** ESO cannot reach the Akeyless Gateway URL.

```bash
# Test connectivity from inside the cluster
kubectl run test-connectivity --rm -it --image=curlimages/curl --restart=Never -- \
  curl -sk https://<GATEWAY_URL>:8000/status
```

**Expected:** JSON response with `"status": "running"`.

**Fix:**
- Verify the Gateway URL is correct in the ClusterSecretStore
- Check network policies or firewall rules between the ESO namespace and the Gateway
- If the Gateway is behind a load balancer, verify the load balancer is healthy
- Check DNS resolution from within the cluster

### Cause 2: Invalid Auth Method Configuration

**Check:**

```bash
kubectl describe clustersecretstore akeyless
```

Look for messages like:
- `failed to authenticate` -- the auth method configuration is incorrect
- `access denied` -- the auth method exists but the ServiceAccount is not authorized

**Fix:**
- Verify the `accessID` in the ClusterSecretStore matches the auth method's access ID
- Verify the `k8sConfName` matches the gateway K8s auth config name (the `--name` from `gateway-create-k8s-auth-config`)
- Check that the ESO ServiceAccount name and namespace are in the auth method's `bound-namespaces` and `bound-sa-names`

```bash
# Verify the auth method configuration
akeyless get-auth-method --name "/k8s-auth/<CLUSTER_NAME>"
```

### Cause 3: Token Reviewer JWT Expired or Invalid

**Check:** The long-lived JWT used to configure the Akeyless auth method may have been rotated or the ServiceAccount deleted.

```bash
kubectl get secret gateway-token-reviewer-token -n kube-system
```

**Fix:** Recreate the token reviewer ServiceAccount and Secret, then update the Akeyless auth method:

```bash
# Recreate the secret
kubectl delete secret gateway-token-reviewer-token -n kube-system
kubectl apply -f manifests/rke/token-reviewer-user.yaml

# Wait for token population
sleep 5

# Get the new JWT
NEW_JWT=$(kubectl get secret gateway-token-reviewer-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d)

# Update the gateway K8s auth config
akeyless gateway-update-k8s-auth-config \
  --name "<CLUSTER_NAME>-k8s-config" \
  --gateway-url "$GATEWAY_URL" \
  --token-reviewer-jwt "$NEW_JWT"
```

## Issue: ExternalSecret Shows "SecretSyncedError"

### Symptoms

```
NAME             STORE      REFRESH INTERVAL   STATUS             READY
my-secret        akeyless   5m                 SecretSyncedError  False
```

### Cause 1: Secret Path Does Not Exist in Akeyless

```bash
kubectl describe externalsecret my-secret -n <NAMESPACE>
```

Look for: `could not get secret data` or `item not found`.

**Fix:**
- Verify the secret path in the `remoteRef.key` field matches exactly what exists in Akeyless
- Akeyless paths are case-sensitive
- Check with the CLI:

```bash
akeyless get-secret-value --name "/production/my-app/db-password"
```

### Cause 2: Insufficient Permissions

Look for: `access denied` or `403`.

**Fix:**
- Verify the Akeyless role associated with the auth method has `read` capability on the secret path
- Check path rules:

```bash
akeyless get-role --name "/k8s-roles/<CLUSTER_NAME>-eso-role"
```

- Verify the role's access rules cover the secret's path with wildcards if needed

### Cause 3: Wrong Secret Type

If fetching a dynamic secret but treating it as static, or vice versa.

**Fix:**
- For dynamic secrets, the `remoteRef.key` should reference the dynamic secret producer name
- The returned value for dynamic secrets is typically a JSON payload -- use templates to extract specific fields

## Issue: K8s Secret Not Updating After Akeyless Secret Changes

### Symptoms

You updated a secret value in Akeyless, but the K8s Secret still has the old value.

### Cause: Refresh Interval Not Elapsed

ESO only fetches on the `refreshInterval` schedule.

**Fix:**
- Wait for the next refresh cycle
- Force an immediate refresh by annotating the ExternalSecret:

```bash
kubectl annotate externalsecret my-secret -n <NAMESPACE> \
  force-sync=$(date +%s) --overwrite
```

- Alternatively, delete and recreate the ExternalSecret

### Cause: Gateway Cache

The Akeyless Gateway may be serving a cached version of the secret.

**Fix:**
- Check the Gateway's cache TTL configuration
- Restart the Gateway pod to clear the cache (last resort):

```bash
kubectl rollout restart deployment akeyless-gateway -n <GATEWAY_NAMESPACE>
```

## Issue: ESO Pods CrashLooping

### Symptoms

```
NAME                                             READY   STATUS             RESTARTS   AGE
external-secrets-xxxxxxxxx-xxxxx                 0/1     CrashLoopBackOff   5          10m
```

### Cause 1: CRD Version Mismatch

After upgrading ESO, CRDs may be out of date.

**Fix:**

```bash
# Reinstall CRDs
kubectl apply -f https://raw.githubusercontent.com/external-secrets/external-secrets/v0.10.7/deploy/crds/bundle.yaml

# Restart ESO
kubectl rollout restart deployment -n external-secrets
```

### Cause 2: Resource Limits Too Low

**Fix:** Increase resource limits:

```bash
helm upgrade external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set resources.limits.memory=512Mi \
  --set resources.limits.cpu=500m \
  --reuse-values
```

### Cause 3: Webhook Certificate Issues

The ESO webhook requires valid TLS certificates managed by the cert-controller.

**Fix:**

```bash
# Check cert-controller logs
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets-cert-controller

# Restart the cert-controller to regenerate certificates
kubectl rollout restart deployment external-secrets-cert-controller -n external-secrets

# Then restart the webhook
kubectl rollout restart deployment external-secrets-webhook -n external-secrets
```

## Issue: TokenReview Fails from Gateway

### Symptoms

Akeyless auth method shows errors in the Gateway logs about failing to validate tokens.

### Cause 1: Gateway Cannot Reach K8s API Server

**Check from the Gateway pod:**

```bash
# If Gateway runs in K8s
kubectl exec -it <GATEWAY_POD> -n <NAMESPACE> -- \
  curl -sk https://<K8S_API_SERVER>:443/healthz
```

**Fix:**
- For private GKE clusters, add the Gateway's IP to authorized networks
- For on-premises clusters, check firewall rules
- Verify the K8s API server URL in the auth method is correct and routable from the Gateway

### Cause 2: CA Certificate Mismatch

The CA certificate configured in the Akeyless auth method does not match the cluster's actual CA.

**Fix:**

```bash
# Get the current cluster CA
CURRENT_CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Update the auth method
akeyless auth-method update k8s \
  --name "/k8s-auth/<CLUSTER_NAME>" \
  --k8s-ca-cert "$CURRENT_CA"
```

### Cause 3: Clock Skew

JWT validation is time-sensitive. If the Gateway and K8s API server clocks are out of sync by more than a few minutes, token validation will fail.

**Fix:**
- Ensure NTP is running on all nodes
- Check the Gateway host's time: `date -u`
- Check the K8s node times: `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}{"\n"}{end}'`

## Issue: Secrets Created in Wrong Format

### Symptoms

Application cannot parse the secret because it is in the wrong format (e.g., base64-encoded when it should be plain text, or missing expected keys).

### Cause: Missing or Incorrect Template

**Fix:** Use the `target.template` field to control the output format:

```yaml
spec:
  target:
    name: my-secret
    template:
      type: Opaque
      data:
        config.json: |
          {"username": "{{ .username }}", "password": "{{ .password }}"}
```

## Issue: "Too Many Requests" from Akeyless

### Symptoms

ESO logs show rate limiting errors from the Akeyless API.

### Cause: Too Many ExternalSecrets with Short Refresh Intervals

**Fix:**
- Increase `refreshInterval` for secrets that change infrequently
- Use the Gateway cache to reduce API calls to the Akeyless backend
- Stagger ExternalSecret creation to avoid thundering herd on restarts

## Issue: Gateway Port Confusion -- 404 on Auth Endpoint

### Symptoms

ESO logs show `404 page not found` when the ClusterSecretStore attempts to authenticate with the Akeyless Gateway.

### Cause

The ClusterSecretStore points to gateway port 8000 (API proxy), which does not serve the `/kubernetes/auth` endpoint.

### Fix

Use the gateway internal service on port 8080 for same-cluster deployments, or ensure your external URL routes to the correct backend:

```yaml
# Same-cluster:
akeylessGWApiURL: "http://<RELEASE_NAME>-akeyless-gateway-internal.<GATEWAY_NAMESPACE>.svc:8080"

# Cross-cluster (ensure this routes to port 8080 backend, not 8000):
akeylessGWApiURL: "https://<GATEWAY_EXTERNAL_URL>"
```

## Issue: Auth Method Missing Bound Namespaces/SA Names

### Symptoms

ClusterSecretStore shows `Valid`, but ExternalSecrets fail with `401 Unauthorized` or `AuthenticationFailed`.

### Cause

The K8s auth method was created without `--bound-namespaces` and `--bound-sa-names`, so the Gateway rejects the ESO service account token.

> **Note:** A Valid ClusterSecretStore does NOT guarantee working authentication -- it only checks basic connectivity.

### Fix

Update the auth method to bind the correct namespace and service account:

```bash
akeyless auth-method update k8s \
  --name /k8s-auth/<name> \
  --bound-namespaces "external-secrets" \
  --bound-sa-names "external-secrets"
```

## Issue: JWT Issuer Validation Failure

### Symptoms

The Gateway rejects ESO tokens with an issuer mismatch error.

### Cause

Non-standard K8s distributions (MicroK8s, K3s, RKE2) use different JWT issuers than the default `https://kubernetes.default.svc.cluster.local`.

### Fix

Disable issuer validation when creating the gateway K8s auth config:

```bash
akeyless gateway-create-k8s-auth-config \
  --name "<CONFIG_NAME>" \
  --gateway-url "https://<GATEWAY_URL>:8000" \
  --access-id "<AUTH_METHOD_ACCESS_ID>" \
  --signing-key "$PRV_KEY" \
  --token-reviewer-jwt "<JWT>" \
  --k8s-host "https://<K8S_API_SERVER>:443" \
  --disable-issuer-validation true
```

## Issue: Two-Step Auth Method Creation

### Symptoms

Running `akeyless auth-method create k8s` does not accept flags like `--token`, `--k8s-host`, or `--disable-issuer-validation`.

### Cause

K8s cluster configuration is a separate command (`gateway-create-k8s-auth-config`). The auth method and the gateway K8s auth config are created independently.

### Fix

Create the auth method first, then configure the gateway K8s auth separately:

```bash
# Step 1: Create the K8s auth method
akeyless auth-method create k8s \
  --name "/k8s-auth/<CLUSTER_NAME>" \
  --bound-namespaces "external-secrets" \
  --bound-sa-names "external-secrets"

# Step 2: Configure gateway K8s auth (separate command)
akeyless gateway-create-k8s-auth-config \
  --name "<CLUSTER_NAME>-k8s-config" \
  --gateway-url "https://<GATEWAY_URL>:8000" \
  --access-id "<AUTH_METHOD_ACCESS_ID>" \
  --signing-key "$PRV_KEY" \
  --token-reviewer-jwt "<JWT>" \
  --k8s-host "https://<K8S_API_SERVER>:443"
```

## Quick Reference: Status Conditions

| Status | Meaning | Action |
|---|---|---|
| `SecretSynced` | Secret was successfully synced | None -- everything is working |
| `SecretSyncedError` | Sync attempt failed | Check `describe` for error message |
| `SecretDeleted` | The source secret was deleted | Verify the secret exists in Akeyless |
| `SecretStoreNotReady` | The referenced SecretStore is not healthy | Fix the ClusterSecretStore first |

## Collecting a Support Bundle

When opening a support ticket, collect the following:

```bash
# ESO version
helm list -n external-secrets

# ESO controller logs (last 500 lines)
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets --tail=500 > eso-logs.txt

# All ExternalSecrets status
kubectl get externalsecrets -A -o yaml > externalsecrets-status.yaml

# ClusterSecretStore status
kubectl get clustersecretstores -o yaml > clustersecretstores-status.yaml

# Events
kubectl get events -n external-secrets --sort-by='.lastTimestamp' > eso-events.txt

# Node info (for clock skew investigation)
kubectl get nodes -o wide > nodes.txt
```

> **Warning:** Do NOT include the actual secret values, token reviewer JWTs, or Akeyless access keys in support bundles.
