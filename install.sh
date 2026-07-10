#!/usr/bin/env bash
set -Eeuo pipefail

# Mihomo / NexusBox one-key installer for PVE LXC side-router.
# Safe defaults:
# - No batch deletion.
# - Existing files are copied to timestamped backups before overwrite.
# - CPU is detected automatically: amd64-v3 core when supported, compatible core otherwise.

VERSION="${VERSION:-v1.19.28}"
BASE_URL="${BASE_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}}"
WORK_DIR="${WORK_DIR:-/tmp/mihomo-router-install}"
LOG="${LOG:-/root/mihomo-router-install.log}"
CONFIG_DIR="${CONFIG_DIR:-/etc/mihomo}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.yaml}"
CONFIG_URL="${CONFIG_URL:-}"
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
NEXUSBOX_BIN="${NEXUSBOX_BIN:-/opt/nexusbox/nexusbox}"
NEXUSBOX_CORE="${NEXUSBOX_CORE:-/opt/mihomo/mihomo}"
NEXUSBOX_CONFIG_DIR="${NEXUSBOX_CONFIG_DIR:-/opt/config}"
NEXUSBOX_DEFAULT_INSTALL_URL="${NEXUSBOX_DEFAULT_INSTALL_URL:-https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh}"
NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-$NEXUSBOX_DEFAULT_INSTALL_URL}"
MODE="${MODE:-auto}"
INSTALL_PROFILE="${INSTALL_PROFILE:-unknown}"

mkdir -p "$WORK_DIR"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { say "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
backup_file() {
  local path="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$path" ]; then
    cp -a "$path" "${path}.bak-${ts}"
    say "Backed up $path -> ${path}.bak-${ts}"
  fi
}

set_yaml_scalar() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    printf '\n%s: %s\n' "$key" "$value" >> "$file"
  fi
}

require_root() {
  [ "$(id -u)" = "0" ] || die "Please run as root."
}

detect_egress_iface() {
  local iface
  iface="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1 || true)"
  [ -n "$iface" ] || iface="eth0"
  printf '%s' "$iface"
}

cpu_supports_amd64_v3() {
  [ "$(uname -m)" = "x86_64" ] || return 1
  local flags missing=0
  flags="$(awk -F: '/flags/{print " " $2 " "; exit}' /proc/cpuinfo 2>/dev/null || true)"
  for f in avx avx2 bmi1 bmi2 f16c fma lzcnt movbe osxsave; do
    case "$flags" in
      *" $f "*) ;;
      *) missing=1 ;;
    esac
  done
  [ "$missing" = "0" ]
}

choose_asset() {
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)
      if cpu_supports_amd64_v3; then
        CORE_KIND="amd64-v3"
        ASSET="mihomo-linux-amd64-v3-${VERSION}.gz"
      else
        CORE_KIND="amd64-compatible"
        ASSET="mihomo-linux-amd64-compatible-${VERSION}.gz"
      fi
      ;;
    aarch64|arm64)
      CORE_KIND="arm64"
      ASSET="mihomo-linux-arm64-${VERSION}.gz"
      ;;
    *)
      die "Unsupported CPU arch: $arch"
      ;;
  esac
  say "Selected core: $CORE_KIND ($ASSET)"
}

download_file() {
  local asset="$1"
  local output="$2"
  local raw_url="${BASE_URL}/${asset}"
  local urls=()

  if [ -n "${GH_PROXY:-}" ]; then
    urls+=("${GH_PROXY%/}/${raw_url}")
  fi

  urls+=(
    "$raw_url"
    "https://gh.llkk.cc/${raw_url}"
    "https://gh-proxy.com/${raw_url}"
    "https://mirror.ghproxy.com/${raw_url}"
  )

  say "Downloading $asset"
  for url in "${urls[@]}"; do
    say "Try: $url"
    if have curl; then
      if curl -fL --connect-timeout 15 --retry 2 -o "$output" "$url"; then
        return 0
      fi
    elif have wget; then
      if wget -T 15 -t 2 -O "$output" "$url"; then
        return 0
      fi
    else
      die "curl/wget is missing. Install curl first."
    fi
  done
  die "Download failed. You can retry with: GH_PROXY=https://your-github-proxy/ bash $0"
}

download_url_with_fallback() {
  local url="$1" output="$2" u
  local urls=()

  [ -n "${GH_PROXY:-}" ] && urls+=("${GH_PROXY%/}/${url}")
  urls+=("$url" "https://gh.llkk.cc/${url}" "https://gh-proxy.com/${url}" "https://mirror.ghproxy.com/${url}")

  for u in "${urls[@]}"; do
    say "Try: $u"
    if have curl; then
      if curl -fL --connect-timeout 20 --retry 2 -o "$output" "$u"; then
        return 0
      fi
    elif have wget; then
      if wget -T 20 -t 2 -O "$output" "$u"; then
        return 0
      fi
    else
      die "curl/wget is missing. Install curl first."
    fi
  done
  return 1
}

