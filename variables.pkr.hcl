variable "template_prefix" {
  type        = string
  default     = "tpl"
  description = "Prefix tên template"
}

variable "hostname" {
  type        = string
  default     = "blue-router"
  description = "Hostname (cũng dùng để ghép tên template)"
}

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

# VM sizing
variable "disk_storage_pool" {
  type        = string
  description = "Proxmox storage pool for the VM disk (e.g. local-lvm, hdd-lvm)."
}

variable "disk_size" {
  type        = string
  default     = "8G"
  description = "VM disk size, e.g. 8G"
}

variable "cpu_cores" {
  type        = number
  default     = 2
  description = "Number of vCPU cores"
}

variable "memory_mb" {
  type        = number
  default     = 2048
  description = "Memory in MB"
}

# portable options
variable "iso_storage_pool" {
  type        = string
  description = "Proxmox storage pool to store the downloaded ISO (e.g. hdd-data)."
}

variable "wan_bridge" {
  type        = string
  description = "Proxmox bridge for WAN (net0), often differs by system."
}

variable "cloud_init_storage_pool" {
  type        = string
  default     = "local-lvm"
  description = "Storage pool to store the Cloud-Init CDROM."
}

# live ISO minimal
variable "dns_server" {
  type        = string
  default     = "1.1.1.1"
  description = "DNS used in live ISO to fetch answerfile (DHCP may overwrite later)."
}

variable "ssh_private_key_file" {
  type        = string
  description = "Private key path that matches ROOTSSHKEY in http/answers."
}

variable "answerfile_name" {
  type        = string
  default     = "answers"
  description = "Filename inside http/ used as setup-alpine answerfile."
}
