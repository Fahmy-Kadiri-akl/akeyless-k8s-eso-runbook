variable "cluster_name" {
  description = "Unique name for the Kubernetes cluster (used in auth method and role naming)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.cluster_name))
    error_message = "Cluster name must be lowercase alphanumeric with hyphens, not starting or ending with a hyphen."
  }
}

variable "configure_k8s_auth" {
  description = "Whether to create the akeyless_k8s_auth_config resource (requires the provider to target a Gateway URL, not the public API)"
  type        = bool
  default     = true
}

variable "k8s_api_server" {
  description = "Kubernetes API server URL (e.g., https://10.0.1.100:6443). Required when configure_k8s_auth is true."
  type        = string
  default     = ""

  validation {
    condition     = var.k8s_api_server == "" || can(regex("^https://", var.k8s_api_server))
    error_message = "K8s API server URL must start with https://."
  }
}

variable "k8s_ca_cert" {
  description = "Base64-encoded CA certificate of the Kubernetes API server. Required when configure_k8s_auth is true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "token_reviewer_jwt" {
  description = "Long-lived JWT of the token reviewer ServiceAccount. Required when configure_k8s_auth is true."
  type        = string
  sensitive   = true
  default     = ""
}

variable "bound_namespaces" {
  description = "List of Kubernetes namespaces allowed to authenticate via this auth method"
  type        = set(string)
  default     = ["external-secrets"]
}

variable "bound_sa_names" {
  description = "List of Kubernetes ServiceAccount names allowed to authenticate"
  type        = set(string)
  default     = ["external-secrets", "external-secrets-cert-controller"]
}

variable "secret_access_paths" {
  description = "List of Akeyless secret paths this role can access (supports wildcards)"
  type        = list(string)

  validation {
    condition     = length(var.secret_access_paths) > 0
    error_message = "At least one secret access path must be specified."
  }
}

variable "sub_claims" {
  description = "Optional sub-claims map for fine-grained access control (e.g., namespace=app-a)"
  type        = map(string)
  default     = {}
}
