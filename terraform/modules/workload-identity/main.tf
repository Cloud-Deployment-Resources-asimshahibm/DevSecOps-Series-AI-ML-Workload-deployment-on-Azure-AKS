################################################################################
# Microsoft Entra Workload ID for every workload that talks to Azure (the AKS
# equivalent of IRSA). One user-assigned managed identity per job-to-be-done,
# federated with explicit namespace:serviceaccount pairs, with data-plane RBAC
# scoped to the containers / vault it needs (least privilege).
#
#  identity          service accounts                                   access
#  ----------------  -------------------------------------------------  -------------------------------------
#  ml-training       ml-training:ml-training, ray:ray-worker             data rw, models rw, artifacts rw
#  ml-inference      ml-serving:ml-inference                             models ro
#  jupyter-user      jupyterhub:jupyter-user                             data rw, models ro, artifacts ro
#  argo-workflows    argo:argo-workflows-server, argo:argo-workflow      artifacts rw
#  loki              monitoring:loki                                     loki rw
#  grafana           monitoring:kube-prometheus-stack-grafana            Monitoring Reader (Azure Monitor datasource)
#  external-secrets  external-secrets:external-secrets                   Key Vault Secrets User
#  image-verifier    kyverno:kyverno-admission-controller,              AcrPull (cosign signatures, image scans)
#                    trivy-system:trivy-operator
#
# Pods opt in with the label azure.workload.identity/use: "true"; the service
# account carries azure.workload.identity/client-id (rendered by Argo CD from
# Terraform outputs, see argocd/app-of-apps `cloud` values).
################################################################################

variable "name" { type = string }
variable "location" { type = string }
variable "resource_group" { type = string }
variable "oidc_issuer_url" { type = string }
variable "container_ids" { type = map(string) } # data, models, artifacts, loki
variable "key_vault_id" { type = string }
variable "monitoring_scope" { type = string } # resource group id(s) Grafana may read metrics from
variable "acr_id" { type = string }
variable "tags" { type = map(string) }

locals {
  rw = "Storage Blob Data Contributor"
  ro = "Storage Blob Data Reader"

  identities = {
    ml-training = {
      sas   = ["ml-training:ml-training", "ray:ray-worker"]
      roles = { data = local.rw, models = local.rw, artifacts = local.rw }
    }
    ml-inference = {
      sas   = ["ml-serving:ml-inference"]
      roles = { models = local.ro }
    }
    jupyter-user = {
      sas   = ["jupyterhub:jupyter-user"]
      roles = { data = local.rw, models = local.ro, artifacts = local.ro }
    }
    argo-workflows = {
      sas   = ["argo:argo-workflows-server", "argo:argo-workflow"]
      roles = { artifacts = local.rw }
    }
    loki = {
      sas   = ["monitoring:loki"]
      roles = { loki = local.rw }
    }
    grafana = {
      sas   = ["monitoring:kube-prometheus-stack-grafana"]
      roles = {}
    }
    external-secrets = {
      sas   = ["external-secrets:external-secrets"]
      roles = {}
    }
    image-verifier = {
      sas   = ["kyverno:kyverno-admission-controller", "trivy-system:trivy-operator"]
      roles = {}
    }
  }

  # Azure rejects concurrent federated-credential writes on one identity -> tiers
  credentials = merge([
    for id, cfg in local.identities : {
      for i, sa in cfg.sas : "${id}/${sa}" => {
        identity  = id
        namespace = split(":", sa)[0]
        sa        = split(":", sa)[1]
        tier      = i
      }
    }
  ]...)

  blob_assignments = merge([
    for id, cfg in local.identities : {
      for container, role in cfg.roles : "${id}/${container}" => { identity = id, container = container, role = role }
    }
  ]...)
}

resource "azurerm_user_assigned_identity" "this" {
  for_each            = local.identities
  name                = "${var.name}-${each.key}"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "tier0" {
  for_each                  = { for k, v in local.credentials : k => v if v.tier == 0 }
  name                      = "${each.value.namespace}-${each.value.sa}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this[each.value.identity].id
  issuer                    = var.oidc_issuer_url
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.sa}"
}

resource "azurerm_federated_identity_credential" "tier1" {
  for_each                  = { for k, v in local.credentials : k => v if v.tier >= 1 }
  name                      = "${each.value.namespace}-${each.value.sa}"
  user_assigned_identity_id = azurerm_user_assigned_identity.this[each.value.identity].id
  issuer                    = var.oidc_issuer_url
  audience                  = ["api://AzureADTokenExchange"]
  subject                   = "system:serviceaccount:${each.value.namespace}:${each.value.sa}"
  depends_on                = [azurerm_federated_identity_credential.tier0]
}

resource "azurerm_role_assignment" "blob" {
  for_each             = local.blob_assignments
  scope                = var.container_ids[each.value.container]
  role_definition_name = each.value.role
  principal_id         = azurerm_user_assigned_identity.this[each.value.identity].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "external_secrets" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.this["external-secrets"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "grafana" {
  scope                = var.monitoring_scope
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.this["grafana"].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "image_verifier" {
  scope                = var.acr_id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.this["image-verifier"].principal_id
  principal_type       = "ServicePrincipal"
}

output "client_ids" {
  value = { for k, v in azurerm_user_assigned_identity.this : k => v.client_id }
}

output "principal_ids" {
  value = { for k, v in azurerm_user_assigned_identity.this : k => v.principal_id }
}
