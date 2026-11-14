subscription_id = "__SUBSCRIPTION_ID__"
project         = "aiml"
environment     = "prod"
location        = "eastus2"
gitops_repo_url = "https://github.com/Cloud-Deployment-Resources-asimshahibm/DevSecOps-Series-AI-ML-Workload-deployment-on-Azure-AKS.git"
gitops_revision = "main"

vnet_cidr = "10.20.0.0/16"
zones     = ["1", "2", "3"]

kubernetes_version = "1.33"
aks_sku_tier       = "Standard" # API server SLA

# Your Entra ID object id (scripts/configure.sh fills this from `az ad signed-in-user show`)
cluster_admin_object_ids = ["__ADMIN_OBJECT_ID__"]

# Replace with your corporate egress / VPN CIDRs before applying prod
# (and add GitHub runner ranges or use self-hosted runners for terraform/CI)
api_server_authorized_ip_ranges = []

system_node_pool = {
  vm_size    = "Standard_D4ds_v5"
  node_count = 3
}

app_gateway = {
  min_capacity = 2
  max_capacity = 10
}

postgres = {
  sku_name              = "GP_Standard_D4ds_v5"
  storage_mb            = 131072
  high_availability     = true
  backup_retention_days = 14
  geo_redundant_backup  = true
}

# DevSecOps: WAF on the Application Gateway (Detection = log only while tuning)
waf = {
  mode                  = "Prevention"
  rate_limit_per_minute = 1200
  max_body_kb           = 256
}

# Key Vault firewall: "Deny" once Terraform runs from inside the VNet (self-hosted runners)
key_vault_default_action    = "Allow"
key_vault_allowed_ip_ranges = []

key_vault_purge_protection = true
argocd_ha                  = true

# Billing guardrails (Cost Management budgets). Add recipients, e.g. ["platform-team@example.com"]
budgets = {
  monthly_total_usd   = 6500
  monthly_compute_usd = 4800
  alert_emails        = []
}
