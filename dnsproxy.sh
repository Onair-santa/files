#!/bin/bash

# Get the latest dnsproxy version from GitHub
VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest | grep tag_name | cut -d '"' -f 4)
echo "Latest AdguardTeam dnsproxy version is $VERSION"

# Download and extract dnsproxy
wget -O dnsproxy.tar.gz "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-amd64-${VERSION}.tar.gz"
tar -xzvf dnsproxy.tar.gz
cd linux-amd64

# Install dnsproxy
sudo mv dnsproxy /usr/bin/dnsproxy

# Create dnsproxy systemd service file
cat << EOF | sudo tee /etc/systemd/system/dnsproxy.service
[Unit]
Description=DNS Proxy
After=network.target
Requires=network.target

[Service]
Type=simple
ExecStart=/usr/bin/dnsproxy -l 127.0.0.1 -p 53 -u https://dns.cloudflare.com/dns-query -b 1.1.1.1:53 -f 8.8.8.8:53 --cache
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable dnsproxy service
sudo systemctl daemon-reload
sudo systemctl enable --now dnsproxy

# Configure /etc/resolv.conf to use local dnsproxy
echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf

# Check DNS resolution and print success message
if host google.com &> /dev/null; then
    echo "DNS proxy is working correctly!"
else
    echo "Error: DNS proxy setup failed."
fi
