#!/bin/bash
set -euo pipefail


CONF_FILE="/etc/gre-tunnel.conf"
INSTALL_BIN="/usr/local/bin/gre.sh"
SERVICE_UNIT="/etc/systemd/system/gre-tunnel.service"

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
  fi
}

detect_local_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

save_config() {
  cat > "$CONF_FILE" <<EOF
ROLE="$ROLE"
LOCAL_PUBLIC_IP="$LOCAL_PUBLIC_IP"
REMOTE_PUBLIC_IP="$REMOTE_PUBLIC_IP"
LOCAL_GRE_IP="$LOCAL_GRE_IP"
REMOTE_GRE_IP="$REMOTE_GRE_IP"
EOF
  chmod 600 "$CONF_FILE"
  echo "Saved configuration to $CONF_FILE"
}

load_config() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    return 0
  fi
  return 1
}

create_tunnel() {
  # create_tunnel [interactive]
  # expects ROLE and REMOTE_PUBLIC_IP set
  local interactive=${1:-0}
  if [ "$interactive" -eq 1 ]; then
    clear
  fi
  LOCAL_PUBLIC_IP="${LOCAL_PUBLIC_IP:-$(detect_local_public_ip)}"
  if [ -z "$LOCAL_PUBLIC_IP" ]; then
    echo "Failed to detect local public IPv4" >&2
    return 1
  fi

  if [ "$ROLE" == "1" ]; then
    SERVER_ROLE="IRAN"
    LOCAL_GRE_IP="10.10.10.1/30"
    REMOTE_GRE_IP="10.10.10.2"
  else
    SERVER_ROLE="kharej"
    LOCAL_GRE_IP="10.10.10.2/30"
    REMOTE_GRE_IP="10.10.10.1"
  fi

  echo "[*] Server role: $SERVER_ROLE"

  modprobe ip_gre || true

  # Remove any existing gre1
  ip link set gre1 down 2>/dev/null || true
  ip tunnel del gre1 2>/dev/null || true

  ip tunnel add gre1 mode gre local "$LOCAL_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255
  ip addr add "$LOCAL_GRE_IP" dev gre1
  ip link set gre1 mtu 1390
  ip link set gre1 up

  if ! ip link show gre1 >/dev/null 2>&1; then
    echo "GRE interface creation failed" >&2
    return 1
  fi

  echo 1 > /proc/sys/net/ipv4/ip_forward || true
  if [ -f /etc/sysctl.conf ]; then
    sed -i 's/^#\?net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf || true
    sysctl -p >/dev/null 2>&1 || true
  fi

  # Allow GRE protocol in iptables
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT
    iptables -C OUTPUT -p gre -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p gre -j ACCEPT
  fi

  echo "[✓] GRE tunnel created as gre1"
  echo "Local GRE IP: $LOCAL_GRE_IP"
  echo "Remote GRE IP: $REMOTE_GRE_IP"

  # If called interactively from the menu, offer to save config and install service
  if [ "$interactive" -eq 1 ]; then
    read -rp "Save this configuration to $CONF_FILE? [y/N]: " yn
    case "$yn" in
      [Yy]*) save_config; echo "Configuration saved to $CONF_FILE" ;;
      *) echo "Configuration not saved." ;;
    esac

    # If config was saved, automatically install the systemd service so tunnel persists on reboot
    if [ -f "$CONF_FILE" ]; then
      echo "Installing persistent service to bring up tunnel on boot..."
      install_service || echo "Failed to install service; you can install manually later." 
    else
      read -rp "Configuration not saved; Install persistent service anyway? [y/N]: " sn
      case "$sn" in
        [Yy]*) install_service || echo "Failed to install service." ;;
        *) echo "Service not installed." ;;
      esac
    fi
  fi

  return 0
}

menu_config_tunnel() {
  clear
  echo
  echo "Configure GRE Tunnel"
  echo "1) Iran Server"
  echo "2) kharej Server"
  echo
  read -rp "Select server type [1-2]: " ROLE
  if [[ "$ROLE" != "1" && "$ROLE" != "2" ]]; then
    echo "Invalid selection"
    return
  fi

  LOCAL_PUBLIC_IP="${LOCAL_PUBLIC_IP:-$(detect_local_public_ip)}"
  echo "Local Public IP detected: $LOCAL_PUBLIC_IP"
  read -rp "Enter REMOTE server Public IPv4: " REMOTE_PUBLIC_IP
  if [ -z "$REMOTE_PUBLIC_IP" ]; then
    echo "Remote IP cannot be empty"
    return
  fi

  # call create_tunnel interactively (will handle save+install flow)
  create_tunnel 1 || echo "create_tunnel failed"
}

