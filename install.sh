#!/usr/bin/env bash
set -Eeuo pipefail

# Mihomo / NexusBox one-key installer for PVE LXC side-router.
# Safe defaults:
# - No batch deletion.
# - Existing files are copied to timestamped backups before overwrite.
# - CPU is detected automatically: amd64-v3 core when supported, compatible core otherwise.

VERSION="${VERSION:-latest}"
MIHOMO_FALLBACK_VERSION="${MIHOMO_FALLBACK_VERSION:-v1.19.28}"
BASE_URL="${BASE_URL:-}"
WORK_DIR="${WORK_DIR:-/tmp/mihomo-router-install}"
LOG="${LOG:-/root/mihomo-router-install.log}"
CONFIG_DIR="${CONFIG_DIR:-/etc/mihomo}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config.yaml}"
CONFIG_URL="${CONFIG_URL:-}"
MIHOMO_BIN="${MIHOMO_BIN:-/usr/local/bin/mihomo}"
NEXUSBOX_BIN="${NEXUSBOX_BIN:-/opt/nexusbox/nexusbox}"
NEXUSBOX_CORE="${NEXUSBOX_CORE:-/opt/mihomo/mihomo}"
NEXUSBOX_CONFIG_DIR="${NEXUSBOX_CONFIG_DIR:-/opt/config}"
NEXUSBOX_DEFAULT_INSTALL_URL="${NEXUSBOX_DEFAULT_INSTALL_URL:-https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh}"
NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-$NEXUSBOX_DEFAULT_INSTALL_URL}"
NEXUSBOX_PATCHED_ENABLE="${NEXUSBOX_PATCHED_ENABLE:-1}"
NEXUSBOX_PATCHED_REPO="${NEXUSBOX_PATCHED_REPO:-czerov/pve-lxc-mihomo}"
NEXUSBOX_PATCHED_BRANCH="${NEXUSBOX_PATCHED_BRANCH:-main}"
NEXUSBOX_PATCHED_REF="${NEXUSBOX_PATCHED_REF:-d52e6852dceea7405fbc8b5477605cd37a40f183}"
NEXUSBOX_PATCHED_BASE="${NEXUSBOX_PATCHED_BASE:-https://raw.githubusercontent.com/${NEXUSBOX_PATCHED_REPO}/${NEXUSBOX_PATCHED_REF}/bin}"
NEXUSBOX_PATCHED_URL="${NEXUSBOX_PATCHED_URL:-}"
NEXUSBOX_PATCHED_SHA256="${NEXUSBOX_PATCHED_SHA256:-}"
MODE="${MODE:-auto}"
INSTALL_PROFILE="${INSTALL_PROFILE:-unknown}"
PREFER_CN_ACCEL="${PREFER_CN_ACCEL:-0}"
DOWNLOAD_SPEED_LIMIT="${DOWNLOAD_SPEED_LIMIT:-1024}"
DOWNLOAD_SPEED_TIME="${DOWNLOAD_SPEED_TIME:-30}"
GEODATA_REPO="${GEODATA_REPO:-MetaCubeX/meta-rules-dat}"
GEODATA_BRANCH="${GEODATA_BRANCH:-release}"
GEODATA_MIN_BYTES="${GEODATA_MIN_BYTES:-1048576}"

mkdir -p "$WORK_DIR"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { say "错误：$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
prefer_cn_accel_enabled() {
  case "$PREFER_CN_ACCEL" in
    1|true|yes|on|cn) return 0 ;;
    *) return 1 ;;
  esac
}
backup_file() {
  local path="$1"
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$path" ]; then
    cp -a "$path" "${path}.bak-${ts}"
    say "已备份：$path -> ${path}.bak-${ts}"
  fi
}

fetch_url() {
  local url="$1" output="$2"
  if have curl; then
    curl -fL --connect-timeout 20 --speed-limit "$DOWNLOAD_SPEED_LIMIT" --speed-time "$DOWNLOAD_SPEED_TIME" --retry 2 -o "$output" "$url"
  elif have wget; then
    wget -T 20 -t 2 -O "$output" "$url"
  else
    die "缺少 curl/wget，请先安装 curl。"
  fi
}

fetch_geodata_url() {
  local url="$1" output="$2"
  if have curl; then
    curl -fL --connect-timeout 10 --speed-limit "$DOWNLOAD_SPEED_LIMIT" --speed-time 15 --retry 1 -o "$output" "$url"
  elif have wget; then
    wget -T 15 -t 1 -O "$output" "$url"
  else
    die "缺少 curl/wget，请先安装 curl。"
  fi
}

probe_download_source() {
  local url="$1" speed
  if have curl; then
    speed="$(curl -fL --range 0-65535 --connect-timeout 8 --max-time 15 -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || true)"
  elif have wget; then
    fetch_url "$url" /dev/null >/dev/null 2>&1 && speed=1 || speed=0
  else
    die "缺少 curl/wget，请先安装 curl。"
  fi

  speed="${speed%.*}"
  case "$speed" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$speed" -gt 0 ] || return 1
  printf '%s' "$speed"
}

