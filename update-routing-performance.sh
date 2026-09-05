#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
DRY_RUN="${DRY_RUN:-0}"
STAMP="${STAMP:-$(date '+%Y%m%d-%H%M%S')}"
BACKUP="${CONFIG_FILE}.bak-routing-performance-${STAMP}"
TMP_GROUPS="${CONFIG_FILE}.tmp-routing-groups-${STAMP}"
TMP_RULES="${CONFIG_FILE}.tmp-routing-rules-${STAMP}"

FILTER_KR_LINE="FilterKR: &FilterKR '^(?=.*(?i)(韩|🇰🇷|韓|首尔|南朝鲜|Korea|South|(^|[^A-Za-z])(KR|KOR)([^A-Za-z]|$))).*$'"
FILTER_NOISE="(?i)(DIRECT|直连|群|邀请|返利|循环|官网|客服|网站|网址|获取|订阅|流量|到期|机场|下次|版本|官址|备用|过期|已用|联系|邮箱|工单|贩卖|通知|倒卖|防止|国内|地址|频道|无法|说明|使用|提示|特别|访问|支持|教程|关注|更新|作者|加入|过滤|USE|USED|TOTAL|EXPIRE|EMAIL|Panel|Channel|Author)"
URL_TEST_ANCHOR_LINE="UrlTest: &UrlTest {type: url-test, proxies: [DIRECT], interval: 300, tolerance: 50, lazy: true, url: 'https://www.gstatic.com/generate_204', disable-udp: false, timeout: 5000, max-failed-times: 2, hidden: true, include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"(?i)(直连|direct)\"}"
SOCIAL_GROUP_LINE="  - {name: 社交媒体, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://api.x.com/', interval: 60, tolerance: 50, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Twitter.png'}"
CONTAINER_GROUP_LINE="  - {name: 容器镜像, type: fallback, proxies: [DIRECT, 自动优选], url: 'https://pkg-containers.githubusercontent.com/', interval: 300, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false}"
AUTO_GROUP_LINE="  - {name: 自动优选, type: url-test, proxies: [DIRECT], include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"$FILTER_NOISE\", url: 'https://www.gstatic.com/generate_204', interval: 300, tolerance: 50, lazy: false, timeout: 5000, max-failed-times: 2, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Auto.png'}"
AIRPORT_GROUP_LINE="  - {name: 机场节点, type: select, proxies: [DIRECT], include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"$FILTER_NOISE\", icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Airport.png' }"
SELECT_GROUP_LINE="  - {name: 节点选择, type: select, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Filter.png', proxies: [自动优选, 稳定优选, 香港节点, 新加坡节点, 韩国节点, 台湾节点, 日本节点, 美国节点, 省流节点, 高级节点, 手动切换, 全球直连, 机场节点]}"
CATCH_ALL_GROUP_LINE="  - {name: 漏网之鱼, type: select, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Unlock.png', proxies: [自动优选, 稳定优选, 节点选择, 全球直连, 香港节点, 新加坡节点, 韩国节点, 台湾节点, 日本节点, 美国节点, 省流节点, 高级节点, 手动切换, 机场节点]}"
FALLBACK_GROUP_LINE="  - {name: 稳定优选, type: fallback, proxies: [自动优选, 香港节点, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://www.gstatic.com/generate_204', interval: 60, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Auto.png'}"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

