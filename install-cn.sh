#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh"
CDN_BASE="${CDN_BASE:-https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}}"

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

download_first_available() {
  local output="$1" url
  shift

  for url in "$@"; do
    say "Try: $url"
    if curl -fsSL --connect-timeout 20 --retry 2 -o "$output" "$url" && [ -s "$output" ]; then
      return 0
    fi
  done
  return 1
}

tmp="${TMPDIR:-/tmp}/install-cn.$$.sh"
trap 'rm -f "$tmp"' EXIT

download_first_available "$tmp" \
  "$RAW_URL" \
  "https://gh.llkk.cc/${RAW_URL}" \
  "https://gh-proxy.com/${RAW_URL}" \
  "https://mirror.ghproxy.com/${RAW_URL}" \
  "${CDN_BASE}/install.sh" \
  "https://fastly.jsdelivr.net/gh/${REPO}@${BRANCH}/install.sh" \
  "https://testingcf.jsdelivr.net/gh/${REPO}@${BRANCH}/install.sh" || {
    echo "All download attempts failed." >&2
    exit 1
  }

bash "$tmp" "$@"
