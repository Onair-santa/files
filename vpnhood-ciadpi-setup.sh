#!/bin/bash
# VpnHood + CiaDPI + Redsocks Setup Script
# Run this on your server as root

set -e

echo "=== VpnHood + CiaDPI + Redsocks Setup ==="
echo

# Step 1: Install redsocks
echo "[1/9] Installing redsocks..."
apt-get update
apt-get install -y redsocks
echo "✓ Redsocks installed"

# Step 2: Configure redsocks
echo "[2/9] Configuring redsocks..."
cat > /etc/redsocks.conf << 'EOF'
base {
    log_debug = off;
    log_info = on;
    log = stderr;
    daemon = on;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = 12345;
    ip = 127.0.0.1;
    port = 20000;
    type = socks5;
}
EOF

echo "✓ Redsocks configured"

# Step 3: Start redsocks
echo "[3/9] Starting redsocks..."
systemctl enable redsocks
systemctl restart redsocks
echo "✓ Redsocks running"

# Step 4: Create vpnhood user
echo "[4/9] Creating vpnhood user..."
useradd -r -s /bin/false -u 996 vpnhood 2>/dev/null || true
chown -R vpnhood:vpnhood /opt/VpnHoodServer
echo "✓ User vpnhood created (uid 996)"

#в debian13 нужно поставить
apt install libicu-dev -y
apt install libevent-dev

# Step 5: Configure VpnHood
echo "[5/9] Configuring VpnHood..."
cp /opt/VpnHoodServer/storage/appsettings.json /opt/VpnHoodServer/storage/appsettings.json.bak 2>/dev/null || true
sed -i 's/:443/:40000/g' /opt/VpnHoodServer/storage/appsettings.json 2>/dev/null || true
echo "✓ VpnHood configured on port 40000"

# Step 6: Create VpnHood systemd service
echo "[6/9] Creating VpnHood systemd service..."

cat > /etc/systemd/system/VpnHoodServer.service << 'EOF'
[Unit]
Description=VpnHood Server
After=network.target

[Service]
Type=simple
User=vpnhood
Group=vpnhood
ExecStart=/opt/VpnHoodServer/v3.2.448/VpnHoodServer
ExecStop=/opt/VpnHoodServer/v3.2.448/VpnHoodServer stop
TimeoutStartSec=0
Restart=always
RestartSec=10
StandardOutput=null

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now VpnHoodServer

echo "✓ VpnHood service created and enabled"

# Step 7: Configure nftables
echo "[7/9] Configuring nftables..."

# NAT table
nft add table ip nat
nft add chain ip nat output { type nat hook output priority filter \; policy accept \; }
nft add rule ip nat output meta mark 0x1 tcp dport != 12345 redirect to :12345

# Mangle table
nft add table ip mangle
nft add chain ip mangle output { type route hook output priority mangle \; policy accept \; }
nft add rule ip mangle output meta skuid 996 meta mark set 0x1

echo 'flush ruleset' >> /etc/nftables.conf
nft list ruleset >> /etc/nftables.conf
systemctl restart nftables
echo "✓ Nftables configured"

#table ip nat {
#   chain postrouting {
#        type nat hook postrouting priority srcnat; policy accept;
#    }
#    chain output {
#        type nat hook output priority filter; policy accept;
#        meta mark 0x00000001 tcp dport != 12345 redirect to :12345
#    }
#}
#
#table ip mangle {
#    chain output {
#        type route hook output priority mangle; policy accept;
#        meta skuid 996 meta mark set 0x00000001
#    }
#}

echo
echo "=== Setup Complete ==="
echo
echo "VpnHood service commands:"
echo "  systemctl start VpnHoodServer    # Start"
echo "  systemctl stop VpnHoodServer     # Stop"
echo "  systemctl restart VpnHoodServer  # Restart"
echo "  systemctl status VpnHoodServer   # Status"
echo "  /opt/VpnHoodServer/vhserver gen  # Add client"
echo "Traffic flow:"
echo "  Client -> VpnHood:40000 -> uid 996 -> redsocks:12345 -> CiaDPI:20000 -> Internet"
echo
echo "Check status:"
echo "  systemctl status VpnHoodServer"
echo "  ps aux | grep -E 'VpnHoodServer|redsocks|ciadpi'"
echo "  nft -a list ruleset"
