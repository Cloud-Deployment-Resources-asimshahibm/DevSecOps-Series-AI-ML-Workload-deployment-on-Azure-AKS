################################################################################
# Blob storage for one environment (one StorageV2 account, Entra ID auth only)
#
#   container   used by                                   access
#   ----------  ----------------------------------------  -----------------------------
#   data        datasets, scratch (training, notebooks)   training rw, jupyter rw
#   models      model registry: <model>/<version>/,       training rw, inference ro,
#               <model>/latest.json pointer               jupyter ro
#   artifacts   Argo Workflows artifacts, Ray results     argo rw, training rw
#   loki        Loki chunks + ruler                       loki rw
#
# Shared keys are disabled: every client authenticates with a workload identity.
# The firewall only admits the AKS subnet (service endpoint) + optional admin IPs.
# RWX file storage (the AWS EFS equivalent) is provisioned by the Azure Files CSI
# driver (NFS, Premium) through the `azurefile-nfs` StorageClass.
################################################################################

variable "name" { type = string }
variable "account_name" { type = string } # globally unique, 3-24 lowercase alphanumerics
variable "location" { type = string }
variable "resource_group" { type = string }
variable "replication_type" {
  type    = string
  default = "ZRS"
}
variable "allowed_subnet_ids" { type = list(string) }
variable "allowed_ip_ranges" {
  description = "Public IPs/CIDRs (e.g. your office) allowed through the storage firewall."
  type        = list(string)
  default     = []
}
variable "tags" { type = map(string) }

locals {
  containers = ["data", "models", "artifacts", "loki"]
}

resource "azurerm_storage_account" "this" {
  name                              = var.account_name
  resource_group_name               = var.resource_group
  location                          = var.location
  account_tier                      = "Standard"
  account_kind                      = "StorageV2"
  account_replication_type          = var.replication_type
  access_tier                       = "Hot"
  min_tls_version                   = "TLS1_2"
  https_traffic_only_enabled        = true
  shared_access_key_enabled         = false
  default_to_oauth_authentication   = true
  allow_nested_items_to_be_public   = false
  cross_tenant_replication_enabled  = false
  infrastructure_encryption_enabled = true  # double encryption at rest
  local_user_enabled                = false # no SFTP/local users

  blob_properties {
    versioning_enabled  = true # model registry history + accidental overwrite protection
    change_feed_enabled = false
    delete_retention_policy {
      days = 14
    }
    container_delete_retention_policy {
      days = 14
    }
  }

  network_rules {
    default_action             = "Deny"
    bypass                     = ["AzureServices", "Logging", "Metrics"]
    virtual_network_subnet_ids = var.allowed_subnet_ids
    ip_rules                   = var.allowed_ip_ranges
  }

  tags = var.tags
}

resource "azurerm_storage_container" "this" {
  for_each              = toset(local.containers)
  name                  = each.value
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "artifacts-expire"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["artifacts/"]
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than = 30
        delete_after_days_since_modification_greater_than       = 180
      }
      version {
        delete_after_days_since_creation = 30
      }
    }
  }

  rule {
    name    = "scratch-expire"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["data/scratch/"]
    }
    actions {
      base_blob {
        delete_after_days_since_modification_greater_than = 30
      }
    }
  }

  rule {
    name    = "old-versions"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["data/", "models/"]
    }
    actions {
      version {
        change_tier_to_cool_after_days_since_creation = 30
        delete_after_days_since_creation              = 365
      }
    }
  }
}

output "account_name" { value = azurerm_storage_account.this.name }
output "account_id" { value = azurerm_storage_account.this.id }
output "blob_endpoint" { value = azurerm_storage_account.this.primary_blob_endpoint }
output "container_ids" {
  description = "ARM resource ids, usable as role assignment scopes."
  value = {
    for k, c in azurerm_storage_container.this :
    k => "${azurerm_storage_account.this.id}/blobServices/default/containers/${c.name}"
  }
}
