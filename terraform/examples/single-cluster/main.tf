terraform {
  required_version = ">= 1.3"

  required_providers {
    akeyless = {
      source  = "akeyless-community/akeyless"
      version = ">= 1.0.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "gcs" {
  #   bucket = "<REPLACE_ME>"
  #   prefix = "akeyless-k8s-auth"
  # }
}

# -----------------------------------------------------------------------------
# Provider Configuration
# Authenticate via environment variables:
#   AKEYLESS_ACCESS_ID
#   AKEYLESS_ACCESS_KEY
# Or set them explicitly below.
# -----------------------------------------------------------------------------
provider "akeyless" {
  api_gateway_address = var.gateway_url
}

# -----------------------------------------------------------------------------
# Variables
# Pass these via terraform.tfvars, environment variables, or CI/CD pipeline.
# -----------------------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the Kubernetes cluster to onboard"
  type        = string
}

variable "k8s_api_server" {
  description = "Kubernetes API server URL"
  type        = string
}

variable "k8s_ca_cert" {
  description = "Base64-encoded CA certificate of the K8s API server"
  type        = string
  sensitive   = true
}

variable "token_reviewer_jwt" {
  description = "Long-lived JWT of the token reviewer ServiceAccount"
  type        = string
  sensitive   = true
}

variable "gateway_url" {
  description = "Akeyless Gateway API URL"
  type        = string
  default     = "https://gateway.example.com:8000/api/v2"
}

variable "secret_access_paths" {
  description = "Akeyless secret paths this cluster can access"
  type        = list(string)
  default     = ["/production/*"]
}

# -----------------------------------------------------------------------------
# Module
# -----------------------------------------------------------------------------
module "akeyless_k8s_auth" {
  source = "../../modules/akeyless-k8s-auth"

  cluster_name        = var.cluster_name
  k8s_api_server      = var.k8s_api_server
  k8s_ca_cert         = var.k8s_ca_cert
  token_reviewer_jwt  = var.token_reviewer_jwt
  bound_namespaces    = ["external-secrets"]
  bound_sa_names      = ["external-secrets", "external-secrets-cert-controller"]
  secret_access_paths = var.secret_access_paths
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "auth_method_access_id" {
  description = "Access ID to use in the ClusterSecretStore"
  value       = module.akeyless_k8s_auth.auth_method_access_id
}

output "auth_method_path" {
  description = "Auth method path to use in the ClusterSecretStore k8sConfName"
  value       = module.akeyless_k8s_auth.auth_method_path
}

output "role_name" {
  description = "Akeyless role name created for this cluster"
  value       = module.akeyless_k8s_auth.role_name
}
