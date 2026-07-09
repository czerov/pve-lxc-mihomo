#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
RAW_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/install.sh"

for proxy in \
  "https://gh.llkk.cc/" \
  "https://gh-proxy.com/" \
  "https://mirror.ghproxy.com/" \
  ""; do
  url="${proxy}${RAW_URL}"
  echo "Trying: $url"
  if bash <(curl -fsSL "$url"); then
    exit 0
  fi
done

echo "All download attempts failed." >&2
exit 1
