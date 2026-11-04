#!/usr/bin/env bash
# =============================================================================
# cake-fairshare 2.0  ——  单机「在线人数自动平分带宽」交互式运维工具
#
# 原理：CAKE 的 per-host 公平队列。出口按目的 IP（客户端）平分，入口按源 IP
#       平分。N 人在线时每人约等于 总带宽/N，人少自动放宽，不依赖面板。
#
# 用法：
#   cake-fairshare              交互菜单（默认，需 root）
#   cake-fairshare apply        按配置启用（供 systemd 调用，无交互）
#   cake-fairshare stop         按配置撤销并恢复原 qdisc
#   cake-fairshare status       快照
#   cake-fairshare monitor [网卡]   实时监控
#   cake-fairshare --help
#
# 依赖：iproute2、bash。Debian 12 / Ubuntu 22.04+ 内核自带 sch_cake。
# =============================================================================

set -uo pipefail

VERSION="2.6.2"
# ---- 默认参数（新节点一键部署时的取值，按需修改这两行即可）----
# 190mbit = 腾讯云轻量 200M 峰值套餐的 95%；换成 30M/100M 套餐时改成 28mbit/95mbit
DEF_RATE="190mbit"
DEF_CAKE_OPTS_INGRESS="ack-filter"
CONF_DIR="/etc/cake-fairshare"
CONF="${CONF_DIR}/config"
UNIT="/etc/systemd/system/cake-fairshare.service"
SELF_INSTALL="/usr/local/sbin/cake-fairshare"
LOG_FILE="/var/log/cake-fairshare.log"
SAMPLE_LOG="/var/log/cake-fairshare-sample.log"
SAMPLE_STATE="/var/lib/cake-fairshare/last"
LOG_UNIT="/etc/systemd/system/cake-fairshare-log.service"

if [ -t 1 ]; then
  R=$'\033[0m'; B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; RD=$'\033[31m'; C=$'\033[36m'; D=$'\033[2m'
else
  R=""; B=""; G=""; Y=""; RD=""; C=""; D=""
fi

# ---------------------------------------------------------------- 基础输出 ----
say()   { printf '%s\n' "$*"; }
dim()   { printf '%b%s%b\n' "$D" "$*" "$R"; }
ok()    { printf '  %b✓%b %s\n' "$G" "$R" "$*"; }
bad()   { printf '  %b✗%b %s\n' "$RD" "$R" "$*"; }
note()  { printf '  %b!%b %s\n' "$Y" "$R" "$*"; }
die()   { printf '%b[错误]%b %s\n' "$RD" "$R" "$*" >&2; exit 1; }
hr()    { printf '%b%s%b\n' "$D" "------------------------------------------------------------" "$R"; }
pause() { printf '\n按回车返回菜单...'; read -r _ || true; }

logline() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请执行： sudo $0"
}

# ---------------------------------------------------------------- 环境探测 ----
os_pretty() {
  if [ -r /etc/os-release ]; then
    (. /etc/os-release; printf '%s' "${PRETTY_NAME:-unknown}")
  else
    printf 'unknown'
  fi
}

primary_iface() {
  ip -4 route show default 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

list_ifaces() {
  ip -o link show up 2>/dev/null \
    | awk -F': ' '{print $2}' \
    | grep -vE '^(lo|ifb[0-9]*|docker[0-9]*|veth.*|br-.*|virbr.*|tun[0-9]*|tap[0-9]*|__.*)$'
}

iface_has_v6() {
  ip -6 addr show dev "$1" scope global 2>/dev/null | grep -q 'inet6'
}

root_qdisc() {
  tc qdisc show dev "$1" 2>/dev/null | head -n1 | awk '{print $2}'
}

cake_supported() {
  modprobe sch_cake 2>/dev/null
  modinfo -n sch_cake >/dev/null 2>&1
}

cake_mq_supported() {
  local rc=1 created=0
  modprobe dummy 2>/dev/null
  ip link show __cakeprobe >/dev/null 2>&1 || {
    ip link add __cakeprobe type dummy 2>/dev/null || return 1
    created=1
  }
  tc qdisc add dev __cakeprobe root cake_mq >/dev/null 2>&1 && rc=0
  tc qdisc del dev __cakeprobe root >/dev/null 2>&1
  [ "$created" = "1" ] && ip link del __cakeprobe >/dev/null 2>&1
  return "$rc"
}

normalize_rate() {
  local raw="$1" num unit
  num=$(printf '%s' "$raw" | grep -oE '[0-9]+' | head -n1)
  unit=$(printf '%s' "$raw" | grep -oE '[A-Za-z]+' | head -n1)
  [ -n "$num" ] || return 1
  [ "$num" -gt 0 ] 2>/dev/null || return 1
  case "$(printf '%s' "$unit" | tr 'A-Z' 'a-z')" in
    g|gb|gbit|gbps) printf '%sgbit' "$num" ;;
    *)              printf '%smbit' "$num" ;;
  esac
}

# ------------------------------------------------------------ 配置与状态 ----
load_conf() {
  IFACES=""; RATE="$DEF_RATE"; MODE="both"
  RATE_EGRESS=""; RATE_INGRESS=""
  CAKE_OPTS=""; CAKE_OPTS_INGRESS="$DEF_CAKE_OPTS_INGRESS"
  # shellcheck disable=SC1090
  if [ -r "$CONF" ]; then . "$CONF"; fi
}

save_conf() {
  mkdir -p "$CONF_DIR"
  {
    printf '# 由 cake-fairshare 生成，手工修改后执行 apply 生效\n'
    printf 'IFACES="%s"\n' "$IFACES"
    printf 'RATE="%s"\n' "$RATE"
    printf 'MODE="%s"\n' "$MODE"
    printf '# 下面四项留空表示不启用；菜单第 9 项可直接改\n'
    printf 'RATE_EGRESS="%s"\n' "${RATE_EGRESS:-}"
    printf 'RATE_INGRESS="%s"\n' "${RATE_INGRESS:-}"
    printf 'CAKE_OPTS="%s"\n' "${CAKE_OPTS:-}"
    printf 'CAKE_OPTS_INGRESS="%s"\n' "${CAKE_OPTS_INGRESS:-}"
  } >"$CONF"
}

state_file() { printf '%s/state.%s' "$CONF_DIR" "$1"; }

get_state() {
  local f
  f=$(state_file "$1")
  [ -r "$f" ] || return 0
  sed -n "s/^$2=//p" "$f" | head -n1
}

put_state() {
  mkdir -p "$CONF_DIR" 2>/dev/null
  printf '%s=%s\n' "$2" "$3" >>"$(state_file "$1")"
}

clear_state() { rm -f "$(state_file "$1")" 2>/dev/null; }

is_active() {
  local ifc q
  load_conf
  for ifc in $IFACES; do
    q=$(root_qdisc "$ifc")
    [ "$q" = "cake" ] && return 0
    [ "$q" = "cake_mq" ] && return 0
  done
  return 1
}

