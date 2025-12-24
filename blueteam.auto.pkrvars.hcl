# =========================
# Proxmox connection
# =========================
proxmox_url      = "https://10.10.100.1:8006/api2/json"
proxmox_username = "root@pam!packer"
proxmox_token    = "28786dd2-1eed-44e6-b8a4-dc2221ce384d"
proxmox_node     = "pve"

# Optional
proxmox_insecure_skip_tls_verify = true
vm_id = 0

# =========================
# VM sizing
# =========================
disk_storage_pool = "hdd-lvm"
disk_size         = "8G"
cpu_cores         = 2
memory_mb         = 2048

template_prefix = "tpl"
hostname        = "blue-router"

# =========================
# Bridges (match your Proxmox vmbr)
# =========================
wan_bridge     = "vmbr10"
transit_bridge = "transit"
dmz_bridge     = "dmz"
blue_bridge    = "blue"

# =========================
# Blue router WAN (also used during LIVE-ISO bootstrap)
# =========================
live_wan_iface = "eth0"
wan_ip_cidr    = "10.10.100.21/24"
wan_gateway    = "10.10.100.1"
dns_server     = "1.1.1.1"

# Packer will SSH to this after install:
ssh_host = "10.10.100.21"

# IMPORTANT: private key corresponding to ROOTSSHKEY in http/answers
ssh_private_key_file = "~/.ssh/id_ed25519"

# answerfile file name under http/
answerfile_name = "answers"
