#!/usr/bin/env bash
set -Eeuo pipefail

# Run this on the Proxmox VE host. It automates stages 1-4:
# 1. Create Debian LXC.
# 2. Configure privileged LXC, nesting, keyctl and TUN.
# 3. Run the Mihomo/NexusBox installer inside LXC.
# 4. Configure LXC NAT firewall and rc.local inside LXC.

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
INSTALL_URL="${INSTALL_URL:-${RAW_BASE}/install.sh}"
PROXY_URL="${PROXY_URL:-${RAW_BASE}/proxy.sh}"
GH_PROXY="${GH_PROXY:-}"

CTID="${CTID:-109}"
USE_EXISTING="${USE_EXISTING:-0}"
EXISTING_CTID="${EXISTING_CTID:-}"
[ -n "$EXISTING_CTID" ] && { CTID="$EXISTING_CTID"; USE_EXISTING=1; }
CT_HOSTNAME="${CT_HOSTNAME:-mihomo-router}"
CT_IP_CIDR="${CT_IP_CIDR:-}"
CT_GW="${CT_GW:-}"
CT_BRIDGE="${CT_BRIDGE:-}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_SWAP="${CT_SWAP:-0}"
CT_DISK_SIZE="${CT_DISK_SIZE:-8}"
CT_ROOTFS_STORAGE="${CT_ROOTFS_STORAGE:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-local}"
CT_TEMPLATE_NAME="${CT_TEMPLATE_NAME:-debian-13-standard_13.1-2_amd64.tar.zst}"
TEMPLATE_URL="${TEMPLATE_URL:-}"
CT_PASSWORD="${CT_PASSWORD:-}"
CT_DNS="${CT_DNS:-223.5.5.5}"
LXC_INSTALL_MODE="${LXC_INSTALL_MODE:-auto}"
VERSION="${VERSION:-v1.19.28}"
LXC_PROXY="${LXC_PROXY:-off}"
LXC_PROXY_ADDR="${LXC_PROXY_ADDR:-}"
LXC_PROXY_PORT="${LXC_PROXY_PORT:-7897}"
LXC_PROXY_COMMON_PORTS="${LXC_PROXY_COMMON_PORTS:-7897 7890 7891 7892 1080 20171}"
LXC_PROXY_HTTP=""
INSTALL_PROFILE="unknown"
INTERACTIVE="${INTERACTIVE:-auto}"
NEXUSBOX_DEFAULT_INSTALL_URL="${NEXUSBOX_DEFAULT_INSTALL_URL:-https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh}"
NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-}"

WORK_DIR="${WORK_DIR:-/tmp/pve-mihomo-router}"
LOG="${LOG:-/root/pve-mihomo-router-install.log}"
mkdir -p "$WORK_DIR"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { say "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

backup_file() {
  local path="$1" ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$path" ]; then
    cp -a "$path" "${path}.bak-${ts}"
    say "Backed up $path -> ${path}.bak-${ts}"
  fi
}

require_pve_host() {
  [ "$(id -u)" = "0" ] || die "Run as root on the PVE host."
  if ! have pct; then
    if systemd-detect-virt --container >/dev/null 2>&1 || [ -f /run/.containerenv ]; then
      die "pct not found because this looks like an LXC/container. Run pve-install.sh on the PVE host. Inside an existing LXC, use install.sh instead."
    fi
    die "pct not found. Run this on a Proxmox VE host."
  fi
  have pveam || die "pveam not found. Run this on a Proxmox VE host."
  have curl || die "curl not found. Install curl on the PVE host first."
}

is_interactive() {
  [ "$INTERACTIVE" != "0" ] && [ "$INTERACTIVE" != "false" ] && [ -t 0 ]
}

prompt_choices() {
  is_interactive || return 0

  if [ "$LXC_INSTALL_MODE" = "auto" ] && [ -z "$NEXUSBOX_INSTALL_URL" ]; then
    echo
    echo "Install mode:"
    echo "  1) Standalone Mihomo side-router (no NexusBox UI / no 18080)"
    echo "  2) Auto: fix NexusBox if already installed, otherwise standalone Mihomo"
    echo "  3) Fix existing NexusBox core only"
    echo "  4) Install NexusBox UI from installer URL, then fix core"
    printf "Choose [1-4, default 1]: "
    read -r install_choice
    case "${install_choice:-1}" in
      1) LXC_INSTALL_MODE="standalone" ;;
      2) LXC_INSTALL_MODE="auto" ;;
      3) LXC_INSTALL_MODE="nexusbox" ;;
      4)
        LXC_INSTALL_MODE="nexusbox-install"
        if [ -z "$NEXUSBOX_INSTALL_URL" ]; then
          printf "NexusBox installer URL [default: %s]: " "$NEXUSBOX_DEFAULT_INSTALL_URL"
          read -r NEXUSBOX_INSTALL_URL
        fi
        NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-$NEXUSBOX_DEFAULT_INSTALL_URL}"
        ;;
      *) die "Invalid install mode choice: $install_choice" ;;
    esac
  fi

  if [ "$LXC_PROXY" = "off" ]; then
    echo
    echo "LXC proxy:"
    echo "  1) Off"
    echo "  2) Auto-detect online proxy"
    echo "  3) Manually enter proxy address"
    printf "Choose [1-3, default 1]: "
    read -r proxy_choice
    case "${proxy_choice:-1}" in
      1) LXC_PROXY="off" ;;
      2) LXC_PROXY="auto" ;;
      3)
        LXC_PROXY="on"
        printf "Proxy address, for example 192.168.1.100:7897: "
        read -r LXC_PROXY_ADDR
        [ -n "$LXC_PROXY_ADDR" ] || die "LXC_PROXY_ADDR is required for manual proxy mode."
        ;;
      *) die "Invalid proxy choice: $proxy_choice" ;;
    esac
  fi

  say "Selected install mode: $LXC_INSTALL_MODE"
  say "Selected LXC proxy mode: $LXC_PROXY"
}