# ------------------------------------------------------------ 环境预检 ----
# 找出会在开机时改写根队列的服务：unit 文件本身通常不含 tc 命令，
# 真正的命令在 ExecStart 指向的脚本里，所以必须顺着 ExecStart 去 grep。
find_shaper_units() {
  local u exe
  for u in $(systemctl list-unit-files --type=service --state=enabled --no-legend 2>/dev/null | awk '{print $1}'); do
    case "$u" in
      cake-fairshare* | systemd-* | ssh* | cron* | dbus* | getty* | user@* | rsyslog* | networking*) continue ;;
    esac
    exe=$(systemctl show -p ExecStart --value "$u" 2>/dev/null | grep -oE '/[^ ;"]+' | head -n1)
    [ -n "$exe" ] || continue
    [ -f "$exe" ] || continue
    if grep -qsE 'tc (qdisc|class|filter)' "$exe"; then
      printf '%s|%s\n' "$u" "$exe"
    fi
  done
}

# 返回 0 表示发现冲突，1 表示干净
preflight() {
  load_conf
  local ifc q d out found=1
  say ""
  say "${B}环境预检${R}"
  hr

  for ifc in ${IFACES:-$(list_ifaces)}; do
    ip link show "$ifc" >/dev/null 2>&1 || { bad "$ifc 不存在"; found=0; continue; }
    q=$(root_qdisc "$ifc")
    case "$q" in
      cake) ok "$ifc 根队列已是 cake" ;;
      mq) ok "$ifc 根队列 mq（多队列，可直接替换为 cake）" ;;
      htb | tbf | hfsc | cbq | prio | netem | drr | qfq)
        note "$ifc 根队列是 $q（将被 cake 替换）"
        found=0
        ;;
      *) dim "  $ifc 根队列是 $q" ;;
    esac
  done

  for d in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    q=$(root_qdisc "$d")
    case "$q" in
      cake) dim "  $d 是本工具创建的（下次 apply 会复用/回收）" ;;
      *)
        note "$d 挂着 $q，像是其他限速工具留下的残留设备"
        found=0
        ;;
    esac
  done

  out=$(find_shaper_units)
  if [ -n "$out" ]; then
    say "  以下已启用的服务会在启动时改写队列："
    printf '%s\n' "$out" | while IFS= read -r line; do
      note "${line%%|*}"
      dim "     ${line#*|}"
    done
    found=0
  fi

  local f
  for f in /root/bandwidth-limit.sh /root/vps-speed-limit /usr/local/sbin/wondershaper /usr/local/sbin/tc-limit; do
    [ -f "$f" ] || continue
    case "$out" in *"$f"*) continue ;; esac
    grep -qsE 'tc (qdisc|class|filter)' "$f" || continue
    dim "  发现历史限速脚本 $f（未随服务运行，留着无妨）"
  done

  if [ -f /etc/rc.local ] && grep -qsE 'tc (qdisc|class|filter)' /etc/rc.local; then
    note "/etc/rc.local 里含 tc 命令，开机时会执行"
    found=0
  fi

  if crontab -l 2>/dev/null | grep -qsE 'tc (qdisc|class|filter)'; then
    note "root 的 crontab 里含 tc 命令"
    found=0
  fi

  hr
  if [ "$found" -eq 1 ]; then
    ok "未发现会与 cake 抢根队列的东西"
    return 0
  fi
  note "存在上述项目；启用时可以选择停用它们，为 cake 让路"
  return 1
}

cleanup_conflicts() {
  local out u exe d n=0
  mkdir -p "$CONF_DIR" 2>/dev/null
  out=$(find_shaper_units)
  if [ -n "$out" ]; then
    while IFS= read -r line; do
      u="${line%%|*}"
      if systemctl disable --now "$u" >/dev/null 2>&1; then
        ok "已停用并禁止自启：$u"
        printf '%s\n' "$u" >>"${CONF_DIR}/disabled-units"
        logline "DISABLE $u"
        n=$((n + 1))
      else
        bad "停用 $u 失败（可能需要手动处理）"
      fi
    done <<EOF
$out
EOF
  fi

  for d in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    [ "$(root_qdisc "$d")" = "cake" ] && continue
    ip link del "$d" >/dev/null 2>&1 && { ok "已删除残留设备 $d"; n=$((n + 1)); }
  done

  if [ -s "${CONF_DIR}/disabled-units" ]; then
    sort -u "${CONF_DIR}/disabled-units" -o "${CONF_DIR}/disabled-units"
    dim "  恢复方式记在 ${CONF_DIR}/disabled-units，例如 systemctl enable --now <名字>"
  fi
  return 0
}


apply_one() {
  local ifc="$1" rate="$2" mode="$3"
  local qdisc="cake" orig cur prev_orig prev_ifb ifb="" idx=0
  local r_eg r_in
  r_eg="${RATE_EGRESS:-$rate}"
  r_in="${RATE_INGRESS:-$rate}"

  cur=$(root_qdisc "$ifc")
  # 注意：不要把 mq 当成障碍。多队列网卡的 root 是 mq，但 replace 到 cake 是允许的，
  # 只有 replace 真失败时才需要降到单队列（见下方失败分支）。

  prev_orig=$(get_state "$ifc" ORIG_QDISC)
  prev_ifb=$(get_state "$ifc" IFB)

  # 先拆掉 ingress 与上一轮的 ifb，再回收所有挂着 cake 的历史 ifb 设备，
  # 否则反复 apply 或状态丢失时会堆出一排孤儿设备（它们不承载流量，但会干扰排查）
  tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
  if [ -n "$prev_ifb" ]; then ip link del "$prev_ifb" >/dev/null 2>&1; fi
  # 回收本工具历史遗留的 ifb（根队列为 cake），但要避开其他已配置网卡正在用的那个，
  # 否则多网卡场景下先配 eth0 会把 eth1 的入口设备删掉
  local dev o o_ifb keep=""
  for o in $IFACES; do
    [ "$o" = "$ifc" ] && continue
    o_ifb=$(get_state "$o" IFB)
    [ -n "$o_ifb" ] && keep="$keep $o_ifb"
  done
  for dev in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    case " $keep " in *" $dev "*) continue ;; esac
    if [ "$(root_qdisc "$dev")" = "cake" ]; then
      ip link del "$dev" >/dev/null 2>&1
    fi
  done

  # 原始 qdisc 只记录第一次，后续 apply 不能把 cake 自己当成"原始值"
  orig="$prev_orig"
  case "$orig" in
    "" | cake | cake_mq)
      case "$cur" in
        cake | cake_mq) orig="${orig:-unknown}" ;;
        *) orig="$cur" ;;
      esac
      ;;
  esac

  clear_state "$ifc"
  put_state "$ifc" ORIG_QDISC "$orig"

  # shellcheck disable=SC2086
  if ! tc qdisc replace dev "$ifc" root "$qdisc" bandwidth "$r_eg" dual-dsthost ${CAKE_OPTS:-} 2>/dev/null; then
    bad "在 $ifc 上挂 $qdisc 失败（检查 CAKE_OPTS 是否合法）"
    if [ "$cur" = "mq" ]; then
      note "$ifc 根队列是 mq（多发送队列），若直接 replace 被拒，可降为单队列后重试："
      note "    ethtool -l $ifc              # 先看当前队列数"
      note "    ethtool -L $ifc combined 1   # 回滚：combined 改回原值"
    fi
    logline "FAIL $ifc tc-replace opts=[${CAKE_OPTS:-}]"
    clear_state "$ifc"
    return 1
  fi
  ok "出口整形：$ifc  $qdisc bandwidth $r_eg dual-dsthost ${CAKE_OPTS:-}"

  if [ "$mode" = "both" ]; then
    while ip link show "ifb$idx" >/dev/null 2>&1; do idx=$((idx + 1)); done
    ifb="ifb$idx"
    if ip link add "$ifb" type ifb 2>/dev/null && ip link set "$ifb" up 2>/dev/null; then
      tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
      tc qdisc add dev "$ifc" handle ffff: ingress 2>/dev/null
      tc filter add dev "$ifc" parent ffff: protocol all u32 \
          match u32 0 0 action mirred egress redirect dev "$ifb" >/dev/null 2>&1
      # shellcheck disable=SC2086
      tc qdisc replace dev "$ifb" root cake bandwidth "$r_in" dual-srchost ${CAKE_OPTS:-} ${CAKE_OPTS_INGRESS:-} 2>/dev/null
      put_state "$ifc" IFB "$ifb"
      ok "入口整形：$ifc -> $ifb  cake bandwidth $r_in dual-srchost ${CAKE_OPTS:-} ${CAKE_OPTS_INGRESS:-}"
    else
      note "入口整形建立失败（ifb 模块缺失？），仅生效出口方向"
    fi
  fi
  return 0
}

