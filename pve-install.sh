#!/usr/bin/env bash
set -Eeuo pipefail

# Run this on the Proxmox VE host. It automates stages 1-4:
# 1. Create Debian LXC.
# 2. Configure privileged LXC, TUN, forwarding and Zashboard.
# 3. Install NexusBox and the CPU-compatible Mihomo core.
# 4. Configure KDocs MASQUERADE firewall and rc.local inside LXC.

REPO="${REPO:-czerov/pve-lxc-mihomo}"
BRANCH="${BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${BRANCH}}"
INSTALL_URL="${INSTALL_URL:-${RAW_BASE}/install.sh}"
PROXY_URL="${PROXY_URL:-${RAW_BASE}/proxy.sh}"
GH_PROXY="${GH_PROXY:-}"
PREFER_CN_ACCEL="${PREFER_CN_ACCEL:-0}"
DOWNLOAD_SPEED_LIMIT="${DOWNLOAD_SPEED_LIMIT:-1024}"
DOWNLOAD_SPEED_TIME="${DOWNLOAD_SPEED_TIME:-30}"

if [ "${CTID+x}" = "x" ]; then
  CTID_WAS_SET=1
else
  CTID_WAS_SET=0
fi
CTID="${CTID:-109}"
AUTO_CTID="${AUTO_CTID:-auto}"
USE_EXISTING="${USE_EXISTING:-0}"
EXISTING_CTID="${EXISTING_CTID:-}"
[ -n "$EXISTING_CTID" ] && { CTID="$EXISTING_CTID"; USE_EXISTING=1; }
CT_HOSTNAME="${CT_HOSTNAME:-mihomo-router}"
CT_IP_CIDR="${CT_IP_CIDR:-}"
CT_GW="${CT_GW:-}"
CT_BRIDGE="${CT_BRIDGE:-}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_SWAP="${CT_SWAP:-0}"
CT_DISK_SIZE="${CT_DISK_SIZE:-8}"
CT_ROOTFS_STORAGE="${CT_ROOTFS_STORAGE:-}"
CT_TEMPLATE_STORAGE="${CT_TEMPLATE_STORAGE:-local}"
CT_TEMPLATE_NAME="${CT_TEMPLATE_NAME:-debian-13-standard_13.1-2_amd64.tar.zst}"
TEMPLATE_MIRROR="${TEMPLATE_MIRROR:-auto}"
TEMPLATE_URL="${TEMPLATE_URL:-}"
CT_PASSWORD="${CT_PASSWORD:-}"
CT_DNS="${CT_DNS:-223.5.5.5}"
if [ "${LXC_INSTALL_MODE+x}" = "x" ]; then
  LXC_INSTALL_MODE_WAS_SET=1
else
  LXC_INSTALL_MODE_WAS_SET=0
fi
LXC_INSTALL_MODE="${LXC_INSTALL_MODE:-auto}"
if [ "${ROUTING_MODE+x}" = "x" ]; then
  ROUTING_MODE_WAS_SET=1
else
  ROUTING_MODE_WAS_SET=0
fi
ROUTING_MODE="${ROUTING_MODE:-kdocs}"
VERSION="${VERSION:-latest}"
LXC_PROXY="${LXC_PROXY:-off}"
LXC_PROXY_ADDR="${LXC_PROXY_ADDR:-}"
LXC_PROXY_PORT="${LXC_PROXY_PORT:-7897}"
LXC_PROXY_COMMON_PORTS="${LXC_PROXY_COMMON_PORTS:-7897 7890 7891 7892 7893 7895 7896 7899 1080 10808 10809 20170 20171}"
LXC_PROXY_HTTP=""
INSTALL_PROFILE="unknown"
INTERACTIVE="${INTERACTIVE:-auto}"
NEXUSBOX_DEFAULT_INSTALL_URL="${NEXUSBOX_DEFAULT_INSTALL_URL:-https://raw.githubusercontent.com/Ladavian/NexusBox/main/install.sh}"
NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-}"
NEXUSBOX_PATCHED_ENABLE="${NEXUSBOX_PATCHED_ENABLE:-1}"
NEXUSBOX_PATCHED_BASE="${NEXUSBOX_PATCHED_BASE:-}"
NEXUSBOX_PATCHED_REF="${NEXUSBOX_PATCHED_REF:-}"
NEXUSBOX_PATCHED_URL="${NEXUSBOX_PATCHED_URL:-}"
NEXUSBOX_PATCHED_SHA256="${NEXUSBOX_PATCHED_SHA256:-}"
DEFAULT_CONFIG_URL="${DEFAULT_CONFIG_URL:-${RAW_BASE}/config.yaml}"
CONFIG_URL="${CONFIG_URL:-$DEFAULT_CONFIG_URL}"
ZASHBOARD_URL="${ZASHBOARD_URL:-https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip}"

WORK_DIR="${WORK_DIR:-/tmp/pve-mihomo-router}"
LOG="${LOG:-/root/pve-mihomo-router-install.log}"
mkdir -p "$WORK_DIR"
exec > >(tee -a "$LOG") 2>&1

say() { printf '\n[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { say "错误：$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

validate_routing_mode() {
  case "$ROUTING_MODE" in
    kdocs|gateway) ;;
    *) die "未知 ROUTING_MODE=$ROUTING_MODE，请使用 kdocs 或 gateway。" ;;
  esac
}

prefer_cn_accel_enabled() {
  case "$PREFER_CN_ACCEL" in
    1|true|yes|on|cn) return 0 ;;
    *) return 1 ;;
  esac
}

