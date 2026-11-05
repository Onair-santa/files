#!/bin/bash
# =====================================================================
#  VPS Management Script for Debian 12 (bookworm) / Debian 13 (trixie)
# =====================================================================

# --- Configuration & Styling ---
LOG_FILE="/var/log/vps_setup.log"
> "$LOG_FILE" # Clear log on startup

# Colors
COLOR_RESET="\033[0m"
COLOR_INFO="\033[1;36m"
COLOR_SUCCESS="\033[1;32m"
COLOR_WARNING="\033[1;33m"
COLOR_ERROR="\033[1;31m"

# Paths
HOST_PATH="/etc/hosts"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-tuning.conf"
SSH_PATH="/etc/ssh/sshd_config"
SSH_DROPIN="/etc/ssh/sshd_config.d/00-vps.conf"
LIMITS_FILE="/etc/security/limits.d/99-vps.conf"
SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-vps-limits.conf"
SWAP_PATH="/swapfile"
SWAP_SIZE="1G"

# Public SSH key that gets added to /root/.ssh/authorized_keys (menu: Full Setup).
# !!! Whoever controls this URL gets root access to the server. Replace with your own key URL !!!
SSH_KEY_URL="https://raw.githubusercontent.com/Onair-santa/files/main/id_ed25519.pub"

# Global State
TOTAL_STEPS=1
CURRENT_STEP=0
INTERFACE=""
CITY="Unknown City"
COUNTRY="Unknown Country"

# APT Safe Options (prevents hanging on configuration prompts)
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"

# --- UI Functions ---
msg_info()    { echo -e "${COLOR_INFO}  $1${COLOR_RESET}"; }
msg_success() { echo -e "${COLOR_SUCCESS}  $1${COLOR_RESET}"; }
msg_warn()    { echo -e "${COLOR_WARNING}  $1${COLOR_RESET}"; }
msg_error()   { echo -e "${COLOR_ERROR}  $1${COLOR_RESET}"; }

set_steps() {
    TOTAL_STEPS=$1
    CURRENT_STEP=0
    echo ""
}

# The Visual Progress Bar Runner (For NON-interactive tasks)
run_task() {
    local task_name="$1"
    local func_name="$2"
    ((CURRENT_STEP++))

    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( percent / 5 ))
    local empty=$(( 20 - filled ))

    local bar=$(printf "%${filled}s" | tr ' ' '=')
    local empty_bar=$(printf "%${empty}s" | tr ' ' '.')

    printf "\r\033[K${COLOR_INFO}[%3d%%] [%s>%s] %s${COLOR_RESET}" "$percent" "$bar" "$empty_bar" "$task_name"

    # Execute silently
    $func_name >> "$LOG_FILE" 2>&1 < /dev/null
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        printf "\r\033[K${COLOR_ERROR}[FAIL] %s (Check log: %s)${COLOR_RESET}\n" "$task_name" "$LOG_FILE"
    elif [ "$CURRENT_STEP" -eq "$TOTAL_STEPS" ]; then
        printf "\n"
        echo -e "${COLOR_SUCCESS}  Done!!!${COLOR_RESET}"
    fi
}

# Runner for INTERACTIVE tasks (Shows output, allows user input)
run_interactive_task() {
    local task_name="$1"
    local func_name="$2"

    echo -e "${COLOR_INFO}\n--- Starting $task_name (Interactive Setup) ---${COLOR_RESET}\n"

    $func_name
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "${COLOR_SUCCESS}\n  Done!!!${COLOR_RESET}"
    else
        echo -e "${COLOR_ERROR}\n[FAIL] $task_name installation encountered an error.${COLOR_RESET}"
    fi
}


# --- Utility Functions ---

check_if_running_as_root() {
    if [[ "$EUID" -ne 0 ]]; then
        msg_error 'Error: You must run this script as root!'
        exit 1
    fi
}

check_os() {
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "$ID" != "debian" || ! "$VERSION_ID" =~ ^(12|13)$ ]]; then
        msg_warn "This script is made for Debian 12/13. Detected: ${PRETTY_NAME:-unknown}"
        msg_warn "Continue anyway? (y/n)"
        local c
        while true; do
            read -r c
            [[ "$c" =~ ^[Yy]$ ]] && break
            [[ "$c" =~ ^[Nn]$ ]] && exit 1
        done
    fi
}

detect_interface() {
    INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
    fi
}

