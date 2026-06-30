#!/bin/bash

set -e

# --- НАСТРОЙКИ ---
CIADPI_LOCAL_PROXY="socks5://127.0.0.1:20000"
VPNHOOD_PORT="40000"
VPNHOOD_UID="996"

# Автоопределение сетевого интерфейса
INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
INTERFACE=${INTERFACE:-ens3}

echo "=== Запуск автонастройки VPNhood + tun2socks + ciadpi ==="
echo "Основной интерфейс: $INTERFACE"

# 1. Пакеты
apt-get update
apt-get install -y unzip iproute2

# 2. Установка tun2socks
echo "--> Установка tun2socks..."
wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip -O /tmp/tun2socks.zip
unzip -o /tmp/tun2socks.zip -d /tmp/
mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
chmod +x /usr/local/bin/tun2socks
rm -f /tmp/tun2socks.zip

# 3. Маршруты iproute2
mkdir -p /etc/iproute2
if ! grep -q "socks_table" /etc/iproute2/rt_tables; then
    echo "200 socks_table" >> /etc/iproute2/rt_tables
fi

# 4. Настройка sysctl
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# 5. Служба tun2socks (направлена на localhost)
echo "--> Создание службы tun2socks.service..."
cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks Proxy for VPNhood (Local ciadpi)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun-proxy -proxy "${CIADPI_LOCAL_PROXY}"

ExecStartPost=/bin/sleep 1
ExecStartPost=/sbin/ip link set dev tun-proxy up
ExecStartPost=/sbin/ip addr add 198.18.0.1/15 dev tun-proxy
ExecStartPost=/sbin/sysctl -w net.ipv4.conf.all.rp_filter=0
ExecStartPost=/sbin/sysctl -w net.ipv4.conf.default.rp_filter=0
ExecStartPost=/sbin/sysctl -w net.ipv4.conf.tun-proxy.rp_filter=0
ExecStartPost=/sbin/ip route add default dev tun-proxy table 200
ExecStartPost=/sbin/ip rule add fwmark 1 lookup 200

ExecStopPost=/sbin/ip rule del fwmark 1 lookup 200
ExecStopPost=/sbin/ip route flush table 200

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 6. Конфигурация nftables
echo "--> Генерация nftables.conf..."
cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        iifname "${INTERFACE}" tcp dport 2222 accept
        iifname "${INTERFACE}" tcp dport 80 accept
        iifname "${INTERFACE}" tcp dport 443 accept
        iifname "${INTERFACE}" udp dport 1024-65535 accept
        iifname "${INTERFACE}" tcp dport 55555 accept
        iifname "${INTERFACE}" tcp dport ${VPNHOOD_PORT} accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${VPNHOOD_UID} ip6 daddr != ::1 drop
    }
}

table ip mangle {
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr 127.0.0.0/8 return
        tcp sport ${VPNHOOD_PORT} return
        udp sport ${VPNHOOD_PORT} return
        meta skuid ${VPNHOOD_UID} mark set 1
    }
}
EOF

# 7. Перезапуск демонов
echo "--> Активация конфигурации..."
systemctl daemon-reload
systemctl enable tun2socks
systemctl restart tun2socks

systemctl enable nftables
nft -f /etc/nftables.conf
systemctl restart nftables

echo "=== Скрипт выполнен. Не забудь запустить ciadpi на порту 20000! ==="