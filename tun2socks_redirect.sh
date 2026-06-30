#!/bin/bash

# Выходить при любой ошибке
set -e

# --- НАСТРОЙКИ (Измени, если на новом сервере будут другие данные) ---
SOCKS_PROXY="socks5://lumi-ez3mjil6rgli:0nrLy5ASiTjMh8jR@89.218.21.9:6011"
SOCKS_IP="89.218.21.9"
VPNHOOD_PORT="40000"
VPNHOOD_UID="996"

# Автоопределение основного сетевого интерфейса (замена ens3)
INTERFACE=$(ip -4 route show default | awk '{print $5}' | head -n1)
INTERFACE=${INTERFACE:-ens3} # Если не определился, берем ens3 по дефолту

echo "=== Запуск автоматической настройки сервера ==="
echo "Используемый сетевой интерфейс: $INTERFACE"

# 1. Обновление и установка необходимых пакетов
echo "--> Установка системных пакетов (nftables, iproute2, unzip)..."
apt-get update
apt-get install -y wget unzip iproute2 nftables

# 2. Скачивание и установка tun2socks
echo "--> Скачивание и установка tun2socks..."
wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip -O /tmp/tun2socks.zip
unzip -o /tmp/tun2socks.zip -d /tmp/
mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
chmod +x /usr/local/bin/tun2socks
rm -f /tmp/tun2socks.zip

# 3. Настройка таблицы маршрутизации iproute2
echo "--> Настройка таблицы маршрутизации socks_table..."
mkdir -p /etc/iproute2
if ! grep -q "socks_table" /etc/iproute2/rt_tables; then
    echo "200 socks_table" >> /etc/iproute2/rt_tables
fi

# 4. Настройка sysctl (Включение IP Forwarding)
echo "--> Настройка sysctl (ip_forward)..."
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

# 5. Создание Systemd сервиса для tun2socks
echo "--> Создание службы tun2socks.service..."
cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks Proxy for VPNhood
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun-proxy -proxy "${SOCKS_PROXY}"

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

# 6. Настройка правил nftables
echo "--> Генерация конфигурации nftables..."
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
        iifname "${INTERFACE}" tcp dport 6011 accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
        
        # БЛОКИРУЕМ IPv6 для VPNhood (защита от утечек)
        meta skuid ${VPNHOOD_UID} ip6 daddr != ::1 drop
    }
}

table ip mangle {
    chain output {
        type route hook output priority mangle; policy accept;
        
        # Исключаем локальный трафик
        ip daddr 127.0.0.0/8 return
        
        # Исключаем трафик до самого SOCKS5 сервера
        ip daddr ${SOCKS_IP} return
        
        # Исключаем ответы сервера обратно клиенту VPNhood
        tcp sport ${VPNHOOD_PORT} return
        udp sport ${VPNHOOD_PORT} return
        
        # Маркируем чистый интернет-трафик от пользователя VPNhood
        meta skuid ${VPNHOOD_UID} mark set 1
    }
}
EOF

# 7. Запуск и добавление служб в автозапуск
echo "--> Запуск служб и применение конфигурации..."
systemctl daemon-reload

# Включаем и перезапускаем tun2socks
systemctl enable tun2socks
systemctl restart tun2socks

# Включаем и перезапускаем nftables
systemctl enable nftables
nft -f /etc/nftables.conf
systemctl restart nftables

echo "=== Настройка успешно завершена! Схема работает. ==="