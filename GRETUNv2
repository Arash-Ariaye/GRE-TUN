#!/bin/bash
set -euo pipefail

# ============================================================
# GRE Tunnel Manager v2
#   - GRE tunnel with native kernel IPsec (ESP/AES-GCM) encryption
#   - Kernel network stack optimization (BBR + cake + buffer tuning)
#   - Automatic MTU/MSS clamping
#   - Self-healing watchdog (systemd timer)
#   - Structured logging via journald
# ============================================================

CONF_FILE="/etc/gre-tunnel.conf"
INSTALL_BIN="/usr/local/bin/gre.sh"
SERVICE_UNIT="/etc/systemd/system/gre-tunnel.service"
WATCHDOG_SERVICE="/etc/systemd/system/gre-tunnel-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/gre-tunnel-watchdog.timer"
SYSCTL_FILE="/etc/sysctl.d/99-gre-tunnel.conf"
TUN_IF="gre1"
LOG_TAG="gre-tunnel"

GRE_SPI_A="0x1000"   # SPI used by whichever side owns "direction A"
GRE_SPI_B="0x1001"

# ---------------- logging ----------------
log() {
  local level="$1"; shift
  logger -t "$LOG_TAG" -p "user.${level}" -- "$*"
  echo "[$level] $*"
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required binary: $1" >&2; exit 1; }
}

detect_local_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

# ---------------- config persistence ----------------
save_config() {
  cat > "$CONF_FILE" <<EOF
ROLE="$ROLE"
LOCAL_PUBLIC_IP="$LOCAL_PUBLIC_IP"
REMOTE_PUBLIC_IP="$REMOTE_PUBLIC_IP"
LOCAL_GRE_IP="$LOCAL_GRE_IP"
REMOTE_GRE_IP="$REMOTE_GRE_IP"
TUN_MTU="$TUN_MTU"
ENCRYPT_ENABLE="$ENCRYPT_ENABLE"
PSK="${PSK:-}"
GRE_KEY="${GRE_KEY:-0}"
EOF
  chmod 600 "$CONF_FILE"
  log info "Configuration saved to $CONF_FILE"
}

load_config() {
  if [ -f "$CONF_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    return 0
  fi
  return 1
}

# ---------------- kernel optimization ----------------
kernel_optimize() {
  log info "Applying kernel network optimizations (BBR + cake + buffer tuning)"

  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_cake 2>/dev/null || true

  cat > "$SYSCTL_FILE" <<'EOF'
# --- GRE tunnel performance tuning ---
net.core.default_qdisc = cake
net.ipv4.tcp_congestion_control = bbr

# Larger buffers for high-latency / cross-border links
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 32768
net.core.somaxconn = 8192

# PMTUD is unreliable across GRE/IPsec, let TCP probe actively
net.ipv4.tcp_mtu_probing = 2
net.ipv4.tcp_base_mss = 1024

# Reduce latency for interactive-ish traffic sharing the tunnel
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# GRE endpoints commonly see asymmetric routing; loosen strict RPF
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2

net.ipv4.ip_forward = 1

# Keepalive tuning so dead peers are detected quickly
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF

  sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

  local current_cc
  current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "")
  if [ "$current_cc" != "bbr" ]; then
    log warning "BBR not active (got '$current_cc'). Check kernel supports tcp_bbr module."
  else
    log info "BBR congestion control active"
  fi
}

# Offload tuning on the physical egress interface (best-effort, safe if it fails)
tune_offloads() {
  local phys_if
  phys_if=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
  if [ -n "$phys_if" ] && command -v ethtool >/dev/null 2>&1; then
    ethtool -K "$phys_if" gro on gso on tso on 2>/dev/null || true
    log info "Offloads (gro/gso/tso) enabled on $phys_if"
  fi
}

# ---------------- IPsec (native kernel xfrm) ----------------
derive_key() {
  # $1 = label (A|B), outputs 40 hex chars (20 bytes: 16-byte AES key + 4-byte salt) for rfc4106 gcm(aes)
  printf '%s|%s' "$1" "$PSK" | sha512sum | cut -c1-40
}