backup_file() {
  local path="$1" ts
  ts="$(date +%Y%m%d-%H%M%S)"
  if [ -e "$path" ]; then
    cp -a "$path" "${path}.bak-${ts}"
    say "已备份：$path -> ${path}.bak-${ts}"
  fi
}

fetch_url() {
  local url="$1" output="$2"
  curl -fL --connect-timeout 20 --speed-limit "$DOWNLOAD_SPEED_LIMIT" --speed-time "$DOWNLOAD_SPEED_TIME" --retry 2 -o "$output" "$url"
}

probe_download_source() {
  local url="$1" speed
  speed="$(curl -fL --range 0-65535 --connect-timeout 8 --max-time 15 -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || true)"
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

require_pve_host() {
  [ "$(id -u)" = "0" ] || die "请在 PVE 宿主机使用 root 用户运行。"
  if ! have pct; then
    if systemd-detect-virt --container >/dev/null 2>&1 || [ -f /run/.containerenv ]; then
      die "当前环境像是 LXC 容器且找不到 pct。请在 PVE 宿主机运行 pve-install.sh；若只修复容器内部，请使用 install-cn.sh。"
    fi
    die "找不到 pct，请在 Proxmox VE 宿主机运行。"
  fi
  have pveam || die "找不到 pveam，请在 Proxmox VE 宿主机运行。"
  have curl || die "找不到 curl，请先在 PVE 宿主机安装 curl。"
}

is_interactive() {
  [ "$INTERACTIVE" != "0" ] && [ "$INTERACTIVE" != "false" ] && [ -t 0 ]
}

prompt_choices() {
  if ! is_interactive; then
    if [ "$LXC_INSTALL_MODE_WAS_SET" = "0" ] && [ "$LXC_INSTALL_MODE" = "auto" ]; then
      LXC_INSTALL_MODE="nexusbox-install"
    fi
    return 0
  fi

  if [ "$LXC_INSTALL_MODE" = "auto" ] && [ -z "$NEXUSBOX_INSTALL_URL" ]; then
    echo
    echo "安装模式："
    echo "  1) 纯 Mihomo 旁路由（不安装 NexusBox UI / 不开放 18080）"
    echo "  2) 自动判断：已有 NexusBox 就修复核心，否则安装纯 Mihomo"
    echo "  3) 只修复已有 NexusBox 的 Mihomo 核心"
    echo "  4) 新建/准备 LXC 后，从安装脚本安装 NexusBox UI，再自动安装适配的 Mihomo 核心"
    printf "请选择 [1-4，默认 4]: "
    read -r install_choice
    case "${install_choice:-4}" in
      1) LXC_INSTALL_MODE="standalone" ;;
      2) LXC_INSTALL_MODE="auto" ;;
      3) LXC_INSTALL_MODE="nexusbox" ;;
      4)
        LXC_INSTALL_MODE="nexusbox-install"
        if [ -z "$NEXUSBOX_INSTALL_URL" ]; then
          printf "NexusBox 安装脚本地址 [默认: %s]: " "$NEXUSBOX_DEFAULT_INSTALL_URL"
          read -r NEXUSBOX_INSTALL_URL
        fi
        NEXUSBOX_INSTALL_URL="${NEXUSBOX_INSTALL_URL:-$NEXUSBOX_DEFAULT_INSTALL_URL}"
        ;;
      *) die "无效安装模式选择: $install_choice" ;;
    esac
  fi

  if [ "$ROUTING_MODE_WAS_SET" = "0" ]; then
    echo
    echo "路由架构："
    echo "  1) KDocs 高性能模式（默认）：原网关不变，DNS 指向 LXC，主路由添加 198.18.0.0/16 静态路由"
    echo "  2) 完整网关模式：客户端网关和 DNS 都指向 LXC"
    echo "  注意：KDocs 模式无法接管 Telegram 固定 DC IP、IPv6 和部分 UDP。"
    printf "请选择 [1-2，默认 1]: "
    read -r routing_choice
    case "${routing_choice:-1}" in
      1) ROUTING_MODE="kdocs" ;;
      2) ROUTING_MODE="gateway" ;;
      *) die "无效路由架构选择: $routing_choice" ;;
    esac
  fi

  if [ "$LXC_PROXY" = "off" ]; then
    echo
    echo "LXC 安装代理："
    echo "  1) 关闭"
    echo "  2) 自动检测 PVE/PC/局域网可用代理"
    echo "  3) 手动输入代理地址"
    printf "请选择 [1-3，默认 1]: "
    read -r proxy_choice
    case "${proxy_choice:-1}" in
      1) LXC_PROXY="off" ;;
      2) LXC_PROXY="auto" ;;
      3)
        LXC_PROXY="on"
        printf "代理地址，例如 192.168.1.100:7897: "
        read -r LXC_PROXY_ADDR
        [ -n "$LXC_PROXY_ADDR" ] || die "手动代理模式必须填写 LXC_PROXY_ADDR。"
        ;;
      *) die "无效代理选择: $proxy_choice" ;;
    esac
  fi

  say "已选择安装模式: $LXC_INSTALL_MODE"
  say "已选择路由模式: $ROUTING_MODE"
  say "已选择 LXC 代理模式: $LXC_PROXY"
}

detect_storage() {
  if [ -z "$CT_ROOTFS_STORAGE" ]; then
    if pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq 'local-lvm'; then
      CT_ROOTFS_STORAGE="local-lvm"
    elif pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq 'local'; then
      CT_ROOTFS_STORAGE="local"
    else
      die "无法自动检测 LXC 根磁盘存储，请手动设置 CT_ROOTFS_STORAGE。"
    fi
  elif ! pvesm status 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$CT_ROOTFS_STORAGE"; then
    die "存储 '$CT_ROOTFS_STORAGE' 不存在，请检查 pvesm status 或重新设置 CT_ROOTFS_STORAGE。"
  fi
  say "使用 LXC 根磁盘存储：$CT_ROOTFS_STORAGE"
}

