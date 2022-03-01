terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.98.0"
    }
  }
}

variable "client_id" {
  type = string
}

variable "client_secret" {
  type      = string
  sensitive = true
}

variable "tenant_id" {
  type = string
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "westeurope"
}

variable "project" {
  type    = string
  default = "reykjavik"
}

variable "environment" {
  type    = string
  default = "dev"
}

locals {
  resource_suffix = "${var.project}-${var.environment}-${var.location}"
}

provider "azurerm" {
  features {}
  client_id       = var.client_id
  client_secret   = var.client_secret
  tenant_id       = var.tenant_id
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_suffix}"
  location = var.location
  tags = {
    project     = var.project
    environment = var.environment
    location    = var.location
  }
}

resource "azurerm_kubernetes_cluster" "main" {
  name                      = "aks-${local.resource_suffix}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.main.name
  dns_prefix                = "${var.project}-${var.environment}"
  sku_tier                  = "Paid"
  automatic_channel_upgrade = "node-image"

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name                         = "default" # 1-11 Linux, 1-6 Windows
    vm_size                      = "Standard_DS2_v2"
    enable_auto_scaling          = true
    min_count                    = 3
    max_count                    = 6
    availability_zones           = ["1", "2", "3"]
    only_critical_addons_enabled = true
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "main" {
  name                  = "main"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_F4s_v2"
  enable_auto_scaling   = true
  min_count             = 2
  max_count             = 4
  max_pods              = 10

  node_labels = {
    "contoso.com" = "app"
  }

  upgrade_settings {
    max_surge = "33%"
  }
}

output "command" {
  value = "az aks get-credentials --name ${azurerm_kubernetes_cluster.main.name} --resource-group ${azurerm_resource_group.main.name} --context ${azurerm_kubernetes_cluster.main.dns_prefix}"
}
