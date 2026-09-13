#!/usr/bin/env bash
set -Eeuo pipefail

CORE_SOCKET="${CORE_SOCKET-/opt/nexusbox/var/core.sock}"
API_BASE="${API_BASE:-http://localhost}"
GROUP_NAME="${GROUP_NAME:-容器镜像}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
STALL_SECONDS="${STALL_SECONDS:-15}"
MIN_RATE_KIB="${MIN_RATE_KIB:-192}"
LOW_RATE_SECONDS="${LOW_RATE_SECONDS:-30}"
WARMUP_SECONDS="${WARMUP_SECONDS:-10}"
MIN_SWITCH_INTERVAL="${MIN_SWITCH_INTERVAL:-20}"
NODE_COOLDOWN_SECONDS="${NODE_COOLDOWN_SECONDS:-600}"
MAX_SWITCHES_PER_WINDOW="${MAX_SWITCHES_PER_WINDOW:-3}"
SWITCH_WINDOW_SECONDS="${SWITCH_WINDOW_SECONDS:-600}"
HOST_REGEX="${HOST_REGEX:-^pkg-containers\.githubusercontent\.com$}"
DRY_RUN="${DRY_RUN:-0}"
RUN_ONCE="${RUN_ONCE:-0}"

declare -A LAST_BYTES LAST_CHECK FIRST_SEEN IDLE_SECONDS LOW_SECONDS NODE_COOLDOWN
LAST_SWITCH=0
SWITCH_WINDOW_START=0
SWITCH_COUNT=0
LAST_LIMIT_LOG=0

say() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  say "错误：$*" >&2
  exit 1
}

is_uint() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

for value in "$CHECK_INTERVAL" "$STALL_SECONDS" "$MIN_RATE_KIB" "$LOW_RATE_SECONDS" \
  "$WARMUP_SECONDS" "$MIN_SWITCH_INTERVAL" "$NODE_COOLDOWN_SECONDS"; do
  is_uint "$value" || die "监控参数必须是非负整数：$value"
done
for value in "$MAX_SWITCHES_PER_WINDOW" "$SWITCH_WINDOW_SECONDS"; do
  is_uint "$value" || die "切换保护参数必须是非负整数：$value"
done
[ "$CHECK_INTERVAL" -gt 0 ] || die "CHECK_INTERVAL 必须大于 0。"
[ "$MAX_SWITCHES_PER_WINDOW" -gt 0 ] || die "MAX_SWITCHES_PER_WINDOW 必须大于 0。"
[ "$SWITCH_WINDOW_SECONDS" -gt 0 ] || die "SWITCH_WINDOW_SECONDS 必须大于 0。"

for command in curl jq sort date; do
  command -v "$command" >/dev/null 2>&1 || die "缺少命令：$command"
done

if [ -n "$CORE_SOCKET" ] && [ ! -S "$CORE_SOCKET" ]; then
  die "找不到 Mihomo 控制套接字：$CORE_SOCKET"
fi

api_request() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-fsS --connect-timeout 3 --max-time 10 -X "$method")

  if [ -n "$CORE_SOCKET" ]; then
    args+=(--unix-socket "$CORE_SOCKET")
  fi
  if [ -n "$data" ]; then
    args+=(-H 'Content-Type: application/json' -d "$data")
  fi
  curl "${args[@]}" "${API_BASE}${path}"
}

uri_encode() {
  jq -nr --arg value "$1" '$value | @uri'
}

group_path="/proxies/$(uri_encode "$GROUP_NAME")"

