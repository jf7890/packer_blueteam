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
  # ISO – AUTO DOWNLOAD (boot_iso block)
  # =========================
  boot_iso {
    type             = "scsi"
    iso_url          = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-standard-3.23.2-x86_64.iso"
    iso_checksum     = "sha256:1b8be1ce264bf50048f2c93d8b4e72dd0f791340090aaed022b366b9a80e3518"
    iso_storage_pool = "hdd-data"
    # iso_download_pve = true  # (optional) để PVE node tự download thay vì máy chạy packer
    unmount          = true
  }

  # =========================
  # VM hardware
  # =========================
  cores    = var.cpu_cores
  sockets  = 1
  cpu_type = "host"
  memory   = var.memory_mb

  os   = "l26"
  bios = "seabios"

  # IMPORTANT: required if disks.io_thread = true
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = false  # dùng ssh_host tĩnh

  # =========================
  # Disk
  # =========================
  disks {
    type         = "scsi"
    disk_size    = var.disk_size
    storage_pool = var.disk_storage_pool

    # LVM-thin thường hợp nhất với raw hơn qcow2 (an toàn cho nhiều loại storage)
    format     = "raw"
    cache_mode = "none"

    io_thread = true
    discard   = true
  }

  # =========================
  # Network adapters (ORDER IS IMPORTANT)
  # =========================
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

  # =========================
  # Packer HTTP server: serve ./http/*
  # =========================
  http_directory = "http"

  # =========================
  # Boot & unattended install
  # =========================
  boot_wait = "10s"
  boot_command = [
    "<enter><wait>",
    "root<enter><wait>",

    # Bring up WAN in live ISO so we can fetch answerfile
    "ip link set ${var.live_wan_iface} up<enter>",
    "ip addr add ${var.wan_ip_cidr} dev ${var.live_wan_iface}<enter>",
    "ip route add default via ${var.wan_gateway}<enter>",
    "echo nameserver ${var.dns_server} > /etc/resolv.conf<enter>",

    # Fetch answerfile from Packer HTTP
    "wget -O /tmp/answers http://{{ .HTTPIP }}:{{ .HTTPPort }}/${var.answerfile_name}<enter>",

    # Non-interactive install (SCSI disk thường là /dev/sda)
    "ERASE_DISKS=/dev/sda setup-alpine -e -f /tmp/answers<enter>",

    "<wait5m>",
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
