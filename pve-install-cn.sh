#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
CDN_BASE="${CDN_BASE:-https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/pve-install.sh"
RAW_REPO_BASE="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

export RAW_BASE="${RAW_BASE:-${RAW_REPO_BASE}}"
export PREFER_CN_ACCEL="${PREFER_CN_ACCEL:-1}"

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

download_first_available() {
  local output="$1" url
  shift

  for url in "$@"; do
    say "尝试下载：$url"
    if curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 30 --retry 2 -o "$output" "$url" && [ -s "$output" ]; then
      return 0
    fi
  done
  return 1
}

tmp="${TMPDIR:-/tmp}/pve-install-cn.$$.sh"
trap 'rm -f "$tmp"' EXIT

download_first_available "$tmp" \
  "https://gh-proxy.com/${RAW_URL}" \
  "https://gh.llkk.cc/${RAW_URL}" \
  "https://mirror.ghproxy.com/${RAW_URL}" \
  "$RAW_URL" \
  "${CDN_BASE}/pve-install.sh" \
  "https://fastly.jsdelivr.net/gh/${REPO}@${BRANCH}/pve-install.sh" \
  "https://testingcf.jsdelivr.net/gh/${REPO}@${BRANCH}/pve-install.sh" || {
    echo "所有下载地址均失败，请检查网络或代理。" >&2
    exit 1
  }

bash "$tmp" "$@"
