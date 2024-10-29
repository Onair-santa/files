#!/bin/bash

# AmneziaWG server installer

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

CONFIG_DIR="/root/configs"

function isRoot() {
    if [ "${EUID}" -ne 0 ]; then
        echo "You need to run this script as root"
        exit 1
    fi
}

function checkVirt() {
    if [ "$(systemd-detect-virt)" == "openvz" ]; then
        echo "OpenVZ is not supported"
        exit 1
    fi

    if [ "$(systemd-detect-virt)" == "lxc" ]; then
        echo "LXC is not supported (yet)."
        echo "AmneziaWG can technically run in an LXC container,"
        echo "but the kernel module has to be installed on the host,"
        echo "the container has to be run with some specific parameters"
        echo "and only the tools need to be installed in the container."
        exit 1
    fi
}


function initialCheck() {
    isRoot
    checkVirt
}

function installQuestions() {
    echo "Welcome to the AmneziaWG installer!"
    echo ""
    echo "I need to ask you a few questions before starting the setup."
    echo "You can keep the default options and just press enter if you are ok with them."
    echo ""

    # Detect public IPv4 address and pre-fill for the user
    SERVER_PUB_IP=$(ip -4 addr | sed -ne 's|^.* inet \([^/]*\)/.* scope global.*$|\1|p' | awk '{print $1}' | head -1)
    read -rp "IPv4 public address: " -e -i "${SERVER_PUB_IP}" SERVER_PUB_IP

    # Detect public interface and pre-fill for the user
    SERVER_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
    until [[ ${SERVER_PUB_NIC} =~ ^[a-zA-Z0-9_]+$ ]]; do
        read -rp "Public interface: " -e -i "${SERVER_NIC}" SERVER_PUB_NIC
    done

    until [[ ${SERVER_WG_NIC} =~ ^[a-zA-Z0-9_]+$ && ${#SERVER_WG_NIC} -lt 16 ]]; do
        read -rp "AmneziaWG interface name: " -e -i awg0 SERVER_WG_NIC
    done

    until [[ ${SERVER_WG_IPV4} =~ ^([0-9]{1,3}\.){3} ]]; do
		read -rp "Server AmneziaWG IPv4: " -e -i 10.66.66.1 SERVER_WG_IPV4
	done

    # Generate random number within private ports range
    RANDOM_PORT=$(shuf -i49152-65535 -n1)
    until [[ ${SERVER_PORT} =~ ^[0-9]+$ ]] && [ "${SERVER_PORT}" -ge 1 ] && [ "${SERVER_PORT}" -le 65535 ]; do
        read -rp "Server AmneziaWG port [1-65535]: " -e -i "${RANDOM_PORT}" SERVER_PORT
    done

    # Adguard DNS by default
    until [[ ${CLIENT_DNS_1} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
        read -rp "First DNS resolver to use for the clients: " -e -i 94.140.14.14 CLIENT_DNS_1
    done
    until [[ ${CLIENT_DNS_2} =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; do
        read -rp "Second DNS resolver to use for the clients (optional): " -e -i 94.140.15.15 CLIENT_DNS_2
        if [[ ${CLIENT_DNS_2} == "" ]]; then
            CLIENT_DNS_2="${CLIENT_DNS_1}"
        fi
    done

    until [[ ${ALLOWED_IPS} =~ ^.+$ ]]; do
        echo -e "\nAmneziaWG uses a parameter called AllowedIPs to determine what is routed over the VPN."
        read -rp "Allowed IPs list for generated clients (leave default to route everything): " -e -i '0.0.0.0/0' ALLOWED_IPS
        if [[ ${ALLOWED_IPS} == "" ]]; then
            ALLOWED_IPS="0.0.0.0/0"
        fi
    done

    echo ""
    echo "Okay, that was all I needed. We are ready to setup your AmneziaWG server now."
    echo "You will be able to generate a client at the end of the installation."
    read -n1 -r -p "Press any key to continue..."
}

function installAmneziaWG() {
    # Run setup questions first
    installQuestions

    # Update packages
    sudo apt update -y && sudo apt upgrade -y && sudo apt-get full-upgrade -y
    sudo apt install -y make dkms software-properties-common python3-launchpadlib gnupg2 curl linux-headers-$(uname -r)

    # Download installer to file
    curl -L https://raw.githubusercontent.com/hayashidevs/amneziawg-install-script/main/amnezia.sh -o amnezia.sh
    chmod +x amnezia.sh

    # Unzip AmneziaWG
    curl -L https://github.com/hayashidevs/amneziawg-sources/releases/download/v6.7.0-3.3/amneziawg-6.7.0-3.3.tar -o amneziawg-6.7.0-3.3.tar
    tar xf amneziawg-6.7.0-3.3.tar
    rm amneziawg-6.7.0-3.3.tar
    sudo mv amneziawg-6.7.0-3.3 /usr/src
    sudo dkms install amneziawg/6.7.0-3.3
    sudo add-apt-repository ppa:amnezia/ppa -y
    sudo apt-get install -y amneziawg-tools
    sudo add-apt-repository --remove ppa:amnezia/ppa -y

    # Make sure the directory exists (this does not seem the be the case on fedora)
    mkdir /etc/amnezia >/dev/null 2>&1
    mkdir /etc/amnezia/amneziawg >/dev/null 2>&1

    chmod 600 -R /etc/amnezia/
    chmod 600 -R /etc/amnezia/amneziawg/

    ln -s /etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf /etc/amnezia/${SERVER_WG_NIC}.conf

    SERVER_PRIV_KEY=$(awg genkey)
    SERVER_PUB_KEY=$(echo "${SERVER_PRIV_KEY}" | awg pubkey)

    # Save AmneziaWG settings
    echo "SERVER_PUB_IP=${SERVER_PUB_IP}
SERVER_PUB_NIC=${SERVER_PUB_NIC}
SERVER_WG_NIC=${SERVER_WG_NIC}
SERVER_WG_IPV4=${SERVER_WG_IPV4}
SERVER_PORT=${SERVER_PORT}
SERVER_PRIV_KEY=${SERVER_PRIV_KEY}
SERVER_PUB_KEY=${SERVER_PUB_KEY}
CLIENT_DNS_1=${CLIENT_DNS_1}
CLIENT_DNS_2=${CLIENT_DNS_2}
ALLOWED_IPS=${ALLOWED_IPS}" >/etc/amnezia/params

    # Add server interface
    echo "[Interface]
Address = ${SERVER_WG_IPV4}/8
ListenPort = ${SERVER_PORT}
PrivateKey = ${SERVER_PRIV_KEY}
Jc = 3
Jmin = 50
Jmax = 1000
S1 = 86
S2 = 37
H1 = 1765270396
H2 = 1916281119
H3 = 1525151619
H4 = 787919628" >"/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"

    # Setup iptables rules
    echo "PostUp = iptables -I INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -I FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE
PostDown = iptables -D INPUT -p udp --dport ${SERVER_PORT} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_PUB_NIC} -o ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -D FORWARD -i ${SERVER_WG_NIC} -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o ${SERVER_PUB_NIC} -j MASQUERADE" >>"/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"

    # Enable routing on the server
    echo "net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1" >/etc/sysctl.d/awg.conf

    sysctl --system

    systemctl start "awg-quick@${SERVER_WG_NIC}"
    systemctl enable "awg-quick@${SERVER_WG_NIC}"

    newClient
    echo -e "${GREEN}If you want to add more clients, you simply need to run this script another time!${NC}"

    # Check if AmneziaWG is running
    systemctl is-active --quiet "awg-quick@${SERVER_WG_NIC}"
    WG_RUNNING=$?

    # AmneziaWG might not work if we updated the kernel. Tell the user to reboot
    if [[ ${WG_RUNNING} -ne 0 ]]; then
        echo -e "\n${RED}WARNING: AmneziaWG does not seem to be running.${NC}"
        echo -e "${ORANGE}You can check if AmneziaWG is running with: systemctl status awg-quick@${SERVER_WG_NIC}${NC}"
        echo -e "${ORANGE}If you get something like \"Cannot find device ${SERVER_WG_NIC}\", please reboot!${NC}"
    else # AmneziaWG is running
        echo -e "\n${GREEN}AmneziaWG is running.${NC}"
        echo -e "${GREEN}You can check the status of AmneziaWG with: systemctl status awg-quick@${SERVER_WG_NIC}\n\n${NC}"
        echo -e "${ORANGE}If you don't have internet connectivity from your client, try to reboot the server.${NC}"
    fi
}

function newClient() {
    ENDPOINT="${SERVER_PUB_IP}:${SERVER_PORT}"

    echo ""
    echo "Client configuration"
    echo ""
    echo "The client name must consist of alphanumeric character(s). It may also include underscores or dashes and can't exceed 15 chars."

    if [[ -n "${CLIENT_NAME}" ]]; then
        echo "Using provided client name: ${CLIENT_NAME}"
    else
        until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ && ${CLIENT_EXISTS} == '0' && ${#CLIENT_NAME} -lt 16 ]]; do
            read -rp "Client name: " -e CLIENT_NAME
            CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf")

            if [[ ${CLIENT_EXISTS} != 0 ]]; then
                echo ""
                echo -e "${ORANGE}A client with the specified name was already created, please choose another name.${NC}"
                echo ""
            fi
        done
    fi

    if [[ -n "${CLIENT_WG_IPV4}" ]]; then
        echo "Using provided IPv4: ${CLIENT_WG_IPV4}"
    else
        until [[ ${IPV4_EXISTS} == '0' ]]; do
            read -rp "Client AmneziaWG IPv4: " -e CLIENT_WG_IPV4
            IPV4_EXISTS=$(grep -c "$CLIENT_WG_IPV4/32" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf")

            if [[ ${IPV4_EXISTS} != 0 ]]; then
                echo ""
                echo -e "${ORANGE}A client with the specified IPv4 was already created, please choose another IPv4.${NC}"
                echo ""
            fi
        done
    fi

    # Generate key pair for the client
    CLIENT_PRIV_KEY=$(awg genkey)
    CLIENT_PUB_KEY=$(echo "${CLIENT_PRIV_KEY}" | awg pubkey)
    CLIENT_PRE_SHARED_KEY=$(awg genpsk)

    mkdir -p "${CONFIG_DIR}"

    # Create client file and add the server as a peer
    echo "[Interface]
PrivateKey = ${CLIENT_PRIV_KEY}
Address = ${CLIENT_WG_IPV4}/32
DNS = ${CLIENT_DNS_1},${CLIENT_DNS_2}
Jc = 3
Jmin = 50
Jmax = 1000
S1 = 86
S2 = 37
H1 = 1765270396
H2 = 1916281119
H3 = 1525151619
H4 = 787919628

[Peer]
PublicKey = ${SERVER_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
Endpoint = ${ENDPOINT}
AllowedIPs = ${ALLOWED_IPS}" >"${CONFIG_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

    # Add the client as a peer to the server
    echo -e "\n### Client ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUB_KEY}
PresharedKey = ${CLIENT_PRE_SHARED_KEY}
AllowedIPs = ${CLIENT_WG_IPV4}/32" >>"/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"

    awg syncconf "${SERVER_WG_NIC}" <(awg-quick strip "${SERVER_WG_NIC}")

    # Generate QR code if qrencode is installed
    if command -v qrencode &>/dev/null; then
        echo -e "${GREEN}\nHere is your client config file as a QR Code:\n${NC}"
        qrencode -t ansiutf8 -l L <"${CONFIG_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"
        echo ""
    fi

    echo -e "${GREEN}Your client config file is in ${CONFIG_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf${NC}"
}

function listClients() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf")
    if [[ ${NUMBER_OF_CLIENTS} -eq 0 ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    grep -E "^### Client" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '
}

function revokeClient() {
    NUMBER_OF_CLIENTS=$(grep -c -E "^### Client" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf")
    if [[ ${NUMBER_OF_CLIENTS} == '0' ]]; then
        echo ""
        echo "You have no existing clients!"
        exit 1
    fi

    echo ""
    echo "Select the existing client you want to revoke"
    grep -E "^### Client" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf" | cut -d ' ' -f 3 | nl -s ') '

    if [[ -n "${CLIENT_NAME}" ]]; then
        echo "Using provided client name: ${CLIENT_NAME}"
    else
        until [[ ${CLIENT_NAME} =~ ^[a-zA-Z0-9_-]+$ ]]; do
            read -rp "Enter the client name to revoke: " -e CLIENT_NAME
            CLIENT_EXISTS=$(grep -c -E "^### Client ${CLIENT_NAME}\$" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf")

            if [[ ${CLIENT_EXISTS} == '0' ]]; then
                echo ""
                echo -e "${ORANGE}A client with the specified name does not exist, please choose an existing client name.${NC}"
                echo ""
            fi
        done
    fi

    # remove [Peer] block matching $CLIENT_NAME
    sed -i "/^### Client ${CLIENT_NAME}\$/,/^$/d" "/etc/amnezia/amneziawg/${SERVER_WG_NIC}.conf"

    # remove generated client file
    rm -f "${CONFIG_DIR}/${SERVER_WG_NIC}-client-${CLIENT_NAME}.conf"

    # restart amneziawg to apply changes
    awg syncconf "${SERVER_WG_NIC}" <(awg-quick strip "${SERVER_WG_NIC}")
}

function uninstallWg() {
    echo ""
    echo -e "\n${RED}WARNING: This will uninstall AmneziaWG and remove all the configuration files!${NC}"
    echo -e "${ORANGE}Please backup the /etc/amnezia directory if you want to keep your configuration files.\n${NC}"
    read -rp "Do you really want to remove AmneziaWG? [y/n]: " -e REMOVE
    REMOVE=${REMOVE:-n}
    if [[ $REMOVE == 'y' ]]; then
        checkOS

        systemctl stop "awg-quick@${SERVER_WG_NIC}"
        systemctl disable "awg-quick@${SERVER_WG_NIC}"

        apt-get remove -y amneziawg qrencode

        rm -rf /etc/amnezia
        rm -f /etc/sysctl.d/awg.conf

        # Reload sysctl
        sysctl --system

        # Check if AmneziaWG is running
        systemctl is-active --quiet "awg-quick@${SERVER_WG_NIC}"
        WG_RUNNING=$?

        if [[ ${WG_RUNNING} -eq 0 ]]; then
            echo "AmneziaWG failed to uninstall properly."
            exit 1
        else
            echo "AmneziaWG uninstalled successfully."
            exit 0
        fi
    else
        echo ""
        echo "Removal aborted!"
    fi
}

function manageMenu() {
    echo "It looks like AmneziaWG is already installed."
    echo ""
    echo "What do you want to do?"
    echo "   1) Add a new user"
    echo "   2) List all users"
    echo "   3) Revoke existing user"
    echo "   4) Uninstall AmneziaWG"
    echo "   5) Exit"
    until [[ ${MENU_OPTION} =~ ^[1-5]$ ]]; do
        read -rp "Select an option [1-5]: " MENU_OPTION
    done
    case "${MENU_OPTION}" in
    1)
        newClient
        ;;
    2)
        listClients
        ;;
    3)
        revokeClient
        ;;
    4)
        uninstallWg
        ;;
    5)
        exit 0
        ;;
    esac
}

# Check for root, virt, OS...
initialCheck

# Check if AmneziaWG is already installed and load params
if [[ -e /etc/amnezia/params ]]; then
    source /etc/amnezia/params
    if [[ $1 == "non-interactive" ]]; then
        MODE="$2"
        CLIENT_NAME="$3"
        CLIENT_WG_IPV4="$4"
        
        case "$MODE" in
            1)
                newClient
                ;;
            3)
                revokeClientW
                ;;
            *)
                echo "Invalid mode"
                exit 1
                ;;
        esac
    else
        manageMenu
    fi
else
    installAmneziaWG
fi

# License Information

# MIT License
# Original parts of code - https://github.com/angristan/wireguard-install.git
#
# Copyright (c) 2019 angristan
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
#
# Mefiseru License
#
# Copyright (c) 2024 Mefiseru
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to use the Software for personal, non-commercial purposes only, under the following conditions:
#
# 1. **Non-Commercial Use**: The Software may only be used for personal, non-commercial purposes. It is explicitly prohibited from being used in any "open-source" projects or any public repositories. For any commercial use, including but not limited to using the Software in a commercial product or service, a commercial license must be obtained by contacting Mefiseru.
#
# 2. **No Sale**: The Software may not be sold, sublicensed, or distributed for any form of remuneration without a commercial license obtained from Mefiseru. Reselling or redistributing copies of the Software is prohibited unless authorized through a commercial license.
#
# 3. **No Editing**: The Software may not be modified, altered, or adapted in any way. All changes or modifications to the Software must be approved by Mefiseru and can only be made with explicit written permission.
#
# 4. **Author Attribution**: Any non-commercial use of the Software must include clear and proper attribution to the author, Mefiseru, in all copies or substantial portions of the Software.
#
# 5. **License Acceptance**: By downloading or using this Software, you agree to be bound by the terms and conditions of this License.
#
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.