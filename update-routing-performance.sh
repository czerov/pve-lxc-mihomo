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
TMP_DNS="${CONFIG_FILE}.tmp-routing-dns-${STAMP}"
TMP_WATCHDOG_INSTALLER="${CONFIG_FILE}.tmp-watchdog-installer-${STAMP}"
TMP_SOCIAL_WATCHDOG_INSTALLER="${CONFIG_FILE}.tmp-social-watchdog-installer-${STAMP}"
WATCHDOG_INSTALL="${WATCHDOG_INSTALL:-1}"
WATCHDOG_INSTALLER_URL="${WATCHDOG_INSTALLER_URL:-}"
SOCIAL_WATCHDOG_INSTALL="${SOCIAL_WATCHDOG_INSTALL:-0}"
SOCIAL_WATCHDOG_INSTALLER_URL="${SOCIAL_WATCHDOG_INSTALLER_URL:-}"
PROJECT_REPO="${PROJECT_REPO:-czerov/pve-lxc-mihomo}"
PROJECT_REF="${PROJECT_REF:-main}"

FILTER_KR_LINE="FilterKR: &FilterKR '^(?=.*(?i)(韩|🇰🇷|韓|首尔|南朝鲜|Korea|South|(^|[^A-Za-z])(KR|KOR)([^A-Za-z]|$))).*$'"
FILTER_NOISE="(?i)(DIRECT|直连|电信推荐|群|邀请|返利|循环|官网|客服|网站|网址|获取|订阅|流量|到期|机场|下次|版本|官址|备用|过期|已用|联系|邮箱|工单|贩卖|通知|倒卖|防止|国内|地址|频道|无法|说明|使用|提示|特别|访问|支持|教程|关注|更新|作者|加入|过滤|USE|USED|TOTAL|EXPIRE|EMAIL|Panel|Channel|Author)"
FILTER_CONTAINER="${FILTER_NOISE%?}|专线|住宅|hy2|hysteria)"
URL_TEST_ANCHOR_LINE="UrlTest: &UrlTest {type: url-test, proxies: [DIRECT], interval: 300, tolerance: 50, lazy: true, url: 'https://www.gstatic.com/generate_204', disable-udp: false, timeout: 5000, max-failed-times: 2, hidden: true, include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"(?i)(直连|direct|电信推荐)\"}"
SOCIAL_GROUP_LINE="  - {name: 社交媒体, type: select, proxies: [新加坡节点, 香港高速, 美国节点, 日本节点, 台湾节点], hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Instagram.png'}"
INSTAGRAM_MEDIA_GROUP_LINE="  - {name: Instagram媒体, type: url-test, proxies: [新加坡节点, 香港高速, 美国节点], url: 'https://scontent.cdninstagram.com/', interval: 60, tolerance: 50, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Instagram.png'}"
X_MEDIA_GROUP_LINE="  - {name: X媒体, type: url-test, proxies: [香港高速, 新加坡节点, 日本节点, 台湾节点, 美国节点], url: 'https://pbs.twimg.com/', interval: 60, tolerance: 50, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Twitter.png'}"
X_VIDEO_GROUP_LINE="  - {name: X视频, type: url-test, proxies: [香港高速, 新加坡节点, 美国节点], url: 'https://video-s.twimg.com/video/', interval: 60, tolerance: 50, lazy: false, timeout: 10000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Twitter.png'}"
CONTAINER_GROUP_LINE="  - {name: 容器镜像, type: url-test, include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"$FILTER_CONTAINER\", exclude-type: \"Hysteria2\", url: 'https://pkg-containers.githubusercontent.com/', interval: 60, tolerance: 20, lazy: false, timeout: 8000, max-failed-times: 1, hidden: false}"
AUTO_GROUP_LINE="  - {name: 自动优选, type: url-test, proxies: [DIRECT], include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"$FILTER_NOISE\", url: 'https://www.gstatic.com/generate_204', interval: 300, tolerance: 50, lazy: false, timeout: 5000, max-failed-times: 2, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Auto.png'}"
AIRPORT_GROUP_LINE="  - {name: 机场节点, type: select, proxies: [DIRECT], include-all: true, include-all-proxies: true, include-all-providers: true, exclude-filter: \"(?i)(DIRECT|直连|群|邀请|返利|循环|官网|客服|网站|网址|获取|订阅|流量|到期|机场|下次|版本|官址|备用|过期|已用|联系|邮箱|工单|贩卖|通知|倒卖|防止|国内|地址|频道|无法|说明|使用|提示|特别|访问|支持|教程|关注|更新|作者|加入|过滤|USE|USED|TOTAL|EXPIRE|EMAIL|Panel|Channel|Author)\", icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Airport.png' }"
SELECT_GROUP_LINE="  - {name: 节点选择, type: select, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Filter.png', proxies: [自动优选, 稳定优选, 香港节点, 新加坡节点, 韩国节点, 台湾节点, 日本节点, 美国节点, 省流节点, 高级节点, 手动切换, 全球直连, 机场节点]}"
CATCH_ALL_GROUP_LINE="  - {name: 漏网之鱼, type: select, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Unlock.png', proxies: [自动优选, 稳定优选, 节点选择, 全球直连, 香港节点, 新加坡节点, 韩国节点, 台湾节点, 日本节点, 美国节点, 省流节点, 高级节点, 手动切换, 机场节点]}"
FALLBACK_GROUP_LINE="  - {name: 稳定优选, type: fallback, proxies: [香港高速, 美国节点, 台湾节点, 日本节点, 新加坡节点], url: 'https://www.gstatic.com/generate_204', interval: 60, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: 'https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/Auto.png'}"

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
  [ ! -e "$TMP_DNS" ] || rm -f "$TMP_DNS"
  [ ! -e "$TMP_WATCHDOG_INSTALLER" ] || rm -f "$TMP_WATCHDOG_INSTALLER"
  [ ! -e "$TMP_SOCIAL_WATCHDOG_INSTALLER" ] || rm -f "$TMP_SOCIAL_WATCHDOG_INSTALLER"
}

