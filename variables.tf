# see https://github.com/siderolabs/talos/releases
# see https://www.talos.dev/v1.9/introduction/support-matrix/
variable "talos_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/talos
  default = "1.9.1"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.talos_version))
    error_message = "Must be a version number."
  }
}

# see https://github.com/siderolabs/kubelet/pkgs/container/kubelet
# see https://www.talos.dev/v1.9/introduction/support-matrix/
variable "kubernetes_version" {
  type = string
  # renovate: datasource=github-releases depName=siderolabs/kubelet
  default = "1.31.4"
  validation {
    condition     = can(regex("^\\d+(\\.\\d+)+", var.kubernetes_version))
    error_message = "Must be a version number."
  }
}

variable "cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "cluster0"
}

variable "cluster_vip" {
  description = "The virtual IP (VIP) address of the Kubernetes API server. Ensure it is synchronized with the 'cluster_endpoint' variable."
  type        = string
  default     = "10.17.4.9"
}

variable "cluster_endpoint" {
  description = "The virtual IP (VIP) endpoint of the Kubernetes API server. Ensure it is synchronized with the 'cluster_vip' variable."
  type        = string
  default     = "https://10.17.4.9:6443"
}

variable "cluster_node_network" {
  description = "The IP network of the cluster nodes"
  type        = string
  default     = "10.17.4.0/24"
}
variable "cluster_node_gateway" {
  description = "The IP gateway of the cluster nodes"
  type        = string
  default     = "10.17.4.1"
}
variable "cluster_node_host" {
  description = "Hostname of the cluster host"
  type        = string
  default     = "tanzen2.tanzen.dev"
}

variable "cluster_node_network_first_controller_hostnum" {
  description = "The hostnum of the first controller host"
  type        = number
  default     = 80
}

variable "cluster_node_network_first_worker_hostnum" {
  description = "The hostnum of the first worker host"
  type        = number
  default     = 90
}

variable "cluster_node_network_load_balancer_first_hostnum" {
  description = "The hostnum of the first load balancer host"
  type        = number
  default     = 130
}

variable "cluster_node_network_load_balancer_last_hostnum" {
  description = "The hostnum of the last load balancer host"
  type        = number
  default     = 230
}

variable "cluster_node_domain" {
  description = "the DNS domain of the cluster nodes"
  type        = string
  default     = "tanzen.one"
}

variable "ingress_domain" {
  description = "the DNS domain of the ingress resources"
  type        = string
  default     = "tanzen.dev"
}

variable "controller_count" {
  type    = number
  default = 1
  validation {
    condition     = var.controller_count >= 1
    error_message = "Must be 1 or more."
  }
}
variable "controller_disk_size" {
  type    = number
  default = 15
  validation {
    condition     = var.controller_disk_size >= 10
    error_message = "Must be 10 or more."
  }
}
variable "controller_cpu_count" {
  type    = number
  default = 2
  validation {
    condition     = var.controller_cpu_count >= 1
    error_message = "Must be 1 or more."
  }
}
variable "controller_memory" {
  type    = number
  default = 4
  validation {
    condition     = var.controller_memory >= 2
    error_message = "Must be 4 or more."
  }
}

variable "worker_count" {
  type    = number
  default = 1
  validation {
    condition     = var.worker_count >= 0
    error_message = "Must be 0 or more."
  }
}
variable "worker_disk_size" {
  type    = number
  default = 40
  validation {
    condition     = var.worker_disk_size >= 10
    error_message = "Must be 10 or more."
  }
}
variable "worker_disk0_size" {
  type    = number
  default = 190
  validation {
    condition     = var.worker_disk0_size >= 10
    error_message = "Must be 10 or more."
  }
}
variable "worker_cpu_count" {
  type    = number
  default = 6
  validation {
    condition     = var.worker_cpu_count >= 1
    error_message = "Must be 1 or more."
  }
}
variable "worker_memory" {
  type    = number
  default = 30
  validation {
    condition     = var.worker_memory >= 4
    error_message = "Must be 4 or more."
  }
}

variable "talos_libvirt_base_volume_name" {
  type    = string
  default = "talos-1.9.1.qcow2"
  validation {
    condition     = can(regex(".+\\.qcow2+$", var.talos_libvirt_base_volume_name))
    error_message = "Must be a name with a .qcow2 extension."
  }
}

variable "prefix" {
  type    = string
  default = "tanzen"
}

#variable "enable_privileged" {
#  type    = bool
#  default = true
#}