download_best_url() {
  local output="$1" url speed best_url="" best_speed="0"
  shift
  local usable_urls=()

  if prefer_cn_accel_enabled; then
    say "已启用国内加速，按顺序尝试下载源"
    for url in "$@"; do
      [ -n "$url" ] || continue
      say "尝试优先下载源：$url"
      if fetch_url "$url" "$output" && [ -s "$output" ]; then
        return 0
      fi
    done
    return 1
  fi

  say "正在测速下载源"
  for url in "$@"; do
    [ -n "$url" ] || continue
    say "检测：$url"
    speed="$(probe_download_source "$url" || true)"
    if [ -z "$speed" ]; then
      say "不可用：$url"
      continue
    fi

    say "可用：$url（${speed} B/s）"
    usable_urls+=("$url")
    if awk "BEGIN {exit !($speed > $best_speed)}"; then
      best_speed="$speed"
      best_url="$url"
    fi
  done

  if [ -n "$best_url" ]; then
    say "已选择下载源：$best_url（${best_speed} B/s）"
    if fetch_url "$best_url" "$output" && [ -s "$output" ]; then
      return 0
    fi
    say "已选下载源失败，继续尝试其他可用源。"
  fi

  for url in "${usable_urls[@]}"; do
    [ "$url" != "$best_url" ] || continue
    say "尝试备用下载源：$url"
    if fetch_url "$url" "$output" && [ -s "$output" ]; then
      return 0
    fi
  done

  say "测速源均未完成下载，改为按顺序逐个尝试。"
  for url in "$@"; do
    [ -n "$url" ] || continue
    say "尝试下载：$url"
    if fetch_url "$url" "$output" && [ -s "$output" ]; then
      return 0
    fi
  done
  return 1
}

download_geodata_asset() {
  local asset="$1" output="$2" tmp release_url size url
  local urls=()
  tmp="${WORK_DIR}/${asset}.download"
  release_url="https://github.com/${GEODATA_REPO}/releases/download/latest/${asset}"

  urls+=(
    "https://testingcf.jsdelivr.net/gh/${GEODATA_REPO}@${GEODATA_BRANCH}/${asset}"
    "https://cdn.jsdelivr.net/gh/${GEODATA_REPO}@${GEODATA_BRANCH}/${asset}"
    "https://fastly.jsdelivr.net/gh/${GEODATA_REPO}@${GEODATA_BRANCH}/${asset}"
  )
  [ -n "${GH_PROXY:-}" ] && urls+=("${GH_PROXY%/}/${release_url}")
  urls+=(
    "https://gh-proxy.com/${release_url}"
    "$release_url"
  )

  mkdir -p "$WORK_DIR" "$(dirname "$output")"
  for url in "${urls[@]}"; do
    say "尝试下载 GEO 数据：$url"
    if ! fetch_geodata_url "$url" "$tmp"; then
      say "GEO 下载源不可用，继续尝试下一个。"
      continue
    fi
    size="$(wc -c < "$tmp" 2>/dev/null || echo 0)"
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -lt "$GEODATA_MIN_BYTES" ]; then
      say "下载内容异常：${asset} 只有 ${size} 字节，继续尝试下一个源。"
      continue
    fi
    backup_file "$output"
    mv "$tmp" "$output"
    chmod 0644 "$output"
    say "GEO 数据下载完成：$asset（${size} 字节）"
    return 0
  done
  return 1
}

install_geodata_files() {
  local target_dir="${1:-$NEXUSBOX_CONFIG_DIR}" refresh="${2:-0}" asset output size
  mkdir -p "$target_dir"
  for asset in geoip.dat geosite.dat country.mmdb; do
    output="${target_dir}/${asset}"
    if [ -f "$output" ]; then
      size="$(wc -c < "$output")"
    else
      size=0
    fi
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$refresh" != "1" ] && [ "$size" -ge "$GEODATA_MIN_BYTES" ]; then
      say "保留已有 GEO 数据：$output"
      continue
    fi
    if download_geodata_asset "$asset" "$output"; then
      continue
    fi
    if [ "$size" -ge "$GEODATA_MIN_BYTES" ]; then
      say "无法更新 $asset，暂时保留已有文件。"
      continue
    fi
    die "所有下载源均无法获取 $asset，且本地没有可保留的文件。"
  done
}

setup_geodata_timer() {
  local updater="/usr/local/sbin/nexusbox-geo-update"
  local service="/etc/systemd/system/nexusbox-geo.service"
  local timer="/etc/systemd/system/nexusbox-geo.timer"

  backup_file "$updater"
  cat > "$updater" <<'EOF'
#!/usr/bin/env bash
set -u

TARGET_DIR="/opt/config"
MIN_BYTES=1048576
mkdir -p "$TARGET_DIR"

download_one() {
  local asset="$1" target="${TARGET_DIR}/$1" tmp="${TARGET_DIR}/.$1.download" url size
  local release_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${asset}"
  for url in \
    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${asset}" \
    "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${asset}" \
    "https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${asset}" \
    "https://gh-proxy.com/${release_url}" \
    "$release_url"; do
    echo "尝试更新 ${asset}：${url}"
    if ! curl -fL --connect-timeout 10 --speed-limit 1024 --speed-time 20 --retry 1 -o "$tmp" "$url"; then
      continue
    fi
    size="$(wc -c < "$tmp" 2>/dev/null || echo 0)"
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -ge "$MIN_BYTES" ]; then
      mv "$tmp" "$target"
      chmod 0644 "$target"
      echo "${asset} 更新成功（${size} 字节）"
      return 0
    fi
  done
  echo "${asset} 更新失败，保留现有文件。" >&2
  return 1
}

