#!/bin/ash
set -eux

echo "[+] Installing packages..."
# silence apk update/add to avoid SSH session noise
apk update > /dev/null 2>&1
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
  dnsmasq > /dev/null 2>&1

# ---- SSH hardening: do NOT restart networking; minimize sshd restarts ----
echo "[+] Ensure sshd runtime dir exists..."
mkdir -p /var/run/sshd

echo "[+] Hardening SSH: key-only..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
  sed -i \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' \
    -e 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' \
    "$SSHD_CFG" || true

  grep -q '^PasswordAuthentication ' "$SSHD_CFG" || echo 'PasswordAuthentication no' >> "$SSHD_CFG"
  grep -q '^KbdInteractiveAuthentication ' "$SSHD_CFG" || echo 'KbdInteractiveAuthentication no' >> "$SSHD_CFG"
  grep -q '^ChallengeResponseAuthentication ' "$SSHD_CFG" || echo 'ChallengeResponseAuthentication no' >> "$SSHD_CFG"
  grep -q '^PubkeyAuthentication ' "$SSHD_CFG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CFG"
  grep -q '^PermitRootLogin ' "$SSHD_CFG" || echo 'PermitRootLogin prohibit-password' >> "$SSHD_CFG"
fi

# silence rc-update/rc-service
rc-update add sshd default > /dev/null 2>&1 || true
rc-service sshd start > /dev/null 2>&1 || true 
rc-service sshd reload > /dev/null 2>&1 || true

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
rc-update add local default > /dev/null 2>&1 || true

# DO NOT restart networking while Packer is SSH-ing.
rc-update add networking default > /dev/null 2>&1 || true
ip link set eth0 up 2>/dev/null || true

# ==========================================================
# Configure IP for internal NICs + persist
# - eth0: DHCP (vmbr10, "external networdk")
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
sysctl -p /etc/sysctl.d/99-router.conf > /dev/null 2>&1 || true  # change

# ==========================================================
# IPTABLES
# ==========================================================
echo "[+] Configure iptables (policy drop + forward + NAT)..."

WAN_IF="eth0"          # vmbr10
TRANSIT_IF="eth1"      # red<->blue transit
DMZ_IF="eth2"
BLUE_IF="eth3"

TRANSIT_IP="10.10.101.1"     # add: IP of eth1 on BLUE router (permanent)
DMZ_WEB_IP="172.16.50.5"     # dmz nginx-love server IP

# add: IP Wazuh Manager in BLUE VNet 
WAZUH_MGR_IP="10.10.172.10"  # Wazuh Manager IP in BLUE network

iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# DHCP client on WAN
iptables -A INPUT -i "$WAN_IF" -p udp --sport 67 --dport 68 -j ACCEPT

# Mgmt basic
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT

# Routing protocols
iptables -A INPUT -p ospf -j ACCEPT
iptables -A INPUT -p igmp -j ACCEPT

# Allow router access from internal
iptables -A INPUT -i "$TRANSIT_IF" -j ACCEPT
iptables -A INPUT -i "$DMZ_IF" -j ACCEPT
iptables -A INPUT -i "$BLUE_IF" -j ACCEPT

# Stateful forward
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow DMZ/Blue -> WAN (internet)
iptables -A FORWARD -i "$DMZ_IF" -o "$WAN_IF" -j ACCEPT
iptables -A FORWARD -i "$BLUE_IF" -o "$WAN_IF" -j ACCEPT

# change: transit <-> BLUE only (không mở transit <-> DMZ đại trà)
iptables -A FORWARD -i "$TRANSIT_IF" -o "$BLUE_IF" -j ACCEPT
iptables -A FORWARD -i "$BLUE_IF" -o "$TRANSIT_IF" -j ACCEPT

# add: BLUE -> DMZ ALLOW (blue manage/scan dmz)
iptables -A FORWARD -i "$BLUE_IF" -o "$DMZ_IF" -j ACCEPT

# add: DMZ -> BLUE DENY mặc định, chỉ allow Wazuh ports
# Wazuh agent -> manager: 1514/tcp (events), 1515/tcp (enroll), 514/udp syslog
iptables -A FORWARD -i "$DMZ_IF" -o "$BLUE_IF" -p tcp -d "$WAZUH_MGR_IP" --dport 1514 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$DMZ_IF" -o "$BLUE_IF" -p tcp -d "$WAZUH_MGR_IP" --dport 1515 -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -i "$DMZ_IF" -o "$BLUE_IF" -p udp -d "$WAZUH_MGR_IP" --dport 514  -j ACCEPT

# DHCP replies on internal nets
iptables -A INPUT -i "$DMZ_IF"  -p udp --dport 67 --sport 68 -j ACCEPT
iptables -A INPUT -i "$BLUE_IF" -p udp --dport 67 --sport 68 -j ACCEPT

# Outbound NAT
iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# ==========================================================
# DNAT 80/443 WAN -> DMZ nginx-love
# ==========================================================
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 80  -j DNAT --to-destination "$DMZ_WEB_IP:80"  2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 80  -j DNAT --to-destination "$DMZ_WEB_IP:80"
iptables -t nat -C PREROUTING -i "$WAN_IF" -p tcp --dport 443 -j DNAT --to-destination "$DMZ_WEB_IP:443" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$WAN_IF" -p tcp --dport 443 -j DNAT --to-destination "$DMZ_WEB_IP:443"

