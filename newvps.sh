#!/bin/bash

# --- Configuration & Styling ---

# Green, Yellow & Red Messages using tput for color (ANSI codes)
green_msg() {
    tput setaf 2
    echo "  $1"
    tput sgr0
}

yellow_msg() {
    tput setaf 3
    echo "  $1"
    tput sgr0
}

red_msg() {
    tput setaf 1
    echo "  $1"
    tput sgr0
}

cyn_msg() {
    tput setaf 6
    echo "  $1"
    tput sgr0
}

# Paths
HOST_PATH="/etc/hosts"
SYS_PATH="/etc/sysctl.conf"
PROF_PATH="/etc/profile"
SSH_PATH="/etc/ssh/sshd_config"
SWAP_PATH="/swapfile"
SWAP_SIZE=1G


# --- Utility Functions ---

# Root Check
check_if_running_as_root() {
    if [[ "$EUID" -ne 0 ]]; then
        red_msg 'Error: You must run this script as root!'
        echo ""
        sleep 0.5
        exit 1
    fi
}

# OS Detection
detect_os() {
    if grep -q "^ID=debian" /etc/os-release; then
        echo "debian"
    elif grep -qE '^(Ubuntu|ubuntugui)' /etc/os-release; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}


# --- Core Functions (Modules) ---

install_dependencies() {
  local os=$1
  yellow_msg 'Installing Dependencies...'
  sleep 0.5

  if [[ "$os" == "ubuntu" || "$os" == "debian" ]]; then
    apt update -q
    apt install -y wget curl sudo jq
    green_msg 'Dependencies Installed successfully.'
  else
    red_msg "Unsupported OS for dependency installation."
  fi
  sleep 0.5
}

fix_etc_hosts() { 
  echo ""
  yellow_msg "Fixing Hosts file..."
  sleep 0.3

  # FIX: Added quotes around variables for safety
  cp "$HOST_PATH" "/etc/hosts.bak"
  yellow_msg "Default hosts file backed up to /etc/hosts.bak"
  sleep 0.3

  if ! grep -q "^$(hostname)$" "$HOST_PATH"; then
    echo "127.0.1.1 $(hostname)" | tee -a "$HOST_PATH" > /dev/null
    green_msg "Hosts Fixed."
  else
    green_msg "Hosts OK. No changes made."
  fi
  sleep 0.3
}

set_timezone() {
    echo ""
    yellow_msg 'Setting TimeZone based on VPS IP address...'
    sleep 0.5

    # FIX: Revised location fetching to correctly process JSON output
    get_location_info() {
        local ip=$(curl -s "https://ipv4.icanhazip.com")
        if [ -n "$ip" ]; then
            # Attempt to fetch location data for the retrieved IP
            curl -s "http://ip-api.com/json/$ip" 2>/dev/null
        fi
    }

    location_data=$(get_location_info)
    
    if [ -n "$location_data" ]; then
        # Use jq to reliably extract timezone from the retrieved JSON
        timezones=$(echo "$location_data" | jq -r '.timezone')

        if [[ "$timezones" != "null" && -n "$timezones" ]]; then
            sudo timedatectl set-timezone "$timezones"
            green_msg "Timezone successfully set to $timezones."
        else
            red_msg "Error: Could not parse timezone from IP API response. Setting timezone to UTC."
            sudo timedatectl set-timezone "UTC"
        fi
    else
        red_msg "Error: Failed to fetch location information. Setting timezone to UTC."
        sudo timedatectl set-timezone "UTC"
    fi

    sleep 0.5
}

ext_interface () {
    for interface in /sys/class/net/*; do
        [[ "${interface##*/}" != 'lo' ]] && \
            ping -c1 -W2 -I "${interface##*/}" 208.67.222.222 >/dev/null 2>&1 && \
                printf '%s\n' "${interface##*/}" && return 0
    done
}

ask_reboot() {
    yellow_msg 'Reboot now? (Recommended) (y/n)'
    echo ""
    while true; do
        read -r choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            sleep 0.5
            reboot
            exit 0
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
            break
        else
            echo "Invalid input. Please enter 'y' or 'n'."
        fi
    done
}

complete_update() {
    echo ""
    yellow_msg 'Updating the System (This can take a while...)'
    sleep 0.5

    sudo apt -q update && \
    sudo apt upgrade -y && \
    sudo apt autoremove -y
    sleep 0.3

    # Clean up
    sudo apt -y clean
    green_msg 'System Updated & Cleaned Successfully.'
    sleep 0.5
}


