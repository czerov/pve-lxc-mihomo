#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"
MIHOMO_BIN="${MIHOMO_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
DRY_RUN="${DRY_RUN:-0}"
FILTER='exclude-filter: "(?i)(直连|direct)"'
STABLE_PROXY_NAME='稳定优选'
URLTEST_LINE='UrlTest: &UrlTest {type: url-test, proxies: [DIRECT], interval: 300, tolerance: 50, lazy: false, url: '\''https://www.gstatic.com/generate_204'\'', disable-udp: false, timeout: 5000, max-failed-times: 2, hidden: true, include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: "(?i)(直连|direct)"}'
STABLE_GROUP_LINE="  - {name: 稳定优选, type: fallback, proxies: [香港节点, 美国节点], url: 'https://www.gstatic.com/generate_204', interval: 60, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Auto.png'}"
GOOGLE_GROUP_LINE="  - {name: 谷歌服务, type: fallback, proxies: [香港节点, 美国节点], url: 'https://www.gstatic.com/generate_204', interval: 60, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Google_Search.png'}"
YOUTUBE_GROUP_LINE="  - {name: YouTube, type: fallback, proxies: [香港节点, 美国节点], url: 'https://www.gstatic.com/generate_204', interval: 60, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/YouTube.png'}"
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

ensure_routing_groups() {
  local temp_file

  temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  if ! awk \
    -v urltest_line="$URLTEST_LINE" \
    -v stable_group_line="$STABLE_GROUP_LINE" \
    -v google_group_line="$GOOGLE_GROUP_LINE" \
    -v youtube_group_line="$YOUTUBE_GROUP_LINE" '
    function prepend_stable(line) {
      gsub(/[[:space:]]*稳定优选[[:space:]]*,?[[:space:]]*/, "", line)
      gsub(/,[[:space:]]*\]/, "]", line)
      sub(/proxies:[[:space:]]*\[/, "proxies: [稳定优选, ", line)
      return line
    }
    BEGIN {
      anchor = stable = google = youtube = 0
      node_select = ai = telegram = fallback_select = 0
    }
    /^# 锚点 - 时延优选参数/ { next }
    /^# 锚点 - 区域节点每 5 分钟测速/ { next }
    /^UrlTest: &UrlTest / {
      print "# 锚点 - 区域节点每 5 分钟测速，避免频繁探测全部订阅节点"
      print urltest_line
      anchor = 1
      next
    }
    /^# 锚点 - 香港优先，美国故障接管$/ { next }
    /^Fallback: &Fallback / { next }
    /name: 稳定优选,/ { next }
    /name: 节点选择,/ {
      print prepend_stable($0)
      node_select = 1
      next
    }
    /name: 漏网之鱼,/ {
      print prepend_stable($0)
      fallback_select = 1
      next
    }
    /name: 人工智能,/ {
      print prepend_stable($0)
      ai = 1
      next
    }
    /name: Telegram,/ {
      print prepend_stable($0)
      telegram = 1
      next
    }
    /name: 谷歌服务,/ {
      if (!stable) {
        print stable_group_line
        stable = 1
      }
      print google_group_line
      google = 1
      next
    }
    /name: YouTube,/ {
      print youtube_group_line
      youtube = 1
      next
    }
    { print }
    END {
      if (!(anchor && stable && google && youtube && node_select && ai && telegram && fallback_select)) {
        exit 1
      }
    }
  ' "$CONFIG_FILE" >"$temp_file"; then
    rm -f "$temp_file"
    return 1
  fi

  cp -f "$temp_file" "$CONFIG_FILE"
  rm -f "$temp_file"
  say "已建立香港优先、美国备用的稳定优选分组。"
}

