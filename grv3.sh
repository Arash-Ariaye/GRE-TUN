#!/bin/bash

# ==============================================================================
# Script Name: MPLS-over-GRE Tunnel Manager (Based on GRETUNv2 architecture)
# Author/Adapted for: Complete MPLS-in-IP Integration & Debugging
# ==============================================================================

# Colors Definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Check Root Access
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Error: This script must be run as root! Use sudo.${NC}"
  exit 1
fi

# Configuration Storage Path
CONFIG_FILE="/etc/mpls_gre_config.env"
SERVICE_FILE="/etc/systemd/system/mpls-gre-tunnel.service"
RESTORE_SCRIPT="/usr/local/bin/restore-mpls-gre.sh"

banner() {
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${GREEN}      MPLS-in-IP (GRE) Professional Manager v2.0      ${NC}"
    echo -e "${CYAN}======================================================${NC}"
}

# ------------------------------------------------------------------------------
# 1. Setup & Installation Function
# ------------------------------------------------------------------------------
install_mpls_gre() {
    banner
    echo -e "${YELLOW}[+] Starting MPLS-over-GRE Setup Wizard...${NC}\n"

    read -p "Enter Local Public IP (Underlay): " LOCAL_PUB_IP
    read -p "Enter Remote Public IP (Underlay): " REMOTE_PUB_IP
    read -p "Enter Tunnel Interface Name (default: tun0): " TUN_NAME
    TUN_NAME=${TUN_NAME:-tun0}
    read -p "Enter Local Tunnel IP with CIDR (e.g., 10.0.0.1/30): " TUN_LOCAL_IP
    read -p "Enter Remote Tunnel IP Gateway (e.g., 10.0.0.2): " TUN_REMOTE_IP
    read -p "Enter Destination Subnet to Route via MPLS (e.g., 192.168.10.0/24): " DEST_SUBNET
    read -p "Enter MPLS Label (e.g., 100): " MPLS_LABEL

    echo -e "\n${BLUE}[*] Step 1/6: Enabling Kernel Modules...${NC}"
    modprobe mpls_router
    modprobe mpls_iptunnel

    # Make modules persistent
    echo "mpls_router" > /etc/modules-load.d/mpls.conf
    echo "mpls_iptunnel" >> /etc/modules-load.d/mpls.conf

    echo -e "${BLUE}[*] Step 2/6: Configuring Sysctl Parameters...${NC}"
    sysctl -w net.mpls.platform_labels=1048575 >/dev/null 2>&1
    
    cat <<EOF > /etc/sysctl.d/99-mpls-tunnel.conf
net.mpls.platform_labels=1048575
net.mpls.conf.$TUN_NAME.input=1
EOF
    sysctl --system >/dev/null 2>&1

    echo -e "${BLUE}[*] Step 3/6: Creating GRE Tunnel Interface ($TUN_NAME)...${NC}"
    if ip link show "$TUN_NAME" > /dev/null 2>&1; then
        ip link set "$TUN_NAME" down
        ip tunnel del "$TUN_NAME"
    fi
    
    ip tunnel add "$TUN_NAME" mode gre remote "$REMOTE_PUB_IP" local "$LOCAL_PUB_IP" ttl 255
    ip link set "$TUN_NAME" up
    ip addr add "$TUN_LOCAL_IP" dev "$TUN_NAME"

    echo -e "${BLUE}[*] Step 4/6: Enabling MPLS input on interface...${NC}"
    sysctl -w net.mpls.conf."$TUN_NAME".input=1 >/dev/null 2>&1

    echo -e "${BLUE}[*] Step 5/6: Applying MPLS Encapsulation Route...${NC}"
    # Remove existing route if present to avoid conflicts
    ip route del "$DEST_SUBNET" 2>/dev/null
    ip route add "$DEST_SUBNET" encap mpls "$MPLS_LABEL" via "$TUN_REMOTE_IP" dev "$TUN_NAME"

    echo -e "${BLUE}[*] Step 6/6: Saving Configuration & Setting up Persistence...${NC}"
    # Save config variables
    cat <<EOF > "$CONFIG_FILE"
LOCAL_PUB_IP="$LOCAL_PUB_IP"
REMOTE_PUB_IP="$REMOTE_PUB_IP"
TUN_NAME="$TUN_NAME"
TUN_LOCAL_IP="$TUN_LOCAL_IP"
TUN_REMOTE_IP="$TUN_REMOTE_IP"
DEST_SUBNET="$DEST_SUBNET"
MPLS_LABEL="$MPLS_LABEL"
EOF

    # Create restore script for systemd
    cat <<EOF > "$RESTORE_SCRIPT"
#!/bin/bash
source $CONFIG_FILE
modprobe mpls_router
modprobe mpls_iptunnel
sysctl -w net.mpls.platform_labels=1048575 >/dev/null 2>&1
ip tunnel add \$TUN_NAME mode gre remote \$REMOTE_PUB_IP local \$LOCAL_PUB_IP ttl 255
ip link set \$TUN_NAME up
ip addr add \$TUN_LOCAL_IP dev \$TUN_NAME
sysctl -w net.mpls.conf.\$TUN_NAME.input=1 >/dev/null 2>&1
ip route add \$DEST_SUBNET encap mpls \$MPLS_LABEL via \$TUN_REMOTE_IP dev \$TUN_NAME
EOF
    chmod +x "$RESTORE_SCRIPT"

    # Create Systemd Service
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=MPLS-over-GRE Tunnel Automatic Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$RESTORE_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mpls-gre-tunnel.service >/dev/null 2>&1

    echo -e "\n${GREEN}[✔] Success! MPLS-in-IP tunnel deployed and persisted successfully.${NC}"
    read -p "Press [Enter] to return to menu..."
}