stop_one() {
  local ifc="$1" orig ifb
  orig=$(get_state "$ifc" ORIG_QDISC)
  ifb=$(get_state "$ifc" IFB)

  tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
  if [ -n "$ifb" ]; then ip link del "$ifb" >/dev/null 2>&1; fi
  tc qdisc del dev "$ifc" root >/dev/null 2>&1

  case "$orig" in
    "" | noqueue | null | mq | cake | cake_mq | unknown)
      ok "$ifc 已清除整形（内核会自动恢复默认队列）"
      ;;
    htb | tbf | hfsc | cbq | drr | qfq | pie | netem)
      note "$ifc 原队列是分层/有状态队列（$orig），无法自动重建其类与过滤器"
      note "若仍需要它，请用原工具重新应用，例如： systemctl enable --now bandwidth-limit"
      ;;
    *)
      if tc qdisc replace dev "$ifc" root "$orig" 2>/dev/null; then
        ok "$ifc 已恢复原 qdisc：$orig"
      else
        note "$ifc 恢复 $orig 失败，已回落内核默认队列"
      fi
      ;;
  esac
  clear_state "$ifc"
}

do_apply() {
  load_conf
  [ -n "$IFACES" ] || die "尚未配置网卡，请先运行交互菜单"
  local rc=0
  for ifc in $IFACES; do
    if ! ip link show "$ifc" >/dev/null 2>&1; then
      bad "网卡 $ifc 不存在，跳过"
      rc=1
      continue
    fi
    apply_one "$ifc" "$RATE" "$MODE" || rc=1
  done
  logline "APPLY ifaces=[$IFACES] rate=$RATE mode=$MODE rc=$rc"
  return "$rc"
}

do_stop() {
  load_conf
  for ifc in $IFACES; do
    ip link show "$ifc" >/dev/null 2>&1 || continue
    stop_one "$ifc"
  done
  logline "STOP ifaces=[$IFACES]"
}

# ---------------------------------------------------------------- 展示类 ----
show_env() {
  say ""
  say "${B}环境信息${R}"
  hr
  printf '  系统      : %s\n' "$(os_pretty)"
  printf '  内核      : %s\n' "$(uname -r)"
  printf '  拥塞控制  : %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  printf '  默认队列  : %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
  printf '  CAKE 支持 : '
  if cake_supported; then printf '%b可用%b\n' "$G" "$R"; else printf '%b缺失（缺 sch_cake 模块）%b\n' "$RD" "$R"; fi
  printf '  cake_mq   : '
  if cake_mq_supported; then
    printf '%b可用%b %b（可选，本工具不依赖它）%b\n' "$G" "$R" "$D" "$R"
  else
    printf '%b不可用%b %b（可选，不影响使用）%b\n' "$D" "$R" "$D" "$R"
  fi
  hr
  say "  网卡"
  local def ifc mark v6tag
  def=$(primary_iface)
  i=0
  for ifc in $ifc_list; do
    i=$((i + 1))
    [ "$ifc" = "$def" ] && def_idx=$i
  done
  for ifc in $(list_ifaces); do
    mark=""
    [ "$ifc" = "$def" ] && mark=" ${G}<- 默认路由${R}"
    v6tag=""
    if iface_has_v6 "$ifc"; then v6tag=" ${C}[+IPv6]${R}"; fi
    printf '    %-12s qdisc=%-8s %s%s%s\n' "$ifc" "$(root_qdisc "$ifc")" \
      "$(ip -4 -br addr show dev "$ifc" 2>/dev/null | awk '{print $3}' | head -n1)" "$v6tag" "$mark"
  done
  hr
  if [ -r "$CONF" ]; then
    load_conf
    if [ -z "${RATE_EGRESS:-}" ] && [ -z "${RATE_INGRESS:-}" ]; then
      printf '  当前配置  : 网卡=%s  带宽=%s  方向=%s\n' "$IFACES" "$RATE" "$MODE"
    else
      printf '  当前配置  : 网卡=%s  下行=%s  上行=%s  方向=%s\n' "$IFACES" "${RATE_EGRESS:-$RATE}" "${RATE_INGRESS:-$RATE}" "$MODE"
    fi
  else
    dim "  当前配置  : 尚未配置"
  fi
  printf '  整形状态  : '
  if is_active; then printf '%b运行中%b\n' "$G" "$R"; else printf '%b未启用%b\n' "$Y" "$R"; fi
  printf '  自启服务  : '
  if systemctl is-enabled cake-fairshare >/dev/null 2>&1; then
    printf '%b已开启%b\n' "$G" "$R"
  else
    printf '未开启\n'
  fi
}

