#!/usr/bin/env bash
set -Eeuo pipefail

CORE_SOCKET="${CORE_SOCKET-/opt/nexusbox/var/core.sock}"
API_BASE="${API_BASE:-http://localhost}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
INITIAL_STALL_SECONDS="${INITIAL_STALL_SECONDS:-15}"
PROGRESS_STALL_SECONDS="${PROGRESS_STALL_SECONDS:-25}"
MIN_RATE_KIB="${MIN_RATE_KIB:-64}"
LOW_RATE_SECONDS="${LOW_RATE_SECONDS:-20}"
WARMUP_SECONDS="${WARMUP_SECONDS:-8}"
MIN_SWITCH_INTERVAL="${MIN_SWITCH_INTERVAL:-30}"
ROUTE_COOLDOWN_SECONDS="${ROUTE_COOLDOWN_SECONDS:-1800}"
MAX_SWITCHES_PER_WINDOW="${MAX_SWITCHES_PER_WINDOW:-1}"
SWITCH_WINDOW_SECONDS="${SWITCH_WINDOW_SECONDS:-900}"
HOST_REGEX="${HOST_REGEX:-(^|\.)(twimg\.com|twittercdn\.com|pscp\.tv|periscope\.tv|cdninstagram\.com|fbcdn\.net|fbsbx\.com)$}"
DRY_RUN="${DRY_RUN:-0}"
RUN_ONCE="${RUN_ONCE:-0}"

declare -A LAST_BYTES LAST_CHECK FIRST_SEEN IDLE_SECONDS PROGRESS_IDLE_SECONDS LOW_SECONDS OBSERVED_PROGRESS ROUTE_COOLDOWN
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

for value in "$CHECK_INTERVAL" "$INITIAL_STALL_SECONDS" "$PROGRESS_STALL_SECONDS" "$MIN_RATE_KIB" \
  "$LOW_RATE_SECONDS" "$WARMUP_SECONDS" "$MIN_SWITCH_INTERVAL" \
  "$ROUTE_COOLDOWN_SECONDS" "$MAX_SWITCHES_PER_WINDOW" "$SWITCH_WINDOW_SECONDS"; do
  is_uint "$value" || die "监控参数必须是非负整数：$value"
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

group_for_host() {
  local host="${1,,}"
  case "$host" in
    twimg.com|*.twimg.com|twittercdn.com|*.twittercdn.com|pscp.tv|*.pscp.tv|periscope.tv|*.periscope.tv)
      printf '%s\n' 'X视频'
      ;;
    cdninstagram.com|*.cdninstagram.com|fbcdn.net|*.fbcdn.net|fbsbx.com|*.fbsbx.com)
      printf '%s\n' 'Instagram媒体'
      ;;
    *)
      return 1
      ;;
  esac
}

supports_progress_stall() {
  local host="${1,,}"
  case "$host" in
    video.twimg.com|*.video.twimg.com|twittercdn.com|*.twittercdn.com|pscp.tv|*.pscp.tv|periscope.tv|*.periscope.tv)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

provider_for_node() {
  local providers_json="$1" node="$2"
  jq -r --arg node "$node" '
    first(
      .providers
      | to_entries[] as $provider
      | $provider.value.proxies[]?
      | select(.name == $node)
      | $provider.key
    ) // ""
  ' <<<"$providers_json"
}

