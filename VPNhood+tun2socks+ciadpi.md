apt update
apt install -y wget unzip iproute2

# Установка CiaDPI

bash <(wget -qO- https://raw.githubusercontent.com/Onair-santa/Byedpi-Setup/refs/heads/main/install.sh)

# /root/.config/byedpi.conf заменяем алгоритм на КЗ или РБ(--max-conn 2048 для увеличения открытых соединений с 512 до 2048 или прописать в службе)

-Kt,h -d1 -s0+s -d3+s -s6+s -d9+s -s12+s -d15+s -s20+s -d25+s -s30+s -An -Ku -a5 -An --max-conn 2048    # КЗ

# Служба CiaDPI /root/.config/systemd/user/ciadpi.service

[Unit]
Description=ByeDPI Proxy Service
Documentation=https://github.com/fatyzzz/Byedpi-Setup
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
EnvironmentFile=-%h/.config/byedpi.conf
ExecStart=%h/ciadpi/ciadpi-core --ip 127.0.0.1 --port $SEL_PORT $SEL_SETTINGS --max-conn 2048

Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=default.target

systemctl --user daemon-reload
systemctl --user enable --now ciadpi


# Create vpnhood user

useradd -r -s /bin/false -u 996 vpnhood 2>/dev/null || true
chown -R vpnhood:vpnhood /opt/VpnHoodServer

# в debian13 нужно поставить

apt install libicu-dev -y
apt install libevent-dev

# Configure VpnHood на port 40000

cp /opt/VpnHoodServer/storage/appsettings.json /opt/VpnHoodServer/storage/appsettings.json.bak 2>/dev/null || true
sed -i 's/:443/:40000/g' /opt/VpnHoodServer/storage/appsettings.json 2>/dev/null || true

# Create VpnHood systemd service

cat <<EOF > /etc/systemd/system/VpnHoodServer.service
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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now VpnHoodServer


# Установка tun2socks

wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip -O /tmp/tun2socks.zip
unzip -o /tmp/tun2socks.zip -d /tmp/
mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
chmod +x /usr/local/bin/tun2socks
rm -f /tmp/tun2socks.zip
mkdir -p /etc/iproute2
if ! grep -q "socks_table" /etc/iproute2/rt_tables; then
    echo "200 socks_table" >> /etc/iproute2/rt_tables
fi


# Служба tun2socks (направлена на localhost)

cat <<EOF > /etc/systemd/system/tun2socks.service
[Unit]
Description=tun2socks Proxy for VPNhood (Local ciadpi)
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/tun2socks -device tun-proxy -proxy "socks5://127.0.0.1:20000"
ExecStartPost=sleep 1
ExecStartPost=ip link set dev tun-proxy mtu 1420 up
ExecStartPost=ip addr add 198.18.0.1/15 dev tun-proxy
ExecStartPost=sysctl -w net.ipv4.conf.all.rp_filter=0
ExecStartPost=sysctl -w net.ipv4.conf.default.rp_filter=0
ExecStartPost=sysctl -w net.ipv4.conf.tun-proxy.rp_filter=0
ExecStartPost=ip route add default dev tun-proxy table 200
ExecStartPost=ip rule add fwmark 1 lookup 200

ExecStopPost=ip rule del fwmark 1 lookup 200
ExecStopPost=ip route flush table 200

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Конфигурация nftables

cat <<EOF > /etc/nftables.conf
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        meta nfproto ipv6 drop
        ct state established,related accept
        ip saddr 185.204.2.249 icmp type echo-request accept
        iifname "${INTERFACE}" tcp dport 2222 accept
        iifname "${INTERFACE}" tcp dport 80 accept
        iifname "${INTERFACE}" tcp dport 443 accept
        iifname "${INTERFACE}" udp dport 1024-65535 accept
        iifname "${INTERFACE}" tcp dport 55555 accept
        iifname "${INTERFACE}" tcp dport 40000 accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
        meta skuid 996 ip6 daddr != ::1 drop
    }
}

table ip mangle {
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr 127.0.0.0/8 return
        tcp sport 40000 return
        udp sport 40000 return
        meta skuid 996 mark set 1
    }
}
EOF


# Перезапуск демонов

systemctl daemon-reload
systemctl enable --now tun2socks
systemctl restart tun2socks
nft -f /etc/nftables.conf
systemctl restart nftables