vmid_exists() {
  local vmid="$1"
  pct status "$vmid" >/dev/null 2>&1 && return 0
  have qm && qm status "$vmid" >/dev/null 2>&1 && return 0
  [ -e "/etc/pve/lxc/${vmid}.conf" ] && return 0
  [ -e "/etc/pve/qemu-server/${vmid}.conf" ] && return 0
  return 1
}

auto_ctid_enabled() {
  case "$AUTO_CTID" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    auto|"") [ "$CTID_WAS_SET" != "1" ] ;;
    *) die "AUTO_CTID=$AUTO_CTID 无效，请使用 auto、1 或 0。" ;;
  esac
}

find_free_ctid() {
  local start="$1" candidate
  case "$start" in
    ''|*[!0-9]*) die "自动选择 CTID 时起始值必须是数字：$start" ;;
  esac

  candidate="$((10#$start))"
  while [ "$candidate" -le 999999 ]; do
    if ! vmid_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    candidate="$((candidate + 1))"
  done
  return 1
}

confirm_new_ctid() {
  case "$CTID" in
    ''|*[!0-9]*) die "CTID 必须是数字：$CTID" ;;
  esac

  if vmid_exists "$CTID"; then
    if auto_ctid_enabled; then
      local old_ctid="$CTID"
      CTID="$(find_free_ctid "$((10#$CTID + 1))")" || die "在 CTID $old_ctid 之后没有找到空闲 ID。"
      say "CTID $old_ctid 已存在，自动选择空闲 CTID：$CTID"
      return 0
    fi
    die "CTID $CTID 已存在。设置 AUTO_CTID=1 可自动选择下一个空闲 ID；使用 USE_EXISTING=1 CTID=$CTID 可安装到现有 LXC。"
  fi
  say "已选择 CTID：$CTID"
}

confirm_existing_ctid() {
  if ! vmid_exists "$CTID"; then
    die "找不到现有 CTID $CTID，请检查 CTID 或改用新建容器模式。"
  fi
}

cidr_prefix_to_mask() {
  local prefix="$1" mask="" full rem i
  full=$((prefix / 8))
  rem=$((prefix % 8))
  for i in 1 2 3 4; do
    if [ "$i" -le "$full" ]; then
      mask="${mask}255"
    elif [ "$i" -eq $((full + 1)) ] && [ "$rem" -gt 0 ]; then
      mask="${mask}$((256 - 2 ** (8 - rem)))"
    else
      mask="${mask}0"
    fi
    [ "$i" -lt 4 ] && mask="${mask}."
  done
  printf '%s' "$mask"
}

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  printf '%u' "$(( (a << 24) + (b << 16) + (c << 8) + d ))"
}

int_to_ip() {
  local n="$1"
  printf '%d.%d.%d.%d' "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

ip_in_pve_config() {
  local ip="$1" ip_re conf
  ip_re="${ip//./\\.}"
  for conf in /etc/pve/lxc/*.conf /etc/pve/qemu-server/*.conf; do
    [ -e "$conf" ] || continue
    if grep -Eq "(^|[,[:space:]])(ip|ipconfig[0-9]+)=${ip_re}(/|,|$)" "$conf"; then
      return 0
    fi
  done
  return 1
}

ip_in_use() {
  local ip="$1"
  ip_in_pve_config "$ip" && return 0
  ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && return 0
  ip neigh show "$ip" 2>/dev/null | awk '
    /lladdr/ && $0 !~ /(FAILED|INCOMPLETE)/ { found = 1 }
    END { exit found ? 0 : 1 }
  '
}

detect_network() {
  say "正在检测 PVE 局域网"
  local route_line dev gw pve_cidr pve_ip prefix network broadcast base candidate host candidates

  route_line="$(ip -4 route get 1.1.1.1 2>/dev/null | head -1 || true)"
  dev="$(printf '%s\n' "$route_line" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
  gw="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"

  if [ -z "$dev" ]; then
    dev="$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  fi
  if [ -z "$dev" ]; then
    dev="$(ip -o -4 addr show scope global | awk '{print $2; exit}')"
  fi
  [ -n "$dev" ] || die "无法检测局域网接口，请手动设置 CT_BRIDGE、CT_IP_CIDR 和 CT_GW。"

  if [ -z "$CT_BRIDGE" ]; then
    if printf '%s' "$dev" | grep -q '^vmbr'; then
      CT_BRIDGE="$dev"
    else
      CT_BRIDGE="$(ip -o -4 addr show scope global | awk '$2 ~ /^vmbr/ {print $2; exit}')"
      [ -n "$CT_BRIDGE" ] || CT_BRIDGE="$dev"
    fi
  fi

  pve_cidr="$(ip -o -4 addr show dev "$CT_BRIDGE" scope global 2>/dev/null | awk '{print $4; exit}')"
  if [ -z "$pve_cidr" ] && [ "$CT_BRIDGE" != "$dev" ]; then
    pve_cidr="$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4; exit}')"
  fi
  [ -n "$pve_cidr" ] || die "无法检测 PVE 局域网 IP，请手动设置 CT_IP_CIDR。"

  pve_ip="${pve_cidr%/*}"
  prefix="${pve_cidr#*/}"
  [ -n "$CT_GW" ] || CT_GW="$gw"
  [ -n "$CT_GW" ] || die "无法检测默认网关，请手动设置 CT_GW。"

  if [ -z "$CT_IP_CIDR" ]; then
    local mask_int pve_int net_int bcast_int
    mask_int="$(ip_to_int "$(cidr_prefix_to_mask "$prefix")")"
    pve_int="$(ip_to_int "$pve_ip")"
    net_int="$((pve_int & mask_int))"
    bcast_int="$((net_int | (0xffffffff ^ mask_int) ))"

    candidates=(9 6 8 10 20 30 50 60 100 200)
    for host in "${candidates[@]}"; do
      candidate="$(int_to_ip "$((net_int + host))")"
      [ "$((net_int + host))" -gt "$net_int" ] || continue
      [ "$((net_int + host))" -lt "$bcast_int" ] || continue
      [ "$candidate" != "$pve_ip" ] || continue
      [ "$candidate" != "$CT_GW" ] || continue
      if ! ip_in_use "$candidate"; then
        CT_IP_CIDR="${candidate}/${prefix}"
        break
      fi
    done

    if [ -z "$CT_IP_CIDR" ]; then
      say "常用候选 IP 均不可用，开始扫描当前子网"
      local start_int end_int cur_int scan_end_int
      start_int="$((net_int + 2))"
      end_int="$((bcast_int - 1))"
      scan_end_int="$end_int"
      if [ "$((scan_end_int - start_int))" -gt 512 ]; then
        scan_end_int="$((start_int + 512))"
      fi
      cur_int="$start_int"
      while [ "$cur_int" -le "$scan_end_int" ]; do
        candidate="$(int_to_ip "$cur_int")"
        cur_int="$((cur_int + 1))"
        [ "$candidate" != "$pve_ip" ] || continue
        [ "$candidate" != "$CT_GW" ] || continue
        if ! ip_in_use "$candidate"; then
          CT_IP_CIDR="${candidate}/${prefix}"
          break
        fi
      done
    fi
  fi

  say "检测到网桥：$CT_BRIDGE"
  say "检测到 PVE IP：$pve_cidr"
  say "检测到网关：$CT_GW"
  [ -n "$CT_IP_CIDR" ] || die "无法选择空闲 LXC IP，请手动设置，例如：CT_IP_CIDR=<空闲IP>/${prefix} CT_GW=${CT_GW} CT_BRIDGE=${CT_BRIDGE} bash pve-install-cn.sh"
  say "已选择 LXC IP：$CT_IP_CIDR"
}

