################################################################################
# ENVIRONMENT STACK (dev / prod)
#
#   Resource group ─┬─> VNet (aks / appgw / postgres / endpoints subnets, NSGs)
#                   ├─> Key Vault (RBAC) + Log Analytics (control-plane logs)
#                   ├─> AKS: system pool + Node Auto-Provisioning (Karpenter, CPU + GPU
#                   │        NodePools via GitOps), Azure CNI Overlay + Cilium,
#                   │        Entra ID + Azure RBAC, Workload ID, AGIC
#                   ├─> Application Gateway v2 (ingress, driven by AGIC)
#                   ├─> Storage: Blob (data, models, artifacts, loki) + Azure Files NFS (RWX)
#                   ├─> PostgreSQL Flexible Server (JupyterHub, Argo Workflows archive)
#                   ├─> Workload identities for every workload
#                   └─> Day-0 platform (storage class, Argo CD root app)
#
# DevSecOps additions: WAF_v2 policy on the gateway, AKS secrets encrypted with a
# Key Vault key (KMS), Defender for Containers sensor, Azure Policy add-on (PSS
# restricted, audit), image-verifier identity (Kyverno / Trivy -> ACR), blob /
# PostgreSQL / gateway / Key Vault audit logs, inference API keys in Key Vault.
################################################################################

data "azurerm_client_config" "current" {}
data "azurerm_subscription" "current" {}

locals {
  name   = "${var.project}-${var.environment}"
  suffix = substr(sha1(var.subscription_id), 0, 6) # same as terraform/global
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.gitops_repo_url
  }
  zones = var.environment == "prod" ? var.zones : []
}

# Shared layer (terraform/global)
data "azurerm_container_registry" "shared" {
  name                = "${var.project}${local.suffix}acr"
  resource_group_name = "${var.project}-global-rg"
}

data "azurerm_user_assigned_identity" "gha" {
  for_each            = toset(["tf-plan", "tf-apply", "ci"])
  name                = "${var.project}-gha-${each.key}"
  resource_group_name = "${var.project}-global-rg"
}

resource "azurerm_resource_group" "this" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------
module "network" {
  source         = "../modules/network"
  name           = local.name
  location       = var.location
  resource_group = azurerm_resource_group.this.name
  vnet_cidr      = var.vnet_cidr
  tags           = local.tags
}

# ------------------------------------------------------------------------------
# Key Vault (secrets for External Secrets) + Log Analytics
# ------------------------------------------------------------------------------
resource "azurerm_key_vault" "this" {
  name                       = "${local.name}-kv-${local.suffix}"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium" # HSM-backed keys for AKS KMS
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection
  soft_delete_retention_days = var.environment == "prod" ? 90 : 7
  tags                       = local.tags

  # AKS KMS (public key-vault mode) and Terraform on GitHub-hosted runners need
  # the public endpoint; access is still Entra ID + RBAC only and audit-logged.
  # With self-hosted runners in the VNet set key_vault_default_action = "Deny".
  network_acls {
    default_action             = var.key_vault_default_action
    bypass                     = "AzureServices"
    virtual_network_subnet_ids = [module.network.subnet_ids.aks]
    ip_rules                   = var.key_vault_allowed_ip_ranges
  }
}

# whoever applies (you, or the tf-apply identity in CI) writes the secrets
resource "azurerm_role_assignment" "kv_secrets_officer" {
  for_each = {
    "current/secrets"  = { principal = data.azurerm_client_config.current.object_id, role = "Key Vault Secrets Officer" }
    "tf-apply/secrets" = { principal = data.azurerm_user_assigned_identity.gha["tf-apply"].principal_id, role = "Key Vault Secrets Officer" }
    "current/crypto"   = { principal = data.azurerm_client_config.current.object_id, role = "Key Vault Crypto Officer" }
    "tf-apply/crypto"  = { principal = data.azurerm_user_assigned_identity.gha["tf-apply"].principal_id, role = "Key Vault Crypto Officer" }
  }
  scope                = azurerm_key_vault.this.id
  role_definition_name = each.value.role
  principal_id         = each.value.principal
}