import_config_from_url() {
  local target="$1" profile="$2"
  [ -n "$CONFIG_URL" ] || return 0

  local downloaded="$WORK_DIR/config.yaml"
  say "Importing custom config for $profile"
  download_url_with_fallback "$CONFIG_URL" "$downloaded" || die "Failed to download CONFIG_URL."
  [ -s "$downloaded" ] || die "Downloaded CONFIG_URL is empty."

  mkdir -p "$(dirname "$target")"
  backup_file "$target"
  cp "$downloaded" "$target"

  set_yaml_scalar "$target" "mixed-port" "7890"
  set_yaml_scalar "$target" "allow-lan" "true"
  set_yaml_scalar "$target" "external-controller" "'0.0.0.0:9090'"
  if [ "$profile" = "nexusbox" ]; then
    set_yaml_scalar "$target" "external-controller-unix" "'/opt/nexusbox/var/core.sock'"
    set_yaml_scalar "$target" "external-ui" "ui/meta"
  fi
}

download_nexusbox_installer() {
  local output="$1"
  local url urls=()

  [ -n "${NEXUSBOX_INSTALL_URL:-}" ] && urls+=("$NEXUSBOX_INSTALL_URL")
  urls+=(
    "$NEXUSBOX_DEFAULT_INSTALL_URL"
    "https://cdn.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
    "https://fastly.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
    "https://testingcf.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
    "https://gh.llkk.cc/${NEXUSBOX_DEFAULT_INSTALL_URL}"
    "https://gh-proxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
    "https://mirror.ghproxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
  )

  say "Downloading NexusBox installer"
  for url in "${urls[@]}"; do
    [ -n "$url" ] || continue
    say "Try: $url"
    if have curl; then
      if curl -fL --connect-timeout 20 --retry 2 -o "$output" "$url"; then
        return 0
      fi
    elif have wget; then
      if wget -T 20 -t 2 -O "$output" "$url"; then
        return 0
      fi
    else
      die "curl/wget is missing. Install curl first."
    fi
  done
  die "NexusBox installer download failed. You can retry with NEXUSBOX_INSTALL_URL=<url>."
}

apt_install_if_missing() {
  local pkgs=()
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    fi
  done
  [ "${#pkgs[@]}" -gt 0 ] || return 0

  say "Installing packages: ${pkgs[*]}"
  export http_proxy="${http_proxy:-}"
  export https_proxy="${https_proxy:-}"
  export HTTP_PROXY="${HTTP_PROXY:-}"
  export HTTPS_PROXY="${HTTPS_PROXY:-}"

  if ! apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false update; then
    say "apt update failed without proxy. Trying normal apt update."
    apt-get update
  fi
  apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false install -y "${pkgs[@]}" || apt-get install -y "${pkgs[@]}"
}

prepare_core_binary() {
  choose_asset
  mkdir -p "$WORK_DIR"
  download_file "$ASSET" "$WORK_DIR/mihomo.gz"
  gzip -dc "$WORK_DIR/mihomo.gz" > "$WORK_DIR/mihomo"
  chmod 0755 "$WORK_DIR/mihomo"
  "$WORK_DIR/mihomo" -v
}

write_rc_local_nat() {
  local iface="$1"
  say "Configure rc.local NAT on interface: $iface"
  backup_file /etc/rc.local
  cat > /etc/rc.local <<EOF
#!/bin/sh -e
echo 1 >/proc/sys/net/ipv4/ip_forward
iptables -t nat -C POSTROUTING -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE
exit 0
EOF
  chmod +x /etc/rc.local
  /etc/rc.local
}

port_listening() {
  local port="$1"
  ss -lntup 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
}

wait_for_port() {
  local port="$1" name="$2"
  for _ in $(seq 1 20); do
    if port_listening "$port"; then
      say "Verified listening port: $name ($port)"
      return 0
    fi
    sleep 1
  done
  die "$name is not listening on port $port."
}

verify_standalone_running() {
  say "Verifying standalone Mihomo runtime"
  if have systemctl; then
    systemctl is-active --quiet mihomo || {
      systemctl status mihomo --no-pager || true
      die "mihomo.service is not active."
    }
  fi
  pgrep -f "${MIHOMO_BIN} -d ${CONFIG_DIR}" >/dev/null || die "Mihomo process was not found."
  wait_for_port 7890 "Mihomo mixed proxy"
  wait_for_port 9090 "Mihomo controller API"
  wait_for_port 1053 "Mihomo DNS"
}

verify_nexusbox_running() {
  say "Verifying NexusBox runtime"
  pgrep -f "$NEXUSBOX_BIN" >/dev/null || die "NexusBox process was not found."
  wait_for_port 18080 "NexusBox UI"
  wait_for_port 7890 "Mihomo mixed proxy"
  wait_for_port 9090 "Mihomo controller API"
}