installations() {
    echo ""
    yellow_msg 'Installing Useful Packages...'
    sleep 0.3

    # Networking packages
    sudo apt -q -y install nftables speedtest-cli
    # System utilities & Misc
    sudo apt -q -y install curl wget jq dialog htop unzip

    green_msg 'Useful Packages Installed Successfully.'
    sleep 0.5
}

enable_packages() {
    echo ""
    sudo systemctl enable nftables
    green_msg 'NFTables service enabled successfully.'
    sleep 0.3
}


swap_maker() {
    echo ""
    yellow_msg 'Making SWAP Space...'
    sleep 0.5

    # Make Swap
    sudo fallocate -l "$SWAP_SIZE" "$SWAP_PATH" # Use quotes
    sudo chmod 600 "$SWAP_PATH"
    sudo mkswap "$SWAP_PATH"
    sudo swapon "$SWAP_PATH"
    echo "$SWAP_PATH none swap sw 0 0" >> /etc/fstab
    green_msg 'SWAP Created Successfully.'
    sleep 0.5
}

sysctl_optimizations() {
    cp "$SYS_PATH" "/etc/sysctl.conf.bak"
    echo ""
    yellow_msg 'Optimizing Network via sysctl...'
    sleep 0.3

    # Download and apply optimized config
    wget "https://raw.githubusercontent.com/Onair-santa/files/main/sysctl.conf" -q -O "$SYS_PATH"
    sed -i '/net.ipv6.conf.\([a-zA-Z0-9]*\).disable_ipv6/d' "$SYS_PATH" # Safer regex replacement
    echo "net.ipv6.conf.${INTERFACE}.disable_ipv6 = 1" | tee -a "$SYS_PATH"
    sysctl -p
    green_msg 'Network sysctl parameters optimized.'
    sleep 0.5
}

find_ssh_port() {
    echo ""
    yellow_msg "Finding SSH port..."
    # More robust grep pattern: looks for Port followed by digits, ignoring comments (#)
    SSH_PORT=$(grep -E "^Port\s+(\d+)" "$SSH_PATH" 2>/dev/null | awk '{print $2}')

    if [ -n "$SSH_PORT" ] && [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
        green_msg "SSH port found: $SSH_PORT"
    else
        green_msg "SSH port not explicitly defined. Defaulting to 22."
        SSH_PORT=22
    fi
    sleep 0.3
}

remove_old_ssh_conf() {
    cp "$SSH_PATH" "/etc/ssh/sshd_config.bak"
    echo ""
    yellow_msg 'Applying baseline security hardening to SSH...'
    sleep 0.5

    # Security Hardening (SED operations are kept as they were, but quotes added)
    sed -i 's/#UseDNS yes/UseDNS no/' "$SSH_PATH"
    sed -i 's/#Compression no/Compression yes/' "$SSH_PATH"
    sed -i 's/Ciphers .*/Ciphers aes256-ctr,chacha20-poly1305@openssh.com/' "$SSH_PATH"

    # Deleting specific directives (using a pattern that matches the line exactly)
    grep -vE '^(MaxAuthTries|MaxSessions|TCPKeepAlive|ClientAliveInterval|ClientAliveCountMax|AllowAgentForwarding|AllowTcpForwarding|GatewayPorts|PermitTunnel|X11Forwarding|Port|PubkeyAuthentication|PasswordAuthentication)' "$SSH_PATH" > temp_ssh
    mv temp_ssh "$SSH_PATH"

    echo ""
    green_msg 'Baseline SSH hardening applied.'
    sleep 0.5
}


update_sshd_conf() {
    echo ""
    yellow_msg 'Optimizing specific SSH settings...'
    sleep 0.3

    # Append/Overwrite necessary lines (using tee -a to append)
    {
        echo "TCPKeepAlive yes"
        echo "ClientAliveInterval 3000"
        echo "ClientAliveCountMax 100"
        echo "AllowAgentForwarding yes"
        echo "AllowTcpForwarding yes"
        echo "GatewayPorts yes"
        echo "PermitTunnel yes"
        echo "X11Forwarding yes"
        # My specific changes
        echo "Port 2222"
        echo "PubkeyAuthentication yes"
        echo "PasswordAuthentication no"
        echo "UseDNS no"
        echo "Banner none"
    } | tee -a "$SSH_PATH"

    service ssh restart
    green_msg 'SSH service restarted with new configuration.'
    sleep 0.5
}


limits_optimizations() {
    echo ""
    yellow_msg 'Optimizing System Limits (ulimits)...'
    sleep 0.3

    # Clear old ulimits by deleting lines matching ulimit-*
    sed -i '/^ulimit -.*$/d' "$PROF_PATH"

    # Add new limits
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
    } | tee -a "$PROF_PATH"

    green_msg 'System Limits optimized in /etc/profile.'
    sleep 0.5
}


