#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
REF="${REF:-main}"
WATCHDOG_URL="${WATCHDOG_URL:-}"
WATCHDOG_BIN="${WATCHDOG_BIN:-/usr/local/sbin/mihomo-container-image-watchdog}"
ENV_FILE="${ENV_FILE:-/etc/default/mihomo-container-image-watchdog}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/mihomo-container-image-watchdog.service}"
TMP="${TMPDIR:-/tmp}/mihomo-container-image-watchdog.$$"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  say "错误：$*" >&2
  exit 1
}

backup_file() {
  local path="$1"
  if [ -e "$path" ]; then
    local backup="${path}.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -a "$path" "$backup"
    say "已备份：$path -> $backup"
  fi
}

cleanup() {
  [ ! -e "$TMP" ] || rm -f "$TMP"
}
trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
command -v systemctl >/dev/null 2>&1 || die "系统不支持 systemd。"
command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v jq >/dev/null 2>&1 || {
  say "正在安装结构化 JSON 解析依赖 jq"
  apt-get update
  apt-get install -y jq
}

raw="https://raw.githubusercontent.com/${REPO}/${REF}/container-image-watchdog.sh"
urls=()
[ -z "$WATCHDOG_URL" ] || urls+=("$WATCHDOG_URL")
urls+=(
  "https://gh-proxy.com/${raw}"
  "https://gh.llkk.cc/${raw}"
  "https://cdn.jsdelivr.net/gh/${REPO}@${REF}/container-image-watchdog.sh"
  "$raw"
)

downloaded=0
for url in "${urls[@]}"; do
  say "尝试下载镜像守护程序：$url"
  if curl -fL --connect-timeout 10 --max-time 60 --retry 1 -o "$TMP" "$url" && [ -s "$TMP" ]; then
    downloaded=1
    break
  fi
done
[ "$downloaded" = "1" ] || die "镜像守护程序下载失败。"
bash -n "$TMP" || die "镜像守护程序语法检查失败。"

backup_file "$WATCHDOG_BIN"
install -m 0755 "$TMP" "$WATCHDOG_BIN"

if [ ! -e "$ENV_FILE" ]; then
  if [ -S /opt/nexusbox/var/core.sock ]; then
    detected_socket="/opt/nexusbox/var/core.sock"
  else
    detected_socket=""
  fi
  cat >"$ENV_FILE" <<EOF
# NexusBox 使用 Unix Socket；纯 Mihomo 留空后使用下方 API 地址。
CORE_SOCKET=${detected_socket}
API_BASE=http://127.0.0.1:9090
# 连续无下载达到该秒数后立即切换节点。
STALL_SECONDS=15
# 连续低于该速度时切换节点，单位 KiB/s。
MIN_RATE_KIB=192
LOW_RATE_SECONDS=30
CHECK_INTERVAL=5
WARMUP_SECONDS=10
MIN_SWITCH_INTERVAL=20
NODE_COOLDOWN_SECONDS=600
MAX_SWITCHES_PER_WINDOW=3
SWITCH_WINDOW_SECONDS=600
EOF
  chmod 0644 "$ENV_FILE"
else
  say "保留现有参数：$ENV_FILE"
fi

backup_file "$SERVICE_FILE"
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Mihomo container image connection watchdog
After=network-online.target nexusbox.service mihomo.service
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=-${ENV_FILE}
ExecStart=${WATCHDOG_BIN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mihomo-container-image-watchdog.service
sleep 2
systemctl is-active --quiet mihomo-container-image-watchdog.service || {
  systemctl status mihomo-container-image-watchdog.service --no-pager || true
  die "镜像守护服务启动失败。"
}

say "镜像守护服务已安装并启动。"
say "状态：systemctl status mihomo-container-image-watchdog --no-pager"
say "日志：journalctl -u mihomo-container-image-watchdog -f"
