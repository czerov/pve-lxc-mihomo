#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
MIHOMO_BIN="${MIHOMO_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
DRY_RUN="${DRY_RUN:-0}"
FILTER='exclude-filter: "(?i)(直连|direct)"'
AI_GROUP_PATH='%E4%BA%BA%E5%B7%A5%E6%99%BA%E8%83%BD'
AI_PROXY_NAME='香港节点'
CHROME_RULE_MARKER='- DOMAIN,chromewebstore.google.com,美国节点'
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

ensure_chrome_store_rules() {
  local temp_file

  temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  if ! awk '
    BEGIN { inserted = 0 }
    index($0, "# Chrome Web Store / CRX") { next }
    index($0, "DOMAIN,chromewebstore.google.com,美国节点") { next }
    index($0, "DOMAIN,chrome.google.com,美国节点") { next }
    index($0, "DOMAIN,chromewebstore.googleapis.com,美国节点") { next }
    index($0, "DOMAIN,clients2.google.com,美国节点") { next }
    index($0, "DOMAIN,clients2.googleusercontent.com,美国节点") { next }
    index($0, "DOMAIN,update.googleapis.com,美国节点") { next }
    !inserted && $0 ~ /^[[:space:]]*-[[:space:]]*RULE-SET,Google,谷歌服务[[:space:]]*$/ {
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      print indent "# Chrome Web Store / CRX"
      print indent "- DOMAIN,chromewebstore.google.com,美国节点"
      print indent "- DOMAIN,chrome.google.com,美国节点"
      print indent "- DOMAIN,chromewebstore.googleapis.com,美国节点"
      print indent "- DOMAIN,clients2.google.com,美国节点"
      print indent "- DOMAIN,clients2.googleusercontent.com,美国节点"
      print indent "- DOMAIN,update.googleapis.com,美国节点"
      inserted = 1
    }
    { print }
    END { if (!inserted) exit 1 }
  ' "$CONFIG_FILE" >"$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  cp -f "$temp_file" "$CONFIG_FILE"
  rm -f "$temp_file"
  say "已更新 Chrome Web Store 美国节点规则。"
}

select_ai_proxy() {
  local response

  if [ "$DRY_RUN" = "1" ]; then
    say "DRY_RUN=1，跳过将人工智能组切换为香港节点。"
    return 0
  fi

  [ -S "$CORE_SOCKET" ] || {
    say "找不到 Mihomo 控制 Socket，无法切换人工智能组。" >&2
    return 1
  }

  curl -fsS --unix-socket "$CORE_SOCKET" \
    -X PUT "http://localhost/proxies/$AI_GROUP_PATH" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$AI_PROXY_NAME\"}" >/dev/null

  response="$(curl -fsS --unix-socket "$CORE_SOCKET" "http://localhost/proxies/$AI_GROUP_PATH")"
  printf '%s' "$response" | grep -Eq '"now"[[:space:]]*:[[:space:]]*"香港节点"'
}

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || die "找不到配置文件：$CONFIG_FILE"

for command in awk cp curl date dirname grep mktemp sed; do
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

ensure_chrome_store_rules || {
  restore_backup
  die "未找到通用 Google 规则，无法加入 Chrome Web Store 规则。"
}

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

grep -Fq -- "$CHROME_RULE_MARKER" "$CONFIG_FILE" || {
  restore_backup
  die "Chrome Web Store 规则校验失败。"
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

if ! select_ai_proxy; then
  restore_backup
  reload_config >/dev/null 2>&1 || true
  die "无法确认人工智能组已切换为香港节点，已恢复原配置。"
fi

say "更新完成：测速组已排除名称含“直连/direct”的节点。"
say "Chrome Web Store 已固定使用美国节点。"
if [ "$DRY_RUN" = "1" ]; then
  say "DRY_RUN=1，人工智能组未执行切换。"
else
  say "人工智能组已切换为香港节点。"
fi
say "备份保留在：$BACKUP"
grep -nE 'UrlTest:|name: (谷歌服务|YouTube|人工智能)|chromewebstore\.google\.com' "$CONFIG_FILE"