show_status() {
  local ifc ifb
  say ""
  if [ ! -r "$CONF" ]; then note "尚未配置，无状态可看"; return 0; fi
  load_conf
  for ifc in $IFACES; do
    if ! ip link show "$ifc" >/dev/null 2>&1; then bad "$ifc 不存在"; continue; fi
    say "${B}$ifc  （出口）${R}"
    tc -s qdisc show dev "$ifc" | sed 's/^/    /'
    ifb=$(get_state "$ifc" IFB)
    if [ -n "$ifb" ] && ip link show "$ifb" >/dev/null 2>&1; then
      say ""
      say "${B}$ifb  （入口）${R}"
      tc -s qdisc show dev "$ifb" | sed 's/^/    /'
    fi
    say ""
  done
  dim "  判读：backlog 长期 0 = 没到上限；backlog 持续堆积 / drops 增长 = 正在压制。"
  dim "        overlimits 只是被整形器调度过的包数，不等于超速次数，别当比例看。"
}

monitor() {
  load_conf
  local ifc="${1:-}"
  [ -n "$ifc" ] || ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || { note "没有可用网卡"; return 1; }
  local rx1 tx1 rx2 tx2 t1 t2 dt stop=0
  trap 'stop=1' INT
  while [ "$stop" -eq 0 ]; do
    t1=$(date +%s%N)
    read -r rx1 tx1 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    sleep 2
    t2=$(date +%s%N)
    read -r rx2 tx2 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN{print (b-a)/1000000000}')
    if [ -t 1 ]; then clear; fi
    say "${B}实时监控  $ifc${R}   ${D}(Ctrl-C 退出)${R}"
    hr
    awk -v a="$rx1" -v b="$rx2" -v c="$tx1" -v d="$tx2" -v t="$dt" 'BEGIN{
      if (t <= 0) t = 1;
      printf "  下行 %.1f Mbps     上行 %.1f Mbps\n", (b-a)*8/t/1000000, (d-c)*8/t/1000000
    }'
    hr
    tc -s qdisc show dev "$ifc" | sed 's/^/  /'
  done
  trap - INT
  say ""
}

# ---------------------------------------------------------------- 菜单动作 ----
menu_enable() {
  local ifc_list def sel rate mode confirm chosen n pick ifc i ack def_idx=1
  ifc_list=$(list_ifaces)
  if [ -z "$ifc_list" ]; then bad "没有可用的物理网卡"; pause; return 1; fi
  def=$(primary_iface)

  # 先扫一遍环境：别的限速脚本/服务会和我们抢根队列，越早处理越好
  if ! preflight; then
    say ""
    read -rp "  是否停用它们并清理残留，为 cake 让路？[Y/n]: " confirm
    case "${confirm:-Y}" in
      y | Y | "")
        cleanup_conflicts
        say ""
        ;;
      *) note "已跳过，冲突项会在开机时与 cake 互相覆盖" ;;
    esac
  fi

  say ""
  say "${B}可用网卡${R}"
  hr
  i=0
  for ifc in $ifc_list; do
    i=$((i + 1))
    printf '  %d) %-12s %s\n' "$i" "$ifc" "$(ip -4 -br addr show dev "$ifc" 2>/dev/null | awk '{print $3}')"
  done
  say "  a) 全部网卡（v4/v6 分属不同网卡时选这个）"
  hr
  read -rp "选择网卡 [默认 ${def_idx}]（可输入 1 2 或 a）: " sel
  sel=${sel:-$def_idx}

  chosen=""
  if [ "$sel" = "a" ] || [ "$sel" = "A" ]; then
    chosen="$ifc_list"
  else
    for n in $sel; do
      pick=$(printf '%s\n' "$ifc_list" | sed -n "${n}p")
      if [ -z "$pick" ]; then bad "编号 $n 无效"; pause; return 1; fi
      chosen="$chosen $pick"
    done
  fi
  chosen=$(printf '%s' "$chosen" | tr -s ' ' | sed 's/^ //; s/ $//')

  read -rp "总带宽（95/100M/1gbit，按套餐峰值打 95%）[默认 ${DEF_RATE}]: " rate
  rate=$(normalize_rate "${rate:-$DEF_RATE}") || { bad "带宽格式无法识别"; pause; return 1; }

  say ""
  say "  限制方向："
  say "    1) 上下行都限（推荐，防止上传抢带宽）"
  say "    2) 只限下行（CPU 更省，仅整形出口）"
  read -rp "  选择 [默认 1]: " mode
  if [ "${mode:-1}" = "2" ]; then mode="down"; else mode="both"; fi

  # 只在还没有自定义 cake 参数时才询问，避免覆盖第 9 项的设置
  if [ -z "${CAKE_OPTS_INGRESS:-}" ]; then
    read -rp "  启用 ack-filter 压缩上行 ACK（跨国链路推荐）？[Y/n]: " ack
    case "${ack:-Y}" in
      n | N) CAKE_OPTS_INGRESS="" ;;
      *) CAKE_OPTS_INGRESS="ack-filter" ;;
    esac
  fi

  say ""
  say "${B}即将执行${R}"
  hr
  for ifc in $chosen; do
    say "  tc qdisc replace dev $ifc root cake bandwidth $rate dual-dsthost"
    if [ "$mode" = "both" ]; then
      say "  tc qdisc add dev $ifc handle ffff: ingress"
      say "  tc filter add dev $ifc parent ffff: ... action mirred redirect dev ifbN"
      say "  tc qdisc replace dev ifbN root cake bandwidth $rate dual-srchost"
    fi
  done
  say ""
  dim "  带宽填实测值的 95% 左右；等于或高于实际链路时队列不成为瓶颈，整形失效。"
  read -rp "确认执行？[y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then note "已取消"; pause; return 0; fi

  IFACES="$chosen"; RATE="$rate"; MODE="$mode"
  save_conf
  local rc=0
  for ifc in $chosen; do
    apply_one "$ifc" "$rate" "$mode" || rc=1
  done
  say ""
  if [ "$rc" -eq 0 ]; then
    if [ -z "${RATE_EGRESS:-}" ] && [ -z "${RATE_INGRESS:-}" ]; then
      ok "已启用：上下行各 ${rate}，每人在线可占 ${rate} ÷ 在线客户端数"
    else
      ok "已启用：下行 ${RATE_EGRESS:-$rate} / 上行 ${RATE_INGRESS:-$rate}（第 9 项可调）"
    fi
    dim "  验证：本菜单第 3/4 项"
  else
    note "部分网卡未成功，见上方提示"
  fi
  pause
}