failed=0
for asset in geoip.dat geosite.dat country.mmdb; do
  download_one "$asset" || failed=1
done
exit "$failed"
EOF
  chmod 0755 "$updater"

  backup_file "$service"
  cat > "$service" <<EOF
[Unit]
Description=NexusBox GEO 数据多源更新
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$updater
EOF

  backup_file "$timer"
  cat > "$timer" <<'EOF'
[Unit]
Description=NexusBox GEO 数据每日更新

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now nexusbox-geo.timer >/dev/null 2>&1 || true
  say "已启用 GEO 数据多源自动更新任务。"
}

set_yaml_scalar() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}:" "$file"; then
    sed -i "s|^${key}:.*|${key}: ${value}|" "$file"
  else
    printf '\n%s: %s\n' "$key" "$value" >> "$file"
  fi
}

set_json_string_field() {
  local file="$1" key="$2" value="$3"
  [ -f "$file" ] || return 0

  if grep -q "\"${key}\"[[:space:]]*:" "$file"; then
    sed -i -E "s|(\"${key}\"[[:space:]]*:[[:space:]]*)\"[^\"]*\"|\\1\"${value}\"|" "$file"
    return 0
  fi

  local tmp="${file}.tmp.$$"
  awk -v key="$key" -v value="$value" '
    !done && /^[[:space:]]*\{/ {
      print
      print "  \"" key "\": \"" value "\","
      done=1
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

set_nexusbox_merge_mode() {
  local file="${NEXUSBOX_CONFIG_DIR}/nexusbox.json"
  [ -f "$file" ] || return 0
  backup_file "$file"
  set_json_string_field "$file" "mode" "merge"
  set_json_string_field "$file" "rule_group" "full"
  say "NexusBox 订阅模式已设置为融合，机场订阅只提供节点。"
}

detect_dns_listen_port() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^dns:/ { in_dns=1; next }
    in_dns && /^[^[:space:]]/ { in_dns=0 }
    in_dns && /^[[:space:]]*listen:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*listen:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/["'\'' ]/, "", value)
      n=split(value, parts, ":")
      if (n > 0 && parts[n] ~ /^[0-9]+$/) {
        print parts[n]
      }
      exit
    }
  ' "$file"
}

detect_redir_port() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^[[:space:]]*redir-port:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*redir-port:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/["'\'' ]/, "", value)
      if (value ~ /^[0-9]+$/) {
        print value
      }
      exit
    }
  ' "$file"
}

require_root() {
  [ "$(id -u)" = "0" ] || die "请使用 root 用户运行。"
}

detect_egress_iface() {
  local iface
  iface="$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1 || true)"
  [ -n "$iface" ] || iface="eth0"
  printf '%s' "$iface"
}

cpu_supports_amd64_v3() {
  [ "$(uname -m)" = "x86_64" ] || return 1
  local flags missing=0 f
  flags="$(awk -F: '/flags/{print " " $2 " "; exit}' /proc/cpuinfo 2>/dev/null || true)"
  for f in avx avx2 bmi1 bmi2 f16c fma lzcnt movbe osxsave; do
    case "$flags" in
      *" $f "*) ;;
      *) missing=1 ;;
    esac
  done
  [ "$missing" = "0" ]
}

missing_amd64_v3_flags() {
  local flags missing="" f
  flags="$(awk -F: '/flags/{print " " $2 " "; exit}' /proc/cpuinfo 2>/dev/null || true)"
  for f in avx avx2 bmi1 bmi2 f16c fma lzcnt movbe osxsave; do
    case "$flags" in
      *" $f "*) ;;
      *) missing="${missing}${missing:+ }${f}" ;;
    esac
  done
  printf '%s' "$missing"
}

choose_asset() {
  local arch missing_flags
  arch="$(uname -m)"
  say "CPU 检测：架构=$arch"
  case "$arch" in
    x86_64)
      if cpu_supports_amd64_v3; then
        say "CPU 支持 amd64-v3：是"
        CORE_KIND="amd64-v3"
        ASSET="mihomo-linux-amd64-v3-${VERSION}.gz"
      else
        missing_flags="$(missing_amd64_v3_flags)"
        if [ -n "$missing_flags" ]; then
          say "CPU 支持 amd64-v3：否；缺少指令：$missing_flags"
        else
          say "CPU 支持 amd64-v3：否"
        fi
        CORE_KIND="amd64-compatible"
        ASSET="mihomo-linux-amd64-compatible-${VERSION}.gz"
      fi
      ;;
    aarch64|arm64)
      say "当前架构 $arch 不适用 amd64-v3 检测"
      CORE_KIND="arm64"
      ASSET="mihomo-linux-arm64-${VERSION}.gz"
      ;;
    *)
      die "不支持的 CPU 架构：$arch"
      ;;
  esac
  say "已选择核心：$CORE_KIND（$ASSET）"
}