route_candidate_rows() {
  local group_json="$1" providers_json="$2" current_route="$3"
  local route route_json node provider delay alive

  while IFS= read -r route; do
    [ -n "$route" ] || continue
    [ "$route" != "$current_route" ] || continue
    route_json="$(api_request GET "/proxies/$(uri_encode "$route")" 2>/dev/null || true)"
    [ -n "$route_json" ] || continue
    node="$(jq -r 'if (.fixed // "") != "" then .fixed else (.now // "") end' <<<"$route_json")"
    [ -n "$node" ] || continue
    provider="$(provider_for_node "$providers_json" "$node")"
    read -r alive delay < <(
      jq -r --arg node "$node" '
        first(
          .providers[]?.proxies[]?
          | select(.name == $node)
          | [(.alive != false), (.history[-1].delay // 65535)]
          | @tsv
        ) // "false\t65535"
      ' <<<"$providers_json"
    )
    [ "$alive" = "true" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$route" "$node" "$provider" "$delay"
  done < <(jq -r '.all[]?' <<<"$group_json")
}

choose_next_route() {
  local group_json="$1" current_route="$2" current_node="$3"
  local providers_json current_provider now row route node provider delay
  local -a candidates=()

  providers_json="$(api_request GET '/providers/proxies')" || return 1
  current_provider="$(provider_for_node "$providers_json" "$current_node")"
  mapfile -t candidates < <(
    route_candidate_rows "$group_json" "$providers_json" "$current_route" |
      sort -t $'\t' -k4,4n
  )

  now="$(date +%s)"
  for prefer_other_provider in 1 0; do
    for row in "${candidates[@]}"; do
      IFS=$'\t' read -r route node provider delay <<<"$row"
      [ "${ROUTE_COOLDOWN[$route]:-0}" -le "$now" ] || continue
      if [ "$prefer_other_provider" = "1" ] && [ -n "$current_provider" ] && [ "$provider" = "$current_provider" ]; then
        continue
      fi
      printf '%s\t%s\t%s\t%s\n' "$route" "$node" "$provider" "$delay"
      return 0
    done
  done
  return 1
}

switch_media_connection() {
  local connection_id="$1" current_node="$2" connection_route="$3" source_ip="$4" host="$5" group="$6" reason="$7"
  local now group_json selected_route current_route next_row next_route next_node next_provider next_delay payload

  now="$(date +%s)"
  if [ "$SWITCH_WINDOW_START" -eq 0 ] || [ $((now - SWITCH_WINDOW_START)) -ge "$SWITCH_WINDOW_SECONDS" ]; then
    SWITCH_WINDOW_START="$now"
    SWITCH_COUNT=0
  fi
  if [ "$SWITCH_COUNT" -ge "$MAX_SWITCHES_PER_WINDOW" ]; then
    if [ $((now - LAST_LIMIT_LOG)) -ge 60 ]; then
      say "已达到 ${SWITCH_WINDOW_SECONDS}s 内最多 ${MAX_SWITCHES_PER_WINDOW} 次切换的保护上限，暂不继续中断 App 媒体连接。"
      LAST_LIMIT_LOG="$now"
    fi
    return 1
  fi
  if [ $((now - LAST_SWITCH)) -lt "$MIN_SWITCH_INTERVAL" ]; then
    return 1
  fi

  group_json="$(api_request GET "/proxies/$(uri_encode "$group")")" || {
    say "无法读取 $group 分组，暂不切换。"
    return 1
  }
  selected_route="$(jq -r 'if (.fixed // "") != "" then .fixed else (.now // "") end' <<<"$group_json")"
  current_route="$selected_route"
  if [ -n "$connection_route" ] && jq -e --arg route "$connection_route" '(.all // []) | index($route) != null' >/dev/null <<<"$group_json"; then
    current_route="$connection_route"
  fi

  if [ -n "$current_route" ] && [ "$current_route" != "$selected_route" ]; then
    say "检测到旧媒体连接仍停留在 $current_route，但 $group 已切到 $selected_route；只关闭旧连接并按当前线路重连。"
    if [ "$DRY_RUN" != "1" ]; then
      api_request DELETE "/connections/$(uri_encode "$connection_id")" >/dev/null || return 1
    else
      say "DRY_RUN=1，跳过旧连接关闭。"
    fi
    LAST_SWITCH="$now"
    SWITCH_COUNT=$((SWITCH_COUNT + 1))
    unset 'LAST_BYTES[$connection_id]' 'LAST_CHECK[$connection_id]' 'FIRST_SEEN[$connection_id]'
    unset 'IDLE_SECONDS[$connection_id]' 'PROGRESS_IDLE_SECONDS[$connection_id]'
    unset 'LOW_SECONDS[$connection_id]' 'OBSERVED_PROGRESS[$connection_id]'
    return 0
  fi

  next_row="$(choose_next_route "$group_json" "$current_route" "$current_node")" || {
    say "没有找到可切换的健康地区组，保留当前线路：$group -> $current_route"
    return 1
  }
  IFS=$'\t' read -r next_route next_node next_provider next_delay <<<"$next_row"
  payload="$(jq -cn --arg name "$next_route" '{name: $name}')"

  say "检测到社交媒体连接异常：来源=$source_ip，目标=$host，分组=$group，当前=$current_route/$current_node，原因=$reason"
  say "切换 $group：$current_route -> $next_route（节点=$next_node，订阅=$next_provider，最近延迟=${next_delay}ms）"
  if [ "$DRY_RUN" != "1" ]; then
    api_request PUT "/proxies/$(uri_encode "$group")" "$payload" >/dev/null || {
      ROUTE_COOLDOWN["$next_route"]=$((now + ROUTE_COOLDOWN_SECONDS))
      say "地区组切换失败，保留当前连接。"
      return 1
    }
    api_request DELETE "/connections/$(uri_encode "$connection_id")" >/dev/null || {
      say "线路已切换，但无法关闭旧媒体连接：$connection_id"
      return 1
    }
  else
    say "DRY_RUN=1，跳过线路切换和连接关闭。"
  fi

  ROUTE_COOLDOWN["$current_route"]=$((now + ROUTE_COOLDOWN_SECONDS))
  LAST_SWITCH="$now"
  SWITCH_COUNT=$((SWITCH_COUNT + 1))
  unset 'LAST_BYTES[$connection_id]' 'LAST_CHECK[$connection_id]' 'FIRST_SEEN[$connection_id]'
  unset 'IDLE_SECONDS[$connection_id]' 'PROGRESS_IDLE_SECONDS[$connection_id]'
  unset 'LOW_SECONDS[$connection_id]' 'OBSERVED_PROGRESS[$connection_id]'
  return 0
}

say "社交媒体连接守护程序已启动：首次无下载=${INITIAL_STALL_SECONDS}s，X 视频中途停滞=${PROGRESS_STALL_SECONDS}s，低速阈值=${MIN_RATE_KIB}KiB/s/${LOW_RATE_SECONDS}s"

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
  while IFS=$'\t' read -r connection_id bytes current_node connection_route source_ip host; do
    [ -n "$connection_id" ] || continue
    group="$(group_for_host "$host" 2>/dev/null || true)"
    [ -n "$group" ] || continue
    seen["$connection_id"]=1
    is_uint "$bytes" || bytes=0

    if [ -z "${LAST_BYTES[$connection_id]+set}" ]; then
      LAST_BYTES["$connection_id"]="$bytes"
      LAST_CHECK["$connection_id"]="$now"
      FIRST_SEEN["$connection_id"]="$now"
      IDLE_SECONDS["$connection_id"]=0
      PROGRESS_IDLE_SECONDS["$connection_id"]=0
      LOW_SECONDS["$connection_id"]=0
      OBSERVED_PROGRESS["$connection_id"]=0
      say "开始监控媒体连接：来源=$source_ip，目标=$host，分组=$group，节点=$current_node"
      continue
    fi

    elapsed=$((now - LAST_CHECK[$connection_id]))
    [ "$elapsed" -gt 0 ] || elapsed="$CHECK_INTERVAL"
    delta=$((bytes - LAST_BYTES[$connection_id]))
    [ "$delta" -ge 0 ] || delta=0
    age=$((now - FIRST_SEEN[$connection_id]))
    rate_kib=$((delta / elapsed / 1024))

    if [ "$bytes" -eq 0 ] && [ "$delta" -eq 0 ]; then
      IDLE_SECONDS["$connection_id"]=$((IDLE_SECONDS[$connection_id] + elapsed))
    else
      IDLE_SECONDS["$connection_id"]=0
    fi
    if [ "$delta" -gt 0 ]; then
      OBSERVED_PROGRESS["$connection_id"]=1
      PROGRESS_IDLE_SECONDS["$connection_id"]=0
    elif [ "${OBSERVED_PROGRESS[$connection_id]}" = "1" ] && supports_progress_stall "$host"; then
      PROGRESS_IDLE_SECONDS["$connection_id"]=$((PROGRESS_IDLE_SECONDS[$connection_id] + elapsed))
    else
      PROGRESS_IDLE_SECONDS["$connection_id"]=0
    fi
    if [ "$delta" -gt 0 ] && [ "$rate_kib" -lt "$MIN_RATE_KIB" ]; then
      LOW_SECONDS["$connection_id"]=$((LOW_SECONDS[$connection_id] + elapsed))
    else
      LOW_SECONDS["$connection_id"]=0
    fi

    LAST_BYTES["$connection_id"]="$bytes"
    LAST_CHECK["$connection_id"]="$now"

    if [ "$age" -ge "$WARMUP_SECONDS" ] && [ "${IDLE_SECONDS[$connection_id]}" -ge "$INITIAL_STALL_SECONDS" ]; then
      switch_media_connection "$connection_id" "$current_node" "$connection_route" "$source_ip" "$host" "$group" \
        "新连接连续 ${IDLE_SECONDS[$connection_id]}s 没有收到数据" && switched=1
    elif [ "$age" -ge "$WARMUP_SECONDS" ] && [ "${PROGRESS_IDLE_SECONDS[$connection_id]}" -ge "$PROGRESS_STALL_SECONDS" ]; then
      switch_media_connection "$connection_id" "$current_node" "$connection_route" "$source_ip" "$host" "$group" \
        "X 视频传输后连续 ${PROGRESS_IDLE_SECONDS[$connection_id]}s 不再增长" && switched=1
    elif [ "$age" -ge "$WARMUP_SECONDS" ] && [ "${LOW_SECONDS[$connection_id]}" -ge "$LOW_RATE_SECONDS" ]; then
      switch_media_connection "$connection_id" "$current_node" "$connection_route" "$source_ip" "$host" "$group" \
        "连续 ${LOW_SECONDS[$connection_id]}s 低于 ${MIN_RATE_KIB}KiB/s（当前约 ${rate_kib}KiB/s）" && switched=1
    fi
    [ "$switched" = "0" ] || break
  done < <(
    jq -r --arg host_regex "$HOST_REGEX" '
      .connections[]?
      | select((.metadata.host // "") | test($host_regex; "i"))
      | [.id, (.download // 0), (.chains[0] // ""), (.chains[1] // ""), (.metadata.sourceIP // ""), (.metadata.host // "")]
      | @tsv
    ' <<<"$connections_json"
  )

  for connection_id in "${!LAST_BYTES[@]}"; do
    if [ -z "${seen[$connection_id]+set}" ]; then
      unset 'LAST_BYTES[$connection_id]' 'LAST_CHECK[$connection_id]' 'FIRST_SEEN[$connection_id]'
      unset 'IDLE_SECONDS[$connection_id]' 'PROGRESS_IDLE_SECONDS[$connection_id]'
      unset 'LOW_SECONDS[$connection_id]' 'OBSERVED_PROGRESS[$connection_id]'
    fi
  done

  [ "$RUN_ONCE" != "1" ] || break
  sleep "$CHECK_INTERVAL"
done
