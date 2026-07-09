#!/usr/bin/env bash
set -Eeuo pipefail

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
CDN_BASE="${CDN_BASE:-https://cdn.jsdelivr.net/gh/${REPO}@${BRANCH}}"

export RAW_BASE="${RAW_BASE:-${CDN_BASE}}"

bash <(curl -fsSL "${CDN_BASE}/pve-install.sh") "$@"