choose_next_node() {
  local group_json="$1" current="$2" providers_json current_provider="" now node provider delay
  local -a candidates=()

  providers_json="$(api_request GET '/providers/proxies')" || return 1
  mapfile -t candidates < <(
    jq -r --argjson group "$group_json" '
      ($group.all // []) as $allowed
      | .providers
      | to_entries[] as $provider
      | $provider.value.proxies[]? as $proxy
      | select(($allowed | index($proxy.name)) != null)
      | select($proxy.alive != false)
      | [$proxy.name, $provider.key, ($proxy.history[-1].delay // 65535)]
      | @tsv
    ' <<<"$providers_json" | sort -t $'\t' -k3,3n
  )

  for row in "${candidates[@]}"; do
    IFS=$'\t' read -r node provider delay <<<"$row"
    if [ "$node" = "$current" ]; then
      current_provider="$provider"
      break
    fi
  done

  now="$(date +%s)"
  for prefer_other_provider in 1 0; do
    for row in "${candidates[@]}"; do
      IFS=$'\t' read -r node provider delay <<<"$row"
      [ -n "$node" ] || continue
      [ "$node" != "$current" ] || continue
      [ "${NODE_COOLDOWN[$node]:-0}" -le "$now" ] || continue
      if [ "$prefer_other_provider" = "1" ] && [ -n "$current_provider" ] && [ "$provider" = "$current_provider" ]; then
        continue
      fi
      printf '%s\t%s\t%s\n' "$node" "$provider" "$delay"
      return 0
    done
  done
  return 1
}

switch_stalled_connection() {
  local connection_id="$1" current="$2" source_ip="$3" host="$4" reason="$5"
  local now group_json next_row next_node next_provider next_delay payload

  now="$(date +%s)"
  if [ "$SWITCH_WINDOW_START" -eq 0 ] || [ $((now - SWITCH_WINDOW_START)) -ge "$SWITCH_WINDOW_SECONDS" ]; then
    SWITCH_WINDOW_START="$now"
    SWITCH_COUNT=0
  fi
  if [ "$SWITCH_COUNT" -ge "$MAX_SWITCHES_PER_WINDOW" ]; then
    if [ $((now - LAST_LIMIT_LOG)) -ge 60 ]; then
      say "已达到 ${SWITCH_WINDOW_SECONDS}s 内最多 ${MAX_SWITCHES_PER_WINDOW} 次切换的保护上限，暂不继续中断 Docker。"
      LAST_LIMIT_LOG="$now"
    fi
    return 1
  fi
  if [ $((now - LAST_SWITCH)) -lt "$MIN_SWITCH_INTERVAL" ]; then
    return 1
  fi

  group_json="$(api_request GET "$group_path")" || {
    say "无法读取 $GROUP_NAME 分组，暂不切换。"
    return 1
  }
  if [ -z "$current" ]; then
    current="$(jq -r 'if (.fixed // "") != "" then .fixed else (.now // "") end' <<<"$group_json")"
  fi
  next_row="$(choose_next_node "$group_json" "$current")" || {
    say "没有找到可切换的健康候选节点，保留当前节点：$current"
    return 1
  }
  IFS=$'\t' read -r next_node next_provider next_delay <<<"$next_row"
  payload="$(jq -cn --arg name "$next_node" '{name: $name}')"

  say "检测到镜像连接异常：来源=$source_ip，目标=$host，当前=$current，原因=$reason"
  say "切换 $GROUP_NAME：$current -> $next_node（订阅=$next_provider，最近延迟=${next_delay}ms）"
  if [ "$DRY_RUN" != "1" ]; then
    api_request PUT "$group_path" "$payload" >/dev/null || {
      NODE_COOLDOWN["$next_node"]=$((now + NODE_COOLDOWN_SECONDS))
      say "节点切换失败，保留当前连接。"
      return 1
    }
    api_request DELETE "/connections/$(uri_encode "$connection_id")" >/dev/null || {
      say "节点已切换，但无法关闭旧镜像连接：$connection_id"
      return 1
    }
  else
    say "DRY_RUN=1，跳过节点切换和连接关闭。"
  fi

  NODE_COOLDOWN["$current"]=$((now + NODE_COOLDOWN_SECONDS))
  LAST_SWITCH="$now"
  SWITCH_COUNT=$((SWITCH_COUNT + 1))
  unset 'LAST_BYTES[$connection_id]' 'LAST_CHECK[$connection_id]' 'FIRST_SEEN[$connection_id]'
  unset 'IDLE_SECONDS[$connection_id]' 'LOW_SECONDS[$connection_id]'
  return 0
}

say "容器镜像连接守护程序已启动：分组=$GROUP_NAME，停滞=${STALL_SECONDS}s，低速阈值=${MIN_RATE_KIB}KiB/s/${LOW_RATE_SECONDS}s"

while :; do
  now="$(date +%s)"
  connections_json="$(api_request GET '/connections' 2>/dev/null || true)"
  if [ -z "$connections_json" ] || ! jq -e '.connections | type == "array"' >/dev/null 2>&1 <<<"$connections_json"; then
    say "无法读取 Mihomo 连接，${CHECK_INTERVAL}s 后重试。"
    [ "$RUN_ONCE" = "1" ] && exit 1
    sleep "$CHECK_INTERVAL"
    continue
  fi

  declare -A seen=()
  switched=0
  while IFS=$'\t' read -r connection_id bytes current source_ip host; do
    [ -n "$connection_id" ] || continue
    seen["$connection_id"]=1
    is_uint "$bytes" || bytes=0

    if [ -z "${LAST_BYTES[$connection_id]+set}" ]; then
      LAST_BYTES["$connection_id"]="$bytes"
      LAST_CHECK["$connection_id"]="$now"
      FIRST_SEEN["$connection_id"]="$now"
      IDLE_SECONDS["$connection_id"]=0
      LOW_SECONDS["$connection_id"]=0
      say "开始监控镜像连接：来源=$source_ip，目标=$host，节点=$current"
      continue
    fi

    elapsed=$((now - LAST_CHECK[$connection_id]))
    [ "$elapsed" -gt 0 ] || elapsed="$CHECK_INTERVAL"
    delta=$((bytes - LAST_BYTES[$connection_id]))
    [ "$delta" -ge 0 ] || delta=0
    age=$((now - FIRST_SEEN[$connection_id]))
    rate_kib=$((delta / elapsed / 1024))

    if [ "$delta" -eq 0 ]; then
      IDLE_SECONDS["$connection_id"]=$((IDLE_SECONDS[$connection_id] + elapsed))
    else
      IDLE_SECONDS["$connection_id"]=0
    fi
    if [ "$delta" -gt 0 ] && [ "$rate_kib" -lt "$MIN_RATE_KIB" ]; then
      LOW_SECONDS["$connection_id"]=$((LOW_SECONDS[$connection_id] + elapsed))
    else
      LOW_SECONDS["$connection_id"]=0
    fi

    LAST_BYTES["$connection_id"]="$bytes"
    LAST_CHECK["$connection_id"]="$now"

    if [ "$age" -ge "$WARMUP_SECONDS" ] && [ "${IDLE_SECONDS[$connection_id]}" -ge "$STALL_SECONDS" ]; then
      switch_stalled_connection "$connection_id" "$current" "$source_ip" "$host" "连续 ${IDLE_SECONDS[$connection_id]}s 无下载" && switched=1
    elif [ "$age" -ge "$WARMUP_SECONDS" ] && [ "${LOW_SECONDS[$connection_id]}" -ge "$LOW_RATE_SECONDS" ]; then
      switch_stalled_connection "$connection_id" "$current" "$source_ip" "$host" "连续 ${LOW_SECONDS[$connection_id]}s 低于 ${MIN_RATE_KIB}KiB/s（当前约 ${rate_kib}KiB/s）" && switched=1
    fi
    [ "$switched" = "0" ] || break
  done < <(
    jq -r --arg host_regex "$HOST_REGEX" '
      .connections[]?
      | select((.metadata.host // "") | test($host_regex; "i"))
      | [.id, (.download // 0), (.chains[0] // ""), (.metadata.sourceIP // ""), (.metadata.host // "")]
      | @tsv
    ' <<<"$connections_json"
  )

  for connection_id in "${!LAST_BYTES[@]}"; do
    if [ -z "${seen[$connection_id]+set}" ]; then
      unset 'LAST_BYTES[$connection_id]' 'LAST_CHECK[$connection_id]' 'FIRST_SEEN[$connection_id]'
      unset 'IDLE_SECONDS[$connection_id]' 'LOW_SECONDS[$connection_id]'
    fi
  done

  [ "$RUN_ONCE" != "1" ] || break
  sleep "$CHECK_INTERVAL"
done
