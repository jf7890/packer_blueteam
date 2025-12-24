# =========================
# Proxmox connection
# =========================
variable "proxmox_url" { type = string }
variable "proxmox_username" { type = string }
variable "proxmox_token" { type = string, sensitive = true }
variable "proxmox_node" { type = string }

variable "proxmox_insecure_skip_tls_verify" {
  type    = bool
  default = true
}

variable "vm_id" {
  type    = number
  default = 0
}

# =========================
# ISO download (public source)
# =========================
variable "iso_url" {
  type    = string
  default = "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/x86_64/alpine-standard-3.23.2-x86_64.iso"
}

# Packer checksum format thường là "sha256:<hash>"
variable "iso_checksum" {
  type = string
}

variable "iso_storage_pool" {
  type    = string
  default = "hdd-data"
}

variable "iso_download_pve" {
  type    = bool
  default = true
}

variable "unmount_iso" {
  type    = bool
  default = true
}

# =========================
# VM sizing
# =========================
variable "disk_storage_pool" { type = string }
variable "disk_size" { type = string }
variable "cpu_cores" { type = number }
variable "memory_mb" { type = number }

variable "template_prefix" { type = string, default = "tpl" }
variable "hostname" { type = string, default = "blue-router" }

# =========================
# Bridges
# =========================
variable "wan_bridge"     { type = string }
variable "transit_bridge" { type = string }
variable "dmz_bridge"     { type = string }
variable "blue_bridge"    { type = string }

# =========================
# Live ISO bootstrap network
# =========================
variable "live_wan_iface" { type = string, default = "eth0" }
variable "wan_ip_cidr" { type = string }
variable "wan_gateway" { type = string }
variable "dns_server" { type = string, default = "1.1.1.1" }

# =========================
# SSH for packer provision
# =========================
variable "ssh_host" { type = string }
variable "ssh_private_key_file" { type = string }

variable "answerfile_name" {
  type    = string
  default = "answers"
}