download_file() {
  local asset="$1"
  local output="$2"
  local raw_url="${BASE_URL}/${asset}"
  local urls=()

  if [ -n "${GH_PROXY:-}" ]; then
    urls+=("${GH_PROXY%/}/${raw_url}")
  fi

  if prefer_cn_accel_enabled; then
    urls+=(
      "https://gh-proxy.com/${raw_url}"
      "https://gh.llkk.cc/${raw_url}"
      "https://mirror.ghproxy.com/${raw_url}"
      "$raw_url"
    )
  else
    urls+=(
      "$raw_url"
      "https://gh.llkk.cc/${raw_url}"
      "https://gh-proxy.com/${raw_url}"
      "https://mirror.ghproxy.com/${raw_url}"
    )
  fi

  say "正在下载：$asset"
  download_best_url "$output" "${urls[@]}" && return 0
  die "下载失败，可设置 GH_PROXY=<GitHub加速地址> 后重试。"
}

download_url_with_fallback() {
  local url="$1" output="$2"
  local urls=()

  [ -n "${GH_PROXY:-}" ] && urls+=("${GH_PROXY%/}/${url}")
  if prefer_cn_accel_enabled; then
    urls+=("https://gh-proxy.com/${url}" "https://gh.llkk.cc/${url}" "https://mirror.ghproxy.com/${url}" "$url")
  else
    urls+=("$url" "https://gh.llkk.cc/${url}" "https://gh-proxy.com/${url}" "https://mirror.ghproxy.com/${url}")
  fi

  download_best_url "$output" "${urls[@]}"
}

resolve_mihomo_version() {
  case "$VERSION" in
    latest|auto|current)
      local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
      local tmp="$WORK_DIR/mihomo-latest.json"
      local url latest urls=()

      [ -n "${GH_PROXY:-}" ] && urls+=("${GH_PROXY%/}/${api}")
      if prefer_cn_accel_enabled; then
        urls+=(
          "https://gh-proxy.com/${api}"
          "https://gh.llkk.cc/${api}"
          "https://mirror.ghproxy.com/${api}"
          "$api"
        )
      else
        urls+=(
          "$api"
          "https://gh.llkk.cc/${api}"
          "https://gh-proxy.com/${api}"
          "https://mirror.ghproxy.com/${api}"
        )
      fi

      say "正在获取 Mihomo 最新版本"
      if download_best_url "$tmp" "${urls[@]}"; then
        latest="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | head -1)"
        if [ -n "$latest" ]; then
          VERSION="$latest"
          say "Mihomo 最新版本：$VERSION"
        fi
      fi

      if [ -z "$latest" ]; then
        say "无法从已选下载源解析版本信息，按顺序尝试 API 地址。"
        for url in "${urls[@]}"; do
          [ -n "$url" ] || continue
          say "尝试版本 API：$url"
          fetch_url "$url" "$tmp" || continue
          latest="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" | head -1)"
          if [ -n "$latest" ]; then
            VERSION="$latest"
            say "Mihomo 最新版本：$VERSION"
            break
          fi
        done
      fi

      case "$VERSION" in
        latest|auto|current)
          VERSION="$MIHOMO_FALLBACK_VERSION"
          say "无法获取 Mihomo 最新版本，使用兜底版本：$VERSION"
          ;;
      esac
      ;;
  esac

  [ -n "$BASE_URL" ] || BASE_URL="https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}"
}

import_config_from_url() {
  local target="$1" profile="$2"
  [ -n "$CONFIG_URL" ] || return 0
  [ "$CONFIG_URL" != "off" ] && [ "$CONFIG_URL" != "none" ] && [ "$CONFIG_URL" != "0" ] || return 0

  local downloaded="$WORK_DIR/config.yaml"
  say "正在为 $profile 导入配置文件"
  download_url_with_fallback "$CONFIG_URL" "$downloaded" || die "下载 CONFIG_URL 失败。"
  [ -s "$downloaded" ] || die "下载的 CONFIG_URL 内容为空。"

  mkdir -p "$(dirname "$target")"
  backup_file "$target"
  cp "$downloaded" "$target"

  set_yaml_scalar "$target" "mixed-port" "7890"
  set_yaml_scalar "$target" "allow-lan" "true"
  set_yaml_scalar "$target" "external-controller" "'0.0.0.0:9090'"
  if [ "$profile" = "nexusbox" ]; then
    set_yaml_scalar "$target" "external-controller-unix" "'/opt/nexusbox/var/core.sock'"
    set_yaml_scalar "$target" "external-ui" "ui/meta"
    set_nexusbox_merge_mode
  fi
}

