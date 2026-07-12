#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
RULE_FILE="${RULE_FILE:-/opt/config/rules/tiktok-ios.yaml}"
RULE_URL="${RULE_URL:-https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/rules/tiktok-ios.yaml}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${CONFIG_FILE}.bak-tiktok-${STAMP}"
RULE_BACKUP="${RULE_FILE}.bak-tiktok-${STAMP}"
TMP="${CONFIG_FILE}.tmp-tiktok-${STAMP}"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

restore_backup() {
  if [ -f "$BACKUP" ]; then
    cp -a "$BACKUP" "$CONFIG_FILE"
    say "已恢复原配置：$BACKUP"
  fi
  if [ -f "$RULE_BACKUP" ]; then
    cp -a "$RULE_BACKUP" "$RULE_FILE"
  fi
}

die() {
  say "错误：$*"
  restore_backup
  trap - ERR
  exit 1
}

trap 'restore_backup' ERR

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -s "$CONFIG_FILE" ] || die "找不到配置文件：$CONFIG_FILE"
[ -x "$CORE_BIN" ] || die "找不到 Mihomo 核心：$CORE_BIN"
[ -S "$CORE_SOCKET" ] || die "找不到 Mihomo 控制套接字：$CORE_SOCKET"
grep -q '^domainYaml: &domainYaml ' "$CONFIG_FILE" || die "当前配置缺少 domainYaml 规则锚点。"
grep -q '^  nameserver-policy:' "$CONFIG_FILE" || die "当前配置缺少 nameserver-policy。"
grep -q '^  TikTok:' "$CONFIG_FILE" || die "当前配置缺少 TikTok 规则提供器。"
grep -q '^  - RULE-SET,TikTok,TikTok$' "$CONFIG_FILE" || die "当前配置缺少 TikTok 路由规则。"

mkdir -p "$(dirname "$RULE_FILE")"
cp -a "$CONFIG_FILE" "$BACKUP"
say "已备份配置：$BACKUP"
if [ -f "$RULE_FILE" ]; then
  cp -a "$RULE_FILE" "$RULE_BACKUP"
  say "已备份规则：$RULE_BACKUP"
fi

download_rule() {
  local url
  for url in \
    "$RULE_URL" \
    "https://gh-proxy.com/https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/rules/tiktok-ios.yaml" \
    "https://raw.githubusercontent.com/czerov/pve-lxc-mihomo/main/rules/tiktok-ios.yaml"; do
    say "尝试下载 TikTok iOS 规则：$url"
    if curl -fsSL --connect-timeout 20 --retry 2 -o "$RULE_FILE" "$url" && [ -s "$RULE_FILE" ]; then
      return 0
    fi
  done
  return 1
}

download_rule || die "TikTok iOS 规则下载失败。"

provider_present=0
grep -q '^  TikTok-iOS:' "$CONFIG_FILE" && provider_present=1
reject_present=0
grep -Fqx '  - AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,TikTok-iOS)),REJECT' "$CONFIG_FILE" && reject_present=1
route_present=0
grep -Fqx '  - RULE-SET,TikTok-iOS,TikTok' "$CONFIG_FILE" && route_present=1

awk \
  -v provider_present="$provider_present" \
  -v reject_present="$reject_present" \
  -v route_present="$route_present" '
function print_proxy_dns(key) {
  print "    \"rule-set:" key "\":"
  print "      - \"https://8.8.8.8/dns-query#节点选择\""
  print "      - \"https://1.1.1.1/dns-query#节点选择\""
}
function print_fixed_dns() {
  print_proxy_dns("Telegram")
  print_proxy_dns("TikTok")
  print_proxy_dns("TikTok-iOS")
  print_proxy_dns("YouTube")
  print_proxy_dns("Google")
}
BEGIN {
  in_policy = 0
  skip_policy_values = 0
  dns_written = 0
  provider_written = provider_present
  reject_written = reject_present
  route_written = route_present
}
{
  if ($0 ~ /^  nameserver-policy:[[:space:]]*$/) {
    print
    print_fixed_dns()
    in_policy = 1
    dns_written = 1
    next
  }

  if (in_policy && $0 ~ /^[^[:space:]#]/) {
    in_policy = 0
    skip_policy_values = 0
  }

  if (in_policy && $0 ~ /^    "rule-set:(Telegram,TikTok|YouTube,Google|Telegram|TikTok|TikTok-iOS|YouTube|Google)"[[:space:]]*:/) {
    skip_policy_values = 1
    next
  }
  if (in_policy && skip_policy_values && $0 ~ /^      - /) {
    next
  }
  if (in_policy && skip_policy_values) {
    skip_policy_values = 0
  }

  if ($0 ~ /^  - RULE-SET,TikTok,TikTok[[:space:]]*$/) {
    if (!reject_written) {
      print "  - AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,TikTok-iOS)),REJECT"
      reject_written = 1
    }
    if (!route_written) {
      print "  - RULE-SET,TikTok-iOS,TikTok"
      route_written = 1
    }
    print
    next
  }

  print

  if (!provider_written && $0 ~ /^  TikTok:[[:space:]]*/) {
    print "  TikTok-iOS: {<<: *domainYaml, path: ./rules/tiktok-ios.yaml, url: https://cdn.jsdelivr.net/gh/czerov/pve-lxc-mihomo@main/rules/tiktok-ios.yaml}"
    provider_written = 1
  }
}
END {
  if (!dns_written || !provider_written || !reject_written || !route_written) {
    exit 42
  }
}
' "$CONFIG_FILE" > "$TMP" || die "生成 TikTok 修复配置失败。"

mv "$TMP" "$CONFIG_FILE"

grep -q '^    "rule-set:TikTok-iOS":' "$CONFIG_FILE" || die "TikTok iOS DNS 策略写入失败。"
grep -q '^  TikTok-iOS:' "$CONFIG_FILE" || die "TikTok iOS 规则提供器写入失败。"
grep -Fqx '  - AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,TikTok-iOS)),REJECT' "$CONFIG_FILE" || die "TikTok QUIC 回退规则写入失败。"
grep -Fqx '  - RULE-SET,TikTok-iOS,TikTok' "$CONFIG_FILE" || die "TikTok iOS 路由规则写入失败。"

"$CORE_BIN" -t -d "$(dirname "$CONFIG_FILE")"
say "Mihomo 配置校验通过。"

payload="$(printf '{"path":"%s","payload":""}' "$CONFIG_FILE")"
curl -fsS --unix-socket "$CORE_SOCKET" \
  -X PUT 'http://localhost/configs?force=true' \
  -H 'Content-Type: application/json' \
  -d "$payload" >/dev/null

curl -fsS --unix-socket "$CORE_SOCKET" -X POST 'http://localhost/cache/dns/flush' >/dev/null
curl -fsS --unix-socket "$CORE_SOCKET" -X POST 'http://localhost/cache/fakeip/flush' >/dev/null
curl -fsS --unix-socket "$CORE_SOCKET" -X DELETE 'http://localhost/connections' >/dev/null

trap - ERR
say "TikTok iOS 域名、代理 DNS 和 QUIC 回退规则已生效。"
say "请在 TikTok 分组选择新加坡、日本或美国节点，然后在 iPhone 上完全关闭 TikTok 后重新打开。"
