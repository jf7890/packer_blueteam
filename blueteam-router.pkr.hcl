packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

locals {
  template_name = "${var.template_prefix}-${var.hostname}"
}

source "proxmox-iso" "blueteam_router" {
  proxmox_url              = var.proxmox_url
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  username = var.proxmox_username
  token    = var.proxmox_token

  node = var.proxmox_node

  vm_id   = var.vm_id
  vm_name = local.template_name

  template_name        = local.template_name
  template_description = "Alpine BlueTeam Router (FRR + nftables NAT + key-only SSH)"

  tags = "alpine;router;blueteam;template"

  source "proxmox-iso" "blueteam_router" {

  iso_url          = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-standard-3.23.2-x86_64.iso"
  iso_checksum     = "file:https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-standard-3.23.2-x86_64.iso.sha256"

  iso_storage_pool = "hdd-data"
  unmount_iso      = true

}

  # VM hardware
  cores    = var.cpu_cores
  sockets  = 1
  cpu_type = "host"
  memory   = var.memory_mb
  os       = "l26"
  bios     = "seabios"

  scsi_controller = "virtio-scsi-pci"
  qemu_agent      = false  # We use a static ssh_host instead of QGA.

  # Disk
  disks {
    type              = "scsi"
    disk_size         = var.disk_size
    storage_pool      = var.disk_storage_pool
    format            = "qcow2"
    cache_mode        = "none"
    io_thread         = true
    discard           = true
  }

  # NIC order matters (be consistent with your Proxmox VM order)
  network_adapters {
    model  = "virtio"
    bridge = var.wan_bridge
  }
  network_adapters {
    model  = "virtio"
    bridge = var.transit_bridge
  }
  network_adapters {
    model  = "virtio"
    bridge = var.dmz_bridge
  }
  network_adapters {
    model  = "virtio"
    bridge = var.blue_bridge
  }

  # Packer's built-in HTTP server serves the "http/" folder.
  http_directory = "http"

  boot_wait = "10s"
  boot_command = [
    "<enter><wait>",
    "root<enter><wait>",
    # Bring up WAN in the live ISO environment so we can fetch the answerfile.
    "ip link set ${var.live_wan_iface} up<enter>",
    "ip addr add ${var.wan_ip_cidr} dev ${var.live_wan_iface}<enter>",
    "ip route add default via ${var.wan_gateway}<enter>",
    "echo nameserver ${var.dns_server} > /etc/resolv.conf<enter>",
    "wget -O /tmp/answers http://{{ .HTTPIP }}:{{ .HTTPPort }}/${var.answerfile_name}<enter>",
    # WARNING: ERASE_DISKS will wipe the disk. This is what makes setup-alpine non-interactive.
    "ERASE_DISKS=/dev/vda setup-alpine -e -f /tmp/answers<enter>",
    "<wait5m>",
    "reboot<enter>"
  ]

  communicator = "ssh"
  ssh_username = "root"
  ssh_host     = var.ssh_host
  ssh_port     = 22
  ssh_timeout  = "25m"

  # Your private key that matches ROOTSSHKEY in http/answers
  ssh_private_key_file = var.ssh_private_key_file
}

build {
  sources = ["source.proxmox-iso.blueteam_router"]

  provisioner "shell" {
    script = "scripts/provision-blue.sh"
  }

  # Clean up Packer temporary keys if you ever add any later.
}