get_location() {
    local ip api_response
    ip=$(curl -s --max-time 10 https://ipv4.icanhazip.com 2>/dev/null)
    if [ -n "$ip" ]; then
        api_response=$(curl -s --max-time 10 "http://ip-api.com/json/$ip" 2>/dev/null)
        if echo "$api_response" | grep -q '"status":"success"'; then
            CITY=$(echo "$api_response" | jq -r '.city')
            COUNTRY=$(echo "$api_response" | jq -r '.country')
        fi
    fi
}

# All ports sshd really listens on + 2222 (so the firewall never locks us out)
get_ssh_ports() {
    local ports
    ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
    printf '%s\n' ${ports:-22} 2222 | sort -un | paste -sd, -
}

ssh_has_keys() {
    [ -s /root/.ssh/authorized_keys ]
}

# Printed on screen (not into the log) before SSH hardening
ssh_preflight() {
    if ! ssh_has_keys; then
        msg_warn "No SSH key in /root/.ssh/authorized_keys -> password login will stay ENABLED."
        msg_warn "Add your key first (ssh-copy-id -p 2222 root@server), then run SSH config again."
    fi
}


# --- Core Functions ---

install_dependencies() {
    apt-get update $APT_OPTS
    apt-get install $APT_OPTS wget curl sudo jq iproute2 unzip btop ca-certificates
}

fix_etc_hosts() {
    cp "$HOST_PATH" "/etc/hosts.bak"
    if ! grep -qE "[[:space:]]$(hostname)([[:space:]]|\$)" "$HOST_PATH"; then
        echo "127.0.1.1 $(hostname)" | tee -a "$HOST_PATH"
    fi
}

set_timezone() {
    local ip=$(curl -s --max-time 10 "https://ipv4.icanhazip.com")
    if [ -n "$ip" ]; then
        local tz=$(curl -s --max-time 10 "http://ip-api.com/json/$ip" | jq -r '.timezone')
        if [[ "$tz" != "null" && -n "$tz" ]]; then
            timedatectl set-timezone "$tz"
            return 0
        fi
    fi
    timedatectl set-timezone "UTC"
}

complete_update() {
    apt-get update $APT_OPTS
    apt-get upgrade $APT_OPTS
    apt-get autoremove $APT_OPTS
    apt-get clean $APT_OPTS
}

cleanup_system() {
    apt-get autoremove $APT_OPTS --purge
    apt-get clean $APT_OPTS
    journalctl --vacuum-time=7d
}

install_libicu() {
    # libicuNN runtime needed by .NET apps (VpnHoodServer): libicu76 on Debian 13, libicu72 on Debian 12
    local icu_pkg
    apt-get update $APT_OPTS
    icu_pkg=$(apt-cache pkgnames libicu 2>/dev/null | grep -E '^libicu[0-9]+$' | sort -V | tail -n1)
    if [ -n "$icu_pkg" ]; then
        echo "Installing $icu_pkg"
        apt-get install $APT_OPTS "$icu_pkg" libssl3 2>/dev/null || apt-get install $APT_OPTS "$icu_pkg"
    fi
}

installations() {
    apt-get update $APT_OPTS
    apt-get install $APT_OPTS nftables speedtest-cli curl wget sudo jq dialog htop btop iproute2 unzip \
        libicu-dev libevent-dev

    install_libicu
}

enable_packages() {
    systemctl enable nftables
}

swap_maker() {
    if swapon --show=NAME --noheadings | grep -qx "$SWAP_PATH"; then
        echo "Swap $SWAP_PATH already active"
        return 0
    fi
    fallocate -l "$SWAP_SIZE" "$SWAP_PATH" || return 1
    chmod 600 "$SWAP_PATH"
    mkswap "$SWAP_PATH"
    swapon "$SWAP_PATH"
    if ! grep -q "$SWAP_PATH" /etc/fstab; then
        echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
    fi
}

# --- Kernel / network tuning (BBR + fq, TCP & UDP for VPN/proxy server) ---
sysctl_optimizations() {
    # BBR module now and on every boot (+ conntrack, so nf_conntrack sysctls exist)
    modprobe tcp_bbr || true
    modprobe nf_conntrack || true
    printf 'tcp_bbr\nnf_conntrack\n' > /etc/modules-load.d/vpn-tuning.conf

    # Old-style /etc/sysctl.conf is read LAST and would override our drop-in -> neutralize it
    if [ -f /etc/sysctl.conf ] && grep -qE '^[[:space:]]*[a-z]' /etc/sysctl.conf; then
        cp /etc/sysctl.conf /etc/sysctl.conf.bak
        echo "# Settings moved to $SYSCTL_FILE (old file: /etc/sysctl.conf.bak)" > /etc/sysctl.conf
    fi

    cat > "$SYSCTL_FILE" <<EOF
# ===== VPN / proxy server tuning (Debian 12/13) =====
# A leading "-" means: do not fail if the key does not exist (yet).

# --- Congestion control & queueing ---
# BBR needs the fq qdisc for proper pacing (better than fq_codel on lossy links)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Socket buffers (autotuned, these are only the ceilings) ---
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
# UDP (WireGuard/QUIC/Hysteria-style VPNs)
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
# tcp_mem / udp_mem are intentionally NOT set: they are in PAGES and the kernel
# already sizes them from the real amount of RAM.

# --- Queues & backlog ---
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_orphans = 262144
net.ipv4.tcp_max_tw_buckets = 1440000

# --- TCP behaviour on bad / lossy networks ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_notsent_lowat = 32768
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_retries2 = 10

# --- Ports ---
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.ip_local_reserved_ports = 2222,40000,55555

# --- Conntrack (many VPN/proxy flows) ---
-net.netfilter.nf_conntrack_max = 262144

# --- Routing / forwarding ---
net.ipv4.ip_forward = 1
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.neigh.default.gc_thresh1 = 512
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 16384
net.ipv4.neigh.default.gc_stale_time = 60

# --- System ---
net.unix.max_dgram_qlen = 256
vm.min_free_kbytes = 65536
vm.swappiness = 10
vm.vfs_cache_pressure = 250
vm.dirty_ratio = 20
fs.file-max = 67108864
fs.nr_open = 1048576
kernel.panic = 1

# --- Turn off IPv6 ---
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.disable_ipv6 = 1
-net.ipv6.conf.${INTERFACE}.disable_ipv6 = 1

# --- Windows OS fingerprint ---
net.ipv4.ip_default_ttl = 128
net.ipv4.route.min_adv_mss = 1460
EOF

    sysctl --system

    echo "Active congestion control: $(sysctl -n net.ipv4.tcp_congestion_control)"
    echo "Active qdisc default:      $(sysctl -n net.core.default_qdisc)"
    [ "$(sysctl -n net.ipv4.tcp_congestion_control)" = "bbr" ]
}

# --- SSH: drop-in file in sshd_config.d (it has priority over the main file) ---
ssh_config() {
    mkdir -p /etc/ssh/sshd_config.d /run/sshd
    [ -f /etc/ssh/sshd_config.bak ] || cp "$SSH_PATH" /etc/ssh/sshd_config.bak

    # Make sure the main config includes the drop-in directory
    if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSH_PATH"; then
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSH_PATH"
    fi

    # "Port" is additive in sshd -> comment out any other Port lines, otherwise 22 stays open too
    local f
    for f in "$SSH_PATH" /etc/ssh/sshd_config.d/*.conf; do
        [ -f "$f" ] || continue
        [ "$f" = "$SSH_DROPIN" ] && continue
        sed -i -E 's/^([[:space:]]*Port[[:space:]]+.*)$/#\1/' "$f"
    done

    # Never lock ourselves out: disable passwords only if a key is installed
    local pass_auth="no" root_login="prohibit-password"
    if ! ssh_has_keys; then
        pass_auth="yes"
        root_login="yes"
        echo "WARNING: no authorized_keys for root -> PasswordAuthentication stays enabled"
    fi

    cat > "$SSH_DROPIN" <<EOF
Port 2222
PermitRootLogin ${root_login}
PubkeyAuthentication yes
PasswordAuthentication ${pass_auth}
KbdInteractiveAuthentication no
UseDNS no
Compression yes
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
TCPKeepAlive yes
ClientAliveInterval 3000
ClientAliveCountMax 100
AllowAgentForwarding yes
AllowTcpForwarding yes
GatewayPorts yes
PermitTunnel yes
X11Forwarding yes
Banner none
EOF

    if ! sshd -t; then
        echo "sshd config test FAILED, removing $SSH_DROPIN"
        rm -f "$SSH_DROPIN"
        return 1
    fi

    # If socket activation is used it would keep port 22
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl disable --now ssh.socket
        systemctl enable ssh.service
    fi
    systemctl restart ssh || systemctl restart sshd
}

# --- Limits: PAM (logins) + systemd default (services) ---
limits_optimizations() {
    # remove old-style ulimit lines from /etc/profile (they never applied to services anyway)
    sed -i '/^ulimit -.*$/d' /etc/profile

    cat > "$LIMITS_FILE" <<EOF
*    soft nofile 1048576
*    hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system.conf.d
    cat > "$SYSTEMD_LIMITS" <<EOF
[Manager]
DefaultLimitNOFILE=1048576:1048576
EOF
    systemctl daemon-reexec
}

# --- Firewall ---
nft_prepare() {
    apt-get purge firewalld $APT_OPTS 2>/dev/null || true
    apt-get update $APT_OPTS
    apt-get install nftables $APT_OPTS
    systemctl enable nftables
    SSH_PORTS=$(get_ssh_ports)
}

# $1 = base | tun2socks
nft_build() {
    local mode="$1"
    local NFTCONF="/etc/nftables.conf"
    local NFTTMP="/etc/nftables.conf.new"
    local out_extra="" mangle=""

    nft_prepare

    if [ "$mode" = "tun2socks" ]; then
        local vh_uid
        vh_uid=$(id -u vpnhood 2>/dev/null || echo 996)
        out_extra="meta skuid ${vh_uid} ip6 daddr != ::1 drop"
        mangle='
table ip mangle {
    chain output {
        type route hook output priority mangle; policy accept;
        ip daddr 127.0.0.0/8 return
        tcp sport 40000 return
        udp sport 40000 return
        meta skuid @UID@ mark set 1
    }
}'
        mangle=${mangle//@UID@/$vh_uid}
    fi

    cat > "$NFTTMP" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        meta nfproto ipv6 drop
        ct state established,related accept
        ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
        iifname "${INTERFACE}" tcp dport { ${SSH_PORTS} } accept
        iifname "${INTERFACE}" tcp dport { 80, 443, 40000, 55555 } accept
        iifname "${INTERFACE}" udp dport 1024-65535 accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
        ${out_extra}
    }
}
${mangle}
EOF

    if ! nft -c -f "$NFTTMP"; then
        echo "nftables config check FAILED, old config kept"
        rm -f "$NFTTMP"
        return 1
    fi
    mv "$NFTTMP" "$NFTCONF"
    systemctl restart nftables
    # 'flush ruleset' wipes fail2ban's tables -> recreate them
    if systemctl is-active --quiet fail2ban; then
        systemctl restart fail2ban
    fi
}

nft_optimizations()         { nft_build base; }
nft_tun2socks_optimizations() { nft_build tun2socks; }

install_key() {
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    wget -q -O /tmp/ssh_key.pub "$SSH_KEY_URL" || return 1
    touch /root/.ssh/authorized_keys
    # add only if not there yet
    while IFS= read -r line; do
        [ -n "$line" ] && ! grep -qxF "$line" /root/.ssh/authorized_keys && echo "$line" >> /root/.ssh/authorized_keys
    done < /tmp/ssh_key.pub
    chmod 600 /root/.ssh/authorized_keys
    rm -f /tmp/ssh_key.pub
}

f2b_install() {
    apt-get update $APT_OPTS && apt-get install fail2ban python3-systemd $APT_OPTS
    local ports
    ports=$(get_ssh_ports)
    # Debian 12/13 have no auth.log by default -> use the systemd journal backend
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime.increment = true
bantime.rndtime = 10m
bantime.factor = 1
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * banFactor
bantime.multipliers = 1 5 30 60 300 720 1440 2880
ignoreself = true
ignoreip = 127.0.0.1/8
bantime  = 1h
findtime  = 10m
maxretry = 3
backend = systemd
banaction = nftables[type=multiport]
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
port    = ${ports}
backend = systemd

[recidive]
enabled = true
backend = auto
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
EOF
    systemctl enable --now fail2ban
    systemctl restart fail2ban
}

systemd_resolved() {
    apt-get update $APT_OPTS && apt-get install systemd-resolved $APT_OPTS
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
Cache=yes
EOF
    systemctl restart systemd-resolved
}

dnsproxy() {
    cd /tmp || return 1
    VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest | jq -r '.tag_name')
    wget -qO dnsproxy.tar.gz "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-amd64-${VERSION}.tar.gz" || return 1
    tar -xzf dnsproxy.tar.gz
    mv linux-amd64/dnsproxy /usr/bin/dnsproxy
    rm -rf linux-amd64 dnsproxy.tar.gz

    cat << 'EOF' > /etc/systemd/system/dnsproxy.service
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

    systemctl daemon-reload
    systemctl disable systemd-resolved --now 2>/dev/null || true
    systemctl enable --now dnsproxy
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

ciadpi() {
    apt-get install -y build-essential
    bash <(wget -qO- https://raw.githubusercontent.com/Onair-santa/Byedpi-Setup/refs/heads/main/ciadpi.sh)
}

tun2socks_install() {
    apt-get update $APT_OPTS && apt-get install $APT_OPTS unzip wget
    wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip -O /tmp/tun2socks.zip
    unzip -o /tmp/tun2socks.zip -d /tmp/
    mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    rm -f /tmp/tun2socks.zip
    mkdir -p /etc/iproute2
    if ! grep -q "socks_table" /etc/iproute2/rt_tables 2>/dev/null; then
        echo "200 socks_table" >> /etc/iproute2/rt_tables
    fi

    cat <<'EOF' > /etc/systemd/system/tun2socks.service
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

    systemctl daemon-reload
    systemctl enable --now tun2socks
}

synth_shell() {
    cd /root || return 1
    apt-get update $APT_OPTS && apt-get install bc fonts-powerline git $APT_OPTS
    git clone --recursive https://github.com/andresgongora/synth-shell.git
    chmod +x synth-shell/setup.sh
    ~/synth-shell/setup.sh
    rm -f ~/.config/synth-shell/synth-shell-greeter.config.default
    rm -f ~/.config/synth-shell/synth-shell-greeter.config
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.config -q -O ~/.config/synth-shell/synth-shell-greeter.config
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.sh -q -O ~/.config/synth-shell/synth-shell-greeter.sh
}

# Official 3X-UI installer (latest version, interactive)
xui() {
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

vpnhood() {
    # Default settings and configuration parameters
    local packageUrl="https://github.com/vpnhood/VpnHood/releases/download/v3.2.448/VpnHoodServer-linux-x64.tar.gz"
    local versionTag="v3.2.448"
    local destinationPath="/opt/VpnHoodServer"
    local binDir="$destinationPath/$versionTag"
    local APPSET="$destinationPath/storage/appsettings.json"
    local EXTIP=$(curl -s ifconfig.me || curl -s ipv4.icanhazip.com)

    # Clean old services/updaters if they exist
    systemctl stop VpnHoodServer >/dev/null 2>&1 || true
    systemctl stop VpnHoodUpdater >/dev/null 2>&1 || true
    systemctl disable VpnHoodUpdater >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/VpnHoodUpdater.service
    rm -f /VpnHoodServer-linux.tar.gz

    # Prompt user for port
    local vh_port
    while true; do
        read -r -p "Enter port for VpnHood Server (default 443): " vh_port
        vh_port=${vh_port:-443}
        if [[ "$vh_port" =~ ^[0-9]+$ ]] && [ "$vh_port" -ge 1 ] && [ "$vh_port" -le 65535 ]; then
            break
        else
            echo -e "${COLOR_ERROR}Invalid port! Please enter a number between 1 and 65535.${COLOR_RESET}"
        fi
    done

    # .NET runtime dependencies (ICU)
    install_libicu >/dev/null 2>&1

    # Download VpnHoodServer
    echo -e "${COLOR_INFO}Downloading VpnHoodServer package...${COLOR_RESET}"
    local packageFile="VpnHoodServer-linux.tar.gz"
    wget -nv -O "$packageFile" "$packageUrl"
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_ERROR}Error: Could not download VpnHoodServer.${COLOR_RESET}"
        return 1
    fi

    # Extract
    echo -e "${COLOR_INFO}Extracting package content...${COLOR_RESET}"
    mkdir -p "$destinationPath"
    tar -xzf "$packageFile" -C "$destinationPath"
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_ERROR}Error: Could not extract VpnHoodServer.${COLOR_RESET}"
        rm -f "$packageFile"
        return 1
    fi
    rm -f "$packageFile"

    # Updating shared files layout
    echo -e "${COLOR_INFO}Updating shared files and paths...${COLOR_RESET}"
    local infoDir="$binDir/publish_info"
    cp "$infoDir/vhserver" "$destinationPath/" -f
    cp "$infoDir/publish.json" "$destinationPath/" -f
    chmod +x "$binDir/VpnHoodServer"
    chmod +x "$destinationPath/vhserver"

    # Config appsettings.json
    mkdir -p "$destinationPath/storage"
    wget "https://github.com/Onair-santa/VpnHood/releases/download/v3.2/appsettings.json" -q -O "$APPSET"
    sed -i "s/externalip/${EXTIP}/g" "$APPSET"

    if [ "$vh_port" != "443" ]; then
        sed -i "s/:443/:${vh_port}/g" "$APPSET" 2>/dev/null || true
    fi

    # Initialize Systemd service and configure user permissions
    local service_file="/etc/systemd/system/VpnHoodServer.service"

    if [ "$vh_port" -eq 443 ]; then
        # Running as root for port 443 binding
        chown -R root:root "$destinationPath"

        cat > "$service_file" <<EOF
[Unit]
Description=VpnHood Server
After=network.target

[Service]
Type=simple
ExecStart=$binDir/VpnHoodServer
ExecStop=$binDir/VpnHoodServer stop
TimeoutStartSec=0
Restart=always
RestartSec=10
StandardOutput=null
StandardError=journal
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    else
        # Running from an isolated system user for safety on alternative ports
        if ! id vpnhood >/dev/null 2>&1; then
            if getent passwd 996 >/dev/null; then
                echo -e "${COLOR_WARNING}UID 996 is already used by '$(getent passwd 996 | cut -d: -f1)', creating vpnhood with another UID${COLOR_RESET}"
                useradd -r -s /usr/sbin/nologin vpnhood
            else
                useradd -r -s /usr/sbin/nologin -u 996 vpnhood
            fi
        fi
        if ! id vpnhood >/dev/null 2>&1; then
            echo -e "${COLOR_ERROR}Could not create user vpnhood${COLOR_RESET}"
            return 1
        fi
        chown -R vpnhood:vpnhood "$destinationPath"

        # keep the nftables rules (meta skuid) in sync with the real UID
        local vh_uid
        vh_uid=$(id -u vpnhood)
        if [ -f /etc/nftables.conf ] && grep -q 'meta skuid' /etc/nftables.conf; then
            sed -i -E "s/meta skuid [0-9]+/meta skuid ${vh_uid}/g" /etc/nftables.conf
            systemctl restart nftables
        fi

        cat > "$service_file" <<EOF
[Unit]
Description=VpnHood Server
After=network.target

[Service]
Type=simple
User=vpnhood
Group=vpnhood
ExecStart=$binDir/VpnHoodServer
ExecStop=$binDir/VpnHoodServer stop
TimeoutStartSec=0
Restart=always
RestartSec=10
StandardOutput=null
StandardError=journal
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    fi

    # Apply & run services
    systemctl daemon-reload
    systemctl enable VpnHoodServer.service
    systemctl restart VpnHoodServer.service

    sleep 3
    if ! systemctl is-active --quiet VpnHoodServer.service; then
        echo -e "${COLOR_ERROR}VpnHoodServer failed to start. Last log lines:${COLOR_RESET}"
        systemctl status VpnHoodServer.service --no-pager -l | head -n 15
        journalctl -u VpnHoodServer.service -n 30 --no-pager
        return 1
    fi

    # Access Token Generation
    echo -e "${COLOR_INFO}Generating AccessKey...${COLOR_RESET}"
    sudo "$destinationPath/vhserver" gen -ep "$EXTIP"
}

ask_reboot() {
    msg_warn 'Reboot now? (Recommended) (y/n)'
    while true; do
        read -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            reboot
            exit 0
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
            break
        fi
    done
}


# --- Menu Display & Main Loop ---

show_menu() {
    clear
    msg_info "========================================="
    msg_info "  VPS Management Script (Debian 12 / 13)"
    if [[ "$CITY" != "Unknown City" ]]; then
        msg_info "   Location: $CITY, $COUNTRY"
    else
        msg_warn "   (Location unknown)"
    fi
    msg_info "========================================="
    msg_warn "              Choose One Option:"
    echo ""

    msg_success '1. Full Setup (Update + All Optimizations)'
    msg_success '2. Quick Update & Core Optimizations'
    echo ""
    msg_info '3. System Cleanup'
    msg_info '4. Install Packages (htop, btop, iproute2, jq, dialog, unzip, libicu, libicu-dev, libevent-dev)'
    msg_info '5. Configure SWAP (1Gb)'
    msg_info '6. Network & SSH Hardening + Limits'
    echo ""
    msg_warn '7. Network Sysctl Settings (BBR + fq)'
    msg_warn '8. SSH Configuration Only (Port 2222)'
    msg_warn '9. System Limits'
    msg_warn '10. Firewall Setup (NFTables)'
    msg_warn '11. Install Synth-Shell'
    msg_warn '12. Fail2ban Installation'
    echo ""
    msg_success '13. DNS Proxy Resolver Setup'
    msg_success '14. Systemd Resolved DNS Setup'
    msg_success '15. ByeDPI Installation'
    msg_success '16. Tun2socks Installation'
    msg_success '17. NFTables for tun2socks+ciadpi+VPNHood'
    msg_success '18. VpnHood Server Installation'
    msg_success '19. 3X-UI (official installer)'
    echo ""
    msg_error 'Q - Exit Script'
    echo "-----------------------------------------"
}

# --- Main Execution Flow ---

main() {
    check_if_running_as_root
    check_os

    msg_info "Initializing system (checking deps, interface, timezone)..."
    detect_interface

    set_steps 3
    run_task "Installing base utilities" "install_dependencies"
    run_task "Fixing /etc/hosts" "fix_etc_hosts"
    run_task "Setting timezone" "set_timezone"
    get_location

    while true; do
        show_menu
        read -r -p 'Enter Your Choice: ' choice
        case $choice in
        1)
            set_steps 8
            run_task "Updating & cleaning system" "complete_update"
            run_task "Installing useful packages" "installations"
            run_task "Enabling services" "enable_packages"
            run_task "Optimizing network (Sysctl + BBR)" "sysctl_optimizations"
            run_task "Optimizing system limits" "limits_optimizations"
            run_task "Installing SSH key" "install_key"
            run_task "Optimizing SSH (Port 2222)" "ssh_config"
            run_task "Configuring Firewall (NFTables)" "nft_optimizations"
            run_interactive_task "Installing Synth-Shell" "synth_shell"
            ask_reboot
            ;;
        2)
            ssh_preflight
            set_steps 4
            run_task "Updating system" "complete_update"
            run_task "Optimizing network" "sysctl_optimizations"
            run_task "Configuring SSH" "ssh_config"
            run_task "Optimizing limits" "limits_optimizations"
            ;;
        3) set_steps 1; run_task "Cleaning system" "cleanup_system" ;;
        4) set_steps 1; run_task "Installing packages" "installations" ;;
        5) set_steps 1; run_task "Configuring SWAP" "swap_maker" ;;
        6)
            ssh_preflight
            set_steps 3
            run_task "Configuring Sysctl" "sysctl_optimizations"
            run_task "Configuring SSH" "ssh_config"
            run_task "Optimizing limits" "limits_optimizations"
            ;;
        7) set_steps 1; run_task "Configuring Sysctl" "sysctl_optimizations" ;;
        8) ssh_preflight; set_steps 1; run_task "Applying SSH config" "ssh_config" ;;
        9) set_steps 1; run_task "Optimizing limits" "limits_optimizations" ;;
        10) set_steps 1; run_task "Configuring Firewall" "nft_optimizations" ;;
        11) run_interactive_task "Installing Synth-Shell" "synth_shell" ;;
        12) set_steps 1; run_task "Installing Fail2Ban" "f2b_install" ;;
        13) set_steps 1; run_task "Installing DNS Proxy" "dnsproxy" ;;
        14) set_steps 1; run_task "Configuring Systemd Resolved" "systemd_resolved" ;;
        15) run_interactive_task "ByeDPI" "ciadpi" ;;
        16) set_steps 1; run_task "Installing Tun2socks" "tun2socks_install" ;;
        17) set_steps 1; run_task "Special NFTables config" "nft_tun2socks_optimizations" ;;
        18) run_interactive_task "VpnHood" "vpnhood" ;;
        19) run_interactive_task "3X-UI" "xui" ;;
        q|Q) echo ""; msg_info "Goodbye!"; exit 0 ;;
        *) msg_error "Wrong input! Please try again." ;;
        esac

        echo ""
        read -r -p "Press Enter to return to menu..."
    done
}

main "$@"
