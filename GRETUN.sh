#!/bin/bash
clear

# Root check
if [ "$EUID" -ne 0 ]; then
  echo "Run as root"
  exit 1
fi

# Detect local public IPv4 safely
LOCAL_PUBLIC_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

if [ -z "$LOCAL_PUBLIC_IP" ]; then
  echo "Failed to detect local public IPv4"
  exit 1
fi

echo "==============================="
echo " ++ GRE Tunnel Setup Script ++ " 
echo "==============================="
echo
echo "1) Iran Server"
echo "2) kharej Server"
echo
read -p "Select server type [1-2]: " ROLE

if [[ "$ROLE" != "1" && "$ROLE" != "2" ]]; then
  echo "Invalid selection"
  exit 1
fi

echo
echo "Local Public IP: $LOCAL_PUBLIC_IP"
echo
read -p "Enter REMOTE server Public IPv4: " REMOTE_PUBLIC_IP

if [ -z "$REMOTE_PUBLIC_IP" ]; then
  echo "Remote IP cannot be empty"
  exit 1
fi

# GRE IP plan
if [ "$ROLE" == "1" ]; then
  SERVER_ROLE="IRAN"
  LOCAL_GRE_IP="10.10.10.1/30"
  REMOTE_GRE_IP="10.10.10.2"
else
  SERVER_ROLE="kharej"
  LOCAL_GRE_IP="10.10.10.2/30"
  REMOTE_GRE_IP="10.10.10.1"
fi

echo
echo "[*] Server role: $SERVER_ROLE"

# Load GRE module
modprobe ip_gre

# Remove old tunnel
ip link set gre1 down 2>/dev/null
ip tunnel del gre1 2>/dev/null

# Create GRE tunnel (secondary interface)
ip tunnel add gre1 mode gre local "$LOCAL_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
ip addr add "$LOCAL_GRE_IP" dev gre1
ip link set gre1 mtu 1390
ip link set gre1 up

if ! ip link show gre1 >/dev/null 2>&1; then
  echo "GRE interface creation failed"
  exit 1
fi

echo "[✓] GRE tunnel created as secondary interface"

# Enable IP forwarding (no routing changes)
echo 1 > /proc/sys/net/ipv4/ip_forward
sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p >/dev/null

# Allow GRE protocol
iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT
iptables -C OUTPUT -p gre -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p gre -j ACCEPT

clear
echo "=============================="
echo "      GRE Tunnel Ready "
echo "=============================="
echo
echo "Primary interface : unchanged"
echo "GRE interface     : gre1 (secondary)"
echo "Local GRE IP      : $LOCAL_GRE_IP"
echo "Remote GRE IP     : $REMOTE_GRE_IP"
echo

# Test only on kharej server
if [ "$ROLE" == "2" ]; then
  echo "[*] Testing GRE tunnel..."
  echo

  if ping -c 4 "$REMOTE_GRE_IP" >/dev/null 2>&1; then
    echo "Tunnel is OK ✅"
  else
    echo "Tunnel is NOT OK ❌"
  fi

else
  echo "Now run this script on the kharej server"
fi

