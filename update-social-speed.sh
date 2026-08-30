#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${CONFIG_FILE}.bak-social-speed-${STAMP}"
TMP_GROUPS="${CONFIG_FILE}.tmp-social-groups-${STAMP}"
TMP_RULES="${CONFIG_FILE}.tmp-social-rules-${STAMP}"

SOCIAL_GROUP_LINE="  - {name: 社交媒体, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://api.x.com/', interval: 60, tolerance: 50, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Twitter.png'}"
GOOGLE_GROUP_LINE="  - {name: 谷歌服务, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://www.google.com/generate_204', interval: 60, tolerance: 50, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Google_Search.png'}"
YOUTUBE_GROUP_LINE="  - {name: YouTube, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://www.youtube.com/generate_204', interval: 60, tolerance: 50, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/YouTube.png'}"
HK_FAST_GROUP_LINE="  - {name: 香港高速, !!merge <<: *UrlTest, filter: *FilterHK, exclude-filter: \"(?i)(直连|direct|专线|住宅|hy2|hysteria)\", icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Hong_Kong.png'}"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

cleanup_temp() {
  [ ! -e "$TMP_GROUPS" ] || rm -f "$TMP_GROUPS"
  [ ! -e "$TMP_RULES" ] || rm -f "$TMP_RULES"
}

reload_config() {
  local payload

  [ "$DRY_RUN" != "1" ] || return 0
  payload="$(printf '{\"path\":\"%s\",\"payload\":\"\"}' "$CONFIG_FILE")"
  curl -fsS --unix-socket "$CORE_SOCKET" \
    -X PUT 'http://localhost/configs?force=true' \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null
}

restore_backup() {
  [ -f "$BACKUP" ] || return 0
  cp -a "$BACKUP" "$CONFIG_FILE"
  say "已恢复原配置：$BACKUP"
  reload_config >/dev/null 2>&1 || true
}

fail() {
  local message="$1"
  trap - ERR
  cleanup_temp
  restore_backup
  say "错误：$message" >&2
  exit 1
}

on_error() {
  local status=$?
  trap - ERR
  cleanup_temp
  restore_backup
  say "错误：更新中断，已恢复原配置。" >&2
  exit "$status"
}

trap on_error ERR
trap cleanup_temp EXIT

[ "$(id -u)" -eq 0 ] || [ "$DRY_RUN" = "1" ] || fail "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || fail "找不到配置文件：$CONFIG_FILE"
[ -x "$CORE_BIN" ] || [ "$DRY_RUN" = "1" ] || fail "找不到 Mihomo 核心：$CORE_BIN"
[ -S "$CORE_SOCKET" ] || [ "$DRY_RUN" = "1" ] || fail "找不到 Mihomo 控制套接字：$CORE_SOCKET"

for command in awk cp curl date dirname grep mv rm; do
  command -v "$command" >/dev/null 2>&1 || fail "缺少命令：$command"
done

grep -q '^proxy-groups:[[:space:]]*$' "$CONFIG_FILE" || fail "找不到 proxy-groups。"
grep -q '^  - {name: 香港节点,' "$CONFIG_FILE" || fail "找不到香港节点分组。"
grep -q '^  - {name: 谷歌服务,' "$CONFIG_FILE" || fail "找不到谷歌服务分组。"
grep -q '^  - {name: YouTube,' "$CONFIG_FILE" || fail "找不到 YouTube 分组。"
grep -q '^  - RULE-SET,YouTube,' "$CONFIG_FILE" || fail "找不到 YouTube 规则。"

cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份：$BACKUP"