status_check() {
  clear
  echo
  echo "GRE Tunnel Status"
  if ip link show gre1 >/dev/null 2>&1; then
    echo "gre1: exists and is $(ip link show gre1 | awk -F': ' 'NR==1{print $2}')"
    # Get remote public IP from tunnel
    REMOTE_PUBLIC_OF_TUN=$(ip tunnel show gre1 2>/dev/null | awk -F'remote ' '{print $2}' | awk '{print $1}') || true
    if [ -n "$REMOTE_PUBLIC_OF_TUN" ]; then
      echo "Tunnel remote public IP: $REMOTE_PUBLIC_OF_TUN"
      echo "Pinging remote public IP (1 try)..."
      PING_PUBLIC_OUT=$(ping -c 1 -W 1 "$REMOTE_PUBLIC_OF_TUN" 2>&1) || true
      echo "$PING_PUBLIC_OUT"
      if echo "$PING_PUBLIC_OUT" | grep -qE '1 received|1 packets received|bytes from'; then
        echo "Remote public is reachable"
      else
        echo "Remote public is NOT reachable"
      fi
    fi

    # If we have saved remote GRE IP, try to ping inner address
    if load_config && [ -n "${REMOTE_GRE_IP:-}" ]; then
      echo "Pinging remote GRE inner IP $REMOTE_GRE_IP (4 tries)..."
      PING_INNER_OUT=$(ping -c 4 "$REMOTE_GRE_IP" 2>&1) || true
      echo "$PING_INNER_OUT"
      if echo "$PING_INNER_OUT" | grep -qE '([1-9]) received|([1-9]) packets received|bytes from'; then
        echo "GRE inner tunnel is UP ✅"
      else
        echo "GRE inner tunnel seems DOWN ❌"
      fi
    else
      echo "No saved inner GRE IP; to check inner reachability save config first."
    fi
  else
    echo "gre1 interface not found"
  fi
}

remove_tun() {
  clear
  echo
  echo "Removing GRE/GRETAP/ERSPAN interfaces..."
  # Detect gre/gretap/erspan interfaces (strip any @peer suffix)
  mapfile -t tunifs < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(gre|gretap|erspan)' || true)

  if [ ${#tunifs[@]} -eq 0 ]; then
    echo "No GRE/GRETAP/ERSPAN interfaces found."
  else
    for ifc in "${tunifs[@]}"; do
      echo "Found tunnel/interface: $ifc"
      ip link set dev "$ifc" down 2>/dev/null || true

      removed=0
      # Try ip tunnel del (for named tunnels)
      if ip tunnel del "$ifc" 2>/dev/null; then
        echo "- $ifc removed with 'ip tunnel del'"
        removed=1
      fi

      # Try ip link delete
      if [ $removed -eq 0 ]; then
        if ip link delete "$ifc" 2>/dev/null; then
          echo "- $ifc removed with 'ip link delete'"
          removed=1
        fi
      fi

      # Some types might require explicit type hint (attempt common variants)
      if [ $removed -eq 0 ]; then
        if ip link delete dev "$ifc" type gretap 2>/dev/null; then
          echo "- $ifc removed with 'ip link delete dev $ifc type gretap'"
          removed=1
        fi
      fi

      if [ $removed -eq 0 ]; then
        echo "- Could not remove $ifc automatically. Showing debug info for manual inspection:"
        ip -d link show "$ifc" || true
        echo "You can try to remove it manually, e.g.:
  sudo ip link set dev $ifc down
  sudo ip link delete $ifc
Or if it's created by a module, consider unloading the module (careful): sudo lsmod | grep <module>; sudo modprobe -r <module>"
      fi
    done
  fi

  echo "Done."
  # Offer to remove saved config
  read -rp "Remove saved config $CONF_FILE as well? [y/N]: " yn
  case "$yn" in
    [Yy]*) rm -f "$CONF_FILE"; echo "Config removed." ;;
    *) echo "Config kept." ;;
  esac

  # If a systemd service was installed, offer to uninstall it
  if command -v systemctl >/dev/null 2>&1; then
    svc_exists=0
    if [ -f "$SERVICE_UNIT" ]; then
      svc_exists=1
    else
      if systemctl list-unit-files | grep -q '^gre-tunnel.service'; then
        svc_exists=1
      fi
    fi

    if [ $svc_exists -eq 1 ]; then
      read -rp "Detected gre-tunnel.service. Uninstall service as well? [y/N]: " sy
      case "$sy" in
        [Yy]*) uninstall_service ;;
        *) echo "Service left installed." ;;
      esac
    fi
  fi
}

install_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "systemctl not available on this system; cannot install service." >&2
    return 1
  fi

  # Copy this script to INSTALL_BIN
  mkdir -p "$(dirname "$INSTALL_BIN")"
  cp -f "$0" "$INSTALL_BIN"
  chmod 755 "$INSTALL_BIN"

  cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=GRE Tunnel Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_BIN --service start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now gre-tunnel.service
  echo "Service installed and started (gre-tunnel.service)"
}

uninstall_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now gre-tunnel.service 2>/dev/null || true
    rm -f "$SERVICE_UNIT"
    systemctl daemon-reload
  fi
  rm -f "$INSTALL_BIN"
  echo "Service uninstalled and script removed from $INSTALL_BIN"
}

service_start() {
  if load_config; then
    echo "Starting tunnel from saved config..."
    # Use values from config and create tunnel in non-interactive mode
    create_tunnel 0
  else
    echo "No saved configuration at $CONF_FILE. Service cannot start." >&2
    return 1
  fi
}

show_menu() {
  clear
  echo "==============================="
  echo " ++ GRE Tunnel Management ++"
  echo "==============================="
  echo
  echo "1) config tunnel"
  echo "2) status"
  echo "3) remove tun"
  echo "0) Exit"
  echo
  read -rp "Choose an option [0-3]: " CHOICE
  case "$CHOICE" in
    1) menu_config_tunnel ; read -rp "Press Enter to continue..." _ ;;
    2) status_check ; read -rp "Press Enter to continue..." _ ;;
    3) remove_tun ; read -rp "Press Enter to continue..." _ ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
}

### Script entry
if [[ "${1:-}" == "--service" ]]; then
  # service mode
  if [[ "${2:-}" == "start" ]]; then
    ensure_root
    service_start
    exit $?
  fi
fi

ensure_root
while true; do
  show_menu
done
