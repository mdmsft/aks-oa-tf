terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "2.98.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.8.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "mdmsft"
    storage_account_name = "mdmsft"
    container_name       = "tfstate"
    key                  = "reykjavik"
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = local.context_name
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

variable "address_space" {
  type    = string
  default = "10.10.0.0/16"
}

locals {
  resource_suffix        = "${var.project}-${var.environment}-${var.location}"
  context_name           = "${var.project}-${var.environment}"
  azure_secret_name      = "azure-secret"
  persistent_volume_name = "pv-azure-file"
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

resource "azurerm_storage_share" "main" {
  name                 = "main"
  storage_account_name = azurerm_storage_account.main.name
}

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_suffix}"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.address_space]
}

resource "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  virtual_network_name = azurerm_virtual_network.main.name
  resource_group_name  = azurerm_resource_group.main.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 0)] # 10.10.0.0/24
}

resource "azurerm_subnet" "agw" {
  name                 = "snet-agw"
  virtual_network_name = azurerm_virtual_network.main.name
  resource_group_name  = azurerm_resource_group.main.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 1)] # 10.10.1.0/24
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
    vnet_subnet_id               = azurerm_subnet.aks.id
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

  network_profile {
    network_plugin = "azure"
    network_policy = "azure"
  }

  ingress_application_gateway {
    gateway_id = azurerm_application_gateway.main.id
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
  availability_zones    = ["1", "2", "3"]
  vnet_subnet_id        = azurerm_subnet.aks.id

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
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
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

resource "azurerm_managed_disk" "main" {
  name                 = "disk-${local.resource_suffix}"
  location             = var.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 64
  zones                = ["1"]
}

resource "azurerm_role_assignment" "aks_disk_pool_operator" {
  role_definition_name = "Disk Pool Operator"
  scope                = azurerm_managed_disk.main.id
  principal_id         = azurerm_kubernetes_cluster.main.identity.0.principal_id
}

resource "azurerm_role_assignment" "aks_network_contributor" {
  role_definition_name = "Network Contributor"
  scope                = azurerm_subnet.aks.id
  principal_id         = azurerm_kubernetes_cluster.main.identity.0.principal_id
}

resource "azurerm_role_assignment" "agw" {
  for_each = {
    "Contributor" = azurerm_application_gateway.main.id
    "Reader"      = azurerm_resource_group.main.id
  }
  scope                = each.value
  role_definition_name = each.key
  principal_id         = azurerm_kubernetes_cluster.main.addon_profile[0].ingress_application_gateway[0].ingress_application_gateway_identity[0].object_id
}

# resource "null_resource" "get_credentials" {
#   depends_on = [
#     azurerm_kubernetes_cluster_node_pool.main
#   ]

#   provisioner "local-exec" {
#     command = "az aks get-credentials --name ${azurerm_kubernetes_cluster.main.name} --resource-group ${azurerm_resource_group.main.name} --context ${local.context_name} --overwrite-existing"
#   }
# }

# resource "null_resource" "convert_kubeconfig" {
#   depends_on = [
#     null_resource.get_credentials
#   ]

#   provisioner "local-exec" {
#     command = "kubelogin convert-kubeconfig -l azurecli"
#   }
# }

# resource "kubernetes_secret_v1" "azure_secret" {
#   depends_on = [
#     null_resource.convert_kubeconfig
#   ]

#   metadata {
#     name = local.azure_secret_name
#   }

#   data = {
#     azurestorageaccountname = azurerm_storage_account.main.name
#     azurestorageaccountkey  = azurerm_storage_account.main.primary_access_key
#   }
# }

# resource "kubernetes_persistent_volume_v1" "azure_file" {
#   depends_on = [
#     kubernetes_secret_v1.azure_secret
#   ]

#   metadata {
#     name = local.persistent_volume_name
#   }

#   spec {
#     capacity = {
#       storage = "1Ti"
#     }

#     access_modes                     = ["ReadWriteMany"]
#     persistent_volume_reclaim_policy = "Retain"

#     persistent_volume_source {
#       csi {
#         driver        = "file.csi.azure.com"
#         read_only     = false
#         volume_handle = md5(local.persistent_volume_name)

#         volume_attributes = {
#           resourceGroup = azurerm_resource_group.main.name
#           shareName     = azurerm_storage_share.main.name
#         }

#         node_stage_secret_ref {
#           name      = kubernetes_secret_v1.azure_secret.metadata.0.name
#           namespace = kubernetes_secret_v1.azure_secret.metadata.0.namespace
#         }
#       }
#     }
#   }
# }

resource "azurerm_container_registry" "main" {
  name                   = "cr${var.project}${var.environment}${var.location}"
  resource_group_name    = azurerm_resource_group.main.name
  location               = var.location
  admin_enabled          = false
  sku                    = "Basic"
  anonymous_pull_enabled = false
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.main.id
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity.0.object_id
}

output "disk_id" {
  value = azurerm_managed_disk.main.id
}

output "registry_name" {
  value = azurerm_container_registry.main.name
}