menu_rate() {
  local rate confirm ifc
  load_conf
  if [ -z "$IFACES" ]; then note "尚未配置，请先执行第 2 项"; pause; return 1; fi
  say ""
  say "当前带宽：${B}$RATE${R}    网卡：$IFACES"
  if [ -n "${RATE_EGRESS:-}" ] || [ -n "${RATE_INGRESS:-}" ]; then
    note "已在第 9 项设置了单独的上/下行带宽，本次只改基准值，不覆盖它们"
  fi
  read -rp "新带宽（如 180mbit）: " rate
  if [ -z "$rate" ]; then note "已取消"; pause; return 0; fi
  rate=$(normalize_rate "$rate") || { bad "带宽格式无法识别"; pause; return 1; }
  read -rp "确认改为 $rate ？[y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then note "已取消"; pause; return 0; fi
  RATE="$rate"; save_conf
  for ifc in $IFACES; do
    apply_one "$ifc" "$RATE" "$MODE" >/dev/null || bad "$ifc 更新失败"
  done
  ok "已切换到 $RATE（不中断现有连接，队列参数即时生效）"
  pause
}

menu_stop() {
  local confirm
  load_conf
  say ""
  note "将撤销整形，并按 ${CONF_DIR}/state.* 记录的原始 qdisc 恢复"
  read -rp "确认停止？[y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then note "已取消"; pause; return 0; fi
  do_stop
  say ""
  ok "已恢复。若开了开机自启，请到第 6 项一并关闭，否则重启后会再次启用。"
  pause
}

install_service() {
  if [ ! -x "$SELF_INSTALL" ]; then
    install -m 0755 "$0" "$SELF_INSTALL" 2>/dev/null || return 1
  fi
  [ -r "$CONF" ] || return 1
  cat >"$UNIT" <<'EOF'
[Unit]
Description=CAKE fair-share bandwidth shaper
Documentation=man:tc-cake(8)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/cake-fairshare apply
ExecStop=/usr/local/sbin/cake-fairshare stop
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cake-fairshare >/dev/null 2>&1
}

do_init() {
  local rate="" ifc a clean=0
  for a in "$@"; do
    case "$a" in
      --clean) clean=1 ;;
      "" ) ;;
      *) rate="$a" ;;
    esac
  done
  rate=$(normalize_rate "${rate:-$DEF_RATE}") || die "带宽格式无法识别：${rate:-}"
  ifc=$(primary_iface)
  [ -n "$ifc" ] || die "找不到默认路由网卡，请手动用菜单第 2 项配置"
  require_root

  if [ -r "$CONF" ]; then
    cp "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    note "已备份原配置"
  fi
  IFACES="$ifc"; RATE="$rate"; MODE="both"
  RATE_EGRESS=""; RATE_INGRESS=""
  CAKE_OPTS=""; CAKE_OPTS_INGRESS="$DEF_CAKE_OPTS_INGRESS"
  save_conf
  ok "配置：网卡 $IFACES  带宽 $RATE  方向 both  入口参数 ${CAKE_OPTS_INGRESS:-无}"

  say ""
  if [ "$clean" = "1" ]; then
    cleanup_conflicts
  else
    preflight || note "上面这些冲突项未自动处理；需要自动停用请加 --clean"
  fi

  say ""
  do_apply || die "启用失败，见上方提示"
  say ""
  if install_service; then
    ok "已设置开机自启（cake-fairshare.service）"
  else
    bad "开机自启设置失败，可稍后用菜单第 6 项"
  fi

  say ""
  say "下一步（可选）："
  dim "  cake-fairshare          # 菜单第 10 项开启每分钟采样"
  dim "  cake-fairshare check    # 现场诊断"
}

menu_service() {
  local act
  say ""
  say "  1) 安装并开启开机自启"
  say "  2) 关闭并移除自启"
  say "  3) 查看服务状态"
  read -rp "选择 [默认 1]: " act
  case "${act:-1}" in
    1)
      [ -r "$CONF" ] || { bad "还没有配置，请先执行第 2 项"; pause; return 1; }
      if install_service; then
        ok "服务已启用并启动"
        systemctl --no-pager --lines=0 status cake-fairshare 2>/dev/null | sed 's/^/  /'
      else
        bad "服务启动失败，排查： journalctl -u cake-fairshare -n 30 --no-pager"
      fi
      ;;
    2)
      systemctl disable --now cake-fairshare >/dev/null 2>&1
      rm -f "$UNIT"
      systemctl daemon-reload
      ok "已关闭并移除自启（当前 tc 规则仍在，清理用第 5 项）"
      ;;
    3)
      if [ -f "$UNIT" ]; then
        systemctl --no-pager status cake-fairshare 2>/dev/null | sed 's/^/  /'
      else
        note "服务未安装"
      fi
      ;;
  esac
  pause
}

menu_advice() {
  say ""
  say "${B}IPv6 与多 IP 用户：为什么会多拿份额${R}"
  hr
  say "  CAKE 的公平单位是「IP 地址」，不是面板账号。以下情况会偏离 1/N："
  say "    · 同一用户双栈（v4+v6 同时连）→ 被识别成 2 个 host，拿 2 份"
  say "    · 同一用户多台设备 → 每台一份"
  say "    · IPv6 临时地址（RFC4941）频繁更换 → 可能被当成新 host"
  say "    · 多人共用同一出口 IP（CGNAT）→ 只拿 1 份"
  hr
  say "  若要严格按用户归并，可把同一用户的地址映射到固定 host 哈希。"
  say "  tc-cake(8) 支持用 tc filter 的 classid 覆盖 host 哈希（major 部分），"
  say "  链路为：nftables 按前缀打 mark → tc fw 分类器转 classid → cake 归并。"
  say ""
  dim "  以下示例未经实测，请先在测试机验证再上生产："
  say ""
  say "    # 1) cake 需带 handle"
  say "    tc qdisc replace dev eth0 root handle 1: cake bandwidth 95mbit dual-dsthost"
  say ""
  say "    # 2) nft 按用户前缀打 mark"
  say "    nft add table inet cakehost"
  say "    nft add set inet cakehost u1 '{ type ipv6_addr; flags interval; }'"
  say "    nft add element inet cakehost u1 '{ 2001:db8:1::/64 }'"
  say "    nft add chain inet cakehost mark '{ type filter hook prerouting priority mangle; }'"
  say "    nft add rule inet cakehost mark ip6 saddr @u1 meta mark set 1"
  say ""
  say "    # 3) tc fw 把 mark 转成 cake 的 host classid"
  say "    tc filter add dev eth0 parent 1: handle 0x1 fw classid 1:1"
  say "    tc filter add dev eth0 parent 1: handle 0x2 fw classid 1:2"
  say ""
  note "维护成本高（每加一个用户要改 nft 集合），普通节点没必要，"
  note "先接受 IP 粒度误差更省事。"
  hr
  say "  ${B}多队列网卡（mq）提示${R}"
  say "    状态里 qdisc 显示 mq 时，说明网卡有多个发送队列，cake 不能直接挂 root。"
  say "    处理：ethtool -L <网卡> combined 1"
  say "    回滚：先用 ethtool -l <网卡> 记下原队列数，再 ethtool -L <网卡> combined N"
  pause
}