nft_optimizations() {
    echo ""
    yellow_msg 'Installing & Optimizing Nftables...'
    sleep 0.3

    sudo apt -y purge firewalld # Ensure conflict removal
    sudo apt update -q
    sudo apt install -y nftables

    # Start and enable nftables
    sudo systemctl start nftables
    sudo systemctl enable nftables
    sleep 0.3

    NFTCONF="/etc/nftables.conf"
    cat > "$NFTCONF" <<-'EOF'
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

    # The sed replacement for interface name was slightly complex, ensuring it runs last
    sed -i "s/ens3/$INTERFACE/" "$NFTCONF"
    sudo systemctl restart nftables
    green_msg 'NFT is Installed and configured (Ports 2222, 80, 443, etc. opened).'
    sleep 0.5
}

install_key() {
    echo ""
    wget -O id_ed25519.pub https://raw.githubusercontent.com/Onair-santa/files/main/id_ed25519.pub
    mkdir -p /root/.ssh
    touch /root/.ssh/authorized_keys
    cat id_ed25519.pub >> "/root/.ssh/authorized_keys"
    rm id_ed25519.pub # Clean up downloaded key
}

f2b_install() {
    echo ""
    yellow_msg 'Installing Fail2ban...'
    sudo apt update -y && sudo apt install fail2ban -y
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
    sudo systemctl enable --now fail2ban
    fail2ban-client reload
    sleep 0.5
    fail2ban-client status | head -n 3 # Show brief status
    green_msg 'Fail2ban installed and configured.'
    sleep 1
}

systemd_resolved() {
    echo ""
    sudo systemctl enable systemd-resolved
    sudo systemctl start systemd-resolved
    chattr -i /etc/resolv.conf
    rm /etc/resolv.conf
    ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

    cat > /etc/systemd/resolved.conf <<-'EOF'
[Resolve]
DNS=1.1.1.1
FallbackDNS=1.0.0.1
Cache=no-negative
EOF

    sudo systemctl restart systemd-resolved
    sleep 0.5
    green_msg 'Systemd DNS resolver setup complete.'
}