detect_existing_container_network() {
  say "正在检测现有 LXC $CTID 的网络配置"
  local conf="/etc/pve/lxc/${CTID}.conf"
  local net0 ip gw bridge status runtime_ip prefix
  [ -e "$conf" ] || die "找不到 LXC 配置：$conf"

  net0="$(sed -n 's/^net0: //p' "$conf" | head -1)"
  [ -n "$net0" ] || die "在 $conf 中找不到 net0。"

  bridge="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^bridge=//p' | head -1)"
  ip="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^ip=//p' | head -1)"
  gw="$(printf '%s\n' "$net0" | tr ',' '\n' | sed -n 's/^gw=//p' | head -1)"

  [ -n "$CT_BRIDGE" ] || CT_BRIDGE="$bridge"
  [ -n "$CT_GW" ] || CT_GW="$gw"

  if [ -z "$CT_IP_CIDR" ] && [ -n "$ip" ] && [ "$ip" != "dhcp" ] && [ "$ip" != "manual" ]; then
    CT_IP_CIDR="$ip"
  fi

  status="$(pct status "$CTID" | awk '{print $2}')"
  if [ "$status" != "running" ]; then
    say "启动现有 LXC $CTID 以检测运行时 IP"
    pct start "$CTID"
    sleep 3
  fi

  if [ -z "$CT_IP_CIDR" ] || printf '%s' "$CT_IP_CIDR" | grep -qi '^dhcp$'; then
    runtime_ip="$(pct exec "$CTID" -- sh -c \"ip -o -4 addr show scope global | awk '{print \\\$4; exit}'\" 2>/dev/null || true)"
    [ -n "$runtime_ip" ] || die "无法检测现有 LXC 的运行时 IP，请手动设置 CT_IP_CIDR。"
    CT_IP_CIDR="$runtime_ip"
  fi

  if [ -z "$CT_BRIDGE" ]; then
    CT_BRIDGE="$(ip -o -4 addr show scope global | awk '$2 ~ /^vmbr/ {print $2; exit}')"
  fi
  if [ -z "$CT_GW" ]; then
    CT_GW="$(pct exec "$CTID" -- sh -c \"ip -4 route show default | awk '{print \\\$3; exit}'\" 2>/dev/null || true)"
  fi

  prefix="${CT_IP_CIDR#*/}"
  if [ "$prefix" = "$CT_IP_CIDR" ]; then
    say "现有 LXC IP 没有 CIDR 前缀，按 /24 处理"
    CT_IP_CIDR="${CT_IP_CIDR}/24"
  fi

  say "现有 LXC 网桥：${CT_BRIDGE:-未知}"
  say "现有 LXC 网关：${CT_GW:-未知}"
  say "现有 LXC IP：$CT_IP_CIDR"
}

download_with_fallback() {
  local url="$1" out="$2"
  local urls=()
  if prefer_cn_accel_enabled; then
    [ -n "$GH_PROXY" ] && urls+=("${GH_PROXY%/}/${url}")
    urls+=("https://gh-proxy.com/${url}" "https://gh.llkk.cc/${url}" "https://mirror.ghproxy.com/${url}" "$url")
  else
    [ -n "$GH_PROXY" ] && urls+=("${GH_PROXY%/}/${url}")
    urls+=("$url" "https://gh.llkk.cc/${url}" "https://gh-proxy.com/${url}" "https://mirror.ghproxy.com/${url}")
  fi
  download_best_url "$out" "${urls[@]}"
}