has_exact_line() {
  local expected="$1"

  awk -v expected="$expected" '
    { sub(/\r$/, "") }
    $0 == expected { found = 1; exit }
    END { exit !found }
  ' "$CONFIG_FILE"
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

grep -q '^FilterKR:' "$CONFIG_FILE" || fail "找不到 FilterKR 节点筛选规则。"
grep -q '^UrlTest:' "$CONFIG_FILE" || fail "找不到 UrlTest 地区测速锚点。"
grep -q '^proxy-groups:[[:space:]]*$' "$CONFIG_FILE" || fail "找不到 proxy-groups。"
grep -q '^  - {name: 社交媒体,' "$CONFIG_FILE" || fail "找不到社交媒体分组。"
grep -q '^  - RULE-SET,Docker,' "$CONFIG_FILE" || fail "找不到 Docker 规则。"

cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份：$BACKUP"

awk \
  -v filter_kr="$FILTER_KR_LINE" \
  -v url_test_anchor="$URL_TEST_ANCHOR_LINE" \
  -v social_group="$SOCIAL_GROUP_LINE" \
  -v container_group="$CONTAINER_GROUP_LINE" \
  -v auto_group="$AUTO_GROUP_LINE" \
  -v airport_group="$AIRPORT_GROUP_LINE" \
  -v select_group="$SELECT_GROUP_LINE" \
  -v catch_all_group="$CATCH_ALL_GROUP_LINE" \
  -v fallback_group="$FALLBACK_GROUP_LINE" '
  BEGIN {
    filter_written = anchor_written = social_written = container_written = auto_written = 0
    select_written = catch_all_written = fallback_written = airport_written = 0
  }
  /^FilterKR:/ {
    print filter_kr
    filter_written = 1
    next
  }
  /^UrlTest:/ {
    print url_test_anchor
    anchor_written = 1
    next
  }
  /^proxy-groups:[[:space:]]*$/ {
    print
    print social_group
    print container_group
    print auto_group
    social_written = container_written = auto_written = 1
    next
  }
  /^  - \{name: 社交媒体,/ { next }
  /^  - \{name: 容器镜像,/ { next }
  /^  - \{name: 自动优选,/ { next }
  /^  - \{name: 节点选择,/ {
    print select_group
    select_written = 1
    next
  }
  /^  - \{name: 漏网之鱼,/ {
    print catch_all_group
    catch_all_written = 1
    next
  }
  /^  - \{name: 稳定优选,/ {
    print fallback_group
    fallback_written = 1
    next
  }
  /^  - \{name: 机场节点,/ {
    print airport_group
    airport_written = 1
    next
  }
  { print }
  END {
    if (!(filter_written && anchor_written && social_written && container_written && auto_written && select_written && catch_all_written && fallback_written && airport_written)) {
      exit 42
    }
  }
' "$CONFIG_FILE" >"$TMP_GROUPS" || fail "生成代理组失败。"

mv "$TMP_GROUPS" "$CONFIG_FILE"

awk '
  function print_container_rules() {
    print "  # GHCR API 与镜像层优先直连，直连不可用时自动回退代理"
    print "  - DOMAIN,ghcr.io,容器镜像"
    print "  - DOMAIN,pkg-containers.githubusercontent.com,容器镜像"
  }
  BEGIN { rules_written = 0 }
  /^  # GHCR API 与镜像层(使用目标站专项测速|优先直连)/ { next }
  /^  - DOMAIN,(ghcr\.io|pkg-containers\.githubusercontent\.com),容器镜像$/ { next }
  /^  - RULE-SET,Docker,/ {
    if (!rules_written) {
      print_container_rules()
      rules_written = 1
    }
    print
    next
  }
  { print }
  END {
    if (!rules_written) {
      exit 42
    }
  }
' "$CONFIG_FILE" >"$TMP_RULES" || fail "生成容器镜像规则失败。"

mv "$TMP_RULES" "$CONFIG_FILE"

has_exact_line "$FILTER_KR_LINE" || fail "韩国节点筛选规则校验失败。"
has_exact_line "$URL_TEST_ANCHOR_LINE" || fail "地区测速锚点校验失败。"
has_exact_line "$SOCIAL_GROUP_LINE" || fail "社交媒体分组校验失败。"
has_exact_line "$CONTAINER_GROUP_LINE" || fail "容器镜像分组校验失败。"
has_exact_line "$AUTO_GROUP_LINE" || fail "自动优选分组校验失败。"
has_exact_line "$AIRPORT_GROUP_LINE" || fail "机场节点分组校验失败。"
has_exact_line "$SELECT_GROUP_LINE" || fail "节点选择分组校验失败。"
has_exact_line "$CATCH_ALL_GROUP_LINE" || fail "漏网之鱼分组校验失败。"
has_exact_line "$FALLBACK_GROUP_LINE" || fail "稳定优选分组校验失败。"
has_exact_line '  - DOMAIN,ghcr.io,容器镜像' || fail "ghcr.io 规则校验失败。"
has_exact_line '  - DOMAIN,pkg-containers.githubusercontent.com,容器镜像' || fail "镜像层规则校验失败。"

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
say "更新完成：已启用跨订阅单层自动优选，并修复韩国节点误匹配、X 可用性测速和 GHCR 镜像下载分流。"
say "备份保留在：$BACKUP"