dnsproxy() {
    echo ""
    yellow_msg "Setting up dnsproxy..."
    VERSION=$(curl -s https://api.github.com/repos/AdguardTeam/dnsproxy/releases/latest | grep tag_name | cut -d '"' -f 4)
    echo "Latest AdguardTeam dnsproxy version is $VERSION"

    wget -O dnsproxy.tar.gz "https://github.com/AdguardTeam/dnsproxy/releases/download/${VERSION}/dnsproxy-linux-amd64-${VERSION}.tar.gz"
    tar -xzvf dnsproxy.tar.gz
    cd linux-amd64

    sudo mv dnsproxy /usr/bin/dnsproxy

    cat << 'EOF' | sudo tee /etc/systemd/system/dnsproxy.service
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

    sudo systemctl daemon-reload
    sudo systemctl enable --now dnsproxy
    systemctl disable systemd-resolved --now # Disable previous DNS setup

    echo "nameserver 127.0.0.1" | sudo tee /etc/resolv.conf
    sleep 0.5

    if host google.com &> /dev/null; then
        green_msg "DNS proxy is working correctly!"
    else
        red_msg "Error: DNS proxy setup failed."
    fi
}

ciadpi() {
    echo ""
    yellow_msg 'Starting ByeDPI installation...'
    bash <(wget -qO- https://raw.githubusercontent.com/Onair-santa/Byedpi-Setup/refs/heads/main/install.sh)
    sleep 1
}

synth_shell() {
    echo ""
    yellow_msg 'Installing Synth Shell...'
    sudo apt update -y && sudo apt install bc fonts-powerline git -y
    git clone --recursive https://github.com/andresgongora/synth-shell.git
    chmod +x synth-shell/setup.sh
    ~/synth-shell/setup.sh
    sleep 1
    rm -f ~/.config/synth-shell/synth-shell-greeter.config.default ~/.config/synth-shell/synth-shell-greeter.config
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.config -q -O ~/.config/synth-shell/synth-shell-greeter.config
    wget https://raw.githubusercontent.com/Onair-santa/files/main/synth-shell-greeter.sh -q -O ~/.config/synth-shell/synth-shell-greeter.sh
    sleep 1
}

xui() {
    echo ""
    yellow_msg 'Installing X-UI...'
    cd /root/ || exit 1
    wget https://github.com/Onair-santa/3X-UI-Debian11/releases/download/2.4.1/x-ui-linux-amd64.tar.gz
    rm -rf x-ui/ /usr/local/x-ui/ /usr/bin/x-ui
    tar zxvf x-ui-linux-amd64.tar.gz
    chmod +x x-ui/x-ui x-ui/bin/xray-linux-* x-ui/x-ui.sh
    cp x-ui/x-ui.sh /usr/bin/x-ui
    cp -f x-ui/x-ui.service /etc/systemd/system/
    mv x-ui/ /usr/local/
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
    green_msg 'X-UI installation complete.'
}

amnezia() {
    echo ""
    yellow_msg 'Starting AmneziaWG installation...'
    wget https://raw.githubusercontent.com/romikb/amneziawg-install/main/amneziawg-install.sh -O amneziawg-install.sh && chmod +x amneziawg-install.sh && bash amneziawg-install.sh
    sleep 1
}

vpnhood() {
    echo ""
    yellow_msg 'Starting VpnHood Server Installation for Linux...'

    # Default settings and configuration parameters
    local packageUrl="https://ghfast.top/https://github.com/vpnhood/VpnHood/releases/download/v3.2.448/VpnHoodServer-linux-x64.tar.gz"
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
        read -r -p "  Enter port for VpnHood Server (default 443): " vh_port
        vh_port=${vh_port:-443}
        if [[ "$vh_port" =~ ^[0-9]+$ ]] && [ "$vh_port" -ge 1 ] && [ "$vh_port" -le 65535 ]; then
            break
        else
            red_msg "Invalid port! Please enter a number between 1 and 65535."
        fi
    done

    # Download VpnHoodServer
    echo ""
    yellow_msg 'Downloading VpnHoodServer package...'
    local packageFile="/tmp/VpnHoodServer-linux.tar.gz"
    wget -nv -O "$packageFile" "$packageUrl"
    if [ $? -ne 0 ]; then
        red_msg 'Error: Could not download VpnHoodServer.'
        return 1
    fi

    # Extract
    echo ""
    yellow_msg 'Extracting package content...'
    mkdir -p "$destinationPath"
    tar -xzf "$packageFile" -C "$destinationPath"
    if [ $? -ne 0 ]; then
        red_msg 'Error: Could not extract VpnHoodServer.'
        rm -f "$packageFile"
        return 1
    fi
    rm -f "$packageFile"

    # Updating shared files layout
    echo ""
    yellow_msg 'Updating shared files and paths...'
    local infoDir="$binDir/publish_info"
    cp "$infoDir/vhserver" "$destinationPath/" -f
    cp "$infoDir/publish.json" "$destinationPath/" -f
    chmod +x "$binDir/VpnHoodServer"
    chmod +x "$destinationPath/vhserver"

    # Config appsettings.json
    mkdir -p "$destinationPath/storage"
    wget "https://ghfast.top/https://github.com/Onair-santa/VpnHood/releases/download/v3.2/appsettings.json" -q -O "$APPSET"
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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    else
        # Running from an isolated system user for safety on alternative ports
        useradd -r -s /bin/false -u 996 vpnhood 2>/dev/null || true
        chown -R vpnhood:vpnhood "$destinationPath"
        
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
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
    fi

    # Apply & run services
    systemctl daemon-reload
    systemctl enable VpnHoodServer.service
    systemctl restart VpnHoodServer.service

    green_msg 'VpnHood Server service OK'
    sleep 0.5
    
    # Access Token Generation
    echo ""
    yellow_msg 'Generating AccessKey...'
    "$destinationPath/vhserver" gen -ep "$EXTIP"
    
    echo ""
    green_msg 'OK! Copy AccessKey above.'
    sleep 2
}

repo_debian() {
   echo ""
   tee /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bullseye main
deb-src http://deb.debian.org/debian bullseye main
deb http://security.debian.org/debian-security bullseye-security main
deb-src http://security.debian.org/debian-security bullseye-security main
deb http://deb.debian.org/debian bullseye-updates main
deb-src http://deb.debian.org/debian bullseye-updates main
deb http://archive.debian.org/debian bullseye-backports main
deb-src http://archive.debian.org/debian bullseye-backports main
EOF
   green_msg "Debian Bullseye repositories added."
}


# --- Menu Display & Main Loop ---

show_menu() {
    local city="Unknown City"
    local country="Unknown Country"
    local ip_data=""

    yellow_msg "Attempting to determine location..."
    sleep 0.5
    
    # Список источников: IP Source | API Endpoint
    local sources=(
        "https://ipv4.icanhazip.com|http://ip-api.com/json/"
        "https://api.ipify.org|http://ip-api.com/json/"
        "https://ipv4.ident.me/|http://ip-api.com/json/"
    )

    for source_pair in "${sources[@]}"; do
        IFS='|' read -r ip_source api_url <<< "$source_pair"
        local ip=$(curl -s "$ip_source")
        if [ -n "$ip" ]; then
            api_response=$(curl -s "${api_url}${ip}")
            if echo "$api_response" | grep -q '"status":"success"'; then
                city=$(echo "$api_response" | jq -r '.city')
                country=$(echo "$api_response" | jq -r '.country')
                break 
            fi
        fi
    done

    clear
    echo "========================================="
    cyn_msg "  Welcome to your VPS Management Script!"
    if [[ "$city" != "Unknown City" ]]; then
        cyn_msg "   Location: $city, $country" 
    else
        echo "   (Waiting for network connection...)"
    fi
    echo "========================================="
    yellow_msg '              Choose One Option:'
    echo ""

    green_msg '1. Full Setup (Update + All Optimizations)'
    green_msg '2. Change Repository to Debian 11'
    green_msg '3. Quick Update & Core Optimizations (Net/SSH/SysLimits)'
    echo ""
    cyn_msg '4. System Cleanup'
    cyn_msg '5. Install Packages(htop, curl, nftables, speedtest, btop)'
    cyn_msg '6. Configure SWAP (1Gb)'
    cyn_msg '7. Network & SSH Hardening + Limits'
    echo ""
    yellow_msg '8. Network Sysctl Settings'
    yellow_msg '9. SSH Configuration Only(port 2222, disable PassAuth, enable PubKey)'
    yellow_msg '10. System Limits'
    yellow_msg '11. Firewall Setup(open ports 2222 443 80, udp 1024-65535, 40000, 55555)'
    yellow_msg '12. Install Synth-Shell'
    yellow_msg '13. Fail2ban Installation'
    echo ""
    green_msg '14. DNS Proxy Resolver Setup'
    green_msg '15. Systemd Resolved DNS Setup'
    green_msg '16. ByeDPI'
    green_msg '17. X-UI (V2Ray/Xray)'
    green_msg '18. AmneziaWG Installation'
    green_msg '19. VpnHood Server Installation'
    echo ""
    red_msg 'Q - Exit Script'
    echo "-----------------------------------------"
}



# --- Main Execution Flow ---

main() {
    check_if_running_as_root
    OS=$(detect_os)
    
    # Initial dependency check based on detected OS
    install_dependencies "$OS"
    fix_etc_hosts
    set_timezone

    while true; do
        show_menu
        read -r -p 'Enter Your Choice: ' choice
        case $choice in
        1) # Full Setup
            complete_update && \
            installations && enable_packages && \
            sysctl_optimizations && \
            remove_old_ssh_conf && update_sshd_conf && \
            limits_optimizations && \
            find_ssh_port && ext_interface && nft_optimizations && \
            install_key && synth_shell
            green_msg '========================================='
            green_msg  '✅ Full Setup Complete.'
            green_msg '========================================='
            ask_reboot
            ;;
        2) repo_debian ;;
        3) complete_update && sysctl_optimizations && remove_old_ssh_conf && update_sshd_conf && limits_optimizations; green_msg "Core Setup Complete." ;;
        4) complete_update; green_msg "Cleanup Complete." ;;
        5) installations; green_msg "Packages Installed." ;;
        6) swap_maker; green_msg "SWAP Configured." ;;
        7) sysctl_optimizations && remove_old_ssh_conf && update_sshd_conf && limits_optimizations; green_msg "Hardening Complete." ;;
        8) sysctl_optimizations; green_msg "Sysctl Optimized." ;;
        9) remove_old_ssh_conf && update_sshd_conf; green_msg "SSH Configured." ;;
        10) limits_optimizations; green_msg "Limits Optimized." ;;
        11) find_ssh_port && ext_interface && nft_optimizations; green_msg "Firewall Configured." ;;
        12) synth_shell ; sleep 1; green_msg "SynthShell Installed." ;;
        13) f2b_install; green_msg "Fail2Ban Ready." ;;
        14) dnsproxy; green_msg "DNS Proxy Active." ;;
        15) systemd_resolved; green_msg "Systemd Resolved Active." ;;
        16) ciadpi ; sleep 1; green_msg "ByeDPI Activated." ;;
        17) xui ; green_msg "X-UI Installed/Started." ;;
        18) amnezia; green_msg "AmneziaWG Setup Running." ;;
        19) vpnhood; green_msg "VpnHood Setup Running." ;;

        q|Q) exit 0 ;;
        *) red_msg 'Wrong input! Please try again.' ;;
        esac
    done
}

main "$@"
