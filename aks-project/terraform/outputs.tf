# Output the path to the generated kubeconfig file
output "kubeconfig" {
  value = local_file.kubeconfig.filename
}

# Output the path to the generated SSH private key file
output "ssh_private_key_path" {
  value = local_file.private_key.filename
}

# Output the name of the AKS cluster
output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}
