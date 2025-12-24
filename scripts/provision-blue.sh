#!/bin/ash
set -eu

echo "[+] Installing packages..."
apk update
apk add --no-cache \
  openssh-server openssh-client \
  nftables \
  frr frr-openrc \
  iproute2 \
  curl

echo "[+] Ensure sshd runtime dir exists (Alpine sometimes needs it)..."
mkdir -p /var/run/sshd

echo "[+] Hardening SSH: key-only, no passwords..."
SSHD_CFG="/etc/ssh/sshd_config"
if [ -f "$SSHD_CFG" ]; then
  # Ensure settings exist (append if missing, replace if present)
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

rc-update add sshd default || true
rc-service sshd restart || rc-service sshd start || true

echo "[+] Fix NICs default DOWN issue (safety net): force links UP at boot via local.d..."
mkdir -p /etc/local.d
cat > /etc/local.d/ifup.start <<'EOF'
#!/bin/sh
for i in eth0 eth1 eth2 eth3; do
  ip link set "$i" up 2>/dev/null || true
done
EOF
chmod +x /etc/local.d/ifup.start
rc-update add local default || true

echo "[+] Enable networking service..."
rc-update add networking default || true
rc-service networking restart || true

echo "[+] Enable IPv4 forwarding..."
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-router.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
sysctl -p /etc/sysctl.d/99-router.conf || true

echo "[+] Configure nftables (basic router + NAT)..."
cat > /etc/nftables.conf <<'EOF'
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    iif "lo" accept
    ct state established,related accept

    # SSH
    tcp dport 22 accept

    # ICMP
    ip protocol icmp accept

    # OSPF (protocol 89) if you use it on transit
    ip protocol ospf accept

    # Allow mgmt from internal if needed (adjust as you like)
    iifname { "eth1", "eth2", "eth3" } accept
  }

  chain forward {
    type filter hook forward priority 0; policy drop;

    ct state established,related accept

    # Allow LAN/DMZ -> WAN
    iifname { "eth2", "eth3" } oifname "eth0" accept

    # Allow transit forwarding (adjust policies later)
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

    # Masquerade internal subnets out WAN
    oif "eth0" ip saddr { 172.16.50.0/24, 10.10.172.0/24 } masquerade
  }
}
EOF

rc-update add nftables default || true
rc-service nftables restart || rc-service nftables start || true

echo "[+] Configure FRR (zebra + ospfd)..."
# Enable daemons
if [ -f /etc/frr/daemons ]; then
  sed -i \
    -e 's/^zebra=.*/zebra=yes/' \
    -e 's/^ospfd=.*/ospfd=yes/' \
    -e 's/^bgpd=.*/bgpd=no/' \
    -e 's/^ripd=.*/ripd=no/' \
    -e 's/^isisd=.*/isisd=no/' \
    /etc/frr/daemons || true
fi

# Base frr.conf (adjust networks as needed)
cat > /etc/frr/frr.conf <<'EOF'
frr defaults traditional
hostname blue-router
service integrated-vtysh-config
!
interface eth1
 ip ospf area 0
!
router ospf
 network 10.10.101.0/30 area 0
 network 172.16.50.0/24 area 0
 network 10.10.172.0/24 area 0
!
line vty
!
EOF

chown -R frr:frr /etc/frr || true
chmod 640 /etc/frr/frr.conf || true

rc-update add frr default || true
rc-service frr restart || rc-service frr start || true

echo "[+] Done."