setup_ipsec() {
  [ "${ENCRYPT_ENABLE:-0}" -eq 1 ] || { log info "Encryption disabled, skipping IPsec setup"; return 0; }
  [ -n "${PSK:-}" ] || { log err "ENCRYPT_ENABLE=1 but PSK is empty"; return 1; }

  require_bin ip

  teardown_ipsec

  local key_a key_b spi_out spi_in key_out key_in
  key_a=$(derive_key "A")
  key_b=$(derive_key "B")

  if [ "$ROLE" == "1" ]; then
    spi_out="$GRE_SPI_A"; key_out="$key_a"
    spi_in="$GRE_SPI_B";  key_in="$key_b"
  else
    spi_out="$GRE_SPI_B"; key_out="$key_b"
    spi_in="$GRE_SPI_A";  key_in="$key_a"
  fi

  # Outbound SA (this host -> remote)
  ip xfrm state add src "$LOCAL_PUBLIC_IP" dst "$REMOTE_PUBLIC_IP" proto esp spi "$spi_out" \
    aead 'rfc4106(gcm(aes))' "0x${key_out}" 128 mode transport

  # Inbound SA (remote -> this host)
  ip xfrm state add src "$REMOTE_PUBLIC_IP" dst "$LOCAL_PUBLIC_IP" proto esp spi "$spi_in" \
    aead 'rfc4106(gcm(aes))' "0x${key_in}" 128 mode transport

  # Policies: only encrypt GRE-encapsulated traffic (proto 47) between the two endpoints
  ip xfrm policy add src "$LOCAL_PUBLIC_IP" dst "$REMOTE_PUBLIC_IP" dir out proto gre \
    tmpl src "$LOCAL_PUBLIC_IP" dst "$REMOTE_PUBLIC_IP" proto esp mode transport

  ip xfrm policy add src "$REMOTE_PUBLIC_IP" dst "$LOCAL_PUBLIC_IP" dir in proto gre \
    tmpl src "$REMOTE_PUBLIC_IP" dst "$LOCAL_PUBLIC_IP" proto esp mode transport

  log info "IPsec ESP (AES-GCM-128, kernel xfrm) established for GRE traffic"
}

teardown_ipsec() {
  ip xfrm state deleteall 2>/dev/null || true
  ip xfrm policy deleteall 2>/dev/null || true
}

# ---------------- MSS clamping ----------------
apply_mss_clamp() {
  local mss=$(( TUN_MTU - 40 ))
  iptables -t mangle -D FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss" 2>/dev/null || true
  iptables -t mangle -A FORWARD -o "$TUN_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss"
  log info "MSS clamped to $mss on $TUN_IF (MTU=$TUN_MTU)"
}

# ---------------- tunnel lifecycle ----------------
create_tunnel() {
  local interactive=${1:-0}
  [ "$interactive" -eq 1 ] && clear

  LOCAL_PUBLIC_IP="${LOCAL_PUBLIC_IP:-$(detect_local_public_ip)}"
  if [ -z "$LOCAL_PUBLIC_IP" ]; then
    log err "Failed to detect local public IPv4"
    return 1
  fi

  TUN_MTU="${TUN_MTU:-1400}"   # lower default MTU: room for GRE(24) + ESP(~40) overhead

  if [ "$ROLE" == "1" ]; then
    SERVER_ROLE="IRAN"
    LOCAL_GRE_IP="10.10.10.1/30"
    REMOTE_GRE_IP="10.10.10.2"
  else
    SERVER_ROLE="kharej"
    LOCAL_GRE_IP="10.10.10.2/30"
    REMOTE_GRE_IP="10.10.10.1"
  fi

  log info "Server role: $SERVER_ROLE"

  modprobe ip_gre || true

  ip link set "$TUN_IF" down 2>/dev/null || true
  ip tunnel del "$TUN_IF" 2>/dev/null || true

  local key_opt=""
  [ "${GRE_KEY:-0}" != "0" ] && key_opt="key ${GRE_KEY}"

  # shellcheck disable=SC2086
  ip tunnel add "$TUN_IF" mode gre local "$LOCAL_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255 $key_opt
  ip addr add "$LOCAL_GRE_IP" dev "$TUN_IF"
  ip link set "$TUN_IF" mtu "$TUN_MTU"
  ip link set "$TUN_IF" up

  if ! ip link show "$TUN_IF" >/dev/null 2>&1; then
    log err "GRE interface creation failed"
    return 1
  fi

  # Kernel/network stack tuning (idempotent, safe to re-run)
  kernel_optimize
  tune_offloads
  apply_mss_clamp

  if [ "${ENCRYPT_ENABLE:-0}" -eq 1 ]; then
    setup_ipsec || log warning "IPsec setup failed, tunnel is running UNENCRYPTED"
  fi

  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p gre -j ACCEPT 2>/dev/null || iptables -A INPUT -p gre -j ACCEPT
    iptables -C OUTPUT -p gre -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p gre -j ACCEPT
    if [ "${ENCRYPT_ENABLE:-0}" -eq 1 ]; then
      iptables -C INPUT -p esp -j ACCEPT 2>/dev/null || iptables -A INPUT -p esp -j ACCEPT
      iptables -C OUTPUT -p esp -j ACCEPT 2>/dev/null || iptables -A OUTPUT -p esp -j ACCEPT
    fi
  fi

  log info "GRE tunnel up: $TUN_IF, local=$LOCAL_GRE_IP remote=$REMOTE_GRE_IP mtu=$TUN_MTU encrypt=${ENCRYPT_ENABLE:-0}"

  if [ "$interactive" -eq 1 ]; then
    read -rp "Save this configuration to $CONF_FILE? [y/N]: " yn
    case "$yn" in
      [Yy]*) save_config ;;
      *) echo "Configuration not saved." ;;
    esac

    if [ -f "$CONF_FILE" ]; then
      echo "Installing persistent service + watchdog..."
      install_service || echo "Failed to install service."
      install_watchdog || echo "Failed to install watchdog."
    fi
  fi

  return 0
}