# terraform plan refreshes secret values and key metadata
resource "azurerm_role_assignment" "kv_plan_reader" {
  for_each             = toset(["Key Vault Secrets User", "Key Vault Reader"])
  scope                = azurerm_key_vault.this.id
  role_definition_name = each.value
  principal_id         = data.azurerm_user_assigned_identity.gha["tf-plan"].principal_id
  principal_type       = "ServicePrincipal"
}

# Envelope encryption of Kubernetes Secrets in etcd (AKS KMS), rotated yearly
resource "azurerm_key_vault_key" "aks_etcd" {
  name            = "aks-etcd-kms"
  key_vault_id    = azurerm_key_vault.this.id
  key_type        = "RSA-HSM"
  key_size        = 2048
  key_opts        = ["encrypt", "decrypt", "wrapKey", "unwrapKey"]
  expiration_date = timeadd(formatdate("YYYY-MM-DD'T'00:00:00Z", plantimestamp()), "17520h") # +2 years

  rotation_policy {
    automatic {
      time_before_expiry = "P30D"
    }
    expire_after         = "P2Y"
    notify_before_expiry = "P29D"
  }

  depends_on = [azurerm_role_assignment.kv_secrets_officer]

  lifecycle {
    ignore_changes = [expiration_date] # rotation policy renews it
  }
}

resource "azurerm_role_assignment" "aks_kms" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = "${local.name}-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.environment == "prod" ? 90 : 30
  daily_quota_gb      = var.environment == "prod" ? -1 : 5
  tags                = local.tags
}

# ------------------------------------------------------------------------------
# Ingress: Application Gateway (configured by the AGIC add-on)
# ------------------------------------------------------------------------------
module "waf" {
  source                = "../modules/waf"
  name                  = local.name
  location              = var.location
  resource_group        = azurerm_resource_group.this.name
  mode                  = var.waf.mode
  rate_limit_per_minute = var.waf.rate_limit_per_minute
  max_body_kb           = var.waf.max_body_kb
  tags                  = local.tags
}

module "app_gateway" {
  source             = "../modules/app-gateway"
  name               = local.name
  location           = var.location
  resource_group     = azurerm_resource_group.this.name
  subnet_id          = module.network.subnet_ids.appgw
  zones              = local.zones
  min_capacity       = var.app_gateway.min_capacity
  max_capacity       = var.app_gateway.max_capacity
  sku                = "WAF_v2"
  firewall_policy_id = module.waf.id
  tags               = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "app_gateway" {
  name                           = "access-and-waf"
  target_resource_id             = module.app_gateway.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }
  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }
}

# ------------------------------------------------------------------------------
# AKS
# ------------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "aks" {
  name                = "${local.name}-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

