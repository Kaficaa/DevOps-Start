terraform {
  backend "azurerm" {
    resource_group_name  = "DevOps-Start"
    storage_account_name = "devopsstorage2026"
    container_name       = "tfstate"
    key                  = "terraform.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "container_image_tag" {
  type        = string
  description = "Tag from GitHub Actions"
  default     = "latest"
}

variable "registry_password" {
  type      = string
  sensitive = true
}

variable "subscription_id" {
  type      = string
  sensitive = true
}

import {
  to = azurerm_resource_group.my_rg
  id = "/subscriptions/${var.subscription_id}/resourceGroups/DevOps-Start"
}

resource "azurerm_resource_group" "my_rg" {
  name     = "DevOps-Start"
  location = "polandcentral"
}

resource "azurerm_virtual_network" "vnet" {
  name                = "devops-vnet"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
}

resource "azurerm_subnet" "aci_subnet" {
  name                 = "aci-subnet"
  resource_group_name  = azurerm_resource_group.my_rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]

  delegation {
    name = "aci-delegation"
    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_public_ip" "lb_pip" {
  name                = "lb-public-ip"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_lb" "my_lb" {
  name                = "devops-lb"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = azurerm_public_ip.lb_pip.id
  }
}

resource "azurerm_lb_backend_address_pool" "backend_pool" {
  loadbalancer_id = azurerm_lb.my_lb.id
  name            = "AciBackendPool"
}

resource "azurerm_lb_rule" "lb_rule" {
  loadbalancer_id                = azurerm_lb.my_lb.id
  name                           = "HTTP-Rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 5000
  frontend_ip_configuration_name = "PublicIPAddress"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.backend_pool.id]
}

import {
  to = azurerm_log_analytics_workspace.logs
  id = "/subscriptions/${var.subscription_id}/resourceGroups/DevOps-Start/providers/Microsoft.OperationalInsights/workspaces/devops-logs-workspace"
}

resource "azurerm_log_analytics_workspace" "logs" {
  name                = "devops-logs-workspace"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}

resource "azurerm_container_group" "my_app" {
  count               = 2
  name                = "devops-server-${count.index}"
  location            = azurerm_resource_group.my_rg.location
  resource_group_name = azurerm_resource_group.my_rg.name
  ip_address_type     = "Private"
  os_type             = "Linux"
  subnet_ids          = [azurerm_subnet.aci_subnet.id]

  container {
    name   = "web-app"
    image  = "devops2026.azurecr.io/my-image-name:${var.container_image_tag}"
    cpu    = "0.5"
    memory = "1.5"

    ports {
      port     = 5000
      protocol = "TCP"
    }
  }

  image_registry_credential {
    server   = "devops2026.azurecr.io"
    username = "devops2026"
    password = var.registry_password
  }

  diagnostics {
    log_analytics {
      workspace_id  = azurerm_log_analytics_workspace.logs.workspace_id
      workspace_key = azurerm_log_analytics_workspace.logs.primary_shared_key
    }
  }
}

resource "azurerm_lb_backend_address_pool_address" "app_address" {
  count                   = 2
  name                    = "app-ip-${count.index}"
  backend_address_pool_id = azurerm_lb_backend_address_pool.backend_pool.id
  virtual_network_id      = azurerm_virtual_network.vnet.id
  ip_address              = azurerm_container_group.my_app[count.index].ip_address
}

output "load_balancer_ip" {
  value = azurerm_public_ip.lb_pip.ip_address
}
