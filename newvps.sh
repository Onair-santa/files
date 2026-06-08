#!/bin/bash

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
SYS_PATH="/etc/sysctl.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE="1G"

# Global Progress State
TOTAL_STEPS=1
CURRENT_STEP=0

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
    
    # Safe ASCII progress bar chars
    local bar=$(printf "%${filled}s" | tr ' ' '=')
    local empty_bar=$(printf "%${empty}s" | tr ' ' '.')
    
    # Draw progress line
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
    
    # Run completely open to the terminal
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

detect_os() {
    if grep -q "^ID=debian" /etc/os-release; then
        echo "debian"
    elif grep -qE '^(Ubuntu|ubuntugui)' /etc/os-release; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}

detect_interface() {
    INTERFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
    if [ -z "$INTERFACE" ]; then
        INTERFACE="eth0"
    fi
}


# --- Core Functions ---

install_dependencies() {
    apt-get update $APT_OPTS
    apt-get install $APT_OPTS wget curl sudo jq iproute2 unzip
}

fix_etc_hosts() { 
    cp "$HOST_PATH" "/etc/hosts.bak"
    if ! grep -q "^$(hostname)$" "$HOST_PATH"; then
        echo "127.0.1.1 $(hostname)" | tee -a "$HOST_PATH"
    fi
}

