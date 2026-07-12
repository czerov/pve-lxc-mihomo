#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${CONFIG_FILE}.bak-youtube-${STAMP}"
TMP="${CONFIG_FILE}.tmp-youtube-${STAMP}"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  say "错误：$*"
  restore_backup
  trap - ERR
  exit 1
}

restore_backup() {
  if [ -f "$BACKUP" ]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    say "已恢复原配置：$BACKUP"
    if [ -S "$CORE_SOCKET" ]; then
      payload="$(printf '{"path":"%s","payload":""}' "$CONFIG_FILE")"
      curl -fsS --unix-socket "$CORE_SOCKET" \
        -X PUT 'http://localhost/configs?force=true' \
        -H 'Content-Type: application/json' \
        -d "$payload" >/dev/null 2>&1 || true
    fi
  fi
}

trap 'restore_backup' ERR

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || die "找不到配置文件：$CONFIG_FILE"
[ -x "$CORE_BIN" ] || die "找不到 Mihomo 核心：$CORE_BIN"
[ -S "$CORE_SOCKET" ] || die "找不到 Mihomo 控制套接字：$CORE_SOCKET"

grep -q '^  nameserver-policy:' "$CONFIG_FILE" ||
  die "当前配置没有 nameserver-policy，请先更新到项目的 Telegram/TikTok DNS 修复版本。"

if ! grep -q 'name: YouTube,' "$CONFIG_FILE"; then
  grep -q '^  - {name: 谷歌服务,' "$CONFIG_FILE" ||
    die "找不到“谷歌服务”代理组，无法安全插入 YouTube 组。"
fi

grep -q 'RULE-SET,YouTube,' "$CONFIG_FILE" ||
  die "找不到 YouTube 规则。"

cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份：$BACKUP"

add_group=1
grep -q 'name: YouTube,' "$CONFIG_FILE" && add_group=0

awk -v add_group="$add_group" '
function print_youtube_dns() {
  print "    \"rule-set:YouTube\":"
  print "      - \"https://8.8.8.8/dns-query#节点选择\""
  print "      - \"https://1.1.1.1/dns-query#节点选择\""
  print "    \"rule-set:Google\":"
  print "      - \"https://8.8.8.8/dns-query#节点选择\""
  print "      - \"https://1.1.1.1/dns-query#节点选择\""
}
BEGIN {
  in_dns = 0
  in_policy = 0
  skip_dns_values = 0
  dns_written = 0
  group_written = (add_group == 0)
}
{
  if ($0 ~ /^dns:[[:space:]]*$/) {
    in_dns = 1
  } else if (in_dns && $0 ~ /^[^[:space:]#]/) {
    in_dns = 0
  }

  if (in_dns && $0 ~ /^  ipv6:[[:space:]]*/) {
    print "  ipv6: false"
    next
  }

  if ($0 ~ /^  nameserver-policy:[[:space:]]*$/) {
    in_policy = 1
  } else if (in_policy && $0 ~ /^[^[:space:]#]/) {
    if (!dns_written) {
      print_youtube_dns()
      dns_written = 1
    }
    in_policy = 0
  }

  if (in_policy && $0 ~ /^    "rule-set:(YouTube,Google|YouTube|Google)"[[:space:]]*:/) {
    skip_dns_values = 1
    next
  }
  if (in_policy && skip_dns_values && $0 ~ /^      - /) {
    next
  }
  if (in_policy && skip_dns_values) {
    skip_dns_values = 0
  }

  if ($0 ~ /^  - RULE-SET,YouTube,/) {
    print "  - RULE-SET,YouTube,YouTube"
    next
  }

  print

  if (!group_written && $0 ~ /^  - \{name: 谷歌服务,/) {
    print "  - {name: YouTube, !!merge <<: *UrlTest, filter: *FilterAll, interval: 60, tolerance: 50, lazy: false, timeout: 5000, max-failed-times: 1, hidden: false, icon: '''https://raw.githubusercontent.com/Koolson/Qure/refs/heads/master/IconSet/Color/YouTube.png'''}"
    group_written = 1
  }
}
END {
  if (in_policy && !dns_written) {
    print_youtube_dns()
    dns_written = 1
  }
  if (!dns_written || !group_written) {
    exit 42
  }
}
' "$CONFIG_FILE" >"$TMP" || die "生成修复配置失败。"

mv "$TMP" "$CONFIG_FILE"

grep -q '^    "rule-set:YouTube":' "$CONFIG_FILE" || die "YouTube DNS 策略写入失败。"
grep -q '^    "rule-set:Google":' "$CONFIG_FILE" || die "Google DNS 策略写入失败。"
grep -q 'name: YouTube,' "$CONFIG_FILE" ||
  die "YouTube 自动测速组写入失败。"
grep -q '^  - RULE-SET,YouTube,YouTube$' "$CONFIG_FILE" ||
  die "YouTube 规则目标修改失败。"

"$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"
say "Mihomo 配置校验通过。"

payload="$(printf '{"path":"%s","payload":""}' "$CONFIG_FILE")"
curl -fsS --unix-socket "$CORE_SOCKET" \
  -X PUT 'http://localhost/configs?force=true' \
  -H 'Content-Type: application/json' \
  -d "$payload" >/dev/null

curl -fsS --unix-socket "$CORE_SOCKET" \
  -X POST 'http://localhost/cache/dns/flush' >/dev/null
curl -fsS --unix-socket "$CORE_SOCKET" \
  -X POST 'http://localhost/cache/fakeip/flush' >/dev/null
curl -fsS --unix-socket "$CORE_SOCKET" \
  -X DELETE 'http://localhost/connections' >/dev/null

trap - ERR
say "YouTube 自动测速、境外 DNS 和手机 IPv4 优先策略已生效。"
say "请完全关闭手机 YouTube 后重新打开；必要时断开并重新连接 Wi-Fi。"
