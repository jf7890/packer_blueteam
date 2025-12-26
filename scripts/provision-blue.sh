#!/bin/ash
set -eux

echo "[+] Installing packages..."
apk update
apk add --no-cache \
  openssh \
  nftables \
  frr frr-openrc \
  iproute2 \
  curl \
  acpid \
  cloud-init \
  cloud-init-openrc \
  busybox-extras

# ---- SSH hardening: do NOT restart networking; minimize sshd restarts ----
echo "[+] Ensure sshd runtime dir exists..."
mkdir -p /var/run/sshd

echo "[+] Hardening SSH: key-only..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
  # set/replace if present
  sed -i \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
    "$SSHD_CFG" || true

  # append if missing
  grep -q '^PasswordAuthentication ' "$SSHD_CFG" || echo 'PasswordAuthentication no' >> "$SSHD_CFG"
  grep -q '^KbdInteractiveAuthentication ' "$SSHD_CFG" || echo 'KbdInteractiveAuthentication no' >> "$SSHD_CFG"
  grep -q '^ChallengeResponseAuthentication ' "$SSHD_CFG" || echo 'ChallengeResponseAuthentication no' >> "$SSHD_CFG"
  grep -q '^PubkeyAuthentication ' "$SSHD_CFG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CFG"
  grep -q '^PermitRootLogin ' "$SSHD_CFG" || echo 'PermitRootLogin prohibit-password' >> "$SSHD_CFG"
fi

rc-update add sshd default || true

# IMPORTANT: avoid restart that may drop SSH.
# Start if not running; if already running then try reload (if supported), otherwise ignore.
rc-service sshd start || true
rc-service sshd reload 2>/dev/null || true

# ---- NIC DOWN safety net: local.d (OK) ----
echo "[+] Force NIC links UP at boot via local.d..."
mkdir -p /etc/local.d
cat > /etc/local.d/ifup.start <<'EOF'
#!/bin/sh
for i in eth0 eth1 eth2 eth3; do
  ip link set "$i" up 2>/dev/null || true
done
EOF
chmod +x /etc/local.d/ifup.start
rc-update add local default || true

# DO NOT restart networking while Packer is SSH-ing.
# Only enable the service so next boot it comes up automatically.
rc-update add networking default || true
# (Optional) If you want eth0 UP right now, only bring link up; do NOT restart networking:
ip link set eth0 up 2>/dev/null || true

# ==========================================================
# [ADDED] Configure IP for NICs (tail .5) + persist
# - Do NOT touch eth0 runtime config (avoid dropping SSH)
# - Only set runtime + write /etc/network/interfaces for eth1/2/3
# ==========================================================
echo "[+] Configure IP for eth1/eth2/eth3 (tail .5) without restarting networking..."

# 1) Set runtime IP (safe: does not affect SSH session via eth0)
ip link set eth1 up 2>/dev/null || true
ip link set eth2 up 2>/dev/null || true
ip link set eth3 up 2>/dev/null || true

# Transit
ip addr replace 10.10.101.1/30 dev eth1 2>/dev/null || true
# DMZ
ip addr replace 172.16.50.1/24 dev eth2 2>/dev/null || true
# Blue LAN
ip addr replace 10.10.172.1/24 dev eth3 2>/dev/null || true

# 2) Persist into /etc/network/interfaces (rewrite eth1/eth2/eth3 sections cleanly)
IF_FILE="/etc/network/interfaces"
if [ -f "$IF_FILE" ]; then
  awk '
    function is_target(i) { return (i=="eth1" || i=="eth2" || i=="eth3") }
    BEGIN { skip=0 }
    /^auto[ \t]+/ {
      i=$2
      if (is_target(i)) { skip=1; next }
      if (skip && !is_target(i)) { skip=0; print }
      else if (!skip) { print }
      next
    }
    /^iface[ \t]+/ {
      i=$2
      if (is_target(i)) { skip=1; next }
      if (skip && !is_target(i)) { skip=0; print }
      else if (!skip) { print }
      next
    }
    { if (!skip) print }
  ' "$IF_FILE" > /tmp/interfaces.new

  cat >> /tmp/interfaces.new <<'EOF'

# --- Added by provision-blue.sh ---
auto eth1
iface eth1 inet static
    address 10.10.101.1
    netmask 255.255.255.252

auto eth2
iface eth2 inet static
    address 172.16.50.1
    netmask 255.255.255.0

auto eth3
iface eth3 inet static
    address 10.10.172.1
    netmask 255.255.255.0
EOF

  mv /tmp/interfaces.new "$IF_FILE"
fi

