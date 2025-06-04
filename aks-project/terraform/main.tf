terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.31"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.37"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Azure provider configuration
provider "azurerm" {
  features {}

  subscription_id = "efa46ddd-af51-47f4-8bcc-28214441907e"
  tenant_id       = "d147d2e3-dc24-4b31-a561-07742c441579"
}

# Helm provider config using AKS cluster kubeconfig
provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  }
}

# Kubernetes provider config using AKS cluster kubeconfig
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
}

# Generate an SSH keypair (RSA 4096 bits)
resource "tls_private_key" "ssh_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Save private key locally with permission 0600
resource "local_file" "private_key" {
  content         = tls_private_key.ssh_key.private_key_pem
  filename        = "${path.module}/ssh/id_rsa"
  file_permission = "0600"
}

# Save public key locally
resource "local_file" "public_key" {
  content  = tls_private_key.ssh_key.public_key_openssh
  filename = "${path.module}/ssh/id_rsa.pub"
}

# Create an Azure resource group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Create a virtual network in the resource group
resource "azurerm_virtual_network" "vnet" {
  name                = "prod-vnet"
  address_space       = ["10.0.0.0/8"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

# Create a subnet within the virtual network for AKS
resource "azurerm_subnet" "aks_subnet" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.240.0.0/16"]
}

# Provision AKS cluster with system-assigned managed identity
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "prod-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  dns_prefix          = "prodaks"

  default_node_pool {
    name            = "default"
    vm_size         = "Standard_B2s"
    vnet_subnet_id  = azurerm_subnet.aks_subnet.id
    os_disk_size_gb = 100
    node_count      = 2
  }

  identity {
    type = "SystemAssigned"
  }

  linux_profile {
    admin_username = "azureuser"

    ssh_key {
      key_data = tls_private_key.ssh_key.public_key_openssh
    }
  }

  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = "loadBalancer"
  }

  tags = {
    environment = "production"
  }
}

# Save AKS cluster kubeconfig locally
resource "local_file" "kubeconfig" {
  content  = azurerm_kubernetes_cluster.aks.kube_config_raw
  filename = "${path.module}/kubeconfig"
}

# Deploy Consul Helm chart with reduced resources for 2-node cluster
resource "helm_release" "consul" {
  name             = "consul"
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "consul"
  version          = "1.5.0"
  namespace        = "consul"
  create_namespace = true
  timeout          = 900  # 15 minutes timeout
  wait             = true
  wait_for_jobs    = true
  cleanup_on_fail  = true
  force_update     = true

  values = [
    yamlencode({
      global = {
        name       = "consul"
        datacenter = "dc1"
      }
      server = {
        replicas       = 1           # Single server for resource constraints
        bootstrapExpect = 1
        storage       = "5Gi"        # Reduced storage size
        storageClass  = "default"
        resources = {
          requests = {
            memory = "200Mi"
            cpu    = "100m"
          }
          limits = {
            memory = "500Mi"
            cpu    = "500m"
          }
        }
      }
      client = {
        enabled = true
        resources = {
          requests = {
            memory = "100Mi"
            cpu    = "50m"
          }
          limits = {
            memory = "200Mi"
            cpu    = "200m"
          }
        }
      }
      ui = {
        enabled = true
        service = {
          type = "LoadBalancer"
        }
      }
      connectInject = {
        enabled = true
        resources = {
          requests = {
            memory = "50Mi"
            cpu    = "25m"
          }
          limits = {
            memory = "100Mi"
            cpu    = "100m"
          }
        }
      }
    })
  ]

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}

# Deploy APISIX Helm chart with minimal config to avoid StatefulSet issues
resource "helm_release" "apisix" {
  name             = "apisix-new"  # Unique name to avoid conflict
  repository       = "https://charts.apiseven.com"
  chart            = "apisix"
  version          = "2.8.0"
  namespace        = "apisix"
  create_namespace = true
  timeout          = 900
  wait             = true
  cleanup_on_fail  = true

  values = [
    yamlencode({
      replicaCount = 1
      gateway = {
        type = "LoadBalancer"
      }
      admin = {
        enabled = true
        type    = "ClusterIP"
      }
      etcd = {
        enabled = true
        # Default etcd settings to avoid StatefulSet issues
      }
      resources = {
        requests = {
          memory = "200Mi"
          cpu    = "100m"
        }
        limits = {
          memory = "500Mi"
          cpu    = "500m"
        }
      }
    })
  ]

  depends_on = [
    azurerm_kubernetes_cluster.aks,
    helm_release.consul
  ]
}
