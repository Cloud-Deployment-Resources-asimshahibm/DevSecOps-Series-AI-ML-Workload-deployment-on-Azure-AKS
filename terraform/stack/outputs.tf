output "resource_group" {
  value = azurerm_resource_group.this.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "configure_kubectl" {
  value = "az aks get-credentials -g ${azurerm_resource_group.this.name} -n ${azurerm_kubernetes_cluster.this.name} && kubelogin convert-kubeconfig -l azurecli"
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "node_resource_group" {
  value = azurerm_kubernetes_cluster.this.node_resource_group
}

output "vnet_id" {
  value = module.network.vnet_id
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "storage_account" {
  value = module.storage.account_name
}

output "postgres_fqdn" {
  value = module.database.fqdn
}

output "app_gateway_fqdn" {
  description = "Public DNS name of the ingress (http://<fqdn>/ for ml-inference until you add your own domain + TLS)."
  value       = module.app_gateway.fqdn
}

output "workload_identity_client_ids" {
  description = "Rendered into the GitOps values by Argo CD (cloud.clientIds); no copy-paste needed."
  value       = module.workload_identity.client_ids
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "budgets" {
  value = module.cost_guardrails.budget_names
}

output "waf_policy_id" {
  value = module.waf.id
}
