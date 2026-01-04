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
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node

  vm_id   = var.vm_id
  vm_name = local.template_name

  template_name        = local.template_name
  template_description = "Alpine BlueTeam Router (FRR + nftables NAT + key-only SSH)"
  tags                 = "alpine;router;blueteam;template"

  # =========================
  # Boot ISO (download từ public source)
  # =========================
  boot_iso {
    type             = "scsi"
    iso_url          = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-virt-3.23.2-x86_64.iso"
    iso_checksum     = "file:https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-virt-3.23.2-x86_64.iso.sha256"
    iso_storage_pool = var.iso_storage_pool

    # Cho PVE tự download ISO (đỡ upload/broken pipe)
    iso_download_pve = true
    unmount          = true
  }

  # =========================
  # VM hardware
  # =========================
  cores           = var.cpu_cores
  sockets         = 1
  cpu_type        = "host"
  memory          = var.memory_mb
  os              = "l26"
  bios            = "seabios"
  scsi_controller = "virtio-scsi-single"
  qemu_agent      = true

  # Packer lấy IP từ NIC nào (DHCP)
  vm_interface = "eth0"

  # =========================
  # Disk
  # =========================
  disks {
    type         = "scsi"
    disk_size    = var.disk_size
    storage_pool = var.disk_storage_pool
    format       = "raw"
    cache_mode   = "none"
    io_thread    = true
    discard      = true
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
    bridge = "transit"
  }
  network_adapters {
    model  = "virtio"
    bridge = "dmz"
  }
  network_adapters {
    model  = "virtio"
    bridge = "blue"
  }

  # =========================
  # Packer HTTP server (serves ./http)
  # =========================
  http_content = {
    "/answers" = templatefile("${path.root}/http/answers.tpl", {
      pub_key = var.pub_key
      dns_server   = var.dns_server
      hostname     = var.hostname
    })
  }

  # =========================
  # Boot & unattended install (WAN DHCP)
  # =========================
  boot_wait = "10s"

  boot_command = [
    "<enter><wait>",
    "root<enter><wait>",

    "ip link set eth0 up<enter>",
    "udhcpc -i eth0<enter>",

    # nếu DHCP chưa set resolv.conf kịp thì ép tạm DNS để wget answerfile
    "echo nameserver ${var.dns_server} > /etc/resolv.conf<enter>",

    "wget -O /tmp/answers http://{{ .HTTPIP }}:{{ .HTTPPort }}/answers<enter>",

    # Cài Alpine + cài qemu-guest-agent vào hệ đã cài để Packer lấy IP qua QGA
    "ERASE_DISKS=/dev/sda setup-alpine -e -f /tmp/answers && mount /dev/sda3 /mnt && apk add --root /mnt qemu-guest-agent && chroot /mnt rc-update add qemu-guest-agent default && reboot<enter>",
  ]

  # =========================
  # SSH communicator
  # - KHÔNG set ssh_host vì DHCP + qemu_agent sẽ lấy IP
  # =========================
  communicator          = "ssh"
  ssh_username          = "root"
  ssh_port              = 22
  ssh_timeout           = "25m"
  ssh_private_key_file  = pathexpand(var.pri_key)

  # =========================
  # Cloud-init CDROM (rỗng) sau khi convert template
  # =========================
  cloud_init              = true
  cloud_init_storage_pool = var.cloud_init_storage_pool
}

build {
  sources = ["source.proxmox-iso.blueteam_router"]

  provisioner "shell" {
    script = "scripts/provision-blue.sh"
  }
}