# Node auto-provisioning (and the cluster in general) creates NICs in our VNet
resource "azurerm_role_assignment" "aks_network" {
  scope                = module.network.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = local.name
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = local.name
  kubernetes_version  = var.kubernetes_version
  sku_tier            = var.aks_sku_tier
  node_resource_group = "${local.name}-nodes-rg"

  # identity & access
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  role_based_access_control_enabled = true
  local_account_disabled            = true
  azure_active_directory_role_based_access_control {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled = true
  }

  dynamic "api_server_access_profile" {
    for_each = length(var.api_server_authorized_ip_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = var.api_server_authorized_ip_ranges
    }
  }

  # upgrades
  automatic_upgrade_channel    = "patch"
  node_os_upgrade_channel      = "NodeImage"
  image_cleaner_enabled        = true
  image_cleaner_interval_hours = 48

  # Only the "system" pool is managed here. CPU and GPU capacity for ML workloads
  # is provisioned just-in-time by node auto-provisioning (Karpenter) from the
  # NodePools in charts/karpenter-nodepools.
  default_node_pool {
    name                        = "system"
    vm_size                     = var.system_node_pool.vm_size
    node_count                  = var.system_node_pool.node_count
    vnet_subnet_id              = module.network.subnet_ids.aks
    zones                       = local.zones
    os_sku                      = "AzureLinux"
    os_disk_type                = "Ephemeral"
    os_disk_size_gb             = 128
    host_encryption_enabled     = true # temp disks, caches, OS disk data flows encrypted on the host
    max_pods                    = 110
    temporary_name_for_rotation = "systemtmp"
    node_labels                 = { workload = "system" }
    tags                        = local.tags

    upgrade_settings {
      max_surge                     = "33%"
      drain_timeout_in_minutes      = 30
      node_soak_duration_in_minutes = 0
    }
  }

  # NAP's own "default"/"system-surge" pools are not created: our cpu/gpu
  # NodePools (GitOps) are the only source of auto-provisioned capacity.
  node_provisioning_profile {
    mode               = "Auto"
    default_node_pools = "None"
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_data_plane  = "cilium"
    network_policy      = "cilium"
    pod_cidr            = "192.168.0.0/16"
    service_cidr        = "172.16.0.0/16"
    dns_service_ip      = "172.16.0.10"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
  }

  ingress_application_gateway {
    gateway_id = module.app_gateway.id
  }

  # DevSecOps: Secrets in etcd encrypted with our Key Vault key
  key_management_service {
    key_vault_key_id         = azurerm_key_vault_key.aks_etcd.id
    key_vault_network_access = "Public"
  }

  # Defender for Containers sensor (runtime threat detection, eBPF)
  microsoft_defender {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  }

  # Azure Policy add-on: compliance reporting for Kubernetes (PSS restricted, audit)
  azure_policy_enabled = true

  storage_profile {
    disk_driver_enabled         = true
    file_driver_enabled         = true
    blob_driver_enabled         = false
    snapshot_controller_enabled = true
  }

  tags = local.tags

  depends_on = [azurerm_role_assignment.aks_network, azurerm_role_assignment.aks_kms]

  lifecycle {
    ignore_changes = [kubernetes_version] # patch upgrades are automatic
  }
}

# kubelet (node) identity pulls images from the shared ACR
resource "azurerm_role_assignment" "acr_pull" {
  scope                = data.azurerm_container_registry.shared.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
  principal_type       = "ServicePrincipal"
}

# AGIC add-on identity manages the Application Gateway
locals {
  agic_principal = azurerm_kubernetes_cluster.this.ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

resource "azurerm_role_assignment" "agic" {
  for_each = {
    appgw = { scope = module.app_gateway.id, role = "Contributor" }
    rg    = { scope = azurerm_resource_group.this.id, role = "Reader" }
    snet  = { scope = module.network.subnet_ids.appgw, role = "Network Contributor" }
  }
  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = local.agic_principal
  principal_type       = "ServicePrincipal"
}

# Control-plane logs -> Log Analytics
resource "azurerm_monitor_diagnostic_setting" "aks" {
  name                           = "control-plane"
  target_resource_id             = azurerm_kubernetes_cluster.this.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated" # resource-specific tables: AKSAudit, AKSAuditAdmin, AKSControlPlane

  dynamic "enabled_log" {
    for_each = ["kube-apiserver", "kube-audit-admin", "kube-controller-manager", "kube-scheduler", "cluster-autoscaler", "guard"]
    content {
      category = enabled_log.value
    }
  }
}

# Pod Security Standards (restricted) reported by Azure Policy — Kyverno enforces,
# Azure Policy gives the compliance view in Defender for Cloud.
data "azurerm_policy_set_definition" "pss_restricted" {
  name = "42b8ef37-b724-4e24-bbc8-7a7708edfe00" # Kubernetes cluster pod security restricted standards for Linux-based workloads
}

resource "azurerm_resource_policy_assignment" "pss_restricted" {
  name                 = "${local.name}-pss-restricted"
  display_name         = "${local.name}: Pod Security Standards restricted (audit)"
  resource_id          = azurerm_kubernetes_cluster.this.id
  policy_definition_id = data.azurerm_policy_set_definition.pss_restricted.id
  enforce              = false
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "audit"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "AuditEvent"
  }
}

