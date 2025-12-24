# Packer Alpine BlueTeam Router (Proxmox)

Mục tiêu:
- Tạo template Alpine Router cho BlueTeam (FRRouting + nftables NAT)
- SSH truy cập bằng KEY (không cần password)

## 1) Sửa `http/answers`
- Thay `ROOTSSHKEY="ssh-ed25519 ... REPLACE_ME ..."` bằng PUBLIC KEY thật.

> Lưu ý: `setup-alpine` hỗ trợ ROOTSSHKEY/USERSSHKEY trong answerfile. (xem Alpine wiki)

## 2) Sửa `blueteam.auto.pkrvars.hcl`
- `proxmox_url`, `proxmox_username`, `proxmox_token`, `proxmox_node`
- `wan_bridge/transit_bridge/dmz_bridge/blue_bridge`
- `wan_ip_cidr`, `wan_gateway`, `ssh_host`
- `ssh_private_key_file` phải là private key tương ứng ROOTSSHKEY

## 3) Build
```bash
packer init .
packer build -var-file=blueteam.auto.pkrvars.hcl blueteam-router.pkr.hcl
```

## 4) Sau khi ra template
- Clone VM mới từ template
- Nếu bạn cần chỉnh rule firewall/nftables hoặc FRR OSPF, sửa trong:
  - `/etc/nftables.conf`
  - `/etc/frr/frr.conf`
