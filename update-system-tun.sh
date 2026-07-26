#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-}"
CORE_BIN="${CORE_BIN:-}"
PROFILE=""
PROXY_PORT="${PROXY_PORT:-7890}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP=""
MODIFIED=0

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

set_yaml_scalar() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    printf '\n%s: %s\n' "$key" "$value" >> "$file"
  fi
}

set_yaml_section_scalar() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  if ! grep -q "^${section}:[[:space:]]*$" "$file"; then
    printf '\n%s:\n  %s: %s\n' "$section" "$key" "$value" >> "$file"
    return 0
  fi

  tmp="${file}.tmp-system-tun-${STAMP}"
  awk -v section="$section" -v key="$key" -v value="$value" '
    $0 ~ "^" section ":[[:space:]]*$" {
      in_section=1
      print
      next
    }
    in_section && /^[^[:space:]#]/ {
      if (!written) {
        print "  " key ": " value
        written=1
      }
      in_section=0
    }
    in_section && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" {
      print "  " key ": " value
      written=1
      next
    }
    { print }
    END {
      if (in_section && !written) {
        print "  " key ": " value
      }
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

yaml_section_has_key() {
  local file="$1" section="$2" key="$3"
  awk -v section="$section" -v key="$key" '
    $0 ~ "^" section ":[[:space:]]*$" { in_section=1; next }
    in_section && /^[^[:space:]#]/ { exit }
    in_section && $0 ~ "^[[:space:]]+" key ":[[:space:]]*" { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$file"
}

ensure_yaml_section_scalar() {
  local file="$1" section="$2" key="$3" value="$4"
  yaml_section_has_key "$file" "$section" "$key" ||
    set_yaml_section_scalar "$file" "$section" "$key" "$value"
}

detect_tun_stack() {
  awk '
    /^tun:[[:space:]]*$/ { in_tun=1; next }
    in_tun && /^[^[:space:]#]/ { in_tun=0 }
    in_tun && /^[[:space:]]*stack:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*stack:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/["'\'' ]/, "", value)
      print tolower(value)
      exit
    }
  ' "$CONFIG_FILE"
}

detect_profile() {
  if [ -z "$CONFIG_FILE" ]; then
    if [ -s /opt/config/config.yaml ] && [ -x /opt/mihomo/mihomo ]; then
      CONFIG_FILE=/opt/config/config.yaml
    elif [ -s /etc/mihomo/config.yaml ] && [ -x /usr/local/bin/mihomo ]; then
      CONFIG_FILE=/etc/mihomo/config.yaml
    fi
  fi

  case "$CONFIG_FILE" in
    /opt/config/*)
      PROFILE=nexusbox
      CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
      ;;
    *)
      PROFILE=standalone
      CORE_BIN="${CORE_BIN:-/usr/local/bin/mihomo}"
      ;;
  esac
}

full_restart() {
  if [ "$PROFILE" = "nexusbox" ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q '^nexusbox\.service'; then
      systemctl restart nexusbox || true
    else
      pkill -f '^/opt/nexusbox/nexusbox$' 2>/dev/null || true
      pkill -f '/opt/mihomo/mihomo -d /opt/config' 2>/dev/null || true
      sleep 2
      nohup /opt/nexusbox/nexusbox >/opt/nexusbox/var/info.log 2>&1 &
    fi
  else
    systemctl restart mihomo || true
  fi
}

runtime_ready() {
  ip link show Meta >/dev/null 2>&1 || return 1
  ss -lnt 2>/dev/null | grep -Eq "[:.]${PROXY_PORT}[[:space:]]" || return 1
  ss -lnt 2>/dev/null | grep -Eq '[:.]9090[[:space:]]' || return 1
}

wait_for_runtime() {
  local _
  for _ in $(seq 1 20); do
    runtime_ready && return 0
    sleep 1
  done
  return 1
}

restore_backup() {
  trap - ERR
  if [ "$MODIFIED" = "1" ] && [ -s "$BACKUP" ]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    say "更新失败，已恢复原配置：$BACKUP"
    full_restart || true
  fi
}

on_error() {
  local status="$?"
  restore_backup
  exit "$status"
}

trap on_error ERR

[ "$(id -u)" -eq 0 ] || { say "错误：请使用 root 运行。"; exit 1; }
detect_profile
[ -s "$CONFIG_FILE" ] || { say "错误：找不到 Mihomo 配置文件。"; exit 1; }
[ -x "$CORE_BIN" ] || { say "错误：找不到 Mihomo 核心：$CORE_BIN"; exit 1; }
[ -c /dev/net/tun ] || { say "错误：缺少 /dev/net/tun，请先配置 LXC TUN 权限。"; exit 1; }

BACKUP="${CONFIG_FILE}.bak-system-tun-${STAMP}"
cp -a "$CONFIG_FILE" "$BACKUP"
MODIFIED=1
say "已备份：$BACKUP"

set_yaml_section_scalar "$CONFIG_FILE" tun enable true
set_yaml_section_scalar "$CONFIG_FILE" tun stack system
set_yaml_section_scalar "$CONFIG_FILE" tun device Meta
set_yaml_section_scalar "$CONFIG_FILE" tun auto-route true
set_yaml_section_scalar "$CONFIG_FILE" tun auto-detect-interface true
set_yaml_section_scalar "$CONFIG_FILE" tun strict-route true
ensure_yaml_section_scalar "$CONFIG_FILE" tun dns-hijack '[any:53, tcp://any:53]'

http_port="$(sed -n -E 's/^port:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG_FILE" | head -1)"
mixed_port="$(sed -n -E 's/^mixed-port:[[:space:]]*([0-9]+).*/\1/p' "$CONFIG_FILE" | head -1)"
if [ -n "$http_port" ] && [ "$http_port" = "$mixed_port" ]; then
  set_yaml_scalar "$CONFIG_FILE" mixed-port 0
  say "已关闭与 HTTP 端口 ${http_port} 重复的 mixed-port。"
  mixed_port=0
fi
if [ -n "$http_port" ] && [ "$http_port" != "0" ]; then
  PROXY_PORT="$http_port"
elif [ -n "$mixed_port" ] && [ "$mixed_port" != "0" ]; then
  PROXY_PORT="$mixed_port"
fi

"$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"
say "正在完整重启核心并启用 System TUN"
full_restart

if ! wait_for_runtime; then
  say "System TUN 启动失败，自动回退 gVisor"
  set_yaml_section_scalar "$CONFIG_FILE" tun stack gvisor
  "$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"
  full_restart
  wait_for_runtime || {
    say "错误：System 与 gVisor 均未正常启动。"
    false
  }
fi

trap - ERR
MODIFIED=0
say "更新完成：stack=$(detect_tun_stack)，订阅和规则均已保留。"
say "端口验证正常：代理 ${PROXY_PORT}，控制接口 9090，TUN Meta。"