template_path_for_name() {
  local name="$1" path
  path="$(pvesm path "${CT_TEMPLATE_STORAGE}:vztmpl/${name}" 2>/dev/null || true)"
  if [ -z "$path" ]; then
    path="/var/lib/vz/template/cache/${name}"
  fi
  printf '%s' "$path"
}

download_template_from_mirrors() {
  local name="$1" output="$2" url best_url="" best_speed="0" speed
  local urls=() usable_urls=()

  if [ "$TEMPLATE_MIRROR" = "off" ] || [ "$TEMPLATE_MIRROR" = "pveam" ]; then
    return 1
  fi

  if [ "$TEMPLATE_MIRROR" != "auto" ]; then
    urls+=("${TEMPLATE_MIRROR%/}/${name}")
  fi

  urls+=(
    "https://mirrors.tuna.tsinghua.edu.cn/proxmox/images/system/${name}"
    "https://mirrors.ustc.edu.cn/proxmox/images/system/${name}"
    "https://mirror.nju.edu.cn/proxmox/images/system/${name}"
    "https://download.proxmox.com/images/system/${name}"
  )

  mkdir -p "$(dirname "$output")"
  for url in "${urls[@]}"; do
    say "检测模板镜像：$url"
    if ! curl -fsI --connect-timeout 8 --max-time 15 "$url" >/dev/null 2>&1; then
      say "模板镜像不可用：$url"
      continue
    fi
    speed="$(curl -fL --range 0-1048575 --connect-timeout 8 --max-time 15 -o /dev/null -w '%{speed_download}' "$url" 2>/dev/null || true)"
    speed="${speed%.*}"
    case "$speed" in
      ''|*[!0-9]*) speed=0 ;;
    esac
    say "模板镜像测速：${speed} B/s"
    usable_urls+=("$url")
    if awk "BEGIN {exit !($speed > $best_speed)}"; then
      best_speed="$speed"
      best_url="$url"
    fi
  done

  [ "${#usable_urls[@]}" -gt 0 ] || return 1

  if [ -n "$best_url" ]; then
    say "已选择最快模板镜像：$best_url（${best_speed} B/s）"
    if curl -fL --connect-timeout 15 --retry 2 -o "$output" "$best_url"; then
      [ -s "$output" ] && return 0
    fi
    say "最快镜像下载失败，继续尝试其他镜像。"
  fi

  for url in "${usable_urls[@]}"; do
    [ "$url" != "$best_url" ] || continue
    say "从镜像下载 LXC 模板：$url"
    if curl -fL --connect-timeout 15 --retry 2 -o "$output" "$url"; then
      [ -s "$output" ] || continue
      return 0
    fi
    say "模板下载失败，尝试下一个镜像。"
  done
  return 1
}

choose_template() {
  local existing latest
  if [ -n "$TEMPLATE_URL" ]; then
    local filename template_path
    filename="${TEMPLATE_URL%%\?*}"
    filename="${filename##*/}"
    [ -n "$filename" ] || die "无法从 TEMPLATE_URL 解析模板文件名。"
    template_path="$(template_path_for_name "$filename")"
    mkdir -p "$(dirname "$template_path")"
    if [ ! -s "$template_path" ]; then
      say "从 TEMPLATE_URL 下载 LXC 模板：$TEMPLATE_URL"
      download_with_fallback "$TEMPLATE_URL" "$template_path" || die "下载 TEMPLATE_URL 失败。"
    else
      say "使用已有模板文件：$template_path"
    fi
    TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${filename}"
    say "使用自定义模板：$TEMPLATE"
    return 0
  fi

  if [ -n "$CT_TEMPLATE_NAME" ]; then
    existing="$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk -v name="$CT_TEMPLATE_NAME" '$1 == name || $1 == "vztmpl/" name || $1 ~ ("/" name "$") {print $1; exit}' || true)"
    if [ -z "$existing" ]; then
      local template_path
      template_path="$(template_path_for_name "$CT_TEMPLATE_NAME")"
      if [ -n "$template_path" ] && [ -s "$template_path" ]; then
        existing="${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_NAME}"
      fi
    fi
    if [ -n "$existing" ]; then
      TEMPLATE="$existing"
      say "使用首选模板：$TEMPLATE"
      return 0
    fi
    say "本地未找到首选模板：$CT_TEMPLATE_NAME"
    local preferred_path
    preferred_path="$(template_path_for_name "$CT_TEMPLATE_NAME")"
    if download_template_from_mirrors "$CT_TEMPLATE_NAME" "$preferred_path"; then
      TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${CT_TEMPLATE_NAME}"
      say "使用已下载的首选模板：$TEMPLATE"
      return 0
    fi
  fi

  existing="$(pveam list "$CT_TEMPLATE_STORAGE" 2>/dev/null | awk '/debian-13-standard.*amd64.*(tar.zst|tar.gz)/{print $1}' | sort -V | tail -1 || true)"
  if [ -n "$existing" ]; then
    TEMPLATE="$existing"
    say "使用已有模板：$TEMPLATE"
    return 0
  fi

  say "正在更新 LXC 模板列表"
  pveam update
  latest="$(pveam available --section system | awk '/debian-13-standard.*amd64.*(tar.zst|tar.gz)/{print $2}' | sort -V | tail -1 || true)"
  if [ -z "$latest" ]; then
    latest="$(pveam available --section system | awk '/debian-12-standard.*amd64.*(tar.zst|tar.gz)/{print $2}' | sort -V | tail -1 || true)"
  fi
  [ -n "$latest" ] || die "找不到 Debian 13/12 amd64 LXC 模板。"
  say "正在下载模板：$latest"
  pveam download "$CT_TEMPLATE_STORAGE" "$latest"
  TEMPLATE="${CT_TEMPLATE_STORAGE}:vztmpl/${latest}"
}