detect_storage() {
  if [ -z "$CT_ROOTFS_STORAGE" ]; then
    if pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq 'local-lvm'; then
      CT_ROOTFS_STORAGE="local-lvm"
    elif pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq 'local'; then
      CT_ROOTFS_STORAGE="local"
    else
      die "Cannot detect rootfs storage. Set CT_ROOTFS_STORAGE manually."
    fi
  elif ! pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$CT_ROOTFS_STORAGE"; then
    die "Storage '$CT_ROOTFS_STORAGE' does not exist. Check pvesm status or set CT_ROOTFS_STORAGE."
  fi
  say "Using rootfs storage: $CT_ROOTFS_STORAGE"
}

confirm_new_ctid() {
  if pct status "$CTID" >/dev/null 2>&1; then
    die "CTID $CTID already exists. Use another one, for example: CTID=110 bash pve-install.sh"
  fi
}

confirm_existing_ctid() {
  if ! pct status "$CTID" >/dev/null 2>&1; then
    die "Existing CTID $CTID was not found. Check CTID or use new-container mode."
  fi
}

cidr_prefix_to_mask() {
  local prefix="$1" mask="" full rem i
  full=$((prefix / 8))
  rem=$((prefix % 8))
  for i in 1 2 3 4; do
    if [ "$i" -le "$full" ]; then
      mask="${mask}255"
    elif [ "$i" -eq $((full + 1)) ] && [ "$rem" -gt 0 ]; then
      mask="${mask}$((256 - 2 ** (8 - rem)))"
    else
      mask="${mask}0"
    fi
    [ "$i" -lt 4 ] && mask="${mask}."
  done
  printf '%s' "$mask"
}

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%u' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