download_nexusbox_installer() {
  local output="$1"
  local url urls=()

  if [ -n "${NEXUSBOX_INSTALL_URL:-}" ] && [ "$NEXUSBOX_INSTALL_URL" != "$NEXUSBOX_DEFAULT_INSTALL_URL" ]; then
    urls+=("$NEXUSBOX_INSTALL_URL")
  fi
  if prefer_cn_accel_enabled; then
    urls+=(
      "https://gh-proxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
      "https://gh.llkk.cc/${NEXUSBOX_DEFAULT_INSTALL_URL}"
      "https://mirror.ghproxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
      "https://cdn.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "https://fastly.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "https://testingcf.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "$NEXUSBOX_DEFAULT_INSTALL_URL"
    )
  else
    urls+=(
      "$NEXUSBOX_DEFAULT_INSTALL_URL"
      "https://cdn.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "https://fastly.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "https://testingcf.jsdelivr.net/gh/Ladavian/NexusBox@main/install.sh"
      "https://gh.llkk.cc/${NEXUSBOX_DEFAULT_INSTALL_URL}"
      "https://gh-proxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
      "https://mirror.ghproxy.com/${NEXUSBOX_DEFAULT_INSTALL_URL}"
    )
  fi

  say "正在下载 NexusBox 安装脚本"
  download_best_url "$output" "${urls[@]}" && return 0
  die "NexusBox 安装脚本下载失败，可设置 NEXUSBOX_INSTALL_URL=<地址> 后重试。"
}

nexusbox_binary_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) return 1 ;;
  esac
}

nexusbox_expected_sha256() {
  case "$1" in
    amd64) echo "24e726dbb12cffd3bf49ea487c1a05da9207de57120347161abb9c9bb877c449" ;;
    arm64) echo "1aac5dba4dce74736c5c0ceae71f7f8c5fca17fafb0756461405d2bb4dea1ff2" ;;
    *) return 1 ;;
  esac
}

file_sha256() {
  local file="$1"
  if have sha256sum; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif have openssl; then
    openssl dgst -sha256 -r "$file" | awk '{print tolower($1)}'
  else
    return 1
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual
  [ -n "$expected" ] || return 0
  actual="$(file_sha256 "$file" || true)"
  [ -n "$actual" ] || die "缺少 sha256sum/openssl，无法验证 SHA256。"
  expected="$(printf '%s' "$expected" | tr 'A-F' 'a-f')"
  [ "$actual" = "$expected" ] || die "$file 的 SHA256 不匹配，预期=$expected，实际=$actual"
}

download_patched_nexusbox_binary() {
  local output="$1" arch asset raw_url expected urls=()
  arch="$(nexusbox_binary_arch)" || {
    say "没有适用于 $(uname -m) 的 NexusBox 修补版二进制。"
    return 1
  }
  asset="nexusbox-linux-${arch}"
  raw_url="${NEXUSBOX_PATCHED_BASE%/}/${asset}"

  if [ -n "$NEXUSBOX_PATCHED_URL" ]; then
    urls+=("$NEXUSBOX_PATCHED_URL")
    expected="$NEXUSBOX_PATCHED_SHA256"
  else
    expected="${NEXUSBOX_PATCHED_SHA256:-$(nexusbox_expected_sha256 "$arch")}"
  fi

  if prefer_cn_accel_enabled; then
    urls+=(
      "https://gh-proxy.com/${raw_url}"
      "https://gh.llkk.cc/${raw_url}"
      "https://mirror.ghproxy.com/${raw_url}"
      "https://cdn.jsdelivr.net/gh/${NEXUSBOX_PATCHED_REPO}@${NEXUSBOX_PATCHED_REF}/bin/${asset}"
      "https://fastly.jsdelivr.net/gh/${NEXUSBOX_PATCHED_REPO}@${NEXUSBOX_PATCHED_REF}/bin/${asset}"
      "$raw_url"
    )
  else
    urls+=(
      "$raw_url"
      "https://cdn.jsdelivr.net/gh/${NEXUSBOX_PATCHED_REPO}@${NEXUSBOX_PATCHED_REF}/bin/${asset}"
      "https://fastly.jsdelivr.net/gh/${NEXUSBOX_PATCHED_REPO}@${NEXUSBOX_PATCHED_REF}/bin/${asset}"
      "https://gh.llkk.cc/${raw_url}"
      "https://gh-proxy.com/${raw_url}"
      "https://mirror.ghproxy.com/${raw_url}"
    )
  fi

  say "正在下载 NexusBox 修补版（$arch）"
  download_best_url "$output" "${urls[@]}" || return 1
  verify_sha256 "$output" "$expected"
  chmod 0755 "$output"
}

install_patched_nexusbox_binary() {
  case "$NEXUSBOX_PATCHED_ENABLE" in
    0|false|no|off)
      say "已通过 NEXUSBOX_PATCHED_ENABLE=$NEXUSBOX_PATCHED_ENABLE 关闭 NexusBox 修补版。"
      return 0
      ;;
  esac

  local patched="$WORK_DIR/nexusbox-patched"
  download_patched_nexusbox_binary "$patched" || die "NexusBox 修补版下载失败。只有明确接受 Mihomo 热重载兼容问题时，才应设置 NEXUSBOX_PATCHED_ENABLE=0。"
  backup_file "$NEXUSBOX_BIN"
  cp "$patched" "$NEXUSBOX_BIN"
  chmod 0755 "$NEXUSBOX_BIN"
  say "已安装 NexusBox 修补版：$NEXUSBOX_BIN"
}