create_container() {
  say "正在创建 LXC $CTID（$CT_HOSTNAME）"
  local password_args=()
  [ -n "$CT_PASSWORD" ] && password_args=(--password "$CT_PASSWORD")

  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --rootfs "${CT_ROOTFS_STORAGE}:${CT_DISK_SIZE}" \
    --cores "$CT_CORES" \
    --memory "$CT_MEMORY" \
    --swap "$CT_SWAP" \
    --net0 "name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP_CIDR},gw=${CT_GW}" \
    --nameserver "$CT_DNS" \
    --ostype debian \
    --unprivileged 0 \
    --features nesting=1,keyctl=1 \
    --onboot 1 \
    "${password_args[@]}"
}

ensure_lxc_conf_line() {
  local conf="$1" line="$2"
  grep -Fxq "$line" "$conf" || echo "$line" >> "$conf"
}

configure_lxc_tun() {
  local conf="/etc/pve/lxc/${CTID}.conf"
  say "正在配置 LXC TUN、嵌套和 keyctl"
  [ -e "$conf" ] || die "找不到 LXC 配置：$conf"
  backup_file "$conf"
  pct set "$CTID" --features nesting=1,keyctl=1
  ensure_lxc_conf_line "$conf" "lxc.cgroup2.devices.allow: c 10:200 rwm"
  ensure_lxc_conf_line "$conf" "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
}

start_container() {
  say "正在启动 LXC $CTID"
  if ! pct status "$CTID" | grep -q 'running'; then
    pct start "$CTID"
  fi
  for _ in $(seq 1 30); do
    pct exec "$CTID" -- test -e /proc/1/status >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "容器未能在规定时间内就绪。"
}

PROXY_HINT_LIST=""

append_proxy_hint() {
  local hint="$1"
  [ -n "$hint" ] || return 0
  case "$hint" in
    *://*) hint="${hint#*://}" ;;
  esac
  hint="${hint%%/*}"
  hint="${hint%%\?*}"
  hint="${hint##*@}"
  hint="${hint#[}"
  hint="${hint%]}"
  hint="$(printf '%s' "$hint" | tr -d '()[]')"
  case "$hint" in
    ''|localhost|127.*|0.0.0.0|::1) return 0 ;;
  esac
  case " $PROXY_HINT_LIST " in
    *" $hint "*) ;;
    *) PROXY_HINT_LIST="${PROXY_HINT_LIST} ${hint}" ;;
  esac
}

detect_proxy_hints() {
  local token hint
  PROXY_HINT_LIST=""

  append_proxy_hint "$LXC_PROXY_ADDR"
  for token in ${PROXY_HINTS:-} ${PVE_PROXY_HINTS:-} ${http_proxy:-} ${https_proxy:-} ${HTTP_PROXY:-} ${HTTPS_PROXY:-}; do
    append_proxy_hint "$token"
  done

  if [ -n "${SSH_CLIENT:-}" ]; then
    append_proxy_hint "$(printf '%s' "$SSH_CLIENT" | awk '{print $1}')"
  fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    append_proxy_hint "$(printf '%s' "$SSH_CONNECTION" | awk '{print $1}')"
  fi

  hint="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)"
  case "$hint" in
    *.*.*.*|*:*) append_proxy_hint "$hint" ;;
  esac

  hint="$(last -i -n 1 root 2>/dev/null | awk 'NR == 1 {print $3}' || true)"
  case "$hint" in
    *.*.*.*|*:*) append_proxy_hint "$hint" ;;
  esac

  while read -r hint; do
    append_proxy_hint "$hint"
  done < <(ip neigh show 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1}' | awk '!seen[$0]++ {print; count++} count >= 30 {exit}' || true)

  printf '%s' "$PROXY_HINT_LIST" | awk '{$1=$1; print}'
}

setup_lxc_proxy() {
  case "$LXC_PROXY" in
    off|"")
      return 0
      ;;
    disable)
      say "正在关闭 LXC 内代理"
      ;;
    auto|on)
      say "正在配置 LXC 内代理：LXC_PROXY=$LXC_PROXY"
      ;;
    *)
      die "未知 LXC_PROXY=$LXC_PROXY，请使用 off、auto、on 或 disable。"
      ;;
  esac

  local local_proxy="$WORK_DIR/proxy.sh"
  if [ -f "./proxy.sh" ]; then
    cp ./proxy.sh "$local_proxy"
  else
    download_with_fallback "$PROXY_URL" "$local_proxy" || die "下载 proxy.sh 失败。"
  fi
  chmod +x "$local_proxy"
  pct push "$CTID" "$local_proxy" /root/lxc-proxy.sh -perms 0755

  if [ "$LXC_PROXY" = "disable" ]; then
    pct exec "$CTID" -- bash /root/lxc-proxy.sh off || true
    return 0
  fi

  local proxy_addr=""
  if [ "$LXC_PROXY" = "auto" ]; then
    local proxy_hints
    proxy_hints="$(detect_proxy_hints || true)"
    [ -n "$proxy_hints" ] && say "LXC 代理自动检测候选：$proxy_hints"
    proxy_addr="$(pct exec "$CTID" -- env \
      PROXY_ADDR="$LXC_PROXY_ADDR" \
      PROXY_HINTS="$proxy_hints" \
      PVE_PROXY_HINTS="$proxy_hints" \
      PROXY_PORT="$LXC_PROXY_PORT" \
      COMMON_PORTS="$LXC_PROXY_COMMON_PORTS" \
      bash /root/lxc-proxy.sh detect 2>/dev/null || true)"
    if [ -z "$proxy_addr" ]; then
      say "未检测到可用 LXC 代理，将不使用代理继续安装。"
      return 0
    fi
    say "检测到可用 LXC 代理：$proxy_addr"
  else
    proxy_addr="$LXC_PROXY_ADDR"
  fi

  pct exec "$CTID" -- env \
    PROXY_ADDR="$LXC_PROXY_ADDR" \
    PROXY_PORT="$LXC_PROXY_PORT" \
    COMMON_PORTS="$LXC_PROXY_COMMON_PORTS" \
    bash /root/lxc-proxy.sh on "$proxy_addr"

  proxy_addr="$(pct exec "$CTID" -- sh -c "sed -n 's/.*http:\\/\\/\\([^\"]*\\).*/\\1/p' /etc/apt/apt.conf.d/99proxy 2>/dev/null | head -1" || true)"
  if [ -n "$proxy_addr" ]; then
    LXC_PROXY_HTTP="http://${proxy_addr}"
    say "LXC 安装过程将使用代理：$LXC_PROXY_HTTP"
  fi
}