int_to_ip() {
  local n="$1"
  printf '%d.%d.%d.%d' "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

ip_in_use() {
  local ip="$1"
  ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && return 0
  ip neigh show "$ip" 2>/dev/null | awk '
    /lladdr/ && $0 !~ /(FAILED|INCOMPLETE)/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

detect_network() {
  say "Detecting PVE LAN network"
  local route_line dev gw pve_cidr pve_ip prefix network broadcast base candidate host candidates

  route_line="$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)"
  dev="$(printf '%s\n' "$route_line" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"

  if [ -z "$dev" ]; then
    dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  fi
  if [ -z "$dev" ]; then
    dev="$(ip -o -4 addr show scope global | awk '{print $2; exit}')"
  fi
  [ -n "$dev" ] || die "Cannot detect LAN interface. Set CT_BRIDGE, CT_IP_CIDR and CT_GW manually."

  if [ -z "$CT_BRIDGE" ]; then
    if printf '%s' "$dev" | grep -q '^vmbr'; then
      CT_BRIDGE="$dev"
    else
      CT_BRIDGE="$(ip -o -4 addr show scope global | awk '$2 ~ /^vmbr/ {print $2; exit}')"
      [ -n "$CT_BRIDGE" ] || CT_BRIDGE="$dev"
    fi
  fi

  pve_cidr="$(ip -o -4 addr show dev "$CT_BRIDGE" scope global 2>/dev/null | awk '{print $4; exit}')"
  if [ -z "$pve_cidr" ] && [ "$CT_BRIDGE" != "$dev" ]; then
    pve_cidr="$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}')"
  fi
  [ -n "$pve_cidr" ] || die "Cannot detect PVE LAN IP. Set CT_IP_CIDR manually."

  pve_ip="${pve_cidr%/*}"
  prefix="${pve_cidr#*/}"
  [ -n "$CT_GW" ] || CT_GW="$gw"
  [ -n "$CT_GW" ] || die "Cannot detect default gateway. Set CT_GW manually."

  if [ -z "$CT_IP_CIDR" ]; then
    local mask_int pve_int net_int bcast_int
    mask_int="$(ip_to_int "$(cidr_prefix_to_mask "$prefix")")"
    pve_int="$(ip_to_int "$pve_ip")"
    net_int="$((pve_int & mask_int))"
    bcast_int="$((net_int | (0xffffffff ^ mask_int) ))"

    candidates=(9 6 8 10 20 30 50 60 100 200)
    for host in "${candidates[@]}"; do
      candidate="$(int_to_ip "$((net_int + host))")"
      [ "$((net_int + host))" -gt "$net_int" ] || continue
      [ "$((net_int + host))" -lt "$bcast_int" ] || continue
      [ "$candidate" != "$pve_ip" ] || continue
      [ "$candidate" != "$CT_GW" ] || continue
      if ! ip_in_use "$candidate"; then
        CT_IP_CIDR="${candidate}/${prefix}"
        break
      fi
    done

    if [ -z "$CT_IP_CIDR" ]; then
      say "Common IP candidates are unavailable; scanning the local subnet"
      local start_int end_int cur_int scan_end_int
      start_int="$((net_int + 2))"
      end_int="$((bcast_int - 1))"
      scan_end_int="$end_int"
      if [ "$((scan_end_int - start_int))" -gt 512 ]; then
        scan_end_int="$((start_int + 512))"
      fi
      cur_int="$start_int"
      while [ "$cur_int" -le "$scan_end_int" ]; do
        candidate="$(int_to_ip "$cur_int")"
        cur_int="$((cur_int + 1))"
        [ "$candidate" != "$pve_ip" ] || continue
        [ "$candidate" != "$CT_GW" ] || continue
        if ! ip_in_use "$candidate"; then
          CT_IP_CIDR="${candidate}/${prefix}"
          break
        fi
      done
    fi
  fi

  say "Detected bridge: $CT_BRIDGE"
  say "Detected PVE IP: $pve_cidr"
  say "Detected gateway: $CT_GW"
  [ -n "$CT_IP_CIDR" ] || die "Cannot choose an unused LXC IP. Set CT_IP_CIDR manually, for example: CT_IP_CIDR=<free-ip>/${prefix} CT_GW=${CT_GW} CT_BRIDGE=${CT_BRIDGE} bash pve-install.sh"
  say "Selected LXC IP: $CT_IP_CIDR"
}

detect_existing_container_network() {
  say "Detecting existing LXC $CTID network"
  local conf="/etc/pve/lxc/${CTID}.conf"
  local net0 ip gw bridge status runtime_ip prefix
  [ -e "$conf" ] || die "LXC config not found: $conf"

  net0="$(sed -n 's/^net0: //p' "$conf" | head -1)"
  [ -n "$net0" ] || die "Cannot find net0 in $conf"

  bridge="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^bridge=//p' | head -1)"
  ip="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^ip=//p' | head -1)"
  gw="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^gw=//p' | head -1)"

  [ -n "$CT_BRIDGE" ] || CT_BRIDGE="$bridge"
  [ -n "$CT_GW" ] || CT_GW="$gw"

  if [ -z "$CT_IP_CIDR" ] && [ -n "$ip" ] && [ "$ip" != "dhcp" ] && [ "$ip" != "manual" ]; then
    CT_IP_CIDR="$ip"
  fi

  status="$(pct status "$CTID" | awk '{print $2}')"
  if [ "$status" != "running" ]; then
    say "Starting existing LXC $CTID for IP detection"
    pct start "$CTID"
    sleep 3
  fi

  if [ -z "$CT_IP_CIDR" ] || printf '%s' "$CT_IP_CIDR" | grep -qi '^dhcp$'; then
    runtime_ip="$(pct exec "$CTID" -- sh -c \"ip -o -4 addr show scope global | awk '{print \\\$4; exit}'\" 2>/dev/null || true)"
    [ -n "$runtime_ip" ] || die "Cannot detect existing LXC runtime IP. Set CT_IP_CIDR manually."
    CT_IP_CIDR="$runtime_ip"
  fi

  if [ -z "$CT_BRIDGE" ]; then
    CT_BRIDGE="$(ip -o -4 addr show scope global | awk '$2 ~ /^vmbr/ {print $2; exit}')"
  fi
  if [ -z "$CT_GW" ]; then
    CT_GW="$(pct exec "$CTID" -- sh -c \"ip -4 route show default | awk '{print \\\$3; exit}'\" 2>/dev/null || true)"
  fi

  prefix="${CT_IP_CIDR#*/}"
  if [ "$prefix" = "$CT_IP_CIDR" ]; then
    say "Existing LXC IP has no CIDR prefix; assuming /24"
    CT_IP_CIDR="${CT_IP_CIDR}/24"
  fi

  say "Existing LXC bridge: ${CT_BRIDGE:-unknown}"
  say "Existing LXC gateway: ${CT_GW:-unknown}"
  say "Existing LXC IP: $CT_IP_CIDR"
}

download_with_fallback() {
  local url="$1" out="$2" u
  local urls=()
  [ -n "$GH_PROXY" ] && urls+=("${GH_PROXY%/}/${url}")
  urls+=("$url" "https://gh.llkk.cc/${url}" "https://gh-proxy.com/${url}" "https://mirror.ghproxy.com/${url}")
  for u in "${urls[@]}"; do
    say "Try download: $u"
    if curl -fsSL --connect-timeout 15 --retry 2 -o "$out" "$u"; then
      return 0
    fi
  done
  return 1
}

choose_template() {
  local existing latest
  if [ -n "$TEMPLATE_URL" ]; then
    local filename template_path
    filename="${TEMPLATE_URL%%\?*}"
    filename="${filename##*/}"
    [ -n "$filename" ] || die "Cannot parse template filename from TEMPLATE_URL."
    template_path="$(pvesm path "${CT_TEMPLATE_STORAGE}:vztmpl/${filename}" 2>/dev/null || true)"
    if [ -z "$template_path" ]; then
      template_path="/var/lib/vz/template/cache/${filename}"
    fi
    mkdir -p "$(dirname "$template_path")"
    if [ ! -s "$template_path" ]; then
      say "Downloading LXC template from TEMPLATE_URL: $TEMPLATE_URL"
      download_with_fallback "$TEMPLATE_URL" "$template_path" || die "Failed to download TEMPLATE_URL."
    else
      say "Use existing template file: $template_path"
    fi
    TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${filename}"
    say "Use custom template: $TEMPLATE"
    return 0
  fi

  if [ -n "$CT_TEMPLATE_NAME" ]; then
    existing="$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk -v name="$CT_TEMPLATE_NAME" '$1 == name || $1 == "vztmpl/" name || $1 ~ ("/" name "$") {print $1; exit}' || true)"
    if [ -z "$existing" ]; then
      local template_path
      template_path="$(pvesm path "${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_NAME}" 2>/dev/null || true)"
      if [ -n "$template_path" ] && [ -s "$template_path" ]; then
        existing="${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_NAME}"
      elif [ -s "/var/lib/vz/template/cache/${CT_TEMPLATE_NAME}" ]; then
        existing="${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_NAME}"
      fi
    fi
    if [ -n "$existing" ]; then
      TEMPLATE="$existing"
      say "Use preferred template: $TEMPLATE"
      return 0
    fi
    say "Preferred template was not found locally: $CT_TEMPLATE_NAME"
  fi

  existing="$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-13-standard.*amd64.*(tar.zst|tar.gz)/{print $1}' | sort -V | tail -1 || true)"
  if [ -n "$existing" ]; then
    TEMPLATE="$existing"
    say "Use existing template: $TEMPLATE"
    return 0
  fi

  say "Updating LXC template list"
  pveam update
  latest="$(pveam available --section system | awk '/debian-13-standard.*amd64.*(tar.zst|tar.gz)/{print $2}' | sort -V | tail -1 || true)"
  if [ -z "$latest" ]; then
    latest="$(pveam available --section system | awk '/debian-12-standard.*amd64.*(tar.zst|tar.gz)/{print $2}' | sort -V | tail -1 || true)"
  fi
  [ -n "$latest" ] || die "Cannot find Debian 13/12 amd64 LXC template."
  say "Downloading template: $latest"
  pveam download "$CT_TEMPLATE_STORAGE" "$latest"
  TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${latest}"
}

create_container() {
  say "Creating LXC $CTID ($CT_HOSTNAME)"
  local password_args=()
  [ -n "$CT_PASSWORD" ] && password_args=(--password "$CT_PASSWORD")

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --rootfs "${CT_ROOTFS_STORAGE}:${CT_DISK_SIZE}" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP_CIDR},gw=${CT_GW}" \
    --nameserver "$CT_DNS" \
    --ostype debian \
    --unprivileged 0 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    "${password_args[@]}"
}

ensure_lxc_conf_line() {
  local conf="$1" line="$2"
  grep -Fxq "$line" "$conf" || echo "$line" >> "$conf"
}

configure_lxc_tun() {
  local conf="/etc/pve/lxc/${CTID}.conf"
  say "Configuring LXC TUN and nesting"
  [ -e "$conf" ] || die "LXC config not found: $conf"
  backup_file "$conf"
  pct set "$CTID" --features nesting=1,keyctl=1
  ensure_lxc_conf_line "$conf" "lxc.cgroup2.devices.allow: c 10:200 rwm"
  ensure_lxc_conf_line "$conf" "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
}

start_container() {
  say "Starting LXC $CTID"
  if ! pct status "$CTID" | grep -q 'running'; then
    pct start "$CTID"
  fi
  for _ in $(seq 1 30); do
    pct exec "$CTID" -- test -e /proc/1/status >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Container did not become ready."
}

setup_lxc_proxy() {
  case "$LXC_PROXY" in
    off|"")
      return 0
      ;;
    disable)
      say "Disabling proxy inside LXC"
      ;;
    auto|on)
      say "Configuring proxy inside LXC: LXC_PROXY=$LXC_PROXY"
      ;;
    *)
      die "Unknown LXC_PROXY=$LXC_PROXY. Use off, auto, on, or disable."
      ;;
  esac

  local local_proxy="$WORK_DIR/proxy.sh"
  if [ -f "./proxy.sh" ]; then
    cp ./proxy.sh "$local_proxy"
  else
    download_with_fallback "$PROXY_URL" "$local_proxy" || die "Failed to download proxy.sh"
  fi
  chmod +x "$local_proxy"
  pct push "$CTID" "$local_proxy" /root/lxc-proxy.sh -perms 0755

  if [ "$LXC_PROXY" = "disable" ]; then
    pct exec "$CTID" -- bash /root/lxc-proxy.sh off || true
    return 0
  fi

  local proxy_addr=""
  if [ "$LXC_PROXY" = "auto" ]; then
    proxy_addr="$(pct exec "$CTID" -- env \
      PROXY_ADDR="$LXC_PROXY_ADDR" \
      PROXY_PORT="$LXC_PROXY_PORT" \
      COMMON_PORTS="$LXC_PROXY_COMMON_PORTS" \
      bash /root/lxc-proxy.sh detect 2>/dev/null || true)"
    if [ -z "$proxy_addr" ]; then
      say "No online LXC proxy detected. Continue without proxy."
      return 0
    fi
    say "Detected online LXC proxy: $proxy_addr"
  else
    proxy_addr="$LXC_PROXY_ADDR"
  fi

  pct exec "$CTID" -- env \
    PROXY_ADDR="$LXC_PROXY_ADDR" \
    PROXY_PORT="$LXC_PROXY_PORT" \
    COMMON_PORTS="$LXC_PROXY_COMMON_PORTS" \
    bash /root/lxc-proxy.sh on "$proxy_addr"

  proxy_addr="$(pct exec "$CTID" -- sh -c "sed -n 's/.*http:\\/\\/\\([^\"]*\\).*/\\1/p' /etc/apt/apt.conf.d/99proxy 2>/dev/null | head -1" || true)"
  if [ -n "$proxy_addr" ]; then
    LXC_PROXY_HTTP="http://${proxy_addr}"
    say "LXC installer will use proxy: $LXC_PROXY_HTTP"
  fi
}