menu_advanced() {
  local e i o oi ifc
  load_conf
  if [ -z "$IFACES" ]; then note "尚未配置，请先执行第 2 项"; pause; return 1; fi
  say ""
  say "${B}高级参数${R}"
  hr
  say "  留空 = 保持不变，输入 - = 清空。参数会原样追加到 cake 命令行。"
  say "  常用： ack-filter（压缩上行纯 ACK）  rtt 70ms  overhead 38  nat  wash"
  say "  注意：上下行分别限速后，第 7 项改的是基准值，此处会覆盖它。"
  hr
  printf '  出口带宽（当前 %s）: ' "${RATE_EGRESS:-跟随 $RATE}"
  read -rp "" e
  printf '  入口带宽（当前 %s）: ' "${RATE_INGRESS:-跟随 $RATE}"
  read -rp "" i
  printf '  通用 cake 参数（当前 %s）: ' "${CAKE_OPTS:-无}"
  read -rp "" o
  printf '  仅入口 cake 参数（当前 %s）: ' "${CAKE_OPTS_INGRESS:-无}"
  read -rp "" oi

  if [ -n "$e" ]; then
    if [ "$e" = "-" ]; then RATE_EGRESS=""; else
      RATE_EGRESS=$(normalize_rate "$e") || { bad "出口带宽格式无法识别"; pause; return 1; }
    fi
  fi
  if [ -n "$i" ]; then
    if [ "$i" = "-" ]; then RATE_INGRESS=""; else
      RATE_INGRESS=$(normalize_rate "$i") || { bad "入口带宽格式无法识别"; pause; return 1; }
    fi
  fi
  if [ "$o" = "-" ]; then CAKE_OPTS=""; elif [ -n "$o" ]; then CAKE_OPTS="$o"; fi
  if [ "$oi" = "-" ]; then CAKE_OPTS_INGRESS=""; elif [ -n "$oi" ]; then CAKE_OPTS_INGRESS="$oi"; fi

  save_conf
  say ""
  dim "  出口：bandwidth ${RATE_EGRESS:-$RATE} dual-dsthost ${CAKE_OPTS:-}"
  dim "  入口：bandwidth ${RATE_INGRESS:-$RATE} dual-srchost ${CAKE_OPTS:-} ${CAKE_OPTS_INGRESS:-}"
  say ""
  local rc=0
  for ifc in $IFACES; do
    apply_one "$ifc" "$RATE" "$MODE" || rc=1
  done
  if [ "$rc" -eq 0 ]; then
    ok "已应用"
  else
    note "有网卡应用失败（参数可能非法），该网卡原有规则未被替换"
  fi
  dim "  验证： tc qdisc show dev <网卡>"
  pause
}

# ------------------------------------------------------------ 采样与诊断 ----
unit_num() {
  local v n
  v=$(printf '%s' "$1")
  n=$(printf '%s' "$v" | grep -oE '[0-9]+' | head -n1)
  [ -n "$n" ] || n=0
  case "$v" in
    *[Gg]*) n=$((n * 1000)) ;;
  esac
  printf '%s' "$n"
}

iface_counters() {
  awk -v d="$1:" '$1==d {print $2, $10}' /proc/net/dev
}

qdisc_stat() {
  tc -s qdisc show dev "$1" 2>/dev/null | grep -oE "$2 [0-9]+" | head -n1 | awk '{print $2}'
}

trim_log() {
  [ -f "$SAMPLE_LOG" ] || return 0
  local n
  n=$(wc -l <"$SAMPLE_LOG" 2>/dev/null || echo 0)
  if [ "$n" -gt 30000 ]; then
    tail -n 20000 "$SAMPLE_LOG" >"${SAMPLE_LOG}.tmp" && mv "${SAMPLE_LOG}.tmp" "$SAMPLE_LOG"
  fi
}

sample_once() {
  load_conf
  local ifc now rx tx lts lrx ltx dt ifb
  ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  # 未配置时静默退出（返回 0），否则 timer 每分钟都会把 unit 记成 failed
  [ -n "$ifc" ] || return 0
  read -r rx tx < <(iface_counters "$ifc")
  [ -n "${rx:-}" ] || return 1

  now=$(date +%s)
  mkdir -p "$(dirname "$SAMPLE_STATE")" "$(dirname "$SAMPLE_LOG")" 2>/dev/null
  if [ -r "$SAMPLE_STATE" ]; then read -r lts lrx ltx <"$SAMPLE_STATE"; fi
  printf '%s %s %s\n' "$now" "$rx" "$tx" >"${SAMPLE_STATE}.tmp" && mv "${SAMPLE_STATE}.tmp" "$SAMPLE_STATE"

  [ -n "${lts:-}" ] || return 0
  dt=$((now - lts))
  [ "$dt" -gt 0 ] || return 0
  [ "$rx" -ge "${lrx:-0}" ] || return 0

  local rx_m tx_m eo ed io cn
  rx_m=$(awk -v a="$lrx" -v b="$rx" -v t="$dt" 'BEGIN{printf "%.2f",(b-a)*8/t/1000000}')
  tx_m=$(awk -v a="$ltx" -v b="$tx" -v t="$dt" 'BEGIN{printf "%.2f",(b-a)*8/t/1000000}')
  eo=$(qdisc_stat "$ifc" overlimits)
  ed=$(qdisc_stat "$ifc" dropped)
  ifb=$(get_state "$ifc" IFB)
  io=""
  [ -n "$ifb" ] && io=$(qdisc_stat "$ifb" overlimits)
  cn=$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')

  printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$rx_m" "$tx_m" \
    "${eo:-0}" "${ed:-0}" "${io:-0}" "${cn:-0}" >>"$SAMPLE_LOG"
  trim_log
}

show_report() {
  local n="${1:-30}"
  if [ ! -r "$SAMPLE_LOG" ]; then note "还没有采样数据，先执行采样开启（菜单第 10 项）"; return 1; fi
  say ""
  say "${B}最近 $n 条采样${R}（每分钟一次，下行=出口 上行=入口）"
  hr
  printf '  %-19s %10s %10s %8s %8s\n' "时间" "下行Mbps" "上行Mbps" "出口超限" "连接数"
  tail -n "$n" "$SAMPLE_LOG" | awk -F, '{
    printf "  %-19s %10.1f %10.1f %8s %8s\n", $1, $2, $3, $4, $7
  }'
  hr
  awk -F, 'BEGIN{mn=99999} {if($2+0<mn)mn=$2+0; if($2+0>mx)mx=$2+0; s+=$2+0; c++}
    END{if(c>0) printf "  下行 最小 %.1f / 平均 %.1f / 最大 %.1f Mbps（%d 个样本）\n", mn, s/c, mx, c}' \
    <(tail -n "$n" "$SAMPLE_LOG")
}

