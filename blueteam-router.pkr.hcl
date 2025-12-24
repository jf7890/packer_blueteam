packer {
  required_plugins {
    proxmox = {
      source  = "github.com/hashicorp/proxmox"
      version = ">= 1.2.0"
    }
  }
}

locals {
  template_name = "${var.template_prefix}-${var.hostname}"
}

source "proxmox-iso" "blueteam_router" {
  # =========================
  # Proxmox connection
  # =========================
  proxmox_url              = var.proxmox_url
  insecure_skip_tls_verify = var.proxmox_insecure_skip_tls_verify

  username = var.proxmox_username
  token    = var.proxmox_token
  node     = var.proxmox_node

  vm_id   = var.vm_id
  vm_name = local.template_name

  template_name        = local.template_name
  template_description = "Alpine BlueTeam Router (FRR + nftables NAT + key-only SSH)"
  tags                 = "alpine;router;blueteam;template"

  # =========================
  # ISO (NEW STYLE) - Proxmox tự download để né upload broken pipe
  # =========================
  boot_iso {
    type             = "scsi"
    iso_url          = var.iso_url
    iso_checksum     = var.iso_checksum
    iso_storage_pool = var.iso_storage_pool
    iso_download_pve = var.iso_download_pve
    unmount          = var.unmount_iso
  } # theo plugin docs :contentReference[oaicite:2]{index=2}

  # =========================
  # VM hardware
  # =========================
  cores    = var.cpu_cores
  sockets  = 1
  cpu_type = "host"
  memory   = var.memory_mb

  os   = "l26"
  bios = "seabios"

  # FIX lỗi io_thread: dùng virtio-scsi-single
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = false

  # =========================
  # Disk
  # =========================
  disks {
    type         = "scsi"
    storage_pool = var.disk_storage_pool
    disk_size    = var.disk_size
    format       = "qcow2"
    cache_mode   = "none"
    io_thread    = true
    discard      = true
  }

  # =========================
  # Network adapters (ORDER matters)
  # =========================
  network_adapters { model = "virtio" bridge = var.wan_bridge }
  network_adapters { model = "virtio" bridge = var.transit_bridge }
  network_adapters { model = "virtio" bridge = var.dmz_bridge }
  network_adapters { model = "virtio" bridge = var.blue_bridge }

  # =========================
  # Packer HTTP server serves ./http
  # =========================
  http_directory = "http"

  # =========================
  # Boot & unattended install
  # =========================
  boot_wait = "10s"

  boot_command = [
    "<enter><wait>",
    "root<enter><wait>",

    # Bring up WAN trong live ISO để wget answerfile
    "ip link set ${var.live_wan_iface} up<enter>",
    "ip addr add ${var.wan_ip_cidr} dev ${var.live_wan_iface}<enter>",
    "ip route add default via ${var.wan_gateway}<enter>",
    "echo nameserver ${var.dns_server} > /etc/resolv.conf<enter>",

    "wget -O /tmp/answers http://{{ .HTTPIP }}:{{ .HTTPPort }}/${var.answerfile_name}<enter>",

    # NOTE:
    # - ERASE_DISKS dùng để khỏi hỏi confirm erase :contentReference[oaicite:3]{index=3}
    # - /dev/sda thường đúng với disk scsi (virtio-scsi-*)
    #   [Suy luận] Nếu máy bạn ra /dev/vda thì đổi lại /dev/vda.
    "ERASE_DISKS=/dev/sda setup-alpine -f /tmp/answers<enter>",

    # [Chưa xác minh] Nếu bản setup-alpine của bạn hỗ trợ -e (empty root password) thì đổi dòng trên thành:
    # "ERASE_DISKS=/dev/sda setup-alpine -e -f /tmp/answers<enter>",

    "<wait8m>",
    "reboot<enter>"
  ]

  # =========================
  # SSH for provisioning
  # =========================
  communicator         = "ssh"
  ssh_username         = "root"
  ssh_host             = var.ssh_host
  ssh_port             = 22
  ssh_timeout          = "25m"
  ssh_private_key_file = var.ssh_private_key_file
}

build {
  sources = ["source.proxmox-iso.blueteam_router"]

  provisioner "shell" {
    script = "scripts/provision-blue.sh"
  }
}
