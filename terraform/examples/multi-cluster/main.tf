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
  #   prefix = "akeyless-k8s-auth-multi"
  # }
}

provider "akeyless" {
  api_gateway_address = var.gateway_url
}

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "gateway_url" {
  description = "Akeyless Gateway API URL"
  type        = string
  default     = "https://gateway.example.com:8000/api/v2"
}

variable "clusters" {
  description = "Map of cluster configurations to onboard"
  type = map(object({
    k8s_api_server      = string
    k8s_ca_cert         = string
    token_reviewer_jwt  = string
    secret_access_paths = list(string)
    bound_namespaces    = optional(list(string), ["external-secrets"])
    bound_sa_names      = optional(list(string), ["external-secrets", "external-secrets-cert-controller"])
  }))

  # Example usage in terraform.tfvars:
  #
  # clusters = {
  #   "prod-rke-us-east" = {
  #     k8s_api_server      = "https://10.0.1.100:6443"
  #     k8s_ca_cert         = "LS0tLS1CRUdJTi..."
  #     token_reviewer_jwt  = "eyJhbGciOiJSUz..."
  #     secret_access_paths = ["/production/*"]
  #   }
  #   "prod-gke-us-central" = {
  #     k8s_api_server      = "https://35.202.100.50"
  #     k8s_ca_cert         = "LS0tLS1CRUdJTi..."
  #     token_reviewer_jwt  = "eyJhbGciOiJSUz..."
  #     secret_access_paths = ["/production/*"]
  #   }
  #   "staging-rke-us-east" = {
  #     k8s_api_server      = "https://10.0.2.100:6443"
  #     k8s_ca_cert         = "LS0tLS1CRUdJTi..."
  #     token_reviewer_jwt  = "eyJhbGciOiJSUz..."
  #     secret_access_paths = ["/staging/*"]
  #   }
  # }
}

# -----------------------------------------------------------------------------
# Module instances -- one per cluster
# -----------------------------------------------------------------------------
module "akeyless_k8s_auth" {
  source   = "../../modules/akeyless-k8s-auth"
  for_each = var.clusters

  cluster_name        = each.key
  k8s_api_server      = each.value.k8s_api_server
  k8s_ca_cert         = each.value.k8s_ca_cert
  token_reviewer_jwt  = each.value.token_reviewer_jwt
  bound_namespaces    = each.value.bound_namespaces
  bound_sa_names      = each.value.bound_sa_names
  secret_access_paths = each.value.secret_access_paths
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "cluster_auth_methods" {
  description = "Map of cluster name to auth method details"
  value = {
    for cluster_name, mod in module.akeyless_k8s_auth : cluster_name => {
      access_id       = mod.auth_method_access_id
      auth_method_path = mod.auth_method_path
      role_name       = mod.role_name
    }
  }
}