run_in_container() {
  say "正在 LXC 内运行安装脚本"
  local local_install="$WORK_DIR/install.sh"
  if [ -f "./install.sh" ]; then
    cp ./install.sh "$local_install"
  else
    download_with_fallback "$INSTALL_URL" "$local_install" || die "下载 install.sh 失败。"
  fi
  chmod +x "$local_install"
  pct push "$CTID" "$local_install" /root/mihomo-router-install.sh -perms 0755

  local env_args=(MODE="$LXC_INSTALL_MODE" ROUTING_MODE="$ROUTING_MODE" VERSION="$VERSION" NEXUSBOX_INSTALL_URL="$NEXUSBOX_INSTALL_URL" NEXUSBOX_DEFAULT_INSTALL_URL="$NEXUSBOX_DEFAULT_INSTALL_URL" NEXUSBOX_PATCHED_ENABLE="$NEXUSBOX_PATCHED_ENABLE" NEXUSBOX_PATCHED_REPO="$REPO" NEXUSBOX_PATCHED_BRANCH="$BRANCH" NEXUSBOX_PATCHED_REF="$NEXUSBOX_PATCHED_REF" NEXUSBOX_PATCHED_BASE="$NEXUSBOX_PATCHED_BASE" NEXUSBOX_PATCHED_URL="$NEXUSBOX_PATCHED_URL" NEXUSBOX_PATCHED_SHA256="$NEXUSBOX_PATCHED_SHA256" CONFIG_URL="$CONFIG_URL" ZASHBOARD_URL="$ZASHBOARD_URL" PREFER_CN_ACCEL="$PREFER_CN_ACCEL" GH_PROXY="$GH_PROXY" DOWNLOAD_SPEED_LIMIT="$DOWNLOAD_SPEED_LIMIT" DOWNLOAD_SPEED_TIME="$DOWNLOAD_SPEED_TIME")
  if [ -n "$LXC_PROXY_HTTP" ]; then
    env_args+=(
      http_proxy="$LXC_PROXY_HTTP"
      https_proxy="$LXC_PROXY_HTTP"
      HTTP_PROXY="$LXC_PROXY_HTTP"
      HTTPS_PROXY="$LXC_PROXY_HTTP"
    )
  fi
  pct exec "$CTID" -- env "${env_args[@]}" bash /root/mihomo-router-install.sh
}

verify_container_health() {
  say "正在验证 LXC 运行状态"
  local result
  result="$(pct exec "$CTID" -- env ROUTING_MODE="$ROUTING_MODE" sh -s <<'EOS'
set -eu
fail=0
profile=standalone
if [ -x /opt/nexusbox/nexusbox ]; then
  profile=nexusbox
fi
echo "安装类型=${profile}"

check_cmd() {
  label="$1"
  shift
  if "$@"; then
    echo "正常：${label}"
  else
    echo "失败：${label}"
    fail=1
  fi
}

check_port() {
  port="$1"
  label="$2"
  if ss -lntup 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
    echo "正常：${label} 端口 ${port}"
  else
    echo "失败：${label} 端口 ${port}"
    fail=1
  fi
}

detect_dns_port() {
  config_file="$1"
  [ -f "$config_file" ] || return 0
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
  ' "$config_file"
}

check_dns_runtime() {
  local config_file dns_port
  config_file="$1"
  dns_port="$(detect_dns_port "$config_file" || true)"
  if [ -z "$dns_port" ]; then
    echo "警告：${config_file} 中未找到 dns.listen"
    return 0
  fi
  check_port "$dns_port" "Mihomo DNS 服务"
  if [ "${ROUTING_MODE:-kdocs}" = "kdocs" ] && [ "$dns_port" != "53" ]; then
    echo "失败：KDocs 模式要求 DNS 监听 53，当前为 $dns_port"
    fail=1
  fi
  if [ "$dns_port" != "53" ]; then
    if iptables -t nat -S PREROUTING 2>/dev/null | grep -Eq -- "--dport 53 .*--to-ports ${dns_port}"; then
      echo "正常：DNS 转发 53 -> ${dns_port}"
    else
      echo "失败：DNS 转发 53 -> ${dns_port}"
      fail=1
    fi
  fi
}

detect_redir_port() {
  local config_file
  config_file="$1"
  [ -f "$config_file" ] || return 0
  awk '
    /^[[:space:]]*redir-port:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*redir-port:[[:space:]]*/, "", value)
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/["'\'' ]/, "", value)
      if (value ~ /^[0-9]+$/) print value
      exit
    }
  ' "$config_file"
}

