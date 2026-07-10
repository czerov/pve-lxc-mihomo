#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh"
CDN_BASE="${CDN_BASE:-https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}}"

say() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

probe_url() {
  local url="$1" speed
  speed="$(curl -fL --range 0-65535 --connect-timeout 8 --max-time 15 -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || true)"
  speed="${speed%.*}"
  case "$speed" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$speed" -gt 0 ] || return 1
  printf '%s' "$speed"
}

download_best() {
  local output="$1" url speed best_url="" best_speed="0"
  shift
  local usable_urls=()

  for url in "$@"; do
    say "Check: $url"
    speed="$(probe_url "$url" || true)"
    [ -n "$speed" ] || continue
    say "Available: $url (${speed} B/s)"
    usable_urls+=("$url")
    if awk "BEGIN {exit !($speed > $best_speed)}"; then
      best_speed="$speed"
      best_url="$url"
    fi
  done

  [ -n "$best_url" ] && say "Selected: $best_url"
  for url in "$best_url" "${usable_urls[@]}" "$@"; do
    [ -n "$url" ] || continue
    if curl -fsSL --connect-timeout 20 --retry 2 -o "$output" "$url" && [ -s "$output" ]; then
      return 0
    fi
  done
  return 1
}

tmp="${TMPDIR:-/tmp}/install-cn.$$.sh"
trap 'rm -f "$tmp"' EXIT

download_best "$tmp" \
  "${CDN_BASE}/install.sh" \
  "https://fastly.jsdelivr.net/gh/${REPO}@${BRANCH}/install.sh" \
  "https://testingcf.jsdelivr.net/gh/${REPO}@${BRANCH}/install.sh" \
  "$RAW_URL" \
  "https://gh.llkk.cc/${RAW_URL}" \
  "https://gh-proxy.com/${RAW_URL}" \
  "https://mirror.ghproxy.com/${RAW_URL}" || {
    echo "All download attempts failed." >&2
    exit 1
  }

bash "$tmp" "$@"