# ------------------------------------------------------------------------------
# 2. Status & Debugging Function
# ------------------------------------------------------------------------------
status_and_debug() {
    banner
    echo -e "${YELLOW}[+] System Status & Deep Debugging Report:${NC}\n"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}[!] No active configuration found. Please setup the tunnel first.${NC}"
        read -p "Press [Enter] to return to menu..."
        return
    fi

    source "$CONFIG_FILE"

    echo -e "${CYAN}--- 1. Interface Link Status ---${NC}"
    if ip link show "$TUN_NAME" > /dev/null 2>&1; then
        ip -brief link show "$TUN_NAME"
        ip -brief addr show "$TUN_NAME"
    else
        echo -e "${RED}[X] Tunnel interface $TUN_NAME is DOWN or missing!${NC}"
    fi

    echo -e "\n${CYAN}--- 2. Kernel Modules Status ---${NC}"
    lsmod | grep mpls || echo -e "${RED}[X] MPLS modules not loaded!${NC}"

    echo -e "\n${CYAN}--- 3. Active MPLS & Tunnel Routes ---${NC}"
    ip route show | grep "$TUN_NAME" || echo -e "${YELLOW}[!] No specific route found for $TUN_NAME${NC}"

    echo -e "\n${CYAN}--- 4. Connectivity Test (Ping Remote Tunnel Gateway) ---${NC}"
    GATEWAY_IP=$(echo "$TUN_REMOTE_IP" | cut -d'/' -f1)
    if ping -c 3 -W 2 "$GATEWAY_IP" > /dev/null 2>&1; then
        echo -e "${GREEN}[✔] Tunnel Gateway ($GATEWAY_IP) is reachable!${NC}"
    else
        echo -e "${RED}[X] Failed to ping Tunnel Gateway ($GATEWAY_IP). Check firewall or remote peer.${NC}"
    fi

    echo -e "\n${CYAN}--- 5. Systemd Service Status ---${NC}"
    systemctl is-active --quiet mpls-gre-tunnel.service && echo -e "${GREEN}[✔] Persistent service is Active${NC}" || echo -e "${RED}[X] Persistent service is inactive or failed${NC}"

    echo ""
    read -p "Press [Enter] to return to menu..."
}

# ------------------------------------------------------------------------------
# 3. Uninstallation Function
# ------------------------------------------------------------------------------
uninstall_tunnel() {
    banner
    echo -e "${RED}[!] Warning: This will remove the tunnel, routes, and persistence service.${NC}"
    read -p "Are you sure you want to uninstall? (y/n): " CONFIRM

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            ip link set "$TUN_NAME" down 2>/dev/null
            ip tunnel del "$TUN_NAME" 2>/dev/null
        }
        systemctl disable mpls-gre-tunnel.service >/dev/null 2>&1
        rm -f "$SERVICE_FILE" "$RESTORE_SCRIPT" "$CONFIG_FILE" /etc/sysctl.d/99-mpls-tunnel.conf
        systemctl daemon-reload
        echo -e "\n${GREEN}[✔] MPLS-over-GRE successfully removed and cleaned up.${NC}"
    else
        echo -e "${YELLOW}Operation cancelled.${NC}"
    fi
    read -p "Press [Enter] to return to menu..."
}

# ------------------------------------------------------------------------------
# Main Application Loop
# ------------------------------------------------------------------------------
while true; do
    banner
    echo -e "Please choose an option:"
    echo -e "  ${GREEN}1)${NC} Setup & Deploy MPLS-over-GRE Tunnel"
    echo -e "  ${GREEN}2)${NC} Check Status & Run Diagnostics / Debug"
    echo -e "  ${GREEN}3)${NC} Uninstall / Remove Tunnel"
    echo -e "  ${RED}4)${NC} Exit"
    echo ""
    read -p "Enter choice [1-4]: " CHOICE

    case $CHOICE in
        1) install_mpls_gre ;;
        2) status_and_debug ;;
        3) uninstall_tunnel ;;
        4) echo -e "\nExiting... Good luck!\n"; exit 0 ;;
        *) echo -e "${RED}[!] Invalid option. Please choose between 1-4.${NC}"; sleep 2 ;;
    esac
done