install_container_watchdog() {
  local raw url downloaded=0
  local -a urls=()

  case "$WATCHDOG_INSTALL" in
    1|true|yes|on) ;;
    *) say "已跳过容器镜像守护服务安装。"; return 0 ;;
  esac
  [ "$DRY_RUN" != "1" ] || return 0

  raw="https://raw.githubusercontent.com/${PROJECT_REPO}/${PROJECT_REF}/install-container-image-watchdog.sh"
  [ -z "$WATCHDOG_INSTALLER_URL" ] || urls+=("$WATCHDOG_INSTALLER_URL")
  urls+=(
    "https://gh-proxy.com/${raw}"
    "https://gh.llkk.cc/${raw}"
    "https://cdn.jsdelivr.net/gh/${PROJECT_REPO}@${PROJECT_REF}/install-container-image-watchdog.sh"
    "$raw"
  )
  for url in "${urls[@]}"; do
    say "尝试下载镜像守护服务安装器：$url"
    if curl -fL --connect-timeout 10 --max-time 60 --retry 1 -o "$TMP_WATCHDOG_INSTALLER" "$url" && [ -s "$TMP_WATCHDOG_INSTALLER" ]; then
      downloaded=1
      break
    fi
  done
  if [ "$downloaded" != "1" ]; then
    say "警告：镜像守护服务安装器下载失败，分流配置已生效，可稍后单独安装。"
    return 0
  fi
  if ! bash "$TMP_WATCHDOG_INSTALLER"; then
    say "警告：镜像守护服务安装失败，分流配置已生效，可稍后单独安装。"
    return 0
  fi
  say "容器镜像低速/停滞自动切换服务已启用。"
}

