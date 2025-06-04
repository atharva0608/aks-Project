output "kubeconfig" {
  value = local_file.kubeconfig.filename
}

output "ssh_private_key_path" {
  value = local_file.private_key.filename
}

output "aks_name" {
  value = azurerm_kubernetes_cluster.aks.name
}
