################################################################################
# Subscription security baseline (DevSecOps) — the Azure counterpart of
# GuardDuty / Security Hub / Inspector / Config / CloudTrail / Macie:
#
#   Microsoft Defender for Cloud
#     Containers   runtime threat detection (sensor), ACR + running-image
#                  vulnerability assessment, agentless K8s discovery
#     Storage      activity anomalies, on-upload malware scanning,
#                  sensitive-data discovery (PII in the ML data account)
#     KeyVaults    anomalous secret access
#     OSS DBs      PostgreSQL threat detection
#     Arm          suspicious control-plane operations
#     CloudPosture Defender CSPM: attack paths, MCSB + CIS compliance
#   Azure Policy   CIS Microsoft Azure Foundations Benchmark 2.0.0 (audit)
#   Activity Log   every control-plane write -> Log Analytics (audit trail)
#
# Set a flag to false if your organization manages it centrally.
################################################################################

variable "project" { type = string }
variable "location" { type = string }
variable "resource_group" { type = string }
variable "subscription_id" { type = string } # /subscriptions/<guid>
variable "security_contact_email" {
  type    = string
  default = ""
}
variable "services" {
  type = object({
    defender_containers = bool
    defender_storage    = bool
    defender_keyvault   = bool
    defender_databases  = bool
    defender_arm        = bool
    defender_cspm       = bool
    cis_policy          = bool
    activity_log        = bool
  })
}
variable "log_retention_days" {
  type    = number
  default = 365
}
variable "tags" { type = map(string) }

# ------------------------------------------------------------------------------
# Central security workspace (activity log, Defender exports)
# ------------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "security" {
  name                = "${var.project}-security-law"
  location            = var.location
  resource_group_name = var.resource_group
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = var.tags
}

resource "azurerm_monitor_diagnostic_setting" "activity_log" {
  count                      = var.services.activity_log ? 1 : 0
  name                       = "${var.project}-activity-log"
  target_resource_id         = var.subscription_id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.security.id

  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "Policy", "Alert", "ServiceHealth", "Recommendation"]
    content {
      category = enabled_log.value
    }
  }
}

# ------------------------------------------------------------------------------
# Defender for Cloud plans. The pricing API rejects concurrent updates, so the
# plans are applied one after another (depends_on chain).
# ------------------------------------------------------------------------------
resource "azurerm_security_center_subscription_pricing" "containers" {
  count         = var.services.defender_containers ? 1 : 0
  tier          = "Standard"
  resource_type = "Containers"

  extension {
    name = "ContainerRegistriesVulnerabilityAssessments"
  }
  extension {
    name = "AgentlessDiscoveryForKubernetes"
  }
  extension {
    name = "ContainerSensor"
  }
}

resource "azurerm_security_center_subscription_pricing" "storage" {
  count         = var.services.defender_storage ? 1 : 0
  tier          = "Standard"
  resource_type = "StorageAccounts"
  subplan       = "DefenderForStorageV2"

  extension {
    name = "OnUploadMalwareScanning"
    additional_extension_properties = {
      CapGBPerMonthPerStorageAccount = "500"
    }
  }
  extension {
    name = "SensitiveDataDiscovery"
  }

  depends_on = [azurerm_security_center_subscription_pricing.containers]
}

resource "azurerm_security_center_subscription_pricing" "keyvault" {
  count         = var.services.defender_keyvault ? 1 : 0
  tier          = "Standard"
  resource_type = "KeyVaults"
  subplan       = "PerKeyVault"
  depends_on    = [azurerm_security_center_subscription_pricing.storage]
}

resource "azurerm_security_center_subscription_pricing" "databases" {
  count         = var.services.defender_databases ? 1 : 0
  tier          = "Standard"
  resource_type = "OpenSourceRelationalDatabases"
  depends_on    = [azurerm_security_center_subscription_pricing.keyvault]
}

resource "azurerm_security_center_subscription_pricing" "arm" {
  count         = var.services.defender_arm ? 1 : 0
  tier          = "Standard"
  resource_type = "Arm"
  subplan       = "PerSubscription"
  depends_on    = [azurerm_security_center_subscription_pricing.databases]
}

resource "azurerm_security_center_subscription_pricing" "cspm" {
  count         = var.services.defender_cspm ? 1 : 0
  tier          = "Standard"
  resource_type = "CloudPosture"

  extension {
    name = "ContainerRegistriesVulnerabilityAssessments"
  }
  extension {
    name = "AgentlessDiscoveryForKubernetes"
  }
  extension {
    name = "SensitiveDataDiscovery"
  }

  depends_on = [azurerm_security_center_subscription_pricing.arm]
}

resource "azurerm_security_center_contact" "this" {
  count               = var.security_contact_email != "" ? 1 : 0
  name                = "default"
  email               = var.security_contact_email
  alert_notifications = true
  alerts_to_admins    = true
}

# ------------------------------------------------------------------------------
# Azure Policy: CIS Microsoft Azure Foundations Benchmark 2.0.0 (audit only —
# reports into Defender for Cloud › Regulatory compliance; enforcement lives in
# our own IaC policies + Kyverno).
# ------------------------------------------------------------------------------
data "azurerm_policy_set_definition" "cis" {
  count = var.services.cis_policy ? 1 : 0
  name  = "06f19060-9e68-4070-92ca-f15cc126059e" # CIS Microsoft Azure Foundations Benchmark v2.0.0
}

resource "azurerm_subscription_policy_assignment" "cis" {
  count                = var.services.cis_policy ? 1 : 0
  name                 = "${var.project}-cis-azure-2-0"
  display_name         = "${var.project}: CIS Microsoft Azure Foundations Benchmark 2.0.0 (audit)"
  subscription_id      = var.subscription_id
  policy_definition_id = data.azurerm_policy_set_definition.cis[0].id
  enforce              = false # audit / report only
  location             = var.location

  identity {
    type = "SystemAssigned"
  }
}

output "security_workspace_id" { value = azurerm_log_analytics_workspace.security.id }
