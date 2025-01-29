# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/network.markdown
resource "libvirt_network" "talos" {
  name      = var.prefix
  mode      = "nat"
  domain    = var.cluster_node_domain
  addresses = [var.cluster_node_network]
  autostart = true
  dhcp {
    enabled = true
  }
  dns {
    enabled    = true
    local_only = false
  }
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/volume.html.markdown
resource "libvirt_volume" "controller" {
  count            = var.controller_count
  name             = "${var.prefix}_c${count.index}.img"
  base_volume_name = var.talos_libvirt_base_volume_name
  format           = "qcow2"
  size             = var.controller_disk_size * 1024 * 1024 * 1024
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/volume.html.markdown
resource "libvirt_volume" "worker" {
  count            = var.worker_count
  name             = "${var.prefix}_w${count.index}.img"
  base_volume_name = var.talos_libvirt_base_volume_name
  format           = "qcow2"
  size             = var.worker_disk_size * 1024 * 1024 * 1024
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/volume.html.markdown
resource "libvirt_volume" "worker_data0" {
  count  = var.worker_count
  name   = "${var.prefix}_w${count.index}d0.img"
  format = "qcow2"
  size   = var.worker_disk0_size * 1024 * 1024 * 1024 # 32GiB.
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/domain.html.markdown
resource "libvirt_domain" "controller" {
  count      = var.controller_count
  name       = "${var.prefix}_${local.controller_nodes[count.index].name}"
  qemu_agent = false
  machine    = "q35"
  firmware   = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = var.controller_cpu_count
  memory = var.controller_memory * 1024
  autostart = true
  video {
    type = "qxl"
  }
  disk {
    volume_id = libvirt_volume.controller[count.index].id
    scsi      = true
  }
  network_interface {
    network_id     = libvirt_network.talos.id
    addresses      = [local.controller_nodes[count.index].address]
    wait_for_lease = true
  }
  lifecycle {
    ignore_changes = [
      nvram,
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.8.1/website/docs/r/domain.html.markdown
resource "libvirt_domain" "worker" {
  count      = var.worker_count
  name       = "${var.prefix}_${local.worker_nodes[count.index].name}"
  qemu_agent = false
  machine    = "q35"
  firmware   = "/usr/share/OVMF/OVMF_CODE_4M.fd"
  cpu {
    mode = "host-passthrough"
  }
  vcpu   = var.worker_cpu_count
  memory = var.worker_memory * 1024
  autostart = true
  video {
    type = "qxl"
  }
  disk {
    volume_id = libvirt_volume.worker[count.index].id
    scsi      = true
  }
  disk {
    volume_id = libvirt_volume.worker_data0[count.index].id
    scsi      = true
    wwn       = format("000000000000ab%02x", count.index)
  }
  network_interface {
    network_id     = libvirt_network.talos.id
    addresses      = [local.worker_nodes[count.index].address]
    wait_for_lease = true
  }
  lifecycle {
    ignore_changes = [
      nvram,
      disk[0].wwn,
      network_interface[0].addresses,
    ]
  }
}
