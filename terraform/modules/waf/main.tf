################################################################################
# Web Application Firewall policy for the Application Gateway (WAF_v2) that
# fronts the ml-inference API and JupyterHub (AGIC). Attached at gateway level,
# so it protects every listener AGIC creates.
#
#   Microsoft_DefaultRuleSet 2.1   OWASP CRS-based core rules (SQLi, XSS, RCE,
#                                  Log4Shell, protocol enforcement, ...)
#   Microsoft_BotManagerRuleSet    known bad bots / scanners
#   per-IP rate limit              custom RateLimitRule
#   body size cap                  prediction batches up to max_body_kb
################################################################################

variable "name" { type = string }
variable "location" { type = string }
variable "resource_group" { type = string }

variable "mode" {
  description = "Detection (log only) or Prevention (block)."
  type        = string
  default     = "Prevention"
}

variable "rate_limit_per_minute" {
  description = "Requests per minute per client IP before blocking."
  type        = number
  default     = 600
}

variable "max_body_kb" {
  description = "Largest request body accepted (prediction batches)."
  type        = number
  default     = 256
}

variable "tags" { type = map(string) }

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${var.name}-waf"
  resource_group_name = var.resource_group
  location            = var.location
  tags                = var.tags

  policy_settings {
    enabled                          = true
    mode                             = var.mode
    request_body_check               = true
    request_body_inspect_limit_in_kb = 128
    max_request_body_size_in_kb      = var.max_body_kb
    file_upload_limit_in_mb          = 10
  }

  custom_rules {
    name                 = "PerIpRateLimit"
    priority             = 10
    rule_type            = "RateLimitRule"
    rate_limit_duration  = "OneMin"
    rate_limit_threshold = var.rate_limit_per_minute
    group_rate_limit_by  = "ClientAddr"
    action               = "Block"

    match_conditions {
      match_variables {
        variable_name = "RemoteAddr"
      }
      operator           = "IPMatch"
      negation_condition = true # every address that is NOT in the (empty) list = everyone
      match_values       = ["255.255.255.255/32"]
    }
  }

  managed_rules {
    # model API keys are not something the WAF should inspect or log
    exclusion {
      match_variable          = "RequestHeaderNames"
      selector                = "x-api-key"
      selector_match_operator = "Equals"
    }

    managed_rule_set {
      type    = "Microsoft_DefaultRuleSet"
      version = "2.1"
    }

    managed_rule_set {
      type    = "Microsoft_BotManagerRuleSet"
      version = "1.0"
    }
  }
}

output "id" { value = azurerm_web_application_firewall_policy.this.id }
