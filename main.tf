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

variable "principal_id" {
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

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.resource_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
}

resource "azurerm_storage_account" "main" {
  name                      = "st${var.project}${var.environment}${var.location}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.main.name
  account_replication_type  = "LRS"
  account_tier              = "Standard"
  access_tier               = "Cool"
  allow_blob_public_access  = false
  enable_https_traffic_only = true
  min_tls_version           = "TLS1_2"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                      = "aks-${local.resource_suffix}"
  location                  = var.location
  resource_group_name       = azurerm_resource_group.main.name
  dns_prefix                = "${var.project}-${var.environment}"
  sku_tier                  = "Paid"
  automatic_channel_upgrade = "node-image"
  azure_policy_enabled      = true

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

  role_based_access_control {
    enabled = true

    azure_active_directory {
      managed                = true
      azure_rbac_enabled     = true
      admin_group_object_ids = []
    }
  }

  oms_agent {
    log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
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

resource "azurerm_monitor_diagnostic_setting" "aks" {
  name               = "default"
  target_resource_id = azurerm_kubernetes_cluster.main.id
  storage_account_id = azurerm_storage_account.main.id

  dynamic "log" {
    for_each = [
      "kube-apiserver",
      "kube-audit",
      "kube-audit-admin",
      "kube-controller-manager",
      "kube-scheduler"
    ]

    content {
      category = log.value
      enabled  = true

      retention_policy {
        enabled = true
        days    = 1
      }
    }
  }
}

resource "azurerm_role_assignment" "aks_rbac_reader" {
  role_definition_name = "Azure Kubernetes Service RBAC Writer"
  scope                = azurerm_kubernetes_cluster.main.id
  principal_id         = var.principal_id
}

resource "azurerm_resource_group_policy_assignment" "main" {
  policy_definition_id = "/providers/Microsoft.Authorization/policySetDefinitions/a8640138-9b0a-4a28-b8cb-1666c838647d"
  name                 = "k8s-pod-security-baseline-standards-for-linux-based-workloads"
  resource_group_id    = azurerm_resource_group.main.id
  parameters           = <<PARAMETERS
  {
    "effect": {
      "value": "deny"
    }
  }
  PARAMETERS
}

output "command" {
  value = "az aks get-credentials --name ${azurerm_kubernetes_cluster.main.name} --resource-group ${azurerm_resource_group.main.name} --context ${azurerm_kubernetes_cluster.main.dns_prefix}"
}