install_social_watchdog() {
  local raw url group downloaded=0
  local -a urls=()

  case "$SOCIAL_WATCHDOG_INSTALL" in
    1|true|yes|on) ;;
    *)
      if [ "$DRY_RUN" != "1" ]; then
        if command -v systemctl >/dev/null 2>&1; then
          systemctl disable --now mihomo-social-media-watchdog.service >/dev/null 2>&1 || true
        fi
        for group in X视频 Instagram媒体; do
          if ! curl -fsS --unix-socket "$CORE_SOCKET" -X DELETE \
            "http://localhost/proxies/${group}" >/dev/null; then
            say "警告：无法清除 ${group} 的 fixed 选择，请在面板中恢复自动选择。"
          fi
        done
      fi
      say "已停用社交媒体守护服务，并恢复 X/Instagram 原生 URLTest 自动选择。"
      return 0
      ;;
  esac
  [ "$DRY_RUN" != "1" ] || return 0

  raw="https://raw.githubusercontent.com/${PROJECT_REPO}/${PROJECT_REF}/install-social-media-watchdog.sh"
  [ -z "$SOCIAL_WATCHDOG_INSTALLER_URL" ] || urls+=("$SOCIAL_WATCHDOG_INSTALLER_URL")
  urls+=(
    "https://gh-proxy.com/${raw}"
    "https://gh.llkk.cc/${raw}"
    "https://cdn.jsdelivr.net/gh/${PROJECT_REPO}@${PROJECT_REF}/install-social-media-watchdog.sh"
    "$raw"
  )
  for url in "${urls[@]}"; do
    say "尝试下载社交媒体守护服务安装器：$url"
    if curl -fL --connect-timeout 10 --max-time 60 --retry 1 -o "$TMP_SOCIAL_WATCHDOG_INSTALLER" "$url" && [ -s "$TMP_SOCIAL_WATCHDOG_INSTALLER" ]; then
      downloaded=1
      break
    fi
  done
  if [ "$downloaded" != "1" ]; then
    say "警告：社交媒体守护服务安装器下载失败，分流配置已生效，可稍后单独安装。"
    return 0
  fi
  if ! bash "$TMP_SOCIAL_WATCHDOG_INSTALLER"; then
    say "警告：社交媒体守护服务安装失败，分流配置已生效，可稍后单独安装。"
    return 0
  fi
  say "X/Instagram 媒体低速/停滞自动切换服务已启用。"
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

awk '
  function print_social_dns() {
    split("x.com twitter.com twimg.com twittercdn.com t.co pscp.tv periscope.tv tweetdeck.com instagram.com cdninstagram.com facebook.com facebook.net fbcdn.net fbsbx.com fb.com fb.me messenger.com meta.com threads.net oculus.com", domains, " ")
    for (i = 1; i <= 20; i++) {
      print "    \"+." domains[i] "\": [\"https://8.8.8.8/dns-query#节点选择\", \"https://1.1.1.1/dns-query#节点选择\"]"
    }
  }
  /^  nameserver-policy:[[:space:]]*$/ {
    print
    print_social_dns()
    dns_written = 1
    next
  }
  /^    "\+\.(x\.com|twitter\.com|twimg\.com|twittercdn\.com|t\.co|pscp\.tv|periscope\.tv|tweetdeck\.com|instagram\.com|cdninstagram\.com|facebook\.com|facebook\.net|fbcdn\.net|fbsbx\.com|fb\.com|fb\.me|messenger\.com|meta\.com|threads\.net|oculus\.com)":/ { next }
  { print }
  END { if (!dns_written) exit 42 }
' "$CONFIG_FILE" >"$TMP_DNS" || fail "生成社交媒体加密 DNS 策略失败。"

mv "$TMP_DNS" "$CONFIG_FILE"