# Amnezia+tun2socks+ciadpi
              
Реальный UDP-порт твоей Амнезии — 33178 (это видно по строке dnat to 172.29.172.2:33178).

Docker активно использует таблицы ip nat и ip filter.

Как заставить их работать вместе и не сломать Docker?
Нам нужно изменить стратегию: вместо полной очистки всего фаервола (flush ruleset), мы будем сбрасывать и переписывать только те таблицы, которыми управляем мы (inet filter и ip mangle), а таблицы Докера (ip nat и ip filter) фаервол вообще не будет трогать.

Вот готовый, безопасный и адаптированный под твою Амнезию полный конфиг фаервола.

Финальный конфиг /etc/nftables.conf для AmneziaWG + Docker + ciadpi
Открой файл:

Bash
nano /etc/nftables.conf
Полностью удали всё, что там есть, и вставь этот вариант. Обрати внимание на первые строчки — они точечно очищают только наши таблицы:

Фрагмент кода
#!/usr/sbin/nft -f

# КРИТИЧНО ДЛЯ DOCKER: Создаем и очищаем ТОЛЬКО свои таблицы,
# чтобы не затронуть автоматические таблицы Докера (ip nat и ip filter)
add table inet filter
flush table inet filter
add table ip mangle
flush table ip mangle

# НАША ТАБЛИЦА ФИЛЬТРАЦИИ
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        iifname "amn0" meta nfproto ipv6 drop
        iifname "ens3" tcp dport 2222 accept
        iifname "ens3" tcp dport 80 accept
        iifname "ens3" tcp dport 443 accept
        
        # Явно разрешаем входящий UDP-порт твоей Амнезии
        iifname "ens3" udp dport 33178 accept
        
        # Общий диапазон (у тебя он был открыт, оставляем)
        iifname "ens3" udp dport 1024-65535 accept
        
        iifname "ens3" tcp dport 55555 accept
        iifname "ens3" tcp dport 40000 accept
        
        # Разрешаем клиентам обращаться к самому серверу внутри сети Амнезии (например, к DNS)
        iifname "amn0" accept
    }

    chain forward {
        type filter hook forward priority filter; policy accept;
        iifname "amn0" meta nfproto ipv6 drop
    }

    chain output {
        type filter hook output priority filter; policy accept;
        ip6 daddr != ::1 drop
    }
}
              # НАША ТАБЛИЦА МАРШРУТИЗАЦИИ (МАНГЛ)
table ip mangle {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;       
        # 1. Если клиент из Амнезии обращается к локальному сервису сервера (например, DNS-резолверу Амнезии)
        # то этот пакет мы не трогаем и в прокси не отправляем. И убираем петлю с порта 30755
        fib daddr type local return
        udp sport 30755 return
        # 2. МАРШРУТИЗАЦИЯ В ОБХОД: Весь интернет-трафик, прилетающий ИЗ интерфейса Амнезии (amn0),
        # маркируем меткой 1. Система перенаправит его в таблицу 200 -> tun2socks -> ciadpi.
        iifname "amn0" mark set 1
    }
}
Как это запустить:
Сохрани файл конфига (Ctrl+O, Enter, Ctrl+X).

Убедись, что служба tun2socks настроена на локальный прокси (socks5://127.0.0.1:20000) в файле /etc/systemd/system/tun2socks.service (как в первой части нашей прошлой шпаргалки).

Перезапусти фаервол командой:

Bash
nft -f /etc/nftables.conf
Перезапусти службу туннеля:

Bash
systemctl restart tun2socks
Почему эта схема идеальна и не будет вызывать петлю?
Пакет от твоего телефона (клиента Амнезии) зашифрованным прилетает на сервер через ens3 на UDP-порт 33178. Докер подхватывает его, расшифровывает и «выплевывает» чистый внутренний пакет внутрь интерфейса amn0.

В этот же момент срабатывает наше правило в цепочке prerouting: оно видит пакет на интерфейсе amn0, ставит на него метку 1, и ядро Linux мгновенно пересылает его в tun2socks и локальный ciadpi. Трафик уходит на разблокировку, а Docker-правила ната (masquerade) даже не успевают зациклить процесс, так как мы перехватили трафик в самом начале его пути внутри сервера.              