install_standalone_mihomo() {
  say "Mode: standalone Mihomo side-router"
  INSTALL_PROFILE="standalone"
  apt_install_if_missing ca-certificates gzip iproute2 iptables procps
  prepare_core_binary

  mkdir -p "$(dirname "$MIHOMO_BIN")" "$CONFIG_DIR"
  backup_file "$MIHOMO_BIN"
  cp "$WORK_DIR/mihomo" "$MIHOMO_BIN"
  chmod 0755 "$MIHOMO_BIN"

  if [ ! -e "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
mixed-port: 7890
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
ipv6: false

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,DIRECT
EOF
  else
    say "Keep existing config: $CONFIG_FILE"
  fi
  import_config_from_url "$CONFIG_FILE" "standalone"

  "$MIHOMO_BIN" -t -d "$CONFIG_DIR"

  backup_file /etc/systemd/system/mihomo.service
  cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=${MIHOMO_BIN} -d ${CONFIG_DIR}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mihomo
  write_rc_local_nat "$(detect_egress_iface)"
  verify_standalone_running
}

restart_nexusbox() {
  say "Restart NexusBox"
  if have systemctl && systemctl list-unit-files | grep -q '^nexusbox\.service'; then
    systemctl restart nexusbox || true
  else
    pkill -f '^/opt/nexusbox/nexusbox$' 2>/dev/null || true
    nohup "$NEXUSBOX_BIN" >/opt/nexusbox/var/info.log 2>&1 &
  fi
  sleep 3
}

stop_nexusbox_for_core_replace() {
  say "Stopping NexusBox before replacing Mihomo core"
  if have systemctl && systemctl list-unit-files | grep -q '^nexusbox\.service'; then
    systemctl stop nexusbox || true
  fi
  pkill -f '^/opt/nexusbox/nexusbox$' 2>/dev/null || true
  pkill -f "${NEXUSBOX_CORE} -d ${NEXUSBOX_CONFIG_DIR}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! pgrep -f "${NEXUSBOX_CORE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  say "Mihomo core process is still present; trying to replace anyway."
}

fix_nexusbox_core() {
  say "Mode: NexusBox core auto-fix"
  INSTALL_PROFILE="nexusbox"
  [ -x "$NEXUSBOX_BIN" ] || die "NexusBox binary not found: $NEXUSBOX_BIN"
  apt_install_if_missing ca-certificates gzip iproute2 iptables procps
  prepare_core_binary

  mkdir -p "$(dirname "$NEXUSBOX_CORE")" /opt/nexusbox/var
  stop_nexusbox_for_core_replace
  backup_file "$NEXUSBOX_CORE"
  cp "$WORK_DIR/mihomo" "$NEXUSBOX_CORE"
  chmod 0755 "$NEXUSBOX_CORE"

  import_config_from_url "${NEXUSBOX_CONFIG_DIR}/config.yaml" "nexusbox"

  "$NEXUSBOX_CORE" -v
  "$NEXUSBOX_CORE" -t -d "$NEXUSBOX_CONFIG_DIR"

  write_rc_local_nat "$(detect_egress_iface)"
  restart_nexusbox

  curl -fsS "http://127.0.0.1:18080/configs?force=true" || true
  verify_nexusbox_running
}

install_nexusbox_from_url() {
  say "Mode: install NexusBox UI, then fix Mihomo core"
  apt_install_if_missing ca-certificates curl gzip iproute2 iptables procps

  local nexusbox_installer="$WORK_DIR/nexusbox-install.sh"
  download_nexusbox_installer "$nexusbox_installer"
  chmod 0755 "$nexusbox_installer"
  printf '\n' | bash "$nexusbox_installer"

  [ -x "$NEXUSBOX_BIN" ] || die "NexusBox installer finished, but $NEXUSBOX_BIN was not found."
  fix_nexusbox_core
}

print_report() {
  say "Final report"
  echo "CPU arch: $(uname -m)"
  echo "Core kind: ${CORE_KIND:-unknown}"
  echo "Install profile: ${INSTALL_PROFILE:-unknown}"
  echo "Egress iface: $(detect_egress_iface)"
  echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)"
  echo
  echo "NAT:"
  iptables -t nat -S POSTROUTING 2>/dev/null || true
  echo
  echo "Processes:"
  ps -ef | grep -Ei 'nexusbox|mihomo|clash|sing-box' | grep -v grep || true
  echo
  echo "Listening ports:"
  ss -lntup 2>/dev/null | grep -E '(:7890|:7898|:9090|:1053|:18080)' || true
  echo
  if [ -d /opt/nexusbox/var ]; then
    echo "NexusBox var:"
    ls -la /opt/nexusbox/var
  fi
  echo
  echo "Log file: $LOG"
}

main() {
  require_root
  say "Mihomo router installer started"
  say "VERSION=$VERSION MODE=$MODE"

  case "$MODE" in
    auto)
      if [ -x "$NEXUSBOX_BIN" ]; then
        fix_nexusbox_core
      else
        install_standalone_mihomo
      fi
      ;;
    nexusbox)
      fix_nexusbox_core
      ;;
    nexusbox-install)
      install_nexusbox_from_url
      ;;
    standalone)
      install_standalone_mihomo
      ;;
    *)
      die "Unknown MODE=$MODE. Use auto, nexusbox, nexusbox-install, or standalone."
      ;;
  esac

  print_report
  say "DONE"
}

main "$@"
