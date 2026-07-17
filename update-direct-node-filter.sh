#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
MIHOMO_BIN="${MIHOMO_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
DRY_RUN="${DRY_RUN:-0}"
FILTER='exclude-filter: "(?i)(直连|direct)"'
BACKUP="${CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"

say() {
  printf '[direct-node-filter] %s\n' "$*"
}

die() {
  say "错误：$*" >&2
  exit 1
}

restore_backup() {
  cp -af "$BACKUP" "$CONFIG_FILE"
  say "已恢复备份：$BACKUP"
}

reload_config() {
  if [ "$DRY_RUN" = "1" ]; then
    say "DRY_RUN=1，跳过运行中内核热重载。"
    return 0
  fi

  if [ -S "$CORE_SOCKET" ]; then
    command -v curl >/dev/null 2>&1 || return 1
    curl -fsS --unix-socket "$CORE_SOCKET" \
      -X PUT "http://localhost/configs?force=true" \
      -H "Content-Type: application/json" \
      -d "{\"path\":\"$CONFIG_FILE\",\"payload\":\"\"}" >/dev/null
    return
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet mihomo; then
    systemctl restart mihomo
    return
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nexusbox; then
    systemctl restart nexusbox
    return
  fi

  return 1
}

check_filter() {
  local marker="$1"
  grep -F "$marker" "$CONFIG_FILE" | grep -Fq "$FILTER"
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || die "找不到配置文件：$CONFIG_FILE"

for command in cp date dirname grep sed; do
  command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
done

if [ ! -x "$MIHOMO_BIN" ]; then
  MIHOMO_BIN="$(command -v mihomo || true)"
fi
[ -n "$MIHOMO_BIN" ] && [ -x "$MIHOMO_BIN" ] || die "找不到 Mihomo 可执行文件。"

cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份：$BACKUP"

sed -Ei '
/^UrlTest: &UrlTest / {
  s/, *exclude-filter: [^,}]*//
  s/}$/, exclude-filter: "(?i)(直连|direct)"}/
}
/name: (谷歌服务|YouTube),/ {
  /exclude-filter:/ {
    s/exclude-filter: [^,}]*/exclude-filter: "(?i)(直连|direct)"/
    b
  }
  s/, interval:/, exclude-filter: "(?i)(直连|direct)", interval:/
}
' "$CONFIG_FILE"

check_filter 'UrlTest: &UrlTest' || {
  restore_backup
  die "未找到或无法修改 UrlTest 锚点。"
}
check_filter 'name: 谷歌服务,' || {
  restore_backup
  die "未找到或无法修改谷歌服务测速组。"
}
check_filter 'name: YouTube,' || {
  restore_backup
  die "未找到或无法修改 YouTube 测速组。"
}

if ! "$MIHOMO_BIN" -t -d "$CONFIG_DIR"; then
  restore_backup
  die "Mihomo 配置校验失败。"
fi

if ! reload_config; then
  restore_backup
  reload_config >/dev/null 2>&1 || true
  die "热重载失败，已恢复原配置。"
fi

say "更新完成，所有自动测速组已排除名称含“直连/direct”的节点。"
say "备份保留在：$BACKUP"
grep -nE 'UrlTest:|name: (谷歌服务|YouTube)' "$CONFIG_FILE"