run_in_container() {
  say "Running installer inside LXC"
  local local_install="$WORK_DIR/install.sh"
  if [ -f "./install.sh" ]; then
    cp ./install.sh "$local_install"
  else
    download_with_fallback "$INSTALL_URL" "$local_install" || die "Failed to download install.sh"
  fi
  chmod +x "$local_install"
  pct push "$CTID" "$local_install" /root/mihomo-router-install.sh -perms 0755

  local env_args=(MODE="$LXC_INSTALL_MODE" VERSION="$VERSION" NEXUSBOX_INSTALL_URL="$NEXUSBOX_INSTALL_URL" NEXUSBOX_DEFAULT_INSTALL_URL="$NEXUSBOX_DEFAULT_INSTALL_URL")
  if [ -n "$LXC_PROXY_HTTP" ]; then
    env_args+=(
      http_proxy="$LXC_PROXY_HTTP"
      https_proxy="$LXC_PROXY_HTTP"
      HTTP_PROXY="$LXC_PROXY_HTTP"
      HTTPS_PROXY="$LXC_PROXY_HTTP"
    )
  fi
  pct exec "$CTID" -- env "${env_args[@]}" bash /root/mihomo-router-install.sh
}

verify_container_health() {
  say "Verifying LXC runtime health"
  local result
  result="$(pct exec "$CTID" -- sh -s <<'EOS'
set -eu
fail=0
profile=standalone
if [ -x /opt/nexusbox/nexusbox ]; then
  profile=nexusbox
fi
echo "profile=${profile}"

check_cmd() {
  label="$1"
  shift
  if "$@"; then
    echo "ok: ${label}"
  else
    echo "fail: ${label}"
    fail=1
  fi
}

check_port() {
  port="$1"
  label="$2"
  if ss -lntup 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
    echo "ok: ${label} port ${port}"
  else
    echo "fail: ${label} port ${port}"
    fail=1
  fi
}

if [ "$profile" = "nexusbox" ]; then
  check_cmd "NexusBox process" pgrep -f /opt/nexusbox/nexusbox
  check_port 18080 "NexusBox UI"
else
  check_cmd "mihomo.service active" systemctl is-active --quiet mihomo
  check_cmd "Mihomo process" pgrep -f "/usr/local/bin/mihomo -d /etc/mihomo"
fi

check_port 7890 "Mihomo mixed proxy"
check_port 9090 "Mihomo controller API"
if [ "$profile" = "standalone" ]; then
  check_port 1053 "Mihomo DNS"
fi

if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ]; then
  echo "ok: ip_forward enabled"