# ---- IPv4 forwarding ----
echo "[+] Enable IPv4 forwarding..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-router.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-router.conf || true

# ---- nftables: start (do NOT restart) to reduce risk of dropping SSH ----
echo "[+] Configure nftables..."
cat > /etc/nftables.conf <<'EOF'
flush ruleset

# --- ĐỊNH NGHĨA BIẾN ---
# eth0 là WAN (Internet) - Nơi sẽ thực hiện NAT
define WAN_IF = "eth0"

# eth1 là OSPF Link - Tuyệt đối không NAT traffic OSPF trên cổng này
define OSPF_IF = "eth1"

# Các cổng LAN nội bộ
define LAN_IFS = { "eth2", "eth3" }
define ALL_INTERNAL = { "eth1", "eth2", "eth3" }

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;

        # 1. Chấp nhận traffic cơ bản
        iif "lo" accept
        ct state established,related accept

        # 2. Quản trị (SSH, Ping)
        tcp dport 22 accept
        ip protocol icmp accept

        # 3. Giao thức định tuyến (OSPF) - BẮT BUỘC
        # Cho phép router nhận gói tin OSPF từ hàng xóm
        ip protocol ospf accept
        ip protocol igmp accept

        # 4. Cho phép mạng nội bộ truy cập router
        iifname $ALL_INTERNAL accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        ct state established,related accept

        # 1. Cho phép LAN ra Internet (qua eth0)
        iifname $LAN_IFS oifname $WAN_IF accept

        # 2. Cho phép Router OSPF (eth1) ra Internet (nếu cần update/ping)
        iifname $OSPF_IF oifname $WAN_IF accept

        # 3. Routing giữa các mạng nội bộ (LAN <-> OSPF Link)
        iifname $OSPF_IF oifname $LAN_IFS accept
        iifname $LAN_IFS oifname $OSPF_IF accept
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority -100;
    }

    chain postrouting {
        type nat hook postrouting priority 100;

        # --- ĐÂY LÀ DÒNG BẠN YÊU CẦU ---
        # Tương đương: iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
        # Ý nghĩa: Cứ hễ đi ra cổng WAN (eth0) là NAT hết.
        oifname $WAN_IF masquerade
    }
}
EOF

rc-update add nftables default || true
rc-service nftables start || true
# If start fails because it's already running, try reload (optional)
rc-service nftables reload 2>/dev/null || true

# ---- FRR: config + start (avoid restart) ----
echo "[+] Configure FRR..."
if [ -f /etc/frr/daemons ]; then
  sed -i \
    -e 's/^zebra=.*/zebra=yes/' \
    -e 's/^ospfd=.*/ospfd=yes/' \
    -e 's/^bgpd=.*/bgpd=no/' \
    -e 's/^ripd=.*/ripd=no/' \
    -e 's/^isisd=.*/isisd=no/' \
    /etc/frr/daemons || true
fi

cat > /etc/frr/frr.conf <<'EOF'
frr defaults traditional
hostname red-router
service integrated-vtysh-config
!
router ospf
 ospf router-id 10.10.101.2
 passive-interface default
 no passive-interface eth1
 network 10.10.101.0/30 area 0
 network 10.10.171.0/24 area 0
!
line vty
!
EOF
rc-update add networking default || true

chown -R frr:frr /etc/frr || true
chmod 640 /etc/frr/frr.conf || true

echo "[+] Enable ACPI for graceful shutdown..."
rc-update add acpid default
rc-service acpid start > /dev/null 2>&1 || true

rc-update add frr default || true
rc-service frr start > /dev/null 2>&1 || true

rc-update add cloud-init default || true

# Use NoCloud datasource only (Proxmox cloud-init drive), do not probe EC2
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-proxmox.cfg <<'EOF'
datasource_list: [ NoCloud, None ]

datasource:
  NoCloud:
    fs_label: cidata
EOF

# Disable cloud-init network module (it overwrites your interfaces)
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

# Clean so clones still run user-data, but do not break network
cloud-init clean --logs > /dev/null 2>&1 || true

echo "[+] Cleaning cloud-init state/logs..."
cloud-init clean -l > /dev/null 2>&1 || true
rm -rf /var/lib/cloud/* > /dev/null 2>&1 || true

# --- IMPORTANT FIX FOR ALPINE ---
# QEMU Agent calls 'shutdown' but Alpine provides 'poweroff' by default.
if [ ! -f /sbin/shutdown ]; then
  ln -s /sbin/poweroff /sbin/shutdown
fi

echo "[+] Restarting QEMU Agent..."
rc-service qemu-guest-agent restart > /dev/null 2>&1 || true

echo "[+] Done."

# poweroff
