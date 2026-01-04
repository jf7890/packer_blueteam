proxmox_url      = "https://10.10.100.1:8006/api2/json"
proxmox_username = "root@pam!packer"
proxmox_token    = "28786dd2-1eed-44e6-b8a4-dc2221ce384d"
proxmox_node     = "homelab"
proxmox_insecure_skip_tls_verify = true
vm_id = 0

cpu_cores = 2
memory_mb = 2048

disk_storage_pool = "hdd-lvm"
disk_size         = "8G"

template_prefix = "tpl"
hostname        = "blue-router"

iso_storage_pool        = "hdd-data"
wan_bridge              = "vmbr10"
cloud_init_storage_pool = "local-lvm"

dns_server = "1.1.1.1"
pri_key = ""
pub_key = ""
answerfile_name = "answers"