awk \
  -v filter_kr="$FILTER_KR_LINE" \
  -v url_test_anchor="$URL_TEST_ANCHOR_LINE" \
  -v x_media_group="$X_MEDIA_GROUP_LINE" \
  -v x_video_group="$X_VIDEO_GROUP_LINE" \
  -v social_group="$SOCIAL_GROUP_LINE" \
  -v instagram_media_group="$INSTAGRAM_MEDIA_GROUP_LINE" \
  -v container_group="$CONTAINER_GROUP_LINE" \
  -v auto_group="$AUTO_GROUP_LINE" \
  -v airport_group="$AIRPORT_GROUP_LINE" \
  -v select_group="$SELECT_GROUP_LINE" \
  -v catch_all_group="$CATCH_ALL_GROUP_LINE" \
  -v fallback_group="$FALLBACK_GROUP_LINE" '
  BEGIN {
    filter_written = anchor_written = x_media_written = x_video_written = social_written = instagram_media_written = container_written = auto_written = 0
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
    print x_media_group
    print x_video_group
    x_video_written = 1
    print social_group
    print instagram_media_group
    print container_group
    print auto_group
    x_media_written = social_written = instagram_media_written = container_written = auto_written = 1
    next
  }
  /^  - \{name: X媒体,/ { next }
  /^  - \{name: X视频,/ { next }
  /^  - \{name: 社交媒体,/ { next }
  /^  - \{name: Instagram媒体,/ { next }
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
    if (!(filter_written && anchor_written && x_media_written && x_video_written && social_written && instagram_media_written && container_written && auto_written && select_written && catch_all_written && fallback_written && airport_written)) {
      exit 42
    }
  }
' "$CONFIG_FILE" >"$TMP_GROUPS" || fail "生成代理组失败。"

mv "$TMP_GROUPS" "$CONFIG_FILE"

awk '
  function print_x_rules() {
    print "  # X 页面、API、静态图片和视频分别使用目标 CDN 自动测速组"
    print "  - DOMAIN-SUFFIX,x.com,X媒体"
    print "  - DOMAIN-SUFFIX,twitter.com,X媒体"
    print "  - DOMAIN,video.twimg.com,X视频"
    print "  - DOMAIN,video-s.twimg.com,X视频"
    print "  - DOMAIN-SUFFIX,twittercdn.com,X视频"
    print "  - DOMAIN-SUFFIX,pscp.tv,X视频"
    print "  - DOMAIN-SUFFIX,periscope.tv,X视频"
    print "  - DOMAIN-SUFFIX,twimg.com,X媒体"
    print "  - DOMAIN-SUFFIX,t.co,X媒体"
    print "  - DOMAIN-SUFFIX,tweetdeck.com,X媒体"
    print "  # Instagram / Meta 账号 API 保持稳定，图片和视频 CDN 独立自动优选"
    print "  - DOMAIN-SUFFIX,instagram.com,社交媒体"
    print "  - DOMAIN-SUFFIX,cdninstagram.com,Instagram媒体"
    print "  - DOMAIN-SUFFIX,facebook.com,社交媒体"
    print "  - DOMAIN-SUFFIX,facebook.net,社交媒体"
    print "  - DOMAIN-SUFFIX,fbcdn.net,Instagram媒体"
    print "  - DOMAIN-SUFFIX,fbsbx.com,Instagram媒体"
    print "  - DOMAIN-SUFFIX,fb.com,社交媒体"
    print "  - DOMAIN-SUFFIX,fb.me,社交媒体"
    print "  - DOMAIN-SUFFIX,messenger.com,社交媒体"
    print "  - DOMAIN-SUFFIX,meta.com,社交媒体"
    print "  - DOMAIN-SUFFIX,threads.net,社交媒体"
    print "  - DOMAIN-SUFFIX,oculus.com,社交媒体"
  }
  function print_container_rules() {
    print "  # GHCR API 与镜像层使用目标站专用测速组选择代理节点"
    print "  - DOMAIN,ghcr.io,容器镜像"
    print "  - DOMAIN,pkg-containers.githubusercontent.com,容器镜像"
  }
  BEGIN { rules_written = 0 }
  /^  # X \/ Instagram \/ Meta 使用非 Hysteria2 高速节点$/ { next }
  /^  # X 图片、视频和 API 走独立的全订阅自动测速组$/ { next }
  /^  # X 页面、API、静态图片和视频分别使用目标 CDN 自动测速组$/ { next }
  /^  # Instagram \/ Meta (继续使用跨地区社交媒体组|账号 API 保持稳定，图片和视频 CDN 独立自动优选)$/ { next }
  /^  - DOMAIN,(video\.twimg\.com|video-s\.twimg\.com),X视频$/ { next }
  /^  - DOMAIN-SUFFIX,(x\.com|twitter\.com|twimg\.com|twittercdn\.com|t\.co|pscp\.tv|periscope\.tv|tweetdeck\.com|instagram\.com|cdninstagram\.com|facebook\.com|facebook\.net|fbcdn\.net|fbsbx\.com|fb\.com|fb\.me|messenger\.com|meta\.com|threads\.net|oculus\.com),(X媒体|X视频|社交媒体|Instagram媒体)$/ { next }
  /^  - RULE-SET,Docker,/ {
    print_x_rules()
    if (!rules_written) {
      print_container_rules()
      rules_written = 1
    }
    print
    next
  }
  /^  # GHCR API 与镜像层(使用目标站专项测速|使用目标站专用测速组|优先直连)/ { next }
  /^  - DOMAIN,(ghcr\.io|pkg-containers\.githubusercontent\.com),容器镜像$/ { next }
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
has_exact_line "$X_MEDIA_GROUP_LINE" || fail "X 媒体分组校验失败。"
has_exact_line "$X_VIDEO_GROUP_LINE" || fail "X 视频分组校验失败。"
has_exact_line "$SOCIAL_GROUP_LINE" || fail "社交媒体稳定账号组校验失败。"
has_exact_line "$INSTAGRAM_MEDIA_GROUP_LINE" || fail "Instagram 媒体分组校验失败。"
has_exact_line "$CONTAINER_GROUP_LINE" || fail "容器镜像分组校验失败。"
has_exact_line "$AUTO_GROUP_LINE" || fail "自动优选分组校验失败。"
has_exact_line "$AIRPORT_GROUP_LINE" || fail "机场节点分组校验失败。"
has_exact_line "$SELECT_GROUP_LINE" || fail "节点选择分组校验失败。"
has_exact_line "$CATCH_ALL_GROUP_LINE" || fail "漏网之鱼分组校验失败。"
has_exact_line "$FALLBACK_GROUP_LINE" || fail "稳定优选分组校验失败。"
has_exact_line '  - DOMAIN,ghcr.io,容器镜像' || fail "ghcr.io 规则校验失败。"
has_exact_line '  - DOMAIN,pkg-containers.githubusercontent.com,容器镜像' || fail "镜像层规则校验失败。"
has_exact_line '  - DOMAIN-SUFFIX,instagram.com,社交媒体' || fail "Instagram 账号规则校验失败。"
has_exact_line '  - DOMAIN,video.twimg.com,X视频' || fail "X 视频规则校验失败。"
has_exact_line '  - DOMAIN,video-s.twimg.com,X视频' || fail "X 视频 CDN 规则校验失败。"
has_exact_line '  - DOMAIN-SUFFIX,twimg.com,X媒体' || fail "X 静态媒体规则校验失败。"
has_exact_line '  - DOMAIN-SUFFIX,cdninstagram.com,Instagram媒体' || fail "Instagram CDN 规则校验失败。"
has_exact_line '  - DOMAIN-SUFFIX,fbcdn.net,Instagram媒体' || fail "Meta CDN 规则校验失败。"
has_exact_line '  - DOMAIN-SUFFIX,fbsbx.com,Instagram媒体' || fail "Meta 媒体规则校验失败。"

for domain in \
  x.com twitter.com twimg.com twittercdn.com t.co pscp.tv periscope.tv \
  tweetdeck.com instagram.com cdninstagram.com facebook.com facebook.net \
  fbcdn.net fbsbx.com fb.com fb.me messenger.com meta.com threads.net oculus.com; do
  has_exact_line "    \"+.${domain}\": [\"https://8.8.8.8/dns-query#节点选择\", \"https://1.1.1.1/dns-query#节点选择\"]" ||
    fail "${domain} 加密 DNS 策略校验失败。"
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
  install_container_watchdog
  install_social_watchdog
else
  say "DRY_RUN=1，已完成文件修改与结构校验，跳过内核验证和热重载。"
fi

trap - ERR
say "更新完成：已启用跨订阅单层自动优选，并让稳定优选直接按地区组故障接管；同时隔离 X 图片/视频与 Instagram 账号/媒体线路、修复韩国节点误匹配和社交应用 DNS 污染，并让 GHCR 自动切换低速或停滞线路。"
say "备份保留在：$BACKUP"
