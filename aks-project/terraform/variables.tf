variable "resource_group_name" {
  default = "myAKSResourceGroup"
}

variable "location" {
  default = "Japan East"
}

variable "dns_prefix" {
  default = "myakscluster"
}

variable "node_count" {
  default = 1
}

variable "node_vm_size" {
  default = "Standard_B2s"
}