# ------------------------------------------------------------------------------
# Cluster access (Entra ID + Azure RBAC for Kubernetes)
#
#  principal                     role(s)                                        why
#  ----------------------------  ---------------------------------------------  ------------------------------
#  cluster_admin_object_ids      AKS RBAC Cluster Admin + Cluster User          platform admins
#  gha-tf-apply                  AKS RBAC Cluster Admin + Cluster User          Terraform helm/k8s resources
#  gha-tf-plan                   <name>-aks-read-all (custom) + Cluster User    plan reads Helm release secrets
#  gha-ci                        Cluster User only; a Kubernetes RoleBinding    may only submit Argo Workflows
#                                in ml-training (charts/ml-pipelines)           in ml-training
# ------------------------------------------------------------------------------
resource "azurerm_role_definition" "aks_read_all" {
  name        = "${local.name}-aks-read-all"
  scope       = azurerm_kubernetes_cluster.this.id
  description = "Read every Kubernetes object in ${local.name}, including Secrets (terraform plan)."

  permissions {
    data_actions = ["Microsoft.ContainerService/managedClusters/*/read"]
  }

  assignable_scopes = [azurerm_kubernetes_cluster.this.id]
}

locals {
  admins = merge(
    { for i, id in var.cluster_admin_object_ids : "admin-${i}" => { principal = id, type = null } },
    { tf-apply = { principal = data.azurerm_user_assigned_identity.gha["tf-apply"].principal_id, type = "ServicePrincipal" } },
  )
  cluster_access = merge(
    merge([for k, a in local.admins : {
      "${k}/admin" = { principal = a.principal, type = a.type, role = "Azure Kubernetes Service RBAC Cluster Admin", role_id = null }
      "${k}/user"  = { principal = a.principal, type = a.type, role = "Azure Kubernetes Service Cluster User Role", role_id = null }
    }]...),
    {
      "tf-plan/read" = { principal = data.azurerm_user_assigned_identity.gha["tf-plan"].principal_id, type = "ServicePrincipal", role = null, role_id = azurerm_role_definition.aks_read_all.role_definition_resource_id }
      "tf-plan/user" = { principal = data.azurerm_user_assigned_identity.gha["tf-plan"].principal_id, type = "ServicePrincipal", role = "Azure Kubernetes Service Cluster User Role", role_id = null }
      "ci/user"      = { principal = data.azurerm_user_assigned_identity.gha["ci"].principal_id, type = "ServicePrincipal", role = "Azure Kubernetes Service Cluster User Role", role_id = null }
    },
  )
}

resource "azurerm_role_assignment" "cluster_access" {
  for_each             = local.cluster_access
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = each.value.role
  role_definition_id   = each.value.role_id
  principal_id         = each.value.principal
  principal_type       = each.value.type
}

# ------------------------------------------------------------------------------
# Data plane: Blob storage, PostgreSQL, workload identities
# ------------------------------------------------------------------------------
module "storage" {
  source             = "../modules/storage"
  name               = local.name
  account_name       = "${var.project}${var.environment}data${local.suffix}"
  location           = var.location
  resource_group     = azurerm_resource_group.this.name
  replication_type   = var.environment == "prod" ? "ZRS" : "LRS"
  allowed_subnet_ids = [module.network.subnet_ids.aks]
  allowed_ip_ranges  = var.storage_allowed_ip_ranges
  tags               = local.tags
}