diagnose() {
  load_conf
  local ifc="${1:-}"
  [ -n "$ifc" ] || ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || { note "尚未配置网卡"; return 1; }

  local ifb egr ing r1 t1 r2 t2 rx_m tx_m pct eo ed
  ifb=$(get_state "$ifc" IFB)
  egr=$(unit_num "${RATE_EGRESS:-$RATE}")
  ing=$(unit_num "${RATE_INGRESS:-$RATE}")

  read -r r1 t1 < <(iface_counters "$ifc")
  sleep 1
  read -r r2 t2 < <(iface_counters "$ifc")
  tx_m=$(awk -v a="$t1" -v b="$t2" 'BEGIN{if(b>=a) printf "%.1f",(b-a)*8/1000000; else print "0"}')
  rx_m=$(awk -v a="$r1" -v b="$r2" 'BEGIN{if(b>=a) printf "%.1f",(b-a)*8/1000000; else print "0"}')
  pct=$(awk -v v="$tx_m" -v c="$egr" 'BEGIN{if(c>0) printf "%d", v*100/c; else print 0}')
  eo=$(qdisc_stat "$ifc" overlimits)
  ed=$(qdisc_stat "$ifc" dropped)

  say ""
  say "${B}现场诊断  $ifc${R}"
  hr
  printf '  当前下行（出口） : %s Mbps   上限 %s Mbps   占用 %s%%\n' "$tx_m" "$egr" "$pct"
  printf '  当前上行（入口） : %s Mbps   上限 %s Mbps\n' "$rx_m" "$ing"
  printf '  出口累计超限包数 : %s\n' "${eo:-?}"
  printf '  出口累计丢弃包数 : %s\n' "${ed:-?}"
  hr
  say "  当前连接数最多的对端（前 5）"
  ss -Htn state established 2>/dev/null | awk '{print $NF}' \
    | sed -E 's/:[0-9]+$//' | sort | uniq -c | sort -rn | head -5 | sed 's/^/    /'
  hr
  if [ "$pct" -ge 85 ]; then
    ok "链路已接近整形上限：此时测速偏低属正常，是自己在占用带宽"
  elif [ "$pct" -ge 40 ]; then
    note "带宽有一半左右在跑，速度还不理想的话看连接数是否分散"
  else
    bad "本机几乎空闲却慢 —— 整形不是瓶颈，问题在上游链路、跨境路由或平台侧限速"
    dim "  排查顺序： ping/mtr 到客户端 → 看是否晚高峰 → 对比历史采样日志"
  fi
}


