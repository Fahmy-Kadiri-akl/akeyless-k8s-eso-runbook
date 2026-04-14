terraform {
  required_version = ">= 1.3"

  required_providers {
    akeyless = {
      source  = "akeyless-community/akeyless"
      version = ">= 1.0.0"
    }
  }
}

# -----------------------------------------------------------------------------
# Kubernetes Auth Method
# Creates an Akeyless K8s auth method that validates ServiceAccount tokens
# from the target cluster via the TokenReview API.
# -----------------------------------------------------------------------------
resource "akeyless_auth_method_k8s" "this" {
  name = "/k8s-auth/${var.cluster_name}"

  bound_namespaces = var.bound_namespaces
  bound_sa_names   = var.bound_sa_names

  # Generate a key pair for the K8s auth config
  gen_key = "true"
}

# -----------------------------------------------------------------------------
# Kubernetes Auth Config
# Configures the Gateway-side K8s auth settings (API server URL, CA cert,
# token reviewer JWT) so the Gateway can validate incoming K8s tokens.
# NOTE: This resource requires the provider to target a Gateway URL (not the
# public API at api.akeyless.io), because gateway-create-k8s-auth-config is
# a Gateway-only command.
# -----------------------------------------------------------------------------
resource "akeyless_k8s_auth_config" "this" {
  count = var.configure_k8s_auth ? 1 : 0

  name               = "${var.cluster_name}-k8s-config"
  access_id          = akeyless_auth_method_k8s.this.access_id
  k8s_host           = var.k8s_api_server
  k8s_ca_cert        = var.k8s_ca_cert
  token_reviewer_jwt = var.token_reviewer_jwt
  signing_key        = akeyless_auth_method_k8s.this.private_key
}

# -----------------------------------------------------------------------------
# Access Role
# Defines what secrets this auth method can access.
# -----------------------------------------------------------------------------
resource "akeyless_role" "eso_role" {
  name = "/k8s-roles/${var.cluster_name}-eso-role"

  dynamic "rules" {
    for_each = var.secret_access_paths
    content {
      path       = rules.value
      capability = ["read", "list"]
    }
  }
}

# -----------------------------------------------------------------------------
# Role-Auth Method Association
# Links the auth method to the role, optionally with sub-claims for
# fine-grained namespace/SA restrictions.
# -----------------------------------------------------------------------------
resource "akeyless_associate_role_auth_method" "this" {
  role_name  = akeyless_role.eso_role.name
  am_name    = akeyless_auth_method_k8s.this.name
  sub_claims = var.sub_claims
}