# Data-plane audit trail (the CloudTrail S3 data events equivalent)
resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                           = "blob-audit"
  target_resource_id             = "${module.storage.account_id}/blobServices/default"
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.this.id
  log_analytics_destination_type = "Dedicated"

  dynamic "enabled_log" {
    for_each = ["StorageRead", "StorageWrite", "StorageDelete"]
    content {
      category = enabled_log.value
    }
  }
}

module "database" {
  source                = "../modules/database"
  name                  = local.name
  location              = var.location
  resource_group        = azurerm_resource_group.this.name
  delegated_subnet_id   = module.network.subnet_ids.postgres
  private_dns_zone_id   = module.network.postgres_private_dns_zone_id
  key_vault_id          = azurerm_key_vault.this.id
  sku_name              = var.postgres.sku_name
  storage_mb            = var.postgres.storage_mb
  high_availability     = var.postgres.high_availability
  backup_retention_days = var.postgres.backup_retention_days
  geo_redundant_backup  = var.postgres.geo_redundant_backup
  log_analytics_id      = azurerm_log_analytics_workspace.this.id
  tags                  = local.tags

  depends_on = [azurerm_role_assignment.kv_secrets_officer]
}

module "workload_identity" {
  source           = "../modules/workload-identity"
  name             = local.name
  location         = var.location
  resource_group   = azurerm_resource_group.this.name
  oidc_issuer_url  = azurerm_kubernetes_cluster.this.oidc_issuer_url
  container_ids    = module.storage.container_ids
  key_vault_id     = azurerm_key_vault.this.id
  monitoring_scope = data.azurerm_subscription.current.id
  acr_id           = data.azurerm_container_registry.shared.id
  tags             = local.tags
}

# ------------------------------------------------------------------------------
# Day-0 platform
# ------------------------------------------------------------------------------
module "platform" {
  source = "../modules/platform"

  project          = var.project
  environment      = var.environment
  postgres_fqdn    = module.database.fqdn
  gitops_repo_url  = var.gitops_repo_url
  gitops_revision  = var.gitops_revision
  bootstrap_gitops = var.bootstrap_gitops
  argocd_ha        = var.argocd_ha

  # Facts Git cannot know -> Argo CD root app -> templated into child apps
  cloud = {
    provider             = "azure"
    tenantId             = data.azurerm_client_config.current.tenant_id
    subscriptionId       = var.subscription_id
    location             = var.location
    resourceGroup        = azurerm_resource_group.this.name
    nodeResourceGroup    = azurerm_kubernetes_cluster.this.node_resource_group
    clusterName          = azurerm_kubernetes_cluster.this.name
    aksSubnetId          = module.network.subnet_ids.aks
    vnetCidr             = var.vnet_cidr
    appGatewaySubnetCidr = module.network.subnet_cidrs.appgw
    storageAccount       = module.storage.account_name
    blobEndpoint         = module.storage.blob_endpoint
    keyVaultName         = azurerm_key_vault.this.name
    keyVaultUri          = azurerm_key_vault.this.vault_uri
    acrLoginServer       = data.azurerm_container_registry.shared.login_server
    appGatewayFqdn       = module.app_gateway.fqdn
    clientIds            = module.workload_identity.client_ids
    ciPrincipalId        = data.azurerm_user_assigned_identity.gha["ci"].principal_id
  }

  depends_on = [
    azurerm_role_assignment.cluster_access,
    azurerm_role_assignment.agic,
    azurerm_role_assignment.acr_pull,
    module.workload_identity,
  ]
}

# ------------------------------------------------------------------------------
# Billing guardrails (Cost Management budgets on the Project/Environment tags)
# ------------------------------------------------------------------------------
module "cost_guardrails" {
  source = "../modules/cost-guardrails"

  name               = local.name
  project            = var.project
  environment        = var.environment
  subscription_id    = data.azurerm_subscription.current.id
  monthly_budget_usd = var.budgets.monthly_total_usd
  compute_budget_usd = var.budgets.monthly_compute_usd
  alert_emails       = var.budgets.alert_emails
}