menu_config_tunnel() {
  clear
  echo "Configure GRE Tunnel"
  echo "1) Iran Server"
  echo "2) kharej Server"
  read -rp "Select server type [1-2]: " ROLE
  if [[ "$ROLE" != "1" && "$ROLE" != "2" ]]; then
    echo "Invalid selection"; return
  fi

  LOCAL_PUBLIC_IP="${LOCAL_PUBLIC_IP:-$(detect_local_public_ip)}"
  echo "Local Public IP detected: $LOCAL_PUBLIC_IP"
  read -rp "Enter REMOTE server Public IPv4: " REMOTE_PUBLIC_IP
  [ -n "$REMOTE_PUBLIC_IP" ] || { echo "Remote IP cannot be empty"; return; }

  read -rp "Tunnel MTU [1400]: " TUN_MTU_IN
  TUN_MTU="${TUN_MTU_IN:-1400}"

  read -rp "Enable encryption (IPsec ESP/AES-GCM)? [Y/n]: " enc
  case "$enc" in
    [Nn]*) ENCRYPT_ENABLE=0 ;;
    *)
      ENCRYPT_ENABLE=1
      read -rsp "Enter shared PSK (same on both servers): " PSK
      echo
      ;;
  esac

  read -rp "Optional GRE key (0 = none, must match on both sides): " GRE_KEY_IN
  GRE_KEY="${GRE_KEY_IN:-0}"

  create_tunnel 1 || echo "create_tunnel failed"
}

status_check() {
  clear
  echo "GRE Tunnel Status"
  if ip link show "$TUN_IF" >/dev/null 2>&1; then
    echo "$TUN_IF: $(ip link show "$TUN_IF" | awk -F': ' 'NR==1{print $2}')"
    echo "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "Qdisc: $(tc qdisc show dev "$TUN_IF" 2>/dev/null | head -1)"

    REMOTE_PUBLIC_OF_TUN=$(ip tunnel show "$TUN_IF" 2>/dev/null | awk -F'remote ' '{print $2}' | awk '{print $1}') || true
    if [ -n "$REMOTE_PUBLIC_OF_TUN" ]; then
      echo "Tunnel remote public IP: $REMOTE_PUBLIC_OF_TUN"
      PING_PUBLIC_OUT=$(ping -c 1 -W 1 "$REMOTE_PUBLIC_OF_TUN" 2>&1) || true
      echo "$PING_PUBLIC_OUT"
    fi

    if load_config && [ -n "${REMOTE_GRE_IP:-}" ]; then
      echo "Pinging remote GRE inner IP $REMOTE_GRE_IP (4 tries)..."
      PING_INNER_OUT=$(ping -c 4 "$REMOTE_GRE_IP" 2>&1) || true
      echo "$PING_INNER_OUT"
      if echo "$PING_INNER_OUT" | grep -qE '([1-9]) received|bytes from'; then
        echo "GRE inner tunnel is UP ✅"
      else
        echo "GRE inner tunnel seems DOWN ❌"
      fi
    fi

    if [ "${ENCRYPT_ENABLE:-0}" -eq 1 ]; then
      echo "--- IPsec state ---"
      ip -s xfrm state 2>/dev/null | head -20
    fi
  else
    echo "$TUN_IF interface not found"
  fi
}