patch_nexusbox_installer() {
  local file="$1"
  [ -f "$file" ] || return 0

  if grep -q '^ install_mihomo$' "$file"; then
    sed -i '/^ install_mihomo$/c\ msg "跳过 NexusBox 自带的 Mihomo 下载；随后将安装与 CPU 匹配的核心。"' "$file"
  fi

  if grep -q '^ install_geo$' "$file"; then
    sed -i '/^ install_geo$/c\ msg "GEO 数据已由 pve-lxc-mihomo 多源下载完成。"' "$file"
  fi

  if grep -q '^ setup_geo_timer$' "$file"; then
    sed -i '/^ setup_geo_timer$/c\ msg "GEO 自动更新将由 pve-lxc-mihomo 配置。"' "$file"
  fi

  if grep -q '是否立即启动 NexusBox' "$file"; then
    sed -i 's/read -rp "是否立即启动 NexusBox？\[Y\/n\] " START/START="${NEXUSBOX_AUTO_START:-N}"/' "$file"
  fi
}

apt_install_if_missing() {
  local pkgs=()
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      pkgs+=("$p")
    fi
  done
  [ "${#pkgs[@]}" -gt 0 ] || return 0

  say "正在安装依赖：${pkgs[*]}"
  export http_proxy="${http_proxy:-}"
  export https_proxy="${https_proxy:-}"
  export HTTP_PROXY="${HTTP_PROXY:-}"
  export HTTPS_PROXY="${HTTPS_PROXY:-}"

  if ! apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false update; then
    say "不使用代理执行 apt update 失败，改用当前代理环境重试。"
    apt-get update
  fi
  apt-get -o Acquire::http::Proxy=false -o Acquire::https::Proxy=false install -y "${pkgs[@]}" || apt-get install -y "${pkgs[@]}"
}

prepare_core_binary() {
  resolve_mihomo_version
  choose_asset
  mkdir -p "$WORK_DIR"
  download_file "$ASSET" "$WORK_DIR/mihomo.gz"
  gzip -dc "$WORK_DIR/mihomo.gz" > "$WORK_DIR/mihomo"
  chmod 0755 "$WORK_DIR/mihomo"
  "$WORK_DIR/mihomo" -v
}

write_rc_local_nat() {
  local iface="$1" dns_port="${2:-}" redir_port="${3:-}"
  say "正在为出口网卡 $iface 配置 rc.local NAT"
  backup_file /etc/rc.local
  cat > /etc/rc.local <<EOF
#!/bin/sh -e
echo 1 >/proc/sys/net/ipv4/ip_forward
iptables -t nat -C POSTROUTING -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o ${iface} -j MASQUERADE
if [ -n "${dns_port}" ] && [ "${dns_port}" != "53" ]; then
  iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${dns_port} 2>/dev/null || iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-ports ${dns_port}
  iptables -t nat -C PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports ${dns_port} 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports ${dns_port}
fi
if [ -n "${redir_port}" ]; then
  iptables -t nat -N MIHOMO_REDIRECT 2>/dev/null || true
  iptables -t nat -F MIHOMO_REDIRECT
  for cidr in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
    iptables -t nat -A MIHOMO_REDIRECT -d \$cidr -j RETURN
  done
  iptables -t nat -A MIHOMO_REDIRECT -p tcp -j REDIRECT --to-ports ${redir_port}
  iptables -t nat -C PREROUTING -p tcp -j MIHOMO_REDIRECT 2>/dev/null || iptables -t nat -A PREROUTING -p tcp -j MIHOMO_REDIRECT
fi
exit 0
EOF
  chmod +x /etc/rc.local
  /etc/rc.local
}

port_listening() {
  local port="$1"
  ss -lntup 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"
}

wait_for_port() {
  local port="$1" name="$2"
  for _ in $(seq 1 20); do
    if port_listening "$port"; then
      say "端口验证正常：$name（$port）"
      return 0
    fi
    sleep 1
  done
  die "$name 未监听端口 $port。"
}

verify_dns_runtime() {
  local config_file="$1" dns_port
  dns_port="$(detect_dns_listen_port "$config_file" || true)"
  [ -n "$dns_port" ] || {
    say "$config_file 中未找到 dns.listen，跳过 DNS 端口验证"
    return 0
  }

  wait_for_port "$dns_port" "Mihomo DNS 服务"
  if [ "$dns_port" != "53" ]; then
    iptables -t nat -S PREROUTING 2>/dev/null | grep -Eq -- "--dport 53 .*--to-ports ${dns_port}" || die "缺少 DNS 转发规则 53 -> ${dns_port}。"
    say "DNS 转发验证正常：53 -> ${dns_port}"
  fi
}

verify_transparent_runtime() {
  local config_file="$1" redir_port
  redir_port="$(detect_redir_port "$config_file" || true)"
  [ -n "$redir_port" ] || {
    say "$config_file 中未找到 redir-port，跳过透明代理验证"
    return 0
  }

  wait_for_port "$redir_port" "Mihomo TCP 透明代理"
  iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "-j MIHOMO_REDIRECT" || die "缺少 TCP 透明代理 PREROUTING 规则。"
  iptables -t nat -S MIHOMO_REDIRECT 2>/dev/null | grep -Eq -- "--to-ports ${redir_port}" || die "缺少 TCP 透明代理目标端口 ${redir_port}。"
  say "TCP 透明代理验证正常：PREROUTING -> ${redir_port}"
}

