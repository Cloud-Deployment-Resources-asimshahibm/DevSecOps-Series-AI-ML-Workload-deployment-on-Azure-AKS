################################################################################
# Azure Database for PostgreSQL Flexible Server shared by platform services
#   jupyterhub      -> JupyterHub state (users, servers, tokens)
#   argo_workflows  -> Argo Workflows archive (workflow history)
#
# Private access only (delegated subnet + private DNS zone, no public endpoint).
# Credentials live in Key Vault as JSON secrets:
#   postgres-master, postgres-jupyterhub, postgres-argo-workflows
# External Secrets syncs them; the platform-config chart's db-init Job creates the
# per-app roles + databases idempotently.
################################################################################

variable "name" { type = string }
variable "location" { type = string }
variable "resource_group" { type = string }
variable "delegated_subnet_id" { type = string }
variable "private_dns_zone_id" { type = string }
variable "key_vault_id" { type = string }

variable "postgres_version" {
  type    = string
  default = "16"
}

variable "sku_name" {
  type    = string
  default = "B_Standard_B2s"
}

variable "storage_mb" {
  type    = number
  default = 32768
}

variable "high_availability" {
  description = "Zone-redundant standby (prod). Requires a General Purpose / Memory Optimized SKU."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

variable "geo_redundant_backup" {
  type    = bool
  default = false
}

variable "app_databases" {
  type    = list(string)
  default = ["jupyterhub", "argo_workflows"]
}

variable "log_analytics_id" { type = string }

variable "tags" { type = map(string) }

resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "random_password" "app" {
  for_each = toset(var.app_databases)
  length   = 32
  special  = false
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                          = "${var.name}-pg"
  resource_group_name           = var.resource_group
  location                      = var.location
  version                       = var.postgres_version
  sku_name                      = var.sku_name
  storage_mb                    = var.storage_mb
  auto_grow_enabled             = true
  zone                          = "1"
  delegated_subnet_id           = var.delegated_subnet_id
  private_dns_zone_id           = var.private_dns_zone_id
  public_network_access_enabled = false
  administrator_login           = "pgadmin"
  administrator_password        = random_password.admin.result
  backup_retention_days         = var.backup_retention_days
  geo_redundant_backup_enabled  = var.geo_redundant_backup

  dynamic "high_availability" {
    for_each = var.high_availability ? [1] : []
    content {
      mode                      = "ZoneRedundant"
      standby_availability_zone = "2"
    }
  }

  maintenance_window {
    day_of_week  = 0 # Sunday
    start_hour   = 3
    start_minute = 0
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [zone, high_availability[0].standby_availability_zone] # Azure may swap zones on failover
  }
}

# TLS required for every connection (the server default, made explicit)
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "logging" {
  for_each = {
    log_connections              = "on"
    log_disconnections           = "on"
    log_checkpoints              = "on"
    "connection_throttle.enable" = "on"
  }
  name      = each.key
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = each.value
}

resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                           = "audit"
  target_resource_id             = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id     = var.log_analytics_id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "PostgreSQLLogs"
  }
}

# ------------------------------------------------------------------------------
# Credentials in Key Vault (JSON; External Secrets extracts the keys)
# ------------------------------------------------------------------------------
resource "azurerm_key_vault_secret" "admin" {
  name         = "postgres-master"
  key_vault_id = var.key_vault_id
  content_type = "application/json"
  value = jsonencode({
    username = "pgadmin"
    password = random_password.admin.result
    host     = azurerm_postgresql_flexible_server.this.fqdn
    port     = 5432
    dbname   = "postgres"
  })
}

resource "azurerm_key_vault_secret" "app" {
  for_each     = toset(var.app_databases)
  name         = "postgres-${replace(each.key, "_", "-")}"
  key_vault_id = var.key_vault_id
  content_type = "application/json"
  value = jsonencode({
    username = each.key
    password = random_password.app[each.key].result
    host     = azurerm_postgresql_flexible_server.this.fqdn
    port     = 5432
    dbname   = each.key
  })
}

output "fqdn" { value = azurerm_postgresql_flexible_server.this.fqdn }
output "id" { value = azurerm_postgresql_flexible_server.this.id }