remove_tun() {
  clear
  echo "Removing GRE/GRETAP/ERSPAN interfaces and IPsec state..."
  teardown_ipsec

  mapfile -t tunifs < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(gre|gretap|erspan)' || true)

  for ifc in "${tunifs[@]:-}"; do
    [ -z "$ifc" ] && continue
    ip link set dev "$ifc" down 2>/dev/null || true
    ip tunnel del "$ifc" 2>/dev/null || ip link delete "$ifc" 2>/dev/null || true
    echo "- $ifc removed"
  done

  read -rp "Remove saved config $CONF_FILE as well? [y/N]: " yn
  case "$yn" in
    [Yy]*) rm -f "$CONF_FILE"; echo "Config removed." ;;
    *) echo "Config kept." ;;
  esac

  if command -v systemctl >/dev/null 2>&1; then
    if [ -f "$SERVICE_UNIT" ] || systemctl list-unit-files | grep -q '^gre-tunnel.service'; then
      read -rp "Uninstall gre-tunnel service + watchdog as well? [y/N]: " sy
      case "$sy" in
        [Yy]*) uninstall_service; uninstall_watchdog ;;
        *) echo "Services left installed." ;;
      esac
    fi
  fi
}

# ---------------- systemd: main service ----------------
install_service() {
  command -v systemctl >/dev/null 2>&1 || { echo "systemctl not available" >&2; return 1; }

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
  log info "gre-tunnel.service installed and started"
}

uninstall_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now gre-tunnel.service 2>/dev/null || true
    rm -f "$SERVICE_UNIT"
    systemctl daemon-reload
  fi
  rm -f "$INSTALL_BIN"
  log info "gre-tunnel.service uninstalled"
}

service_start() {
  if load_config; then
    log info "Starting tunnel from saved config..."
    create_tunnel 0
  else
    log err "No saved configuration at $CONF_FILE. Service cannot start."
    return 1
  fi
}

# ---------------- systemd: watchdog (self-healing) ----------------
install_watchdog() {
  command -v systemctl >/dev/null 2>&1 || { echo "systemctl not available" >&2; return 1; }

  cat > "$WATCHDOG_SERVICE" <<EOF
[Unit]
Description=GRE Tunnel Watchdog Check

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALL_BIN --watchdog-check
EOF

  cat > "$WATCHDOG_TIMER" <<EOF
[Unit]
Description=Run GRE Tunnel Watchdog every 15s

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now gre-tunnel-watchdog.timer
  log info "gre-tunnel-watchdog.timer installed (checks every 15s)"
}

uninstall_watchdog() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now gre-tunnel-watchdog.timer 2>/dev/null || true
    rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
    systemctl daemon-reload
  fi
  log info "Watchdog uninstalled"
}

WATCHDOG_FAILS_FILE="/run/gre-tunnel-watchdog.fails"
WATCHDOG_MAX_FAILS=3

watchdog_check() {
  load_config || { log err "watchdog: no config, skipping"; return 0; }

  local fails=0
  [ -f "$WATCHDOG_FAILS_FILE" ] && fails=$(cat "$WATCHDOG_FAILS_FILE" 2>/dev/null || echo 0)

  if ! ip link show "$TUN_IF" >/dev/null 2>&1 || ! ping -c 2 -W 2 "$REMOTE_GRE_IP" >/dev/null 2>&1; then
    fails=$((fails + 1))
    echo "$fails" > "$WATCHDOG_FAILS_FILE"
    log warning "watchdog: tunnel check failed ($fails/$WATCHDOG_MAX_FAILS)"
    if [ "$fails" -ge "$WATCHDOG_MAX_FAILS" ]; then
      log warning "watchdog: rebuilding tunnel after $fails consecutive failures"
      create_tunnel 0 && echo 0 > "$WATCHDOG_FAILS_FILE"
    fi
  else
    [ "$fails" -ne 0 ] && log info "watchdog: tunnel recovered"
    echo 0 > "$WATCHDOG_FAILS_FILE"
  fi
}

# ---------------- menu ----------------
show_menu() {
  clear
  echo "==============================="
  echo " ++ GRE Tunnel Management v2 ++"
  echo "==============================="
  echo "1) config tunnel"
  echo "2) status"
  echo "3) remove tun"
  echo "4) install/refresh watchdog"
  echo "0) Exit"
  read -rp "Choose an option [0-4]: " CHOICE
  case "$CHOICE" in
    1) menu_config_tunnel ; read -rp "Press Enter to continue..." _ ;;
    2) load_config >/dev/null 2>&1 || true; status_check ; read -rp "Press Enter to continue..." _ ;;
    3) load_config >/dev/null 2>&1 || true; remove_tun ; read -rp "Press Enter to continue..." _ ;;
    4) install_watchdog ; read -rp "Press Enter to continue..." _ ;;
    0) echo "Bye"; exit 0 ;;
    *) echo "Invalid option"; sleep 1 ;;
  esac
}

### Script entry
if [[ "${1:-}" == "--service" && "${2:-}" == "start" ]]; then
  ensure_root
  service_start
  exit $?
fi

if [[ "${1:-}" == "--watchdog-check" ]]; then
  ensure_root
  watchdog_check
  exit $?
fi

ensure_root
while true; do
  show_menu
done