reload_nexusbox_core_direct() {
  local config_file="${1:-${NEXUSBOX_CONFIG_DIR}/config.yaml}"
  local socket="/opt/nexusbox/var/core.sock"
  local body
  body="$(printf '{"path":"%s","payload":""}' "$config_file")"

  for _ in $(seq 1 20); do
    [ -S "$socket" ] && break
    sleep 1
  done
  [ -S "$socket" ] || die "缺少 Mihomo 控制接口套接字：$socket"

  curl -fsS --unix-socket "$socket" \
    -X PUT "http://localhost/configs?force=true" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null || die "通过 $socket 重载 Mihomo 配置失败。"
  say "Mihomo 配置热重载接口验证正常"
}

json_string_value() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 0
  sed -n -E "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -1
}

verify_nexusbox_hot_reload_api() {
  local config_json="${NEXUSBOX_CONFIG_DIR}/nexusbox.json"
  local user pass cookie
  user="$(json_string_value "$config_json" "username")"
  pass="$(json_string_value "$config_json" "password")"
  if [ -z "$user" ] || [ -z "$pass" ]; then
    say "无法从 $config_json 读取 NexusBox 登录信息，跳过 UI 热重载验证。"
    return 0
  fi
  case "${user}${pass}" in
    *[!A-Za-z0-9._@-]*)
      say "NexusBox 登录信息包含特殊字符，跳过 UI 热重载验证。"
      return 0
      ;;
  esac

  cookie="$WORK_DIR/nexusbox-cookie.txt"
  curl -fsS -c "$cookie" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}" \
    "http://127.0.0.1:18080/login" >/dev/null || {
      say "无法在本机登录 NexusBox，跳过 UI 热重载验证。"
      return 0
    }

  curl -fsS -b "$cookie" -X PUT "http://127.0.0.1:18080/configs" >/dev/null || die "NexusBox UI 热重载接口失败，通常表示 NexusBox 二进制未兼容当前 Mihomo。"
  say "NexusBox UI 热重载接口验证正常"
}

verify_standalone_running() {
  say "正在验证纯 Mihomo 运行状态"
  if have systemctl; then
    systemctl is-active --quiet mihomo || {
      systemctl status mihomo --no-pager || true
      die "mihomo.service 未运行。"
    }
  fi
  pgrep -f "${MIHOMO_BIN} -d ${CONFIG_DIR}" >/dev/null || die "未找到 Mihomo 进程。"
  wait_for_port 7890 "Mihomo HTTP/SOCKS 代理"
  wait_for_port 9090 "Mihomo 控制接口"
  verify_dns_runtime "$CONFIG_FILE"
  verify_transparent_runtime "$CONFIG_FILE"
}

verify_nexusbox_running() {
  say "正在验证 NexusBox 运行状态"
  pgrep -f "$NEXUSBOX_BIN" >/dev/null || die "未找到 NexusBox 进程。"
  wait_for_port 18080 "NexusBox 管理页面"
  wait_for_port 7890 "Mihomo HTTP/SOCKS 代理"
  wait_for_port 9090 "Mihomo 控制接口"
  reload_nexusbox_core_direct "${NEXUSBOX_CONFIG_DIR}/config.yaml"
  verify_nexusbox_hot_reload_api
  verify_dns_runtime "${NEXUSBOX_CONFIG_DIR}/config.yaml"
  verify_transparent_runtime "${NEXUSBOX_CONFIG_DIR}/config.yaml"
}

install_standalone_mihomo() {
  say "安装模式：纯 Mihomo 旁路由"
  INSTALL_PROFILE="standalone"
  apt_install_if_missing ca-certificates gzip iproute2 iptables procps
  prepare_core_binary

  mkdir -p "$(dirname "$MIHOMO_BIN")" "$CONFIG_DIR"
  backup_file "$MIHOMO_BIN"
  cp "$WORK_DIR/mihomo" "$MIHOMO_BIN"
  chmod 0755 "$MIHOMO_BIN"

  if [ ! -e "$CONFIG_FILE" ]; then
    cat > "$CONFIG_FILE" <<'EOF'
mixed-port: 7890
allow-lan: true
bind-address: "*"
mode: rule
log-level: info
external-controller: 0.0.0.0:9090
ipv6: false

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - 223.5.5.5
    - 119.29.29.29

proxies: []
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
rules:
  - MATCH,DIRECT
EOF
  else
    say "保留现有配置：$CONFIG_FILE"
  fi
  import_config_from_url "$CONFIG_FILE" "standalone"

  "$MIHOMO_BIN" -t -d "$CONFIG_DIR"

  backup_file /etc/systemd/system/mihomo.service
  cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=Mihomo Proxy Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
LimitNOFILE=1048576
ExecStart=${MIHOMO_BIN} -d ${CONFIG_DIR}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mihomo
  write_rc_local_nat "$(detect_egress_iface)" "$(detect_dns_listen_port "$CONFIG_FILE" || true)" "$(detect_redir_port "$CONFIG_FILE" || true)"
  verify_standalone_running
}

