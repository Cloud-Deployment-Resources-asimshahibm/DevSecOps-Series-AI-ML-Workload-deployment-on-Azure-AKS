################################################################################
# Application secrets in Key Vault (RBAC-authorized, soft-delete, audit-logged).
# Key Vault secret names allow only letters, digits and dashes, so values are
# JSON documents; External Secrets extracts the keys (charts/platform-config).
################################################################################

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "grafana_admin" {
  name         = "grafana-admin"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value = jsonencode({
    "admin-user"     = "admin"
    "admin-password" = random_password.grafana_admin.result
  })
  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}

# GitHub OAuth App for JupyterHub login. Terraform creates it with placeholder
# values; set the real ones once (runbook Phase 6):
#   az keyvault secret set --vault-name <kv> --name jupyterhub-github-oauth \
#     --value '{"client_id":"...","client_secret":"..."}'
resource "azurerm_key_vault_secret" "jupyterhub_oauth" {
  name         = "jupyterhub-github-oauth"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value        = jsonencode({ client_id = "CHANGE_ME", client_secret = "CHANGE_ME" })
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]

  lifecycle {
    ignore_changes = [value] # managed out-of-band after creation
  }
}

# Read-only Elasticsearch user used by the Grafana "Elasticsearch (ELK)" datasource
resource "random_password" "es_grafana" {
  length  = 24
  special = false
}

resource "azurerm_key_vault_secret" "es_grafana" {
  name         = "elasticsearch-grafana"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value        = jsonencode({ username = "grafana", password = random_password.es_grafana.result })
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}

# API keys for the ml-inference API (/v1/*). One key per line in "keys";
# rotate by adding a key, rolling clients, then removing the old one.
resource "random_password" "inference_api_key" {
  length  = 40
  special = false
}

resource "azurerm_key_vault_secret" "inference_api_keys" {
  name         = "inference-api-keys"
  key_vault_id = azurerm_key_vault.this.id
  content_type = "application/json"
  value        = jsonencode({ keys = random_password.inference_api_key.result })
  depends_on   = [azurerm_role_assignment.kv_secrets_officer]
}