ensure_chrome_store_rules() {
  local temp_file

  temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  if ! awk '
    BEGIN { inserted = 0; google_seen = 0 }
    index($0, "# Chrome Web Store / CRX") { next }
    index($0, "DOMAIN,chromewebstore.google.com,美国节点") { next }
    index($0, "DOMAIN,chrome.google.com,美国节点") { next }
    index($0, "DOMAIN,chromewebstore.googleapis.com,美国节点") { next }
    index($0, "DOMAIN,clients2.google.com,美国节点") { next }
    index($0, "DOMAIN,clients2.googleusercontent.com,美国节点") { next }
    index($0, "DOMAIN,update.googleapis.com,美国节点") { next }
    $0 ~ /^[[:space:]]*-[[:space:]]*RULE-SET,Google,谷歌服务[[:space:]]*$/ {
      if (google_seen) next
      google_seen = 1
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
      print
      next
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

select_proxy() {
  local group_name="$1"
  local group_path="$2"
  local response

  if [ "$DRY_RUN" = "1" ]; then
    say "DRY_RUN=1，跳过将${group_name}切换为${STABLE_PROXY_NAME}。"
    return 0
  fi

  [ -S "$CORE_SOCKET" ] || {
    say "找不到 Mihomo 控制 Socket，无法切换${group_name}。" >&2
    return 1
  }

  curl -fsS --unix-socket "$CORE_SOCKET" \
    -X PUT "http://localhost/proxies/$group_path" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$STABLE_PROXY_NAME\"}" >/dev/null

  response="$(curl -fsS --unix-socket "$CORE_SOCKET" "http://localhost/proxies/$group_path")"
  printf '%s' "$response" | grep -Eq '"now"[[:space:]]*:[[:space:]]*"稳定优选"'
}

select_stable_proxies() {
  select_proxy '节点选择' '%E8%8A%82%E7%82%B9%E9%80%89%E6%8B%A9' &&
    select_proxy '人工智能' '%E4%BA%BA%E5%B7%A5%E6%99%BA%E8%83%BD' &&
    select_proxy 'Telegram' 'Telegram' &&
    select_proxy '漏网之鱼' '%E6%BC%8F%E7%BD%91%E4%B9%8B%E9%B1%BC'
}

[ "$(id -u)" -eq 0 ] || [ "$DRY_RUN" = "1" ] || die "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || die "找不到配置文件：$CONFIG_FILE"

for command in awk cp curl date dirname grep mktemp; do
  command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
done

if [ ! -x "$MIHOMO_BIN" ]; then
  MIHOMO_BIN="$(command -v mihomo || true)"
fi
[ -n "$MIHOMO_BIN" ] && [ -x "$MIHOMO_BIN" ] || die "找不到 Mihomo 可执行文件。"

cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份：$BACKUP"

ensure_routing_groups || {
  restore_backup
  die "未找到所需代理组，无法建立稳定优选。"
}

ensure_chrome_store_rules || {
  restore_backup
  die "未找到通用 Google 规则，无法加入 Chrome Web Store 规则。"
}

check_filter 'UrlTest: &UrlTest' || {
  restore_backup
  die "未找到或无法修改 UrlTest 锚点。"
}
grep -Fxq "$STABLE_GROUP_LINE" "$CONFIG_FILE" || {
  restore_backup
  die "稳定优选分组校验失败。"
}
grep -Fxq "$GOOGLE_GROUP_LINE" "$CONFIG_FILE" || {
  restore_backup
  die "谷歌服务回退组校验失败。"
}
grep -Fxq "$YOUTUBE_GROUP_LINE" "$CONFIG_FILE" || {
  restore_backup
  die "YouTube 回退组校验失败。"
}

for group in '节点选择' '人工智能' 'Telegram' '漏网之鱼'; do
  grep -F "name: ${group}," "$CONFIG_FILE" | grep -Fq 'proxies: [稳定优选,' || {
    restore_backup
    die "${group}未加入稳定优选。"
  }
done

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

if ! select_stable_proxies; then
  restore_backup
  reload_config >/dev/null 2>&1 || true
  die "无法确认主要代理组已切换为稳定优选，已恢复原配置。"
fi

say "更新完成：区域节点每 5 分钟测速，并排除名称含“直连/direct”的节点。"
say "稳定优选仅使用香港和美国节点，香港不可用时自动切换到美国。"
say "Chrome Web Store 已固定使用美国节点。"
if [ "$DRY_RUN" = "1" ]; then
  say "DRY_RUN=1，运行中的代理组未执行切换。"
else
  say "节点选择、人工智能、Telegram、漏网之鱼已切换为稳定优选。"
fi
say "备份保留在：$BACKUP"
grep -nE 'UrlTest:|name: (稳定优选|谷歌服务|YouTube|人工智能)|chromewebstore\.google\.com' "$CONFIG_FILE"
