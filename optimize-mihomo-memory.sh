#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
SERVICE_NAME="${SERVICE_NAME:-nexusbox.service}"
MEMORY_LIMIT="${MEMORY_LIMIT:-600MiB}"
STAMP="${STAMP:-$(date '+%Y%m%d-%H%M%S')}"
BACKUP="${CONFIG_FILE}.bak-memory-opt-${STAMP}"
TMP_CONFIG="${CONFIG_FILE}.tmp-memory-opt-${STAMP}"
DROPIN_DIR="/etc/systemd/system/${SERVICE_NAME}.d"
DROPIN_FILE="${DROPIN_DIR}/memory.conf"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  say "错误：$*" >&2
  exit 1
}

cleanup() {
  [ ! -e "$TMP_CONFIG" ] || rm -f "$TMP_CONFIG"
}
trap cleanup EXIT

[ -f "$CONFIG_FILE" ] || fail "找不到配置文件：$CONFIG_FILE"
[ -x "$CORE_BIN" ] || fail "找不到 Mihomo：$CORE_BIN"

cp -a "$CONFIG_FILE" "$BACKUP"

awk '
  /^proxy-providers:/ { in_providers = 1 }
  in_providers && /^[^[:space:]#]/ && !/^proxy-providers:/ { in_providers = 0 }

  /^  - \{name: 容器镜像,/ {
    print "  - {name: 容器镜像, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: '\''https://pkg-containers.githubusercontent.com/'\'', interval: 300, tolerance: 20, lazy: true, timeout: 8000, max-failed-times: 2, hidden: false}"
    next
  }

  /^  - \{name: (自动优选|稳定优选|谷歌服务|YouTube),/ {
    sub(/interval: 60/, "interval: 300")
    sub(/lazy: false/, "lazy: true")
    sub(/max-failed-times: 1/, "max-failed-times: 2")
  }

  /^UrlTest: &UrlTest / {
    sub(/lazy: false/, "lazy: true")
  }

  in_providers && /^[[:space:]]+interval:[[:space:]]+600[[:space:]]*$/ {
    sub(/600/, "1800")
  }

  { print }
' "$CONFIG_FILE" >"$TMP_CONFIG"

for group in 容器镜像 自动优选 稳定优选 谷歌服务 YouTube; do
  grep -q "name: ${group}," "$TMP_CONFIG" || fail "缺少代理组：${group}"
done

cp "$TMP_CONFIG" "$CONFIG_FILE"
if ! "$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"; then
  cp -a "$BACKUP" "$CONFIG_FILE"
  fail "Mihomo 配置校验失败，已恢复原配置"
fi

install -d -m 0755 "$DROPIN_DIR"
if [ -f "$DROPIN_FILE" ]; then
  cp -a "$DROPIN_FILE" "${DROPIN_FILE}.bak-${STAMP}"
fi
printf '[Service]\nEnvironment="GOMEMLIMIT=%s"\n' "$MEMORY_LIMIT" >"$DROPIN_FILE"

systemctl daemon-reload
systemctl restart "$SERVICE_NAME"
systemctl is-active --quiet "$SERVICE_NAME" || fail "服务重启失败"

say "优化完成：高频测速已收敛，订阅健康检查为 1800 秒，GOMEMLIMIT=${MEMORY_LIMIT}。"
say "原配置备份：${BACKUP}"