set_timezone() {
    local ip=$(curl -s "https://ipv4.icanhazip.com")
    if [ -n "$ip" ]; then
        local tz=$(curl -s "http://ip-api.com/json/$ip" | jq -r '.timezone')
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

installations() {
    apt-get install $APT_OPTS nftables speedtest-cli curl wget jq dialog htop unzip
}

enable_packages() {
    systemctl enable nftables
}

swap_maker() {
    fallocate -l "$SWAP_SIZE" "$SWAP_PATH"
    chmod 600 "$SWAP_PATH"
    mkswap "$SWAP_PATH"
    swapon "$SWAP_PATH"
    if ! grep -q "$SWAP_PATH" /etc/fstab; then
        echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
    fi
}

sysctl_optimizations() {
    cp "$SYS_PATH" "/etc/sysctl.conf.bak"
    wget "https://raw.githubusercontent.com/Onair-santa/files/main/sysctl.conf" -q -O "$SYS_PATH"
    sed -i '/net.ipv6.conf.\([a-zA-Z0-9]*\).disable_ipv6/d' "$SYS_PATH"
    echo "net.ipv6.conf.${INTERFACE}.disable_ipv6 = 1" >> "$SYS_PATH"
    sysctl -p
}

find_ssh_port() {
    SSH_PORT=$(grep -E "^Port\s+([0-9]+)" "$SSH_PATH" 2>/dev/null | awk '{print $2}')
    if [ -z "$SSH_PORT" ]; then
        SSH_PORT=22
    fi
}

remove_old_ssh_conf() {
    cp "$SSH_PATH" "/etc/ssh/sshd_config.bak"
    sed -i 's/#UseDNS yes/UseDNS no/' "$SSH_PATH"
    sed -i 's/#Compression no/Compression yes/' "$SSH_PATH"
    sed -i 's/Ciphers .*/Ciphers aes256-ctr,chacha20-poly1305@openssh.com/' "$SSH_PATH"
    grep -vE '^(MaxAuthTries|MaxSessions|TCPKeepAlive|ClientAliveInterval|ClientAliveCountMax|AllowAgentForwarding|AllowTcpForwarding|GatewayPorts|PermitTunnel|X11Forwarding|Port|PubkeyAuthentication|PasswordAuthentication)' "$SSH_PATH" > /tmp/temp_ssh
    mv /tmp/temp_ssh "$SSH_PATH"
}

update_sshd_conf() {
    {
        echo "TCPKeepAlive yes"
        echo "ClientAliveInterval 3000"
        echo "ClientAliveCountMax 100"
        echo "AllowAgentForwarding yes"
        echo "AllowTcpForwarding yes"
        echo "GatewayPorts yes"
        echo "PermitTunnel yes"
        echo "X11Forwarding yes"
        echo "Port 2222"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication no"
        echo "UseDNS no"
        echo "Banner none"
    } >> "$SSH_PATH"
    systemctl restart ssh || systemctl restart sshd
}

limits_optimizations() {
    sed -i '/^ulimit -.*$/d' "$PROF_PATH"
    {
        echo "ulimit -c unlimited"
        echo "ulimit -d unlimited"
        echo "ulimit -f unlimited"
        echo "ulimit -i unlimited"
        echo "ulimit -l unlimited"
        echo "ulimit -m unlimited"
        echo "ulimit -n 1048576"
        echo "ulimit -q unlimited"
        echo "ulimit -s -H 65536"
        echo "ulimit -s 32768"
        echo "ulimit -t unlimited"
        echo "ulimit -u unlimited"
        echo "ulimit -v unlimited"
        echo "ulimit -x unlimited"
    } >> "$PROF_PATH"
}

nft_optimizations() {
    apt-get purge firewalld $APT_OPTS 2>/dev/null || true
    apt-get update $APT_OPTS
    apt-get install nftables $APT_OPTS
    
    systemctl start nftables
    systemctl enable nftables

    local NFTCONF="/etc/nftables.conf"
    
    cat > "$NFTCONF" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state established,related accept
        iifname "$INTERFACE" tcp dport 2222 accept
        iifname "$INTERFACE" tcp dport 80 accept
        iifname "$INTERFACE" tcp dport 443 accept
        iifname "$INTERFACE" udp dport 1024-65535 accept
        iifname "$INTERFACE" tcp dport 55555 accept
        iifname "$INTERFACE" tcp dport 40000 accept
        iifname "$INTERFACE" udp dport 40000 accept
    }
    chain forward {
        type filter hook forward priority filter; policy accept;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
    systemctl restart nftables
}

nft_tun2socks_optimizations() {
    apt-get purge firewalld $APT_OPTS 2>/dev/null || true
    apt-get update $APT_OPTS
    apt-get install nftables $APT_OPTS
    
    systemctl start nftables
    systemctl enable nftables

    local NFTCONF="/etc/nftables.conf"
    
    cat > "$NFTCONF" <<EOF
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

    systemctl restart nftables
}

install_key() {
    wget -O /tmp/id_ed25519.pub https://raw.githubusercontent.com/Onair-santa/files/main/id_ed25519.pub
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    cat /tmp/id_ed25519.pub >> /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    rm /tmp/id_ed25519.pub
}

f2b_install() {
    apt-get update $APT_OPTS && apt-get install fail2ban $APT_OPTS
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
banaction = nftables[type=multiport]
banaction_allports = nftables[type=allports]

[sshd]
enabled = true
port    = 2222
logpath = %(sshd_log)s
backend = %(sshd_backend)s

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime = 1w
findtime = 1d
EOF
    systemctl enable --now fail2ban
    fail2ban-client reload
}

systemd_resolved() {
    systemctl enable systemd-resolved
    systemctl start systemd-resolved
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    cat > /etc/systemd/resolved.conf <<EOF
[Resolve]
DNS=1.1.1.1
FallbackDNS=1.0.0.1
Cache=no-negative
EOF
    systemctl restart systemd-resolved
}

dnsproxy() {
    VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest | jq -r '.tag_name')
    wget -qO dnsproxy.tar.gz "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-amd64-${VERSION}.tar.gz"
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
    systemctl enable --now dnsproxy
    systemctl disable systemd-resolved --now 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
}