# ------------------------------------------------------------ 健康报告 ----
show_speedtest_history() {
  local dir="${SPEEDTEST_DIR:-/root/speedtest_history}"
  [ -d "$dir" ] || return 0
  local files f ts dl ul maxdl
  files=$(ls -1t "$dir"/* 2>/dev/null | head -12 | sort)
  [ -n "$files" ] || return 0

  local maxdl=0 maxul=0
  for f in $files; do
    dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [ -n "$dl" ] || continue
    maxdl=$(awk -v a="$maxdl" -v b="$dl" 'BEGIN{print (b>a)?b:a}')
    [ -n "$ul" ] && maxul=$(awk -v a="$maxul" -v b="$ul" 'BEGIN{print (b>a)?b:a}')
  done
  awk -v m="$maxdl" 'BEGIN{exit !(m > 0)}' || return 0

  ST_ALERTS=0
  say ""
  say "  ${B}历史测速记录${R} ${D}（$dir   基准：下行 ${maxdl} / 上行 ${maxul} Mbps）${R}"
  for f in $files; do
    ts=$(head -1 "$f" 2>/dev/null)
    dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    [ -n "$dl" ] || continue
    tag=""
    if awk -v v="$dl" -v m="$maxdl" 'BEGIN{exit !(v < m*0.3)}'; then
      tag="  <- 下行异常偏低"
    fi
    if [ -n "$ul" ] && awk -v v="$ul" -v m="$maxul" 'BEGIN{exit !(v < m*0.3)}'; then
      if [ -n "$tag" ]; then tag="  <- 上下行都异常偏低"; else tag="  <- 上行异常偏低"; fi
    fi
    [ -n "$tag" ] && ST_ALERTS=$((ST_ALERTS + 1))
    if [ -n "$tag" ]; then
      printf '    %-18s 下行 %7s   上行 %7s Mbps   %b%s%b\n' "$ts" "$dl" "${ul:-?}" "$Y" "$tag" "$R"
    else
      printf '    %-18s 下行 %7s   上行 %7s Mbps\n' "$ts" "$dl" "${ul:-?}"
    fi
  done
}

health_report() {
  load_conf
  if [ ! -r "$SAMPLE_LOG" ]; then
    note "还没有采样数据"
    dim "  先到菜单第 10 项开启采样（每分钟记一次），累积几小时后这里就有报告了"
    return 1
  fi

  local cap_e cap_i n
  cap_e=$(unit_num "${RATE_EGRESS:-$RATE}")
  cap_i=$(unit_num "${RATE_INGRESS:-$RATE}")
  n=$(wc -l <"$SAMPLE_LOG")

  if [ "$n" -lt 2 ]; then
    note "采样数据只有 ${n} 条，还不够生成报告"
    dim "  采样每分钟 1 条，跑十几分钟后再看就有内容了"
    return 1
  fi

  say ""
  say "${B}带宽健康报告${R}"
  hr
  printf '  整形上限：下行 %s Mbps / 上行 %s Mbps\n' "$cap_e" "$cap_i"
  printf '  采样样本：%s 条（每分钟 1 条，约 %s 分钟）\n' "$n" "$n"
  hr

  awk -F, -v ce="$cap_e" -v ci="$cap_i" '
    {
      ts = $1; rx = $2 + 0; tx = $3 + 0; cn = $7 + 0
      key = substr(ts, 1, 13)
      if (!(key in seen)) { seen[key] = 1; order[++h] = key }
      cnt[key]++
      sr[key] += rx; st[key] += tx
      if (tx > mx[key]) mx[key] = tx
      if (rx > mr[key]) mr[key] = rx
      if (cn > mc[key]) mc[key] = cn
      if (tx > gmax) { gmax = tx; gmax_t = ts }
      if (rx > gramax) gramax = rx
      first = (first == "" ? ts : first)
      last = ts
    }
    END {
      printf "  %-13s %6s %8s %10s %10s %10s\n", "时段", "样本", "连接峰值", "下行峰值", "下行均值", "上行均值"
      for (i = 1; i <= h; i++) {
        k = order[i]
        flag = ""
        if (cnt[k] >= 5 && mc[k] >= 3 && mx[k] < ce * 0.2)
          flag = sprintf("  <- %d 个连接但峰值仅 %.1f Mbps，疑似外部限制", mc[k], mx[k])
        printf "  %-13s %6d %8d %10.1f %10.1f %10.1f%s\n", substr(k,6) ":00", cnt[k], mc[k], mx[k], st[k]/cnt[k], sr[k]/cnt[k], flag
      }
      printf "\n  记录区间：%s  ~  %s\n", first, last
      printf "  下行峰值：%.1f Mbps（%s）\n", gmax, gmax_t
      printf "  上行峰值：%.1f Mbps\n", gramax
      if (gmax > ce * 1.05) printf "  %s\n", "注：峰值高于整形上限，说明该时段整形被临时关闭过（例如手动测速）"
      else if (gmax < ce * 0.5) printf "  %s\n", "提示：峰值不到上限一半，可能是用户少，或上游本身跑不满"
    }
  ' "$SAMPLE_LOG"
  hr

  show_speedtest_history

  say ""
  hr
  if [ "${ST_ALERTS:-0}" -eq 0 ]; then
    ok "历史测速未发现异常，也没有「有连接但跑不动」的时段"
  else
    note "历史测速中有 ${ST_ALERTS} 次明显偏低（已用黄色标出），其余时间正常"
    dim "  短暂一两次通常是上游抖动或当时本机流量占满；频繁出现才需要考虑换线路或找服务商"
  fi
  dim "  说明：采样是「实际用量」不是「能力测试」。用量低不等于被限速，"
  dim "        只有「有多个连接、却始终跑不过上限 20%」才值得怀疑。"
  dim "        历史测速记录才是直接证据，偏低的那几条已经标出来了。"
}

menu_log() {
  local act n
  say ""
  say "  采样日志：每分钟记录一次上行/下行实速与队列统计，用于事后判断是否被平台限速"
  hr
  say "  1) 开启每分钟采样"
  say "  2) 关闭采样"
  say "  3) 查看最近记录"
  say "  4) 立即诊断（我现在占满没有）"
  read -rp "选择 [默认 1]: " act
  case "${act:-1}" in
    1)
      cat >"$LOG_UNIT" <<'EOF'
[Unit]
Description=CAKE fair-share bandwidth sampling
After=cake-fairshare.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cake-fairshare log
EOF
      cat >"${LOG_UNIT%.service}.timer" <<'EOF'
[Unit]
Description=Sample CAKE bandwidth every minute

[Timer]
OnBootSec=90s
OnUnitActiveSec=60s
AccuracySec=5s
Unit=cake-fairshare-log.service

[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      if systemctl enable --now cake-fairshare-log.timer >/dev/null 2>&1; then
        ok "已开启，每分钟采样一次（日志：$SAMPLE_LOG）"
        dim "  首次采样在 90 秒后，第二分钟起才有速率数据"
      else
        bad "启动失败，排查： systemctl status cake-fairshare-log.timer"
      fi
      ;;
    2)
      systemctl disable --now cake-fairshare-log.timer >/dev/null 2>&1
      rm -f "${LOG_UNIT%.service}.timer" "$LOG_UNIT"
      systemctl daemon-reload
      ok "已关闭采样（历史日志保留在 $SAMPLE_LOG）"
      ;;
    3)
      read -rp "看最近多少条 [默认 30]: " n
      show_report "${n:-30}"
      ;;
    4)
      diagnose
      ;;
  esac
  pause
}

# ---------------------------------------------------------------- 主菜单 ----
draw_menu() {
  if [ -t 1 ]; then clear; fi
  say ""
  printf '%b  CAKE 公平带宽分配 v%s%b   %b%s%b\n' "$B" "$VERSION" "$R" "$D" "$(os_pretty)" "$R"
  hr
  if is_active; then
    printf '  状态：%b● 运行中%b' "$G" "$R"
  else
    printf '  状态：%b○ 未启用%b' "$Y" "$R"
  fi
  if [ -r "$CONF" ]; then
    printf '      网卡 %s   下行 %s / 上行 %s   方向 %s\n' "$IFACES" "${RATE_EGRESS:-$RATE}" "${RATE_INGRESS:-$RATE}" "$MODE"
  else
    printf '      尚未配置\n'
  fi
  hr
  say "  1) 环境自检（系统 / 内核 / 网卡 / qdisc / BBR / cake 支持）"
  say "  2) 启用或重新配置整形"
  say "  3) 查看当前状态快照"
  say "  4) 实时流量监控"
  say "  5) 停止整形并恢复原始 qdisc"
  say "  6) 开机自启（安装 / 移除 / 查看）"
  say "  7) 调整带宽"
  say "  8) IPv6 与多 IP 用户说明（进阶）"
  say "  9) 高级参数（cake 选项 / 上下行分别限速）"
  say " 10) 采样日志与现场诊断"
  say " 11) 带宽健康报告（是否被限速，可给小白看）"
  say "  0) 退出"
  hr
}

main_menu() {
  require_root
  local choice
  while true; do
    draw_menu
    read -rp "  请输入编号: " choice || { say ""; exit 0; }
    case "$choice" in
      1) show_env; preflight; pause ;;
      2) menu_enable ;;
      3) show_status; pause ;;
      4) monitor ;;
      5) menu_stop ;;
      6) menu_service ;;
      7) menu_rate ;;
      8) menu_advice ;;
      9) menu_advanced ;;
      10) menu_log ;;
      11) health_report; pause ;;
      0|q|Q) say ""; exit 0 ;;
      *) note "无效输入"; sleep 1 ;;
    esac
  done
}

usage() {
  cat <<EOF
cake-fairshare v${VERSION} — 按在线人数自动平分带宽

  cake-fairshare                交互菜单（推荐）
  cake-fairshare apply          按配置启用（无交互，供 systemd 用）
  cake-fairshare stop           撤销整形并恢复原 qdisc
  cake-fairshare status         状态快照
  cake-fairshare monitor [网卡] 实时监控
  cake-fairshare log            采样一次（供 systemd timer 调用）
  cake-fairshare report [N]     查看最近 N 条采样
  cake-fairshare check          现场诊断（判断是否自身占满）
  cake-fairshare health         带宽健康报告（限速历史）
  cake-fairshare init [带宽] [--clean]
                                一键配置并启用；--clean 自动停用冲突的限速服务
  cake-fairshare preflight      只检查环境，不改任何东西
  cake-fairshare --help

配置：${CONF}
状态：${CONF_DIR}/state.<网卡>
日志：${LOG_FILE}
EOF
}

case "${1:-}" in
  "")             main_menu ;;
  apply)          require_root; do_apply ;;
  stop)           require_root; do_stop ;;
  status)         require_root; show_status ;;
  monitor)        require_root; load_conf; monitor "${2:-}" ;;
  log)            require_root; sample_once ;;
  sample)         require_root; sample_once ;;
  report)         require_root; show_report "${2:-30}" ;;
  check)          require_root; load_conf; diagnose "${2:-}" ;;
  health)         require_root; health_report ;;
  preflight)      require_root; preflight ;;
  init)
    shift
    load_conf
    require_root
    do_init "$@"
    ;;
  -h|--help|help) usage ;;
  *)              usage; exit 1 ;;
esac
