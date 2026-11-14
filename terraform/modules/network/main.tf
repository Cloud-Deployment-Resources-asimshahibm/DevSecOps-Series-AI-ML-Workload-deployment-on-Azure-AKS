################################################################################
# Virtual network for one environment
#
#   snet-aks          /20  AKS system pool + NAP (Karpenter) nodes. Pods use the
#                          Azure CNI Overlay range (no VNet IPs per pod).
#                          Service endpoints: Storage, KeyVault, ContainerRegistry
#   snet-appgw        /24  Application Gateway (AGIC ingress) — dedicated subnet
#   snet-postgres     /24  delegated to PostgreSQL Flexible Server (private access)
#   snet-endpoints    /24  private endpoints (used by the DevSecOps edition)
################################################################################

variable "name" { type = string }
variable "location" { type = string }
variable "resource_group" { type = string }
variable "vnet_cidr" { type = string }
variable "tags" { type = map(string) }

locals {
  subnets = {
    aks       = cidrsubnet(var.vnet_cidr, 4, 0)  # 10.x.0.0/20
    appgw     = cidrsubnet(var.vnet_cidr, 8, 16) # 10.x.16.0/24
    postgres  = cidrsubnet(var.vnet_cidr, 8, 17) # 10.x.17.0/24
    endpoints = cidrsubnet(var.vnet_cidr, 8, 18) # 10.x.18.0/24
  }
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name}-vnet"
  location            = var.location
  resource_group_name = var.resource_group
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.aks]
  # Storage / Key Vault / ACR traffic stays on the Azure backbone and lets the
  # data-plane firewalls allow this subnet only.
  dynamic "service_endpoint" {
    for_each = ["Microsoft.Storage", "Microsoft.KeyVault", "Microsoft.ContainerRegistry"]
    content {
      service = service_endpoint.value
    }
  }
}

# AGIC with Azure CNI Overlay requires a dedicated subnet of at most /24,
# delegated to Application Gateway.
resource "azurerm_subnet" "appgw" {
  name                 = "snet-appgw"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.appgw]

  delegation {
    name = "application-gateway"
    service_delegation {
      name    = "Microsoft.Network/applicationGateways"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  name                 = "snet-postgres"
  resource_group_name  = var.resource_group
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [local.subnets.postgres]

  delegation {
    name = "postgres-flexible"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "endpoints" {
  name                              = "snet-endpoints"
  resource_group_name               = var.resource_group
  virtual_network_name              = azurerm_virtual_network.this.name
  address_prefixes                  = [local.subnets.endpoints]
  private_endpoint_network_policies = "Enabled"
}

# ------------------------------------------------------------------------------
# NSGs. The AKS subnet keeps the NSG that AKS manages on node NICs.
# ------------------------------------------------------------------------------
resource "azurerm_network_security_group" "appgw" {
  name                = "${var.name}-appgw-nsg"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags

  # required by Application Gateway v2 (infrastructure health probes)
  security_rule {
    name                       = "allow-gateway-manager"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "65200-65535"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-azure-lb"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-http-https"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "appgw" {
  subnet_id                 = azurerm_subnet.appgw.id
  network_security_group_id = azurerm_network_security_group.appgw.id
}

resource "azurerm_network_security_group" "endpoints" {
  name                = "${var.name}-endpoints-nsg"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags

  security_rule {
    name                       = "allow-https-from-aks"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = local.subnets.aks
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-other-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "endpoints" {
  subnet_id                 = azurerm_subnet.endpoints.id
  network_security_group_id = azurerm_network_security_group.endpoints.id
}

resource "azurerm_network_security_group" "postgres" {
  name                = "${var.name}-postgres-nsg"
  location            = var.location
  resource_group_name = var.resource_group
  tags                = var.tags

  security_rule {
    name                       = "allow-postgres-from-aks"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = local.subnets.aks
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-other-vnet-inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

# ------------------------------------------------------------------------------
# Private DNS for PostgreSQL Flexible Server (private access)
# ------------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name}.private.postgres.database.azure.com"
  resource_group_name = var.resource_group
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                 = "${var.name}-postgres"
  private_dns_zone_id  = azurerm_private_dns_zone.postgres.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

output "vnet_id" { value = azurerm_virtual_network.this.id }
output "vnet_name" { value = azurerm_virtual_network.this.name }
output "vnet_cidr" { value = var.vnet_cidr }
output "subnet_ids" {
  value = {
    aks       = azurerm_subnet.aks.id
    appgw     = azurerm_subnet.appgw.id
    postgres  = azurerm_subnet.postgres.id
    endpoints = azurerm_subnet.endpoints.id
  }
}
output "subnet_cidrs" { value = local.subnets }
output "postgres_private_dns_zone_id" { value = azurerm_private_dns_zone.postgres.id }