else
  echo "fail: ip_forward disabled"
  fail=1
fi

if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- '-j MASQUERADE'; then
  echo "ok: NAT MASQUERADE rule"
else
  echo "fail: NAT MASQUERADE rule"
  fail=1
fi

exit "$fail"
EOS
)" || {
    printf '%s\n' "$result"
    die "LXC runtime verification failed."
  }
  printf '%s\n' "$result"
  INSTALL_PROFILE="$(printf '%s\n' "$result" | sed -n 's/^profile=//p' | head -1)"
  [ -n "$INSTALL_PROFILE" ] || INSTALL_PROFILE="unknown"
}

print_summary() {
  local ip="${CT_IP_CIDR%/*}"
  say "Stage 1-4 completed"
  echo "LXC ID: $CTID"
  echo "LXC IP: $ip"
  echo "Install profile: $INSTALL_PROFILE"
  if [ "$INSTALL_PROFILE" = "nexusbox" ]; then
    echo "NexusBox UI: http://${ip}:18080"
  else
    echo "NexusBox UI: not installed (standalone Mihomo mode)"
  fi
  echo "Mihomo mixed proxy: ${ip}:7890"
  echo "Mihomo controller API: http://${ip}:9090"
  [ "$INSTALL_PROFILE" = "standalone" ] && echo "Mihomo DNS: ${ip}:1053"
  [ -n "$LXC_PROXY_HTTP" ] && echo "LXC proxy used during install: $LXC_PROXY_HTTP"
  echo
  echo "Stage 5 still needs router settings:"
  echo "  route: 198.18.0.0/16 -> ${ip}"
  echo "  client DNS: ${ip}"
  echo
  echo "Log file: $LOG"
}

main() {
  require_pve_host
  prompt_choices
  detect_storage
  if [ "$USE_EXISTING" = "1" ]; then
    confirm_existing_ctid
    detect_existing_container_network
  else
    detect_network
    confirm_new_ctid
    choose_template
    create_container
  fi
  configure_lxc_tun
  start_container
  setup_lxc_proxy
  run_in_container
  verify_container_health
  print_summary
}

main "$@"
