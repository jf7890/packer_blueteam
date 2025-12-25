#!/bin/ash
set -eux

echo "[+] Installing packages..."
apk update
apk add --no-cache \
  openssh \
  nftables \
  frr frr-openrc \
  iproute2 \
  curl

# ---- SSH: harden nhưng KHÔNG restart networking, hạn chế restart sshd ----
echo "[+] Ensure sshd runtime dir exists..."
mkdir -p /var/run/sshd

echo "[+] Hardening SSH: key-only..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
  # set/replace nếu có
  sed -i \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
    "$SSHD_CFG" || true

  # append nếu thiếu dòng
  grep -q '^PasswordAuthentication ' "$SSHD_CFG" || echo 'PasswordAuthentication no' >> "$SSHD_CFG"
  grep -q '^KbdInteractiveAuthentication ' "$SSHD_CFG" || echo 'KbdInteractiveAuthentication no' >> "$SSHD_CFG"
  grep -q '^ChallengeResponseAuthentication ' "$SSHD_CFG" || echo 'ChallengeResponseAuthentication no' >> "$SSHD_CFG"
  grep -q '^PubkeyAuthentication ' "$SSHD_CFG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CFG"
  grep -q '^PermitRootLogin ' "$SSHD_CFG" || echo 'PermitRootLogin prohibit-password' >> "$SSHD_CFG"
fi

rc-update add sshd default || true

# QUAN TRỌNG: tránh restart làm rớt SSH.
# start nếu chưa chạy; nếu đã chạy thì chỉ reload (nếu có), không reload được thì thôi.
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

# KHÔNG restart networking trong lúc Packer SSH.
# Chỉ enable service để lần boot sau nó tự lên.
rc-update add networking default || true
# (Optional) Nếu muốn chắc chắn eth0 đang UP ngay lúc này, chỉ up link, không restart:
ip link set eth0 up 2>/dev/null || true

# ==========================================================
# [THÊM] Cấu hình IP cho các card mạng (đuôi .5) + persist
# - Không đụng runtime config của eth0 (tránh rớt SSH)
# - Chỉ set runtime + ghi vào /etc/network/interfaces cho eth1/2/3
# ==========================================================
echo "[+] Configure IP for eth1/eth2/eth3 (tail .5) without restarting networking..."

# 1) Set runtime IP (an toàn: không ảnh hưởng session SSH qua eth0)
ip link set eth1 up 2>/dev/null || true
ip link set eth2 up 2>/dev/null || true
ip link set eth3 up 2>/dev/null || true

# Transit
ip addr replace 10.10.101.1/30 dev eth1 2>/dev/null || true
# DMZ
ip addr replace 172.16.50.1/24 dev eth2 2>/dev/null || true
# Blue LAN
ip addr replace 10.10.172.1/24 dev eth3 2>/dev/null || true

# 2) Persist vào /etc/network/interfaces (rewrite phần eth1/eth2/eth3 cho sạch)
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

# ---- nftables: start (không restart) để giảm nguy cơ drop session ----
echo "[+] Configure nftables..."
cat > /etc/nftables.conf <<'EOF'
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iif "lo" accept
    ct state established,related accept

    tcp dport 22 accept
    ip protocol icmp accept
    ip protocol ospf accept

    iifname { "eth1", "eth2", "eth3" } accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    ct state established,related accept
    iifname { "eth2", "eth3" } oifname "eth0" accept
    iifname "eth1" accept
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
    oif "eth0" ip saddr { 172.16.50.0/24, 10.10.172.0/24 } masquerade
  }
}
EOF

rc-update add nftables default || true
rc-service nftables start || true
# nếu start fail do đã chạy, thử reload/restart nhẹ (không bắt buộc)
rc-service nftables reload 2>/dev/null || true

# ---- FRR: config + start (tránh restart) ----
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
hostname blue-router
service integrated-vtysh-config
!
router ospf
 ospf router-id 10.10.100.21
 network 10.10.101.0/30 area 0
 network 10.10.172.0/24 area 0
!
line vty
!
EOF

chown -R frr:frr /etc/frr || true
chmod 640 /etc/frr/frr.conf || true

rc-update add frr default || true
rc-service frr start > /dev/null 2>&1 || true

echo "[+] Done."
