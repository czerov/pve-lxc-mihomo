#!/bin/sh
set -eu

CONFIG_DIR="${CORE_WORK_DIR:-/opt/config}"
CONFIG_FILE="${CONFIG_TARGET:-${CONFIG_DIR}/config.yaml}"
CORE_BIN="${CORE_BIN:-/opt/mihomo/mihomo}"
DEFAULTS_DIR="${DEFAULTS_DIR:-/usr/share/pve-lxc-mihomo}"
NEXUSBOX_CONFIG_FILE="${FLUXOR_CONFIG_FILE:-${CONFIG_DIR}/nexusbox.json}"

say() {
  printf '[docker-entrypoint] %s\n' "$*"
}

copy_if_missing() {
  source_file="$1"
  target_file="$2"
  [ -s "$target_file" ] && return 0
  install -D -m 0644 "$source_file" "$target_file"
  say "initialized $target_file"
}

set_tun_enabled() {
  enabled="$1"
  temp_file="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
  awk -v enabled="$enabled" '
    /^tun:[[:space:]]*$/ { in_tun = 1; print; next }
    in_tun && /^[^[:space:]#]/ { in_tun = 0 }
    in_tun && /^[[:space:]]+enable:[[:space:]]*/ {
      match($0, /^[[:space:]]*/)
      print substr($0, 1, RLENGTH) "enable: " enabled
      changed = 1
      next
    }
    { print }
    END { if (!changed) exit 42 }
  ' "$CONFIG_FILE" >"$temp_file" || {
    rm -f "$temp_file"
    say "unable to update tun.enable in $CONFIG_FILE" >&2
    exit 1
  }
  mv "$temp_file" "$CONFIG_FILE"
}

mkdir -p "$CONFIG_DIR/rules" "$CONFIG_DIR/ui/zash" /opt/nexusbox/var
copy_if_missing "$DEFAULTS_DIR/config.yaml" "$CONFIG_FILE"
copy_if_missing "$DEFAULTS_DIR/rules/tiktok-ios.yaml" "$CONFIG_DIR/rules/tiktok-ios.yaml"

for asset in geoip.dat geosite.dat country.mmdb; do
  copy_if_missing "$DEFAULTS_DIR/geodata/$asset" "$CONFIG_DIR/$asset"
done

if [ ! -s "$CONFIG_DIR/ui/zash/index.html" ]; then
  cp -a "$DEFAULTS_DIR/ui/zash/." "$CONFIG_DIR/ui/zash/"
  say "initialized $CONFIG_DIR/ui/zash"
fi

if [ ! -s "$NEXUSBOX_CONFIG_FILE" ]; then
  username="${NEXUSBOX_USERNAME:-admin}"
  password="${NEXUSBOX_PASSWORD:-admin}"
  dns_servers="${NEXUSBOX_DNS_FAILOVER_SERVERS:-223.5.5.5,119.29.29.29}"
  umask 077
  jq -n \
    --arg username "$username" \
    --arg password "$password" \
    --arg dns_servers "$dns_servers" \
    '{
      active_subscription: "",
      dns_failover: true,
      dns_failover_servers: ($dns_servers | split(",") | join("\n")),
      meta_backend_url: "",
      mode: "merge",
      panel_port: 9090,
      panel_secret: "",
      password: $password,
      proxy_port: 7890,
      rule_group: "full",
      subscriptions: [],
      tproxy_dst_exceptions: ["223.5.5.5", "1.12.12.12"],
      tproxy_port: 7896,
      tproxy_proxy_local: true,
      tproxy_src_exceptions: ["172.16.0.0/12"],
      ui_panel: "zashboard",
      username: $username
    }' >"$NEXUSBOX_CONFIG_FILE"
  say "initialized $NEXUSBOX_CONFIG_FILE"
fi

case "${MIHOMO_TUN_ENABLED:-auto}" in
  auto|'') ;;
  1|true|yes|on) set_tun_enabled true ;;
  0|false|no|off) set_tun_enabled false ;;
  *) say "invalid MIHOMO_TUN_ENABLED=${MIHOMO_TUN_ENABLED}" >&2; exit 1 ;;
esac

if [ "${SKIP_CONFIG_TEST:-0}" != 1 ]; then
  "$CORE_BIN" -t -d "$CONFIG_DIR"
fi

exec "$@"
