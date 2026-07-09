#!/usr/bin/env bash

PVE_PROXY_SOURCED=0
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  PVE_PROXY_SOURCED=1
else
  set -Eeuo pipefail
fi

# Debian LXC proxy helper, adapted for this project from czerov/pve-proxy.
# It manages APT proxy and shell proxy variables without hard-coded LAN IPs.

APT_CONF="${APT_CONF:-/etc/apt/apt.conf.d/99proxy}"
PROFILE_CONF="${PROFILE_CONF:-/etc/profile.d/lxc-proxy.sh}"
DEFAULT_PORT="${PROXY_PORT:-7897}"
COMMON_PORTS="${COMMON_PORTS:-7897 7890 7891 7892 1080 20171}"

if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

say() { printf '%b\n' "$*"; }
die() {
  say "${RED}ERROR: $*${NC}" >&2
  if [ "$PVE_PROXY_SOURCED" = "1" ]; then
    return 1
  fi
  exit 1
}

need_root() {
  [ "$(id -u)" = "0" ] || die "Please run as root."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

detect_gateway() {
  ip -4 route show default 2>/dev/null | awk '{print $3; exit}'
}

detect_subnet_prefix() {
  local cidr ip
  cidr="$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4; exit}')"
  ip="${cidr%/*}"
  printf '%s' "$ip" | awk -F. 'NF == 4 {print $1"."$2"."$3}'
}

tcp_probe() {
  local host="$1" port="$2"
  timeout 1 bash -c "cat < /dev/null > /dev/tcp/${host}/${port}" >/dev/null 2>&1
}

normalize_addr() {
  local input="$1"
  if printf '%s' "$input" | grep -q ':'; then
    printf '%s' "$input"
  else
    printf '%s:%s' "$input" "$DEFAULT_PORT"
  fi
}

auto_detect_proxy() {
  local detected
  if detected="$(auto_detect_online_proxy)"; then
    printf '%s' "$detected"
    return 0
  fi

  if [ -n "${PROXY_ADDR:-}" ]; then
    printf '%s' "$(normalize_addr "$PROXY_ADDR")"
    return 0
  fi

  local gw
  gw="$(detect_gateway || true)"
  if [ -n "$gw" ]; then
    printf '%s:%s' "$gw" "$DEFAULT_PORT"
  else
    printf '127.0.0.1:%s' "$DEFAULT_PORT"
  fi
}

auto_detect_online_proxy() {
  local gw prefix host port candidate

  if [ -n "${PROXY_ADDR:-}" ]; then
    candidate="$(normalize_addr "$PROXY_ADDR")"
    host="${candidate%:*}"
    port="${candidate##*:}"
    if tcp_probe "$host" "$port"; then
      printf '%s' "$candidate"
      return 0
    fi
    return 1
  fi

  gw="$(detect_gateway || true)"
  if [ -n "$gw" ]; then
    for port in $COMMON_PORTS; do
      if tcp_probe "$gw" "$port"; then
        printf '%s:%s' "$gw" "$port"
        return 0
      fi
    done
  fi

  prefix="$(detect_subnet_prefix || true)"
  if [ -n "$prefix" ]; then
    for host in 1 2 5 9 10 100 101 102 200; do
      candidate="${prefix}.${host}"
      [ "$candidate" = "$gw" ] && continue
      for port in $COMMON_PORTS; do
        if tcp_probe "$candidate" "$port"; then
          printf '%s:%s' "$candidate" "$port"
          return 0
        fi
      done
    done
  fi

  return 1
}

write_proxy() {
  local addr="$1"
  need_root || return 1
  mkdir -p "$(dirname "$APT_CONF")" "$(dirname "$PROFILE_CONF")"
  cat > "$APT_CONF" <<EOF
Acquire::http::Proxy "http://${addr}";
Acquire::https::Proxy "http://${addr}";
EOF
  cat > "$PROFILE_CONF" <<EOF
export http_proxy="http://${addr}"
export https_proxy="http://${addr}"
export HTTP_PROXY="http://${addr}"
export HTTPS_PROXY="http://${addr}"
EOF
  chmod 0644 "$APT_CONF" "$PROFILE_CONF"

  export http_proxy="http://${addr}"
  export https_proxy="http://${addr}"
  export HTTP_PROXY="http://${addr}"
  export HTTPS_PROXY="http://${addr}"
  say "${GREEN}Proxy enabled: http://${addr}${NC}"
  say "APT config: $APT_CONF"
  say "Shell profile: $PROFILE_CONF"
}

disable_proxy() {
  need_root || return 1
  if [ -f "$APT_CONF" ]; then
    rm "$APT_CONF"
  fi
  if [ -f "$PROFILE_CONF" ]; then
    rm "$PROFILE_CONF"
  fi
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
  say "${YELLOW}Proxy disabled.${NC}"
}

current_proxy_addr() {
  if [ -f "$APT_CONF" ]; then
    sed -n 's/.*http:\/\/\([^"]*\).*/\1/p' "$APT_CONF" | head -1
  fi
}

show_status() {
  local addr
  addr="$(current_proxy_addr || true)"
  say "${YELLOW}=== Debian LXC proxy helper ===${NC}"
  if [ -n "$addr" ]; then
    say "APT proxy: ${GREEN}ON${NC} http://${addr}"
  else
    say "APT proxy: ${RED}OFF${NC}"
    addr="$(auto_detect_proxy)"
    say "Auto candidate: http://${addr}"
  fi

  if [ -n "$addr" ]; then
    local host port
    host="${addr%:*}"
    port="${addr##*:}"
    if tcp_probe "$host" "$port"; then
      say "Probe: ${GREEN}online${NC} ${host}:${port}"
    else
      say "Probe: ${RED}offline${NC} ${host}:${port}"
    fi
  fi
}

open_menu() {
  local choice addr input_ip input_port
  while true; do
    clear 2>/dev/null || true
    show_status
    say "--------------------------------"
    say "1. Enable proxy automatically"
    say "2. Enter proxy address manually"
    say "3. Disable proxy"
    say "4. Refresh"
    say "5. Exit"
    say "--------------------------------"
    printf 'Choose [1-5]: '
    read -r choice

    case "$choice" in
      1)
        addr="$(auto_detect_proxy)"
        write_proxy "$addr"
        sleep 1
        ;;
      2)
        printf 'Proxy IP or host: '
        read -r input_ip
        printf 'Proxy port [%s]: ' "$DEFAULT_PORT"
        read -r input_port
        [ -n "$input_ip" ] || input_ip="$(detect_gateway)"
        [ -n "$input_port" ] || input_port="$DEFAULT_PORT"
        write_proxy "${input_ip}:${input_port}"
        sleep 1
        ;;
      3)
        disable_proxy
        sleep 1
        ;;
      4)
        continue
        ;;
      5)
        break
        ;;
      *)
        say "${RED}Invalid choice.${NC}"
        sleep 1
        ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage:
  source <(curl -fsSL URL/proxy.sh)
  bash proxy.sh menu
  bash proxy.sh on [host:port]
  bash proxy.sh off
  bash proxy.sh status
  bash proxy.sh detect

Environment:
  PROXY_ADDR=192.168.1.100:7897
  PROXY_PORT=7897
  COMMON_PORTS="7897 7890 7891 7892"
EOF
}

main() {
  local cmd="${1:-menu}" addr
  case "$cmd" in
    menu)
      open_menu
      ;;
    on|enable)
      addr="${2:-}"
      [ -n "$addr" ] || addr="$(auto_detect_proxy)"
      write_proxy "$(normalize_addr "$addr")"
      ;;
    off|disable)
      disable_proxy
      ;;
    status)
      show_status
      ;;
    detect)
      auto_detect_online_proxy
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
