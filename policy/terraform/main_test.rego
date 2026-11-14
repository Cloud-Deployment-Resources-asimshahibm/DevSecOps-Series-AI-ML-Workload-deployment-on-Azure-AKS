package main

import rego.v1

plan(env, rcs) := {"variables": {"environment": {"value": env}}, "resource_changes": rcs}

rc(type, after) := {"address": sprintf("%s.test", [type]), "type": type, "change": {"actions": ["create"], "after": after}}

good_storage := {"shared_access_key_enabled": false, "allow_nested_items_to_be_public": false, "min_tls_version": "TLS1_2"}

test_storage_shared_keys_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_storage_account", object.union(good_storage, {"shared_access_key_enabled": true}))])
}

test_hardened_storage_allowed if {
	count(deny) == 0 with input as plan("dev", [rc("azurerm_storage_account", good_storage)])
}

test_public_container_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_storage_container", {"container_access_type": "blob"})])
}

test_public_postgres_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_postgresql_flexible_server", {"public_network_access_enabled": true})])
}

test_prod_key_vault_needs_purge_protection if {
	count(deny) > 0 with input as plan("prod", [rc("azurerm_key_vault", {"rbac_authorization_enabled": true, "purge_protection_enabled": false})])
	count(deny) == 0 with input as plan("dev", [rc("azurerm_key_vault", {"rbac_authorization_enabled": true, "purge_protection_enabled": false})])
}

test_acr_admin_user_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_container_registry", {"admin_enabled": true})])
}

aks(ranges) := rc("azurerm_kubernetes_cluster", {
	"local_account_disabled": true,
	"workload_identity_enabled": true,
	"azure_active_directory_role_based_access_control": [{"azure_rbac_enabled": true}],
	"key_management_service": [{"key_vault_key_id": "k"}],
	"microsoft_defender": [{"log_analytics_workspace_id": "w"}],
	"api_server_access_profile": [{"authorized_ip_ranges": ranges}],
})

test_hardened_aks_allowed if {
	count(deny) == 0 with input as plan("prod", [aks(["203.0.113.0/24"])])
}

test_aks_local_accounts_denied if {
	bad := rc("azurerm_kubernetes_cluster", object.union(aks(["203.0.113.0/24"]).change.after, {"local_account_disabled": false}))
	count(deny) > 0 with input as plan("dev", [bad])
}

test_aks_without_kms_denied if {
	bad := rc("azurerm_kubernetes_cluster", object.union(aks(["203.0.113.0/24"]).change.after, {"key_management_service": []}))
	count(deny) > 0 with input as plan("dev", [bad])
}

test_open_api_server_denied_in_prod if {
	count(deny) > 0 with input as plan("prod", [aks([])])
}

test_open_api_server_only_warns_in_dev if {
	count(deny) == 0 with input as plan("dev", [aks([])])
	count(warn) == 1 with input as plan("dev", [aks([])])
}

nsg(source, port) := rc("azurerm_network_security_group", {"security_rule": [{"name": "r", "direction": "Inbound", "access": "Allow", "source_address_prefix": source, "destination_port_range": port, "destination_port_ranges": []}]})

test_ssh_from_internet_denied if {
	count(deny) > 0 with input as plan("dev", [nsg("Internet", "22")])
}

test_https_from_internet_allowed if {
	count(deny) == 0 with input as plan("dev", [nsg("Internet", "443")])
}

test_gateway_manager_allowed if {
	count(deny) == 0 with input as plan("dev", [nsg("GatewayManager", "65200-65535")])
}

test_app_gateway_without_waf_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_application_gateway", {"sku": [{"name": "Standard_v2", "tier": "Standard_v2"}], "firewall_policy_id": null})])
}

test_app_gateway_with_waf_allowed if {
	count(deny) == 0 with input as plan("dev", [rc("azurerm_application_gateway", {"sku": [{"name": "WAF_v2", "tier": "WAF_v2"}], "firewall_policy_id": "/subscriptions/x/wafpolicy"})])
}

test_wildcard_custom_role_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_role_definition", {"permissions": [{"actions": ["*"]}]})])
}

test_owner_assignment_denied if {
	count(deny) > 0 with input as plan("dev", [rc("azurerm_role_assignment", {"role_definition_name": "Owner"})])
}
