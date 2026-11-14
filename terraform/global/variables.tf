variable "subscription_id" {
  description = "Azure subscription that hosts the platform (scripts/configure.sh renders it)."
  type        = string
}

variable "location" {
  description = "Azure region for shared resources (state, ACR)."
  type        = string
  default     = "eastus2"
}

variable "project" {
  description = "Short project prefix used in every resource name."
  type        = string
  default     = "aiml"
}

variable "github_org" {
  description = "GitHub organization or user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org)."
  type        = string
}

variable "environments" {
  description = "GitHub Environments allowed to use the apply identity."
  type        = list(string)
  default     = ["dev", "prod"]
}

variable "acr_sku" {
  description = "Premium is required by the DevSecOps edition (retention, zone redundancy, dedicated data endpoints, private endpoints)."
  type        = string
  default     = "Premium"
  validation {
    condition     = var.acr_sku == "Premium"
    error_message = "The DevSecOps edition requires a Premium registry."
  }
}

variable "billing_alert_emails" {
  description = "Recipients of subscription-level cost anomaly alerts."
  type        = list(string)
  default     = []
}

variable "security_services" {
  description = "Subscription security services. Set a flag to false if it is already managed centrally (management group / landing zone)."
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
  default = {
    defender_containers = true
    defender_storage    = true
    defender_keyvault   = true
    defender_databases  = true
    defender_arm        = true
    defender_cspm       = true
    cis_policy          = true
    activity_log        = true
  }
}

variable "security_contact_email" {
  description = "Defender for Cloud security alerts recipient."
  type        = string
  default     = ""
}
