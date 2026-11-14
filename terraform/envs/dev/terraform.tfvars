subscription_id = "__SUBSCRIPTION_ID__"
project         = "aiml"
environment     = "dev"
location        = "eastus2"
gitops_repo_url = "https://github.com/Cloud-Deployment-Resources-asimshahibm/DevSecOps-Series-AI-ML-Workload-deployment-on-Azure-AKS.git"
gitops_revision = "main"

vnet_cidr = "10.10.0.0/16"

kubernetes_version = "1.33"
aks_sku_tier       = "Free"

# Your Entra ID object id (scripts/configure.sh fills this from `az ad signed-in-user show`)
cluster_admin_object_ids = ["__ADMIN_OBJECT_ID__"]

system_node_pool = {
  vm_size    = "Standard_D4ds_v5"
  node_count = 2
}

app_gateway = {
  min_capacity = 1
  max_capacity = 2
}

postgres = {
  sku_name              = "B_Standard_B2s"
  storage_mb            = 32768
  high_availability     = false
  backup_retention_days = 7
  geo_redundant_backup  = false
}

# DevSecOps: WAF on the Application Gateway (Detection = log only while tuning)
waf = {
  mode                  = "Prevention"
  rate_limit_per_minute = 600
  max_body_kb           = 256
}

# Key Vault firewall: "Deny" once Terraform runs from inside the VNet (self-hosted runners)
key_vault_default_action    = "Allow"
key_vault_allowed_ip_ranges = []

key_vault_purge_protection = false
argocd_ha                  = false

# Billing guardrails (Cost Management budgets). Add recipients, e.g. ["platform-team@example.com"]
budgets = {
  monthly_total_usd   = 900
  monthly_compute_usd = 550
  alert_emails        = []
}
