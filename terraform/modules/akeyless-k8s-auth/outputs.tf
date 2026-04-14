output "auth_method_access_id" {
  description = "Access ID of the created Kubernetes auth method"
  value       = akeyless_auth_method_k8s.this.access_id
}

output "auth_method_path" {
  description = "Full path of the auth method in Akeyless"
  value       = akeyless_auth_method_k8s.this.name
}

output "k8s_auth_config_name" {
  description = "Name of the gateway K8s auth config (use as k8sConfName in ClusterSecretStore)"
  value       = var.configure_k8s_auth ? akeyless_k8s_auth_config.this[0].name : "${var.cluster_name}-k8s-config"
}

output "role_name" {
  description = "Full path of the created Akeyless role"
  value       = akeyless_role.eso_role.name
}