check_transparent_runtime() {
  local config_file redir_port
  config_file="$1"
  if [ "${ROUTING_MODE:-kdocs}" = "kdocs" ]; then
    echo "正常：KDocs 模式不启用 TCP REDIRECT"
    return 0
  fi
  redir_port="$(detect_redir_port "$config_file" || true)"
  if [ -z "$redir_port" ]; then
    echo "警告：${config_file} 中未找到 redir-port"
    return 0
  fi
  check_port "$redir_port" "Mihomo TCP 透明代理"
  if iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- '-j MIHOMO_REDIRECT' && iptables -t nat -S MIHOMO_REDIRECT 2>/dev/null | grep -Eq -- "--to-ports ${redir_port}"; then
    echo "正常：TCP 透明代理 -> ${redir_port}"
  else
    echo "失败：TCP 透明代理 -> ${redir_port}"
    fail=1
  fi
}

if [ "$profile" = "nexusbox" ]; then
  check_cmd "NexusBox 进程" pgrep -f /opt/nexusbox/nexusbox
  check_port 18080 "NexusBox 管理页面"
  check_dns_runtime /opt/config/config.yaml
  check_transparent_runtime /opt/config/config.yaml
else
  check_cmd "mihomo.service 运行状态" systemctl is-active --quiet mihomo
  check_cmd "Mihomo 进程" pgrep -f "/usr/local/bin/mihomo -d /etc/mihomo"
  check_dns_runtime /etc/mihomo/config.yaml
  check_transparent_runtime /etc/mihomo/config.yaml
fi

check_port 7890 "Mihomo HTTP/SOCKS 代理"
check_port 9090 "Mihomo 控制接口"

if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = "1" ]; then
  echo "正常：IPv4 转发已开启"
else
  echo "失败：IPv4 转发未开启"
  fail=1
fi

if [ "${ROUTING_MODE:-kdocs}" = "kdocs" ] && [ -e /proc/sys/net/ipv6/conf/all/forwarding ]; then
  if [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || echo 0)" = "1" ]; then
    echo "正常：IPv6 转发已开启"
  else
    echo "失败：IPv6 转发未开启"
    fail=1
  fi
fi

if [ "${ROUTING_MODE:-kdocs}" = "kdocs" ]; then
  check_cmd "TUN 设备权限" test -c /dev/net/tun
  check_cmd "Meta TUN 网卡" ip link show Meta
fi

if iptables -t nat -S POSTROUTING 2>/dev/null | grep -q -- '-j MASQUERADE'; then
  echo "正常：NAT MASQUERADE 规则"
else
  echo "失败：缺少 NAT MASQUERADE 规则"
  fail=1
fi

exit "$fail"
EOS
)" || {
    printf '%s\n' "$result"
    die "LXC 运行状态验证失败。"
  }
  printf '%s\n' "$result"
  INSTALL_PROFILE="$(printf '%s\n' "$result" | sed -n 's/^安装类型=//p' | head -1)"
  [ -n "$INSTALL_PROFILE" ] || INSTALL_PROFILE="unknown"
}

print_summary() {
  local ip="${CT_IP_CIDR%/*}"
  say "第 1-4 阶段已完成"
  echo "LXC ID：$CTID"
  echo "LXC IP：$ip"
  echo "安装类型：$INSTALL_PROFILE"
  echo "路由模式：$ROUTING_MODE"
  if [ "$INSTALL_PROFILE" = "nexusbox" ]; then
    echo "NexusBox 管理页面：http://${ip}:18080"
  else
    echo "NexusBox 管理页面：未安装（纯 Mihomo 模式）"
  fi
  echo "Mihomo HTTP/SOCKS 代理：${ip}:7890"
  echo "Mihomo 控制接口：http://${ip}:9090"
  if [ "$ROUTING_MODE" = "kdocs" ]; then
    echo "Mihomo DNS：${ip}:53"
  elif [ "$INSTALL_PROFILE" = "standalone" ]; then
    echo "Mihomo DNS：${ip}:6666（客户端仍访问 53，由 LXC 转发）"
  fi
  [ -n "$LXC_PROXY_HTTP" ] && echo "安装时使用的 LXC 代理：$LXC_PROXY_HTTP"
  echo
  echo "第 5 阶段需要在主路由或终端设置："
  if [ "$ROUTING_MODE" = "kdocs" ]; then
    echo "  KDocs 模式："
    echo "    客户端网关：保持原主路由"
    echo "    客户端 DNS：${ip}"
    echo "    静态路由：198.18.0.0/16 -> ${ip}"
    echo "    主路由关闭 ICMP 重定向"
    echo "    限制：Telegram 固定 DC IP、真实 IP、IPv6 和部分 UDP 可能绕过 LXC"
  else
    echo "  完整网关模式："
    echo "    客户端网关：${ip}"
    echo "    客户端 DNS：${ip}"
  fi
  echo
  echo "安装日志：$LOG"
}

main() {
  require_pve_host
  prompt_choices
  validate_routing_mode
  detect_storage
  if [ "$USE_EXISTING" = "1" ]; then
    confirm_existing_ctid
    detect_existing_container_network
  else
    confirm_new_ctid
    detect_network
    choose_template
    create_container
  fi
  configure_lxc_tun
  start_container
  setup_lxc_proxy
  run_in_container
  verify_container_health
  print_summary
}

main "$@"