ciadpi() {
    bash <(wget -qO- https://raw.githubusercontent.com/Onair-santa/Byedpi-Setup/refs/heads/main/install.sh)
}

tun2socks_install() {
    apt-get update $APT_OPTS && apt-get install $APT_OPTS unzip wget
    wget -q https://github.com/xjasonlyu/tun2socks/releases/download/v2.5.2/tun2socks-linux-amd64.zip -O /tmp/tun2socks.zip
    unzip -o /tmp/tun2socks.zip -d /tmp/
    mv /tmp/tun2socks-linux-amd64 /usr/local/bin/tun2socks
    chmod +x /usr/local/bin/tun2socks
    rm -f /tmp/tun2socks.zip
    mkdir -p /etc/iproute2
    if ! grep -q "socks_table" /etc/iproute2/rt_tables; then
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
    apt-get update $APT_OPTS && apt-get install bc fonts-powerline git $APT_OPTS
    rm -rf /tmp/synth-shell
    git clone --recursive https://github.com/andresgongora/synth-shell.git /tmp/synth-shell
    chmod +x /tmp/synth-shell/setup.sh
    /tmp/synth-shell/setup.sh -y
    rm -f ~/.config/synth-shell/synth-shell-greeter.config*
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.config -q -O ~/.config/synth-shell/synth-shell-greeter.config
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.sh -q -O ~/.config/synth-shell/synth-shell-greeter.sh
}

xui() {
    cd /root/ || exit 1
    wget -q https://github.com/Onair-santa/3X-UI-Debian11/releases/download/2.4.1/x-ui-linux-amd64.tar.gz
    rm -rf x-ui/ /usr/local/x-ui/ /usr/bin/x-ui
    tar zxf x-ui-linux-amd64.tar.gz
    chmod +x x-ui/x-ui x-ui/bin/xray-linux-* x-ui/x-ui.sh
    cp x-ui/x-ui.sh /usr/bin/x-ui
    cp -f x-ui/x-ui.service /etc/systemd/system/
    mv x-ui/ /usr/local/
    rm x-ui-linux-amd64.tar.gz
    systemctl daemon-reload
    systemctl enable --now x-ui
}

amnezia() {
    wget -q https://raw.githubusercontent.com/romikb/amneziawg-install/main/amneziawg-install.sh -O /tmp/amneziawg-install.sh 
    chmod +x /tmp/amneziawg-install.sh 
    bash /tmp/amneziawg-install.sh
}

repo_debian() {
   cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bullseye main
deb-src http://deb.debian.org/debian bullseye main
deb http://security.debian.org/debian-security bullseye-security main
deb-src http://security.debian.org/debian-security bullseye-security main
deb http://deb.debian.org/debian bullseye-updates main
deb-src http://deb.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian bullseye-backports main
deb-src http://archive.debian.org/debian bullseye-backports main
EOF
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
    local city="Unknown City"
    local country="Unknown Country"

    local ip=$(curl -s https://ipv4.icanhazip.com 2>/dev/null)
    if [ -n "$ip" ]; then
        local api_response=$(curl -s "http://ip-api.com/json/$ip" 2>/dev/null)
        if echo "$api_response" | grep -q '"status":"success"'; then
            city=$(echo "$api_response" | jq -r '.city')
            country=$(echo "$api_response" | jq -r '.country')
        fi
    fi

    clear
    msg_info "========================================="
    msg_info "  Welcome to your VPS Management Script!"
    if [[ "$city" != "Unknown City" ]]; then
        msg_info "   Location: $city, $country" 
    else
        msg_warn "   (Waiting for network connection...)"
    fi
    msg_info "========================================="
    msg_warn "              Choose One Option:"
    echo ""

    msg_success '1. Full Setup (Update + All Optimizations)'
    msg_success '2. Change Repository to Debian 11'
    msg_success '3. Quick Update & Core Optimizations'
    echo ""
    msg_info '4. System Cleanup'
    msg_info '5. Install Packages (htop, curl, nftables...)'
    msg_info '6. Configure SWAP (1Gb)'
    msg_info '7. Network & SSH Hardening + Limits'
    echo ""
    msg_warn '8. Network Sysctl Settings'
    msg_warn '9. SSH Configuration Only (Port 2222)'
    msg_warn '10. System Limits'
    msg_warn '11. Firewall Setup (NFTables)'
    msg_warn '12. Install Synth-Shell'
    msg_warn '13. Fail2ban Installation'
    echo ""
    msg_success '14. DNS Proxy Resolver Setup'
    msg_success '15. Systemd Resolved DNS Setup'
    msg_success '16. ByeDPI Installation'
    msg_success '17. Tun2socks Installation'
    msg_success '18. NFTables for tun2socks+ciadpi+VPNHood'
    msg_success '19. X-UI (V2Ray/Xray)'
    msg_success '20. AmneziaWG Installation'
    echo ""
    msg_error 'Q - Exit Script'
    echo "-----------------------------------------"
}

# --- Main Execution Flow ---

main() {
    check_if_running_as_root
    
    msg_info "Initializing system (checking deps, interface, timezone)..."
    detect_interface 
    
    set_steps 3
    run_task "Installing base utilities" "install_dependencies"
    run_task "Fixing /etc/hosts" "fix_etc_hosts"
    run_task "Setting timezone" "set_timezone"

    while true; do
        show_menu
        read -r -p 'Enter Your Choice: ' choice
        case $choice in
        1) 
            set_steps 11
            run_task "Updating & cleaning system" "complete_update"
            run_task "Installing useful packages" "installations"
            run_task "Enabling services" "enable_packages"
            run_task "Optimizing network (Sysctl)" "sysctl_optimizations"
            run_task "Resetting old SSH config" "remove_old_ssh_conf"
            run_task "Optimizing SSH (Port 2222)" "update_sshd_conf"
            run_task "Optimizing system limits" "limits_optimizations"
            run_task "Finding active SSH port" "find_ssh_port"
            run_task "Configuring Firewall (NFTables)" "nft_optimizations"
            run_task "Installing SSH key" "install_key"
            run_task "Installing Synth-Shell" "synth_shell"
            ask_reboot
            ;;
        2) set_steps 1; run_task "Changing Debian 11 repositories" "repo_debian" ;;
        3) 
            set_steps 4
            run_task "Updating system" "complete_update"
            run_task "Optimizing network" "sysctl_optimizations"
            run_task "Configuring SSH" "update_sshd_conf"
            run_task "Optimizing limits" "limits_optimizations"
            ;;
        4) set_steps 1; run_task "Cleaning system" "complete_update" ;;
        5) set_steps 1; run_task "Installing packages" "installations" ;;
        6) set_steps 1; run_task "Configuring SWAP" "swap_maker" ;;
        7) 
            set_steps 3
            run_task "Configuring Sysctl" "sysctl_optimizations"
            run_task "Configuring SSH" "update_sshd_conf"
            run_task "Optimizing limits" "limits_optimizations"
            ;;
        8) set_steps 1; run_task "Configuring Sysctl" "sysctl_optimizations" ;;
        9) set_steps 2; run_task "Cleaning old SSH config" "remove_old_ssh_conf"; run_task "Applying new SSH config" "update_sshd_conf" ;;
        10) set_steps 1; run_task "Optimizing limits" "limits_optimizations" ;;
        11) set_steps 1; run_task "Configuring Firewall" "nft_optimizations" ;;
        12) set_steps 1; run_task "Installing Synth-Shell" "synth_shell" ;;
        13) set_steps 1; run_task "Installing Fail2Ban" "f2b_install" ;;
        14) set_steps 1; run_task "Installing DNS Proxy" "dnsproxy" ;;
        15) set_steps 1; run_task "Configuring Systemd Resolved" "systemd_resolved" ;;
        16) run_interactive_task "ByeDPI" "ciadpi" ;;
        17) set_steps 1; run_task "Installing Tun2socks" "tun2socks_install" ;;
        18) set_steps 1; run_task "Special NFTables config" "nft_tun2socks_optimizations" ;;
        19) set_steps 1; run_task "Installing X-UI" "xui" ;;
        20) run_interactive_task "AmneziaWG" "amnezia" ;;
        q|Q) echo ""; msg_info "Goodbye!"; exit 0 ;;
        *) msg_error "Wrong input! Please try again." ;;
        esac
        
        echo ""
        read -r -p "Press Enter to return to menu..."
    done
}

main "$@"
