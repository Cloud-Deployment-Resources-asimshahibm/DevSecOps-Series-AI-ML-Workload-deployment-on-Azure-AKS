output "subscription_id" {
  value = var.subscription_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "name_suffix" {
  value = local.suffix
}

output "state_storage_account" {
  description = "Use as storage_account_name in every backend.hcl."
  value       = azurerm_storage_account.tfstate.name
}

output "state_resource_group" {
  value = azurerm_resource_group.global.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "acr_id" {
  value = azurerm_container_registry.this.id
}

output "gha_variables" {
  description = "Set these as GitHub repository variables (docs/RUNBOOK.md, Phase 3)."
  value = {
    AZURE_TENANT_ID          = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID    = var.subscription_id
    AZURE_CLIENT_ID_TF_PLAN  = module.github_oidc.client_ids["tf-plan"]
    AZURE_CLIENT_ID_TF_APPLY = module.github_oidc.client_ids["tf-apply"]
    AZURE_CLIENT_ID_CI       = module.github_oidc.client_ids["ci"]
    ACR_NAME                 = azurerm_container_registry.this.name
    TFSTATE_STORAGE_ACCOUNT  = azurerm_storage_account.tfstate.name
  }
}

output "gha_principal_ids" {
  description = "Object ids of the GitHub identities (the stack grants them cluster access)."
  value       = module.github_oidc.principal_ids
}

output "security_workspace_id" {
  description = "Log Analytics workspace for the activity log and Defender exports."
  value       = module.security_baseline.security_workspace_id
}
