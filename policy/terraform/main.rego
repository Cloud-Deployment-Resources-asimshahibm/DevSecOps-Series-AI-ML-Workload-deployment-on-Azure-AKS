# Policy-as-code gate on `terraform show -json tfplan` (conftest), azurerm edition.
# Runs in .github/workflows/terraform.yml before every apply; a deny fails the job.
package main

import rego.v1

creating_or_updating(rc) if {
	some action in rc.change.actions
	action in {"create", "update"}
}

changes contains rc if {
	some rc in input.resource_changes
	creating_or_updating(rc)
}

environment := input.variables.environment.value

after(rc, key, default_value) := object.get(rc.change.after, key, default_value)

# ---------------------------------------------------------------- storage & data
deny contains msg if {
	some rc in changes
	rc.type == "azurerm_storage_account"
	after(rc, "shared_access_key_enabled", true) != false
	msg := sprintf("%s: storage accounts must disable shared keys (Entra ID auth only)", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_storage_account"
	after(rc, "allow_nested_items_to_be_public", true) != false
	msg := sprintf("%s: storage accounts must not allow public blob access", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_storage_account"
	after(rc, "min_tls_version", "TLS1_0") != "TLS1_2"
	msg := sprintf("%s: storage accounts must require TLS 1.2", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_storage_container"
	after(rc, "container_access_type", "private") != "private"
	msg := sprintf("%s: blob containers must be private", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_postgresql_flexible_server"
	after(rc, "public_network_access_enabled", true) != false
	msg := sprintf("%s: PostgreSQL must not be publicly accessible", [rc.address])
}

# ---------------------------------------------------------------- keys & secrets
deny contains msg if {
	some rc in changes
	rc.type == "azurerm_key_vault"
	after(rc, "rbac_authorization_enabled", false) != true
	msg := sprintf("%s: Key Vault must use Azure RBAC (no access policies)", [rc.address])
}

deny contains msg if {
	environment == "prod"
	some rc in changes
	rc.type == "azurerm_key_vault"
	after(rc, "purge_protection_enabled", false) != true
	msg := sprintf("%s: prod Key Vault must have purge protection", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_key_vault_key"
	count(after(rc, "rotation_policy", [])) == 0
	msg := sprintf("%s: Key Vault keys must have a rotation policy", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_container_registry"
	after(rc, "admin_enabled", true) != false
	msg := sprintf("%s: ACR admin user must be disabled", [rc.address])
}

# ---------------------------------------------------------------- AKS
deny contains msg if {
	some rc in changes
	rc.type == "azurerm_kubernetes_cluster"
	after(rc, "local_account_disabled", false) != true
	msg := sprintf("%s: AKS local accounts must be disabled (Entra ID only)", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_kubernetes_cluster"
	not azure_rbac(rc)
	msg := sprintf("%s: AKS must use Entra ID with Azure RBAC for Kubernetes", [rc.address])
}

azure_rbac(rc) if {
	some aad in after(rc, "azure_active_directory_role_based_access_control", [])
	aad.azure_rbac_enabled == true
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_kubernetes_cluster"
	after(rc, "workload_identity_enabled", false) != true
	msg := sprintf("%s: AKS must enable Workload ID (no secrets for Azure access)", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_kubernetes_cluster"
	count(after(rc, "key_management_service", [])) == 0
	msg := sprintf("%s: AKS secrets must be encrypted with a Key Vault key (KMS etcd encryption)", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_kubernetes_cluster"
	count(after(rc, "microsoft_defender", [])) == 0
	msg := sprintf("%s: Defender for Containers sensor must be enabled", [rc.address])
}

open_api_server(rc) if {
	rc.type == "azurerm_kubernetes_cluster"
	ranges := [r | some p in after(rc, "api_server_access_profile", []); some r in object.get(p, "authorized_ip_ranges", [])]
	not restricted(ranges)
}

restricted(ranges) if {
	count(ranges) > 0
	not "0.0.0.0/0" in ranges
}

deny contains msg if {
	environment == "prod"
	some rc in changes
	open_api_server(rc)
	msg := sprintf("%s: prod AKS API server must restrict authorized IP ranges (set api_server_authorized_ip_ranges)", [rc.address])
}

warn contains msg if {
	environment != "prod"
	some rc in changes
	open_api_server(rc)
	msg := sprintf("%s: AKS API server reachable from any IP (acceptable for dev only)", [rc.address])
}

# ---------------------------------------------------------------- network exposure
internet_sources := {"*", "Internet", "0.0.0.0/0", "any"}

allowed_internet_ports := {"80", "443"}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_network_security_group"
	some rule in after(rc, "security_rule", [])
	rule.direction == "Inbound"
	rule.access == "Allow"
	rule.source_address_prefix in internet_sources
	some port in rule_ports(rule)
	not port in allowed_internet_ports
	msg := sprintf("%s: inbound rule %s allows port %s from the Internet (only 80/443)", [rc.address, rule.name, port])
}

rule_ports(rule) := ports if {
	ports := array.concat(
		[p | p := object.get(rule, "destination_port_range", ""); p != ""; p != null],
		object.get(rule, "destination_port_ranges", []),
	)
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_application_gateway"
	not waf_attached(rc)
	msg := sprintf("%s: Application Gateway must be WAF_v2 with a WAF policy", [rc.address])
}

waf_attached(rc) if {
	some sku in after(rc, "sku", [])
	sku.tier == "WAF_v2"
	after(rc, "firewall_policy_id", null) != null
}

# the WAF policy is known only after apply on first create; then the SKU is enough
waf_attached(rc) if {
	some sku in after(rc, "sku", [])
	sku.tier == "WAF_v2"
	object.get(object.get(rc.change, "after_unknown", {}), "firewall_policy_id", false) == true
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_web_application_firewall_policy"
	some ps in after(rc, "policy_settings", [])
	ps.mode != "Prevention"
	environment == "prod"
	msg := sprintf("%s: prod WAF policy must run in Prevention mode", [rc.address])
}

# ---------------------------------------------------------------- RBAC
deny contains msg if {
	some rc in changes
	rc.type == "azurerm_role_assignment"
	after(rc, "role_definition_name", "") == "Owner"
	msg := sprintf("%s: Terraform must not grant Owner", [rc.address])
}

deny contains msg if {
	some rc in changes
	rc.type == "azurerm_role_definition"
	some perm in after(rc, "permissions", [])
	"*" in object.get(perm, "actions", [])
	msg := sprintf("%s: custom roles must not grant actions *", [rc.address])
}
