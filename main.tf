terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.98.0"
    }
  }
}

variable "client_secret" {
  type      = string
  sensitive = true
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
  client_id       = "71d61b9c-20f4-4082-8095-55a701919a61"
  client_secret   = var.client_secret
  tenant_id       = "72f988bf-86f1-41af-91ab-2d7cd011db47"
  subscription_id = "6f3a143b-51cc-4a89-aa5a-3c98bb3f5e46"
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
  name                = "aks-${local.resource_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = "${var.project}-${var.environment}"

  identity {
    type = "SystemAssigned"
  }

  default_node_pool {
    name       = "default" # 1-11 Linux, 1-6 Windows
    vm_size    = "Standard_DS2_v2"
    node_count = 3
  }
}

output "command" {
  value = "az aks get-credentials --name ${azurerm_kubernetes_cluster.main.name} --resource-group ${azurerm_resource_group.main.name} --context ${azurerm_kubernetes_cluster.main.dns_prefix}"
}
