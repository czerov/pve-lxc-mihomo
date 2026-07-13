#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
REF="${REF:-a59ce608bb2ba552898f1a536ef8c4a5b940b908}"
NEXUSBOX_BIN="${NEXUSBOX_BIN:-/opt/nexusbox/nexusbox}"
CONFIG_FILE="${CONFIG_FILE:-/opt/config/config.yaml}"
CONFIG_JSON="${CONFIG_JSON:-/opt/config/nexusbox.json}"
CORE_SOCKET="${CORE_SOCKET:-/opt/nexusbox/var/core.sock}"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP="${NEXUSBOX_BIN}.bak-replay-${STAMP}"
TMP="/tmp/nexusbox-patch-${STAMP}"
COOKIE="/tmp/nexusbox-patch-cookie-${STAMP}"

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  say "错误：$*"
  exit 1
}

cleanup() {
  if [ -e "$TMP" ]; then
    rm -f "$TMP"
  fi
  if [ -e "$COOKIE" ]; then
    rm -f "$COOKIE"
  fi
}

json_string_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -1
}

nexusbox_ready() {
  systemctl is-active --quiet nexusbox &&
    [ -S "$CORE_SOCKET" ] &&
    ss -lnt 2>/dev/null | grep -Eq '[:.]18080[[:space:]]'
}

rollback_and_die() {
  local reason="$1"
  say "${reason}，正在恢复旧版。"
  systemctl stop nexusbox >/dev/null 2>&1 || true
  if cp -a "$BACKUP" "$NEXUSBOX_BIN" && systemctl start nexusbox >/dev/null 2>&1; then
    say "旧版 NexusBox 已恢复并重新启动。"
  else
    say "警告：旧二进制已保留在 $BACKUP，请手动检查 nexusbox.service。"
  fi
  die "$reason"
}

verify_nexusbox_reload_api() {
  local username password
  if [ ! -s "$CONFIG_JSON" ]; then
    say "未找到 $CONFIG_JSON，跳过 NexusBox 登录接口验证。"
    return 0
  fi

  username="$(json_string_value "$CONFIG_JSON" username)"
  password="$(json_string_value "$CONFIG_JSON" password)"
  if [ -z "$username" ] || [ -z "$password" ]; then
    say "无法读取 NexusBox 登录信息，跳过登录接口验证。"
    return 0
  fi
  case "${username}${password}" in
    *[!A-Za-z0-9._@-]*)
      say "NexusBox 登录信息含特殊字符，跳过登录接口验证。"
      return 0
      ;;
  esac

  curl --noproxy '*' -fsS -c "$COOKIE" \
    -H 'Content-Type: application/json' \
    -d "{\"username\":\"${username}\",\"password\":\"${password}\"}" \
    'http://127.0.0.1:18080/login' >/dev/null || return 1
  curl --noproxy '*' -fsS -b "$COOKIE" -X PUT \
    'http://127.0.0.1:18080/configs' >/dev/null || return 1
  say "NexusBox /configs 热重载接口验证正常。"
}

trap cleanup EXIT

[ "$(id -u)" -eq 0 ] || die "请使用 root 运行。"
[ -x "$NEXUSBOX_BIN" ] || die "找不到 NexusBox：$NEXUSBOX_BIN"
[ -s "$CONFIG_FILE" ] || die "找不到 Mihomo 配置：$CONFIG_FILE"
for command in curl sha256sum systemctl ss sed install; do
  command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
done

case "$(uname -m)" in
  x86_64|amd64)
    asset="nexusbox-linux-amd64"
    expected="443af7d019f92459cb692c86cf0161a7251c240c3a9344831657a3533b6e3408"
    ;;
  aarch64|arm64)
    asset="nexusbox-linux-arm64"
    expected="e1aad8f69667dd1f2c145ef2c93d6d6663fd5b1f8a9bbd28e2914ad190bc707a"
    ;;
  *) die "暂不支持当前架构：$(uname -m)" ;;
esac

raw="https://raw.githubusercontent.com/${REPO}/${REF}/bin/${asset}"
urls=(
  "https://gh-proxy.com/${raw}"
  "https://gh.llkk.cc/${raw}"
  "https://cdn.jsdelivr.net/gh/${REPO}@${REF}/bin/${asset}"
  "$raw"
)

downloaded=0
for url in "${urls[@]}"; do
  say "尝试下载：$url"
  if curl -fL --connect-timeout 10 --speed-limit 1024 --speed-time 20 --retry 1 -o "$TMP" "$url"; then
    downloaded=1
    break
  fi
  if [ -n "${http_proxy:-}${https_proxy:-}${HTTP_PROXY:-}${HTTPS_PROXY:-}${all_proxy:-}${ALL_PROXY:-}" ]; then
    say "当前代理失败，改用直连重试：$url"
    if curl -fL --proxy "" --connect-timeout 15 --speed-limit 1024 --speed-time 30 --retry 1 -o "$TMP" "$url"; then
      downloaded=1
      break
    fi
  fi
done
[ "$downloaded" = "1" ] || die "NexusBox 修补版下载失败。"

actual="$(sha256sum "$TMP" | awk '{print tolower($1)}')"
[ "$actual" = "$expected" ] || die "SHA256 不匹配，预期=$expected，实际=$actual"

cp -a "$NEXUSBOX_BIN" "$BACKUP"
say "已备份：$BACKUP"
systemctl stop nexusbox || die "无法停止 nexusbox.service，未替换二进制。"
install -m 0755 "$TMP" "$NEXUSBOX_BIN" || rollback_and_die "安装新 NexusBox 二进制失败"
systemctl start nexusbox || rollback_and_die "新 NexusBox 无法启动"

for _ in $(seq 1 30); do
  if nexusbox_ready; then
    break
  fi
  sleep 1
done

nexusbox_ready || rollback_and_die "新 NexusBox 未通过服务、端口或核心套接字验证"
curl --noproxy '*' -fsS 'http://127.0.0.1:18080/auth-status' >/dev/null ||
  rollback_and_die "NexusBox 管理接口不可用"

payload="$(printf '{"path":"%s","payload":""}' "$CONFIG_FILE")"
curl -fsS --unix-socket "$CORE_SOCKET" \
  -X PUT 'http://localhost/configs?force=true' \
  -H 'Content-Type: application/json' \
  -d "$payload" >/dev/null || rollback_and_die "Mihomo 热重载验证失败"

verify_nexusbox_reload_api || rollback_and_die "NexusBox /configs 热重载接口验证失败"

say "NexusBox 请求体重放修补版更新完成。"
say "配置和订阅未被修改，请返回订阅页再次点击“保存并应用”。"
