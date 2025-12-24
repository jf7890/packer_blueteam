variable "proxmox_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://pve:8006/api2/json"
}

variable "proxmox_username" {
  type        = string
  description = "Proxmox username incl. realm. For token auth: user@realm!tokenid"
}

variable "proxmox_token" {
  type        = string
  sensitive   = true
  description = "Proxmox API token secret (NOT the token id)."
}

variable "proxmox_node" {
  type        = string
  description = "Proxmox node name to build on."
}

variable "proxmox_insecure_skip_tls_verify" {
  type        = bool
  default     = true
  description = "Skip TLS verify for Proxmox API."
}

variable "vm_id" {
  type        = number
  default     = 0
  description = "Optional fixed VMID. Set 0 to auto-assign."
}

variable "template_prefix" {
  type        = string
  default     = "tpl"
}

variable "hostname" {
  type        = string
  default     = "alpine-blue-router"
}

variable "iso_file" {
  type        = string
  description = "Proxmox ISO path, e.g. local:iso/alpine-standard-3.20.3-x86_64.iso"
}

variable "iso_checksum" {
  type        = string
  default     = ""
  description = "Optional checksum, e.g. sha256:.... Leave empty to skip."
}

variable "disk_storage_pool" {
  type        = string
  default     = "local-lvm"
}

variable "disk_size" {
  type        = string
  default     = "8G"
}

variable "cpu_cores" {
  type        = number
  default     = 2
}

variable "memory_mb" {
  type        = number
  default     = 512
}

variable "wan_bridge"     { type = string }
variable "transit_bridge" { type = string }
variable "dmz_bridge"     { type = string }
variable "blue_bridge"    { type = string }

# Live ISO bootstrapping (to fetch answerfile)
variable "live_wan_iface" {
  type        = string
  default     = "eth0"
  description = "Interface name in the live ISO environment (usually eth0)."
}

variable "wan_ip_cidr" {
  type        = string
  description = "WAN IP/CIDR for the Blue router (also used during live ISO bootstrap), e.g. 10.10.100.2/24"
}

variable "wan_gateway" {
  type        = string
  description = "WAN gateway, e.g. 10.10.100.1"
}

variable "dns_server" {
  type        = string
  default     = "1.1.1.1"
}

variable "ssh_host" {
  type        = string
  description = "IP that Packer will SSH to after install (usually same as WAN IP without /mask), e.g. 10.10.100.2"
}

variable "ssh_private_key_file" {
  type        = string
  description = "Private key path that matches ROOTSSHKEY in http/answers (e.g. ~/.ssh/id_ed25519)."
}

variable "answerfile_name" {
  type        = string
  default     = "answers"
  description = "Filename inside http/ used as setup-alpine answerfile."
}