restart_nexusbox() {
  say "正在重启 NexusBox"
  if have systemctl && systemctl list-unit-files | grep -q '^nexusbox\.service'; then
    systemctl restart nexusbox || true
  else
    pkill -f '^/opt/nexusbox/nexusbox$' 2>/dev/null || true
    nohup "$NEXUSBOX_BIN" >/opt/nexusbox/var/info.log 2>&1 &
  fi
  sleep 3
}

stop_nexusbox_for_core_replace() {
  say "替换 Mihomo 核心前停止 NexusBox"
  if have systemctl && systemctl list-unit-files | grep -q '^nexusbox\.service'; then
    systemctl stop nexusbox || true
  fi
  pkill -f '^/opt/nexusbox/nexusbox$' 2>/dev/null || true
  pkill -f "${NEXUSBOX_CORE} -d ${NEXUSBOX_CONFIG_DIR}" 2>/dev/null || true
  for _ in $(seq 1 10); do
    if ! pgrep -f "${NEXUSBOX_CORE}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  say "Mihomo 核心进程仍然存在，将继续尝试替换。"
}

fix_nexusbox_core() {
  say "安装模式：自动修复 NexusBox 核心"
  INSTALL_PROFILE="nexusbox"
  [ -x "$NEXUSBOX_BIN" ] || die "找不到 NexusBox 程序：$NEXUSBOX_BIN"
  apt_install_if_missing ca-certificates curl gzip iproute2 iptables procps
  prepare_core_binary

  mkdir -p "$(dirname "$NEXUSBOX_CORE")" /opt/nexusbox/var
  stop_nexusbox_for_core_replace
  install_patched_nexusbox_binary
  backup_file "$NEXUSBOX_CORE"
  cp "$WORK_DIR/mihomo" "$NEXUSBOX_CORE"
  chmod 0755 "$NEXUSBOX_CORE"

  import_config_from_url "${NEXUSBOX_CONFIG_DIR}/config.yaml" "nexusbox"
  install_geodata_files "$NEXUSBOX_CONFIG_DIR" 1
  setup_geodata_timer

  "$NEXUSBOX_CORE" -v
  "$NEXUSBOX_CORE" -t -d "$NEXUSBOX_CONFIG_DIR"

  write_rc_local_nat "$(detect_egress_iface)" "$(detect_dns_listen_port "${NEXUSBOX_CONFIG_DIR}/config.yaml" || true)" "$(detect_redir_port "${NEXUSBOX_CONFIG_DIR}/config.yaml" || true)"
  restart_nexusbox

  reload_nexusbox_core_direct "${NEXUSBOX_CONFIG_DIR}/config.yaml"
  verify_nexusbox_running
}

install_nexusbox_from_url() {
  say "安装模式：安装 NexusBox 管理页面并修复 Mihomo 核心"
  apt_install_if_missing ca-certificates curl gzip iproute2 iptables procps

  local nexusbox_installer="$WORK_DIR/nexusbox-install.sh"
  download_nexusbox_installer "$nexusbox_installer"
  patch_nexusbox_installer "$nexusbox_installer"
  chmod 0755 "$nexusbox_installer"
  printf '\n' | bash "$nexusbox_installer"

  [ -x "$NEXUSBOX_BIN" ] || die "NexusBox 安装脚本已结束，但未找到 $NEXUSBOX_BIN。"
  fix_nexusbox_core
}

print_report() {
  say "安装完成报告"
  echo "CPU 架构：$(uname -m)"
  echo "核心类型：${CORE_KIND:-未知}"
  echo "安装类型：${INSTALL_PROFILE:-未知}"
  echo "出口网卡：$(detect_egress_iface)"
  echo "IPv4 转发：$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || true)"
  echo
  echo "NAT 规则："
  iptables -t nat -S POSTROUTING 2>/dev/null || true
  echo
  echo "运行进程："
  ps -ef | grep -Ei 'nexusbox|mihomo|clash|sing-box' | grep -v grep || true
  echo
  echo "监听端口："
  ss -lntup 2>/dev/null | grep -E '(:7877|:7890|:7896|:7898|:9090|:1053|:6666|:18080)' || true
  echo
  if [ -d /opt/nexusbox/var ]; then
    echo "NexusBox 运行目录："
    ls -la /opt/nexusbox/var
  fi
  echo
  echo "安装日志：$LOG"
}

main() {
  require_root
  say "Mihomo 旁路由安装脚本已启动"
  say "版本=$VERSION，模式=$MODE"

  case "$MODE" in
    auto)
      if [ -x "$NEXUSBOX_BIN" ]; then
        fix_nexusbox_core
      else
        install_standalone_mihomo
      fi
      ;;
    nexusbox)
      fix_nexusbox_core
      ;;
    nexusbox-install)
      install_nexusbox_from_url
      ;;
    standalone)
      install_standalone_mihomo
      ;;
    *)
      die "未知 MODE=$MODE，请使用 auto、nexusbox、nexusbox-install 或 standalone。"
      ;;
  esac

  print_report
  say "全部完成"
}

main "$@"