iptables -C FORWARD -i "$WAN_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 80  -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 2 -i "$WAN_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 80  -m conntrack --ctstate NEW -j ACCEPT
iptables -C FORWARD -i "$WAN_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 2 -i "$WAN_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 443 -m conntrack --ctstate NEW -j ACCEPT

# ==========================================================
# add: DNAT 80/443 từ TRANSIT (RED) -> DMZ nginx-love
# RED network will access with: http(s)://10.10.101.1/ + Host header
# ==========================================================
iptables -t nat -C PREROUTING -i "$TRANSIT_IF" -d "$TRANSIT_IP" -p tcp --dport 80  -j DNAT --to-destination "$DMZ_WEB_IP:80"  2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$TRANSIT_IF" -d "$TRANSIT_IP" -p tcp --dport 80  -j DNAT --to-destination "$DMZ_WEB_IP:80"
iptables -t nat -C PREROUTING -i "$TRANSIT_IF" -d "$TRANSIT_IP" -p tcp --dport 443 -j DNAT --to-destination "$DMZ_WEB_IP:443" 2>/dev/null \
  || iptables -t nat -A PREROUTING -i "$TRANSIT_IF" -d "$TRANSIT_IP" -p tcp --dport 443 -j DNAT --to-destination "$DMZ_WEB_IP:443"

iptables -C FORWARD -i "$TRANSIT_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 80  -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 2 -i "$TRANSIT_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 80  -m conntrack --ctstate NEW -j ACCEPT
iptables -C FORWARD -i "$TRANSIT_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 443 -m conntrack --ctstate NEW -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD 2 -i "$TRANSIT_IF" -o "$DMZ_IF" -p tcp -d "$DMZ_WEB_IP" --dport 443 -m conntrack --ctstate NEW -j ACCEPT

rc-update add iptables default > /dev/null 2>&1 || true
rc-service iptables start > /dev/null 2>&1 || true
rc-service iptables save > /dev/null 2>&1 || true

# ==========================================================
# [DHCP] Configure Dnsmasq for eth2 (DMZ) and eth3 (Blue)
# ==========================================================
echo "[+] Configuring Dnsmasq DHCP Server..."

cat > /etc/dnsmasq.conf <<'EOF'
interface=eth2
interface=eth3
bind-interfaces

# --- DMZ (eth2) ---
dhcp-range=set:dmz_net,172.16.50.100,172.16.50.200,24h
dhcp-option=tag:dmz_net,option:router,172.16.50.1
dhcp-option=tag:dmz_net,option:dns-server,8.8.8.8

# --- Blue (eth3) ---
dhcp-range=set:blue_net,10.10.172.100,10.10.172.200,24h
dhcp-option=tag:blue_net,option:router,10.10.172.1
dhcp-option=tag:blue_net,option:dns-server,1.1.1.1

# Log file (giữ như cũ)
log-facility=/var/log/dnsmasq.log
EOF

rc-update add dnsmasq default > /dev/null 2>&1 || true
rc-service dnsmasq restart > /dev/null 2>&1 || true

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

# OSPF: only hello on eth1; advertise transit + BLUE; NOT DMZ
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
# silence acpid enable/start
rc-update add acpid default > /dev/null 2>&1 || true
rc-service acpid start > /dev/null 2>&1 || true

# silence frr enable/start
rc-update add frr default > /dev/null 2>&1 || true
rc-service frr start > /dev/null 2>&1 || true

# silence cloud-init enable
rc-update add cloud-init default > /dev/null 2>&1 || true

# Use NoCloud datasource only (Proxmox cloud-init drive), do not probe EC2
mkdir -p /etc/cloud/cloud.cfg.d
cat > /etc/cloud/cloud.cfg.d/99-proxmox.cfg <<'EOF'
datasource_list: [ NoCloud, None ]

datasource:
  NoCloud:
    fs_label: cidata
EOF

cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
network: {config: disabled}
EOF

echo "[+] Template cleanup (Alpine)..."

# Remove baked-in root key
rm -f /root/.ssh/authorized_keys 2>/dev/null || true

# Lock passwords (để không login bằng pass)
passwd -l root 2>/dev/null || true

# Remove SSH host keys so clones regenerate
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

# Reset machine-id (tuỳ Alpine version)
rm -f /etc/machine-id 2>/dev/null || true

# Clean logs
find /var/log -type f -exec sh -c ': > "$1"' _ {} \; 2>/dev/null || true

sync || true


cloud-init clean --logs > /dev/null 2>&1 || true
cloud-init clean -l > /dev/null 2>&1 || true
rm -rf /var/lib/cloud/* > /dev/null 2>&1 || true

# --- IMPORTANT FIX FOR ALPINE ---
if [ ! -f /sbin/shutdown ]; then
  ln -s /sbin/poweroff /sbin/shutdown
fi

# silence qemu-guest-agent enable/restart
rc-update add qemu-guest-agent default > /dev/null 2>&1 || true
rc-service qemu-guest-agent restart > /dev/null 2>&1 || true

echo "[+] Done."