awk \
  -v social_group="$SOCIAL_GROUP_LINE" \
  -v google_group="$GOOGLE_GROUP_LINE" \
  -v youtube_group="$YOUTUBE_GROUP_LINE" \
  -v hk_fast_group="$HK_FAST_GROUP_LINE" '
  BEGIN {
    social_written = google_written = youtube_written = hk_fast_written = 0
  }
  /^proxy-groups:[[:space:]]*$/ {
    print
    print social_group
    social_written = 1
    next
  }
  /^  - \{name: 社交媒体,/ { next }
  /^  - \{name: 谷歌服务,/ {
    print google_group
    google_written = 1
    next
  }
  /^  - \{name: YouTube,/ {
    print youtube_group
    youtube_written = 1
    next
  }
  /^  - \{name: 香港高速,/ { next }
  /^  - \{name: 香港节点,/ {
    print
    print hk_fast_group
    hk_fast_written = 1
    next
  }
  { print }
  END {
    if (!(social_written && google_written && youtube_written && hk_fast_written)) {
      exit 42
    }
  }
' "$CONFIG_FILE" >"$TMP_GROUPS" || fail "生成高速代理组失败。"

mv "$TMP_GROUPS" "$CONFIG_FILE"

awk '
  function print_social_rules() {
    print "  # X / Instagram / Meta 使用非 Hysteria2 高速节点"
    print "  - DOMAIN-SUFFIX,x.com,社交媒体"
    print "  - DOMAIN-SUFFIX,twitter.com,社交媒体"
    print "  - DOMAIN-SUFFIX,twimg.com,社交媒体"
    print "  - DOMAIN-SUFFIX,twittercdn.com,社交媒体"
    print "  - DOMAIN-SUFFIX,t.co,社交媒体"
    print "  - DOMAIN-SUFFIX,pscp.tv,社交媒体"
    print "  - DOMAIN-SUFFIX,periscope.tv,社交媒体"
    print "  - DOMAIN-SUFFIX,tweetdeck.com,社交媒体"
    print "  - DOMAIN-SUFFIX,instagram.com,社交媒体"
    print "  - DOMAIN-SUFFIX,cdninstagram.com,社交媒体"
    print "  - DOMAIN-SUFFIX,facebook.com,社交媒体"
    print "  - DOMAIN-SUFFIX,facebook.net,社交媒体"
    print "  - DOMAIN-SUFFIX,fbcdn.net,社交媒体"
    print "  - DOMAIN-SUFFIX,fbsbx.com,社交媒体"
    print "  - DOMAIN-SUFFIX,fb.com,社交媒体"
    print "  - DOMAIN-SUFFIX,fb.me,社交媒体"
    print "  - DOMAIN-SUFFIX,messenger.com,社交媒体"
    print "  - DOMAIN-SUFFIX,meta.com,社交媒体"
    print "  - DOMAIN-SUFFIX,threads.net,社交媒体"
    print "  - DOMAIN-SUFFIX,oculus.com,社交媒体"
  }
  BEGIN { rules_written = youtube_written = 0 }
  /^  # X \/ Instagram \/ Meta 使用非 Hysteria2 高速节点$/ { next }
  /^  - DOMAIN-SUFFIX,(x\.com|twitter\.com|twimg\.com|twittercdn\.com|t\.co|pscp\.tv|periscope\.tv|tweetdeck\.com|instagram\.com|cdninstagram\.com|facebook\.com|facebook\.net|fbcdn\.net|fbsbx\.com|fb\.com|fb\.me|messenger\.com|meta\.com|threads\.net|oculus\.com),社交媒体$/ { next }
  /^  - RULE-SET,YouTube,/ {
    if (!rules_written) {
      print_social_rules()
      rules_written = 1
    }
    print "  - RULE-SET,YouTube,YouTube"
    youtube_written = 1
    next
  }
  { print }
  END {
    if (!(rules_written && youtube_written)) {
      exit 42
    }
  }
' "$CONFIG_FILE" >"$TMP_RULES" || fail "生成社交媒体规则失败。"

mv "$TMP_RULES" "$CONFIG_FILE"

grep -Fxq "$SOCIAL_GROUP_LINE" "$CONFIG_FILE" || fail "社交媒体自动测速组校验失败。"
grep -Fxq "$GOOGLE_GROUP_LINE" "$CONFIG_FILE" || fail "谷歌服务自动测速组校验失败。"
grep -Fxq "$YOUTUBE_GROUP_LINE" "$CONFIG_FILE" || fail "YouTube 自动测速组校验失败。"
grep -Fxq "$HK_FAST_GROUP_LINE" "$CONFIG_FILE" || fail "香港高速节点组校验失败。"

for domain in \
  x.com twitter.com twimg.com twittercdn.com t.co pscp.tv periscope.tv \
  tweetdeck.com instagram.com cdninstagram.com facebook.com facebook.net \
  fbcdn.net fbsbx.com fb.com fb.me messenger.com meta.com threads.net oculus.com; do
  grep -Fxq "  - DOMAIN-SUFFIX,${domain},社交媒体" "$CONFIG_FILE" ||
    fail "${domain} 规则校验失败。"
done

if [ "$DRY_RUN" != "1" ]; then
  "$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"
  say "Mihomo 配置校验通过。"

  reload_config
  curl -fsS --unix-socket "$CORE_SOCKET" -X POST \
    'http://localhost/cache/dns/flush' >/dev/null
  curl -fsS --unix-socket "$CORE_SOCKET" -X POST \
    'http://localhost/cache/fakeip/flush' >/dev/null
  curl -fsS --unix-socket "$CORE_SOCKET" -X DELETE \
    'http://localhost/connections' >/dev/null
else
  say "DRY_RUN=1，已完成文件修改与结构校验，跳过内核验证和热重载。"
fi

trap - ERR
say "更新完成：X、Instagram、YouTube、Google 已使用跨地区自动测速组。"
say "香港高速组已排除名称含专线、住宅、直连、HY2 或 Hysteria 的节点。"
say "备份保留在：$BACKUP"
