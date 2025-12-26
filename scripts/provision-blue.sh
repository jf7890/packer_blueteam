#!/bin/ash
set -eux

echo "[+] Installing packages..."
apk update
apk add --no-cache \
  openssh \
  iptables iptables-openrc \
  frr frr-openrc \
  iproute2 \
  curl \
  acpid \
  qemu-guest-agent \
  cloud-init \
  cloud-init-openrc \
  busybox-extras \
  dnsmasq

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
rc-service sshd start || true
rc-service sshd reload 2>/dev/null || true

# ---- NIC DOWN safety net: local.d ----
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
rc-update add networking default || true
ip link set eth0 up 2>/dev/null || true

# ==========================================================
# Configure IP for internal NICs + persist
# - eth0: DHCP (không đụng runtime để khỏi rớt SSH)
# - eth1: transit 10.10.101.1/30
# - eth2: DMZ   172.16.50.1/24
# - eth3: BLUE  10.10.172.1/24
# ==========================================================
echo "[+] Configure IP for eth1/eth2/eth3 without restarting networking..."

ip link set eth1 up 2>/dev/null || true
ip link set eth2 up 2>/dev/null || true
ip link set eth3 up 2>/dev/null || true

ip addr replace 10.10.101.1/30 dev eth1 2>/dev/null || true
ip addr replace 172.16.50.1/24 dev eth2 2>/dev/null || true
ip addr replace 10.10.172.1/24 dev eth3 2>/dev/null || true

# Persist /etc/network/interfaces (rewrite eth1/eth2/eth3 sections cleanly)
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

# ==========================================================
# IPTABLES (thay nftables)
# Logic giống rule bạn/Quang dùng:
# - INPUT drop, allow lo/established
# - allow SSH, ICMP, OSPF(89), IGMP(2)
# - allow internal NICs truy cập router
# - FORWARD: LAN/DMZ -> WAN, OSPF link <-> LAN/DMZ, (optional) OSPF link -> WAN
# - NAT: hễ ra eth0 là masquerade
# ==========================================================
echo "[+] Configure iptables (policy drop + forward + NAT)..."

WAN_IF="eth0"
OSPF_IF="eth1"
LAN_IFS="eth2 eth3"

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# INPUT basics
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DHCP client on eth0 (để chắc chắn không bị drop lúc xin lease)
iptables -A INPUT -i "$WAN_IF" -p udp --sport 67 --dport 68 -j ACCEPT

# Mgmt
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT

# OSPF/IGMP
iptables -A INPUT -p ospf -j ACCEPT
iptables -A INPUT -p igmp -j ACCEPT

# allow internal to router
iptables -A INPUT -i "$OSPF_IF" -j ACCEPT
iptables -A INPUT -i eth2 -j ACCEPT
iptables -A INPUT -i eth3 -j ACCEPT

# FORWARD
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# LAN/DMZ -> WAN
for IF in $LAN_IFS; do
  iptables -A FORWARD -i "$IF" -o "$WAN_IF" -j ACCEPT
done

# OSPF link -> WAN (nếu cần)
iptables -A FORWARD -i "$OSPF_IF" -o "$WAN_IF" -j ACCEPT

# OSPF link <-> LAN/DMZ
for IF in $LAN_IFS; do
  iptables -A FORWARD -i "$OSPF_IF" -o "$IF" -j ACCEPT
  iptables -A FORWARD -i "$IF" -o "$OSPF_IF" -j ACCEPT
done

# INPUT: Cho phép DHCP Request từ nội bộ (Port 67/68)
for IF in $LAN_IFS; do
  iptables -A INPUT -i "$IF" -p udp --dport 67 --sport 68 -j ACCEPT
done

# NAT all out WAN
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# Persist rules
rc-update add iptables default || true
rc-service iptables start > /dev/null 2>&1 || true
rc-service iptables save  > /dev/null 2>&1 || true

# ---- FRR: config + start (BLUE) ----
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

# ==========================================================
# [DHCP] Configure Dnsmasq for eth2 (DMZ) and eth3 (Blue)
# ==========================================================
echo "[+] Configuring Dnsmasq DHCP Server..."

cat > /etc/dnsmasq.conf <<EOF
interface=eth2
interface=eth3
bind-interfaces

# --- Cấu hình cho DMZ (eth2) ---
# Dải IP: .100 -> .200, Lease time: 24h
dhcp-range=set:dmz_net,172.16.50.100,172.16.50.200,24h
dhcp-option=tag:dmz_net,option:router,172.16.50.1
dhcp-option=tag:dmz_net,option:dns-server,8.8.8.8

# --- Cấu hình cho Blue Net (eth3) ---
dhcp-range=set:blue_net,10.10.172.100,10.10.172.200,24h
dhcp-option=tag:blue_net,option:router,10.10.172.1
dhcp-option=tag:blue_net,option:dns-server,1.1.1.1

# Log file (giảm thiểu ghi vào console automation)
log-facility=/var/log/dnsmasq.log
EOF

rc-update add dnsmasq default || true
rc-service dnsmasq restart > /dev/null 2>&1 || true

# OSPF:
# - chỉ chạy hello trên eth1 (transit)
# - quảng bá transit + BLUE LAN
# - KHÔNG quảng bá DMZ (eth2)
cat > /etc/frr/frr.conf <<'EOF'
frr defaults traditional
hostname blue-router
service integrated-vtysh-config
!
router ospf
 ospf router-id 10.10.101.1
 passive-interface default
 no passive-interface eth1
 network 10.10.101.0/30 area 0
 network 10.10.172.0/24 area 0
!
line vty
!
EOF

chown -R frr:frr /etc/frr || true
chmod 640 /etc/frr/frr.conf || true

echo "[+] Enable ACPI for graceful shutdown..."
rc-update add acpid default || true
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

cloud-init clean --logs > /dev/null 2>&1 || true
cloud-init clean -l    > /dev/null 2>&1 || true
rm -rf /var/lib/cloud/* > /dev/null 2>&1 || true

# --- IMPORTANT FIX FOR ALPINE ---
if [ ! -f /sbin/shutdown ]; then
  ln -s /sbin/poweroff /sbin/shutdown
fi

rc-update add qemu-guest-agent default || true
rc-service qemu-guest-agent restart > /dev/null 2>&1 || true

echo "[+] Done."
