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

VERSION="3.2.2"
# ---- 默认参数（新节点一键部署时的取值，按需修改这两行即可）----
# 190mbit = 腾讯云轻量 200M 峰值套餐的 95%；换成 30M/100M 套餐时改成 28mbit/95mbit
DEF_RATE="190mbit"
DEF_CAKE_OPTS_INGRESS="ack-filter"
CONF_DIR="/etc/cake-fairshare"
CONF="${CONF_DIR}/config"
UNIT="/etc/systemd/system/cake-fairshare.service"
SELF_INSTALL="/usr/local/sbin/cake-fairshare"
ALIAS_LINK="/usr/local/sbin/cake"
LOG_FILE="/var/log/cake-fairshare.log"
SAMPLE_LOG="/var/log/cake-fairshare-sample.log"
SAMPLE_STATE="/var/lib/cake-fairshare/last"
LOG_UNIT="/etc/systemd/system/cake-fairshare-log.service"
DAILY_LOG="/var/log/cake-fairshare-daily.log"
REPORT_UNIT="/etc/systemd/system/cake-fairshare-report.service"

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
  NODE_NAME=""
  IFACES=""; RATE="$DEF_RATE"; MODE="both"
  RATE_EGRESS=""; RATE_INGRESS=""
  CAKE_OPTS=""; CAKE_OPTS_INGRESS="$DEF_CAKE_OPTS_INGRESS"
  # shellcheck disable=SC1090
  if [ -r "$CONF" ]; then . "$CONF"; fi
}

save_conf() {
  mkdir -p "$CONF_DIR"
  # 与基准值相同的分方向设置等于没设，顺手清掉：
  # 否则配置里会留着 RATE_EGRESS=168 这种冗余，用户看到会以为改它有用。
  if [ -n "${RATE_EGRESS:-}" ] && [ "$(unit_num "$RATE_EGRESS")" = "$(unit_num "$RATE")" ]; then
    RATE_EGRESS=""
  fi
  if [ -n "${RATE_INGRESS:-}" ] && [ "$(unit_num "$RATE_INGRESS")" = "$(unit_num "$RATE")" ]; then
    RATE_INGRESS=""
  fi
  {
    printf '# 由 cake-fairshare 生成，手工修改后执行 apply 生效\n'
    printf 'NODE_NAME="%s"\n' "${NODE_NAME:-}"
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
      # ifb 新建时 txqueuelen 只有 32 个包，入口方向任何微突发都会被直接丢弃
      # （实测某节点 4 天丢 280 万个包）。放到 1000，让 cake 自己去管排队。
      ip link set "$ifb" txqueuelen 1000 2>/dev/null
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
  printf '  节点名称  : %s\n' "${NODE_NAME:-(未命名，用 cake-fairshare name 设置)}"
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
  # 注意：这里不要引用 ifc_list —— 那是 menu_enable 的局部变量，
  # 在 set -u 下自检会直接中断（v2.9.0 前的隐藏 bug：自检只显示到"网卡"就停）
  for ifc in $(list_ifaces); do
    mark=""
    [ "$ifc" = "$def" ] && mark=" ${G}<- 默认路由${R}"
    v6tag=""
    if iface_has_v6 "$ifc"; then v6tag=" ${C}[+IPv6]${R}"; fi
    printf '    %-12s qdisc=%-8s %s%s%s\n' "$ifc" "$(root_qdisc "$ifc")" \
      "$(ip -4 -br addr show dev "$ifc" 2>/dev/null | awk '{print $3}' | head -n1)" "$v6tag" "$mark"
  done

  # 只有私网地址 = 云厂商 EIP/NAT 场景：带宽限制作用在出方向
  local a4
  a4=$(ip -4 -br addr show dev "$def" 2>/dev/null | awk '{print $3}' | head -n1)
  case "$a4" in
    10.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.*)
      dim "  公网出口  : $def 只有私网地址（EIP/NAT），云厂商的带宽限制作用在出方向"
      dim "              所以 RATE_EGRESS 才是用户下载的实际上限，RATE_INGRESS 可略高"
      ;;
  esac

  # 入口 ifb 队列过短会在微突发时直接丢包（旧版本默认 32，实测丢 1.4%）
  local dev q
  for dev in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    q=$(cat "/sys/class/net/$dev/tx_queue_len" 2>/dev/null)
    if [ -n "$q" ] && [ "$q" -lt 1000 ]; then
      printf '  %b!%b %s 队列长度仅 %s 个包，入口容易丢包；重新 apply 会自动改为 1000\n' "$Y" "$R" "$dev" "$q"
    fi
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
  if [ -n "${NODE_NAME:-}" ]; then say "${B}$NODE_NAME${R}"; fi
  for ifc in $IFACES; do
    if ! ip link show "$ifc" >/dev/null 2>&1; then bad "$ifc 不存在"; continue; fi
    say "${B}$ifc  （出口）${R}"
    tc -s qdisc show dev "$ifc" | sed 's/^/    /'
    ifb=$(get_state "$ifc" IFB)
    if [ -n "$ifb" ] && ip link show "$ifb" >/dev/null 2>&1; then
      say ""
      say "${B}$ifb  （入口）${R}  ${D}qlen=$(cat "/sys/class/net/$ifb/tx_queue_len" 2>/dev/null)${R}"
      tc -s qdisc show dev "$ifb" | sed 's/^/    /'
    fi
    say ""
  done
  dim "  判读：backlog 长期 0 = 没到上限；backlog 持续堆积 / drops 增长 = 正在压制。"
  dim "        overlimits 只是被整形器调度过的包数，不等于超速次数，别当比例看。"
}

menu_monitor() {
  local act
  load_conf
  say ""
  say "${B}实时监控${R}"
  hr
  say "  1) 总体：整机上下行速率 + 队列计数"
  say "  2) 按客户端：每个 IP 的实时上下行、连接数、估算份额    ← 新"
  read -rp "选择 [默认 2]: " act
  case "${act:-2}" in
    1) monitor ;;
    *) monitor_clients ;;
  esac
}

client_snapshot() {
  # 输出每行 "ip 下行字节 上行字节 连接数"
  # 下行 = 服务器发给客户端（bytes_sent），上行 = 客户端发来（bytes_received）
  # 只统计本地端口是本机监听端口的连接，排除 22，
  # 否则会把 XrayR 出站到目标站的连接也算进来。
  # 监听端口集合由调用方传入（一次采集里不会变），省掉每帧一次 ss 调用。
  local lports="${1:-}"
  [ -n "$lports" ] || lports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*://' | grep -vx '22' | sort -u | tr '\n' ',')
  [ -n "$lports" ] || return 0
  ss -Htni state established 2>/dev/null | awk -v lp=",$lports" '
    NF >= 4 && $3 ~ /:[0-9]+$/ && $4 ~ /:[0-9]+$/ {
      n = split($3, a, ":")
      if (index(lp, "," a[n] ",") > 0) {
        ip = $4
        sub(/:[0-9]+$/, "", ip)
        gsub(/^\[/, "", ip); gsub(/\]$/, "", ip); sub(/^::ffff:/, "", ip)
        cur = ip
        C[ip]++
      } else {
        cur = ""
      }
      next
    }
    cur != "" && /bytes_sent:|bytes_received:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^bytes_sent:/) { v = $i; sub(/^bytes_sent:/, "", v); S[cur] += v + 0 }
        else if ($i ~ /^bytes_received:/) { v = $i; sub(/^bytes_received:/, "", v); R[cur] += v + 0 }
      }
    }
    END { for (k in C) printf "%s %d %d %d\n", k, S[k], R[k], C[k] }
  '
}

# 解析 tc -s qdisc show：按 dev 名分别取 backlog 字节数
QD_AWK='
  /^qdisc/ {
    cur = ""; k = 0
    for (i = 1; i <= NF; i++) if ($i == "dev") k = i + 1
    if (k > 0) cur = $k
  }
  /backlog/ {
    if (cur == a && ea == "") ea = $2
    if (cur == b && eb == "") eb = $2
  }
  END {
    sub(/b$/, "", ea); sub(/b$/, "", eb)
    printf "%s %s\n", (ea == "" ? 0 : ea), (eb == "" ? 0 : eb)
  }'

monitor_clients() {
  require_root
  load_conf
  local ifc interval="${1:-2}" rows="${2:-10}" cap_e cap_i f1 f2 f3 t1 t2 stop=0 eb ib ifb lports ln l2
  ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || ifc=$(primary_iface)
  [ -n "$ifc" ] || { note "没有可用网卡"; return 1; }
  case "$interval" in '' | *[!0-9]*) interval=2 ;; esac
  [ "$interval" -ge 1 ] || interval=1
  case "$rows" in '' | *[!0-9]*) rows=10 ;; esac
  [ "$rows" -ge 3 ] 2>/dev/null || rows=10
  [ "$rows" -le 40 ] 2>/dev/null || rows=40
  cap_e=$(unit_num "${RATE_EGRESS:-$RATE}")
  cap_i=$(unit_num "${RATE_INGRESS:-$RATE}")

  f1=$(mktemp) || return 1
  f2=$(mktemp) || { rm -f "$f1"; return 1; }
  f3=$(mktemp) || { rm -f "$f1" "$f2"; return 1; }
  # 监听端口在一次观察期间不会变，算一次就够
  local lports
  lports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*://' | grep -vx '22' | sort -u | tr '\n' ',')
  [ -n "$lports" ] || { note "没找到正在监听的代理端口（XrayR 没跑？）"; rm -f "$f1" "$f2"; return 1; }
  ifb=$(get_state "$ifc" IFB)
  trap 'stop=1' INT
  # 只在一开始清一次屏。之后每帧把光标移回左上角就地覆盖，
  # 不要再 clear —— 先清空再重画会让整屏闪一下，看起来一闪一闪的。
  if [ -t 1 ]; then clear; fi
  while [ "$stop" -eq 0 ]; do
    # EPOCHREALTIME 是 bash 内建，比 date 少 fork 两次
    if [ -n "${EPOCHREALTIME:-}" ]; then t1=${EPOCHREALTIME/./}; else t1=$(date +%s%6N); fi
    client_snapshot "$lports" >"$f1"
    sleep "$interval"
    if [ -n "${EPOCHREALTIME:-}" ]; then t2=${EPOCHREALTIME/./}; else t2=$(date +%s%6N); fi
    client_snapshot "$lports" >"$f2"
    {
    say "${B}客户端实时带宽${R}  ${D}$ifc   上限 下行 ${cap_e} / 上行 ${cap_i} Mbps   Ctrl-C 退出${R}"
    hr
    # 表头用 shell 手写而不是 awk 的 %-20s：printf 按字节补齐，
    # 中文是 3 字节但只占 2 列宽，交给它排必然错位。
    say "  客户端 IP            连接       下行       上行       合计  占份额"
    say "  --------------------  ----  ---------  ---------  ---------  -------"
    awk -v t="$t1" -v t2="$t2" -v ce="$cap_e" -v TBL="$rows" '
      BEGIN { dt = (t2 - t) / 1000000; if (dt <= 0) dt = 1 }
      FNR == NR { s1[$1] = $2; r1[$1] = $3; next }
      {
        ip = $1
        dn = ($2 - (ip in s1 ? s1[ip] : $2)) * 8 / dt / 1000000
        up = ($3 - (ip in s1 ? r1[ip] : $3)) * 8 / dt / 1000000
        if (dn < 0) dn = 0
        if (up < 0) up = 0
        n++
        IP[n] = ip; DN[ip] = dn; UP[ip] = up; CN[ip] = $4
        if (dn + up >= 0.05) act++
        TD += dn; TU += up
      }
      END {
        # 按合计速率降序
        for (i = 1; i <= n; i++) {
          bi = i
          for (j = i + 1; j <= n; j++)
            if (DN[IP[j]] + UP[IP[j]] > DN[IP[bi]] + UP[bi]) bi = j
          k = IP[i]; IP[i] = IP[bi]; IP[bi] = k
        }
        sh = (act > 0) ? ce / act : 0

        # 有流量的排前面（按合计速率降序），没流量的排后面（按连接数降序）
        a = 0
        b = 0
        for (i = 1; i <= n; i++) {
          ip = IP[i]
          if (DN[ip] + UP[ip] >= 0.05) { a++; A[a] = ip }
          else { b++; B[b] = ip }
        }
        for (i = 1; i <= b; i++) {
          bi = i
          for (j = i + 1; j <= b; j++) if (CN[B[j]] > CN[B[bi]]) bi = j
          k = B[i]; B[i] = B[bi]; B[bi] = k
        }
        r = 0
        for (i = 1; i <= a; i++) { r++; RIP[r] = A[i]; RACT[r] = 1 }
        for (i = 1; i <= b; i++) { r++; RIP[r] = B[i]; RACT[r] = 0 }

        # 表格固定占 TBL 行。否则客户端数量一变，下面的汇总行就跟着上下跳，
        # 盯着看很晃眼。超出部分折成一行提示。
        if (r == 0) {
          printf "  （当前没有任何客户端连接）\n"
          used = 1
        } else {
          show = (r > TBL) ? TBL - 1 : r
          for (i = 1; i <= show; i++) {
            ip = RIP[i]
            if (RACT[i]) {
              pct = (sh > 0) ? (DN[ip] + UP[ip]) * 100 / sh : 0
              printf "  %-20s %4d %10.2f %10.2f %10.2f %5.0f%%\n", ip, CN[ip], DN[ip], UP[ip], DN[ip] + UP[ip], pct
            } else {
              printf "  %-20s %4d %10s %10s %10s  空载\n", ip, CN[ip], "-", "-", "-"
            }
          }
          used = show
          if (r > TBL) {
            printf "  ... 另有 %d 个客户端未显示（共 %d 个在线，其中 %d 个在传数据）\n", r - show, r, a
            used++
          }
        }
        for (i = used; i < TBL; i++) printf "\n"

        # 汇总固定三行，不随客户端数量增减
        printf "\n"
        printf "  活跃客户端 %d 个（有流量的）   合计 下行 %.2f / 上行 %.2f Mbps\n", act, TD, TU
        if (act > 0 && ce > 0)
          printf "  每人估算份额 %.1f Mbps（%d ÷ %d）   出口占用 %.0f%%\n", sh, ce, act, TD * 100 / ce
        else
          printf "  每人估算份额 --（当前没有客户端在传数据）   出口占用 0%%\n"
        if (n > act)
          printf "  另有 %d 个客户端连着但没有流量（不占份额）\n", n - act
        else
          printf "  所有在线的客户端都有流量\n"
      }' "$f1" "$f2"
    hr
    # 一次 tc 同时取出口和入口的积压，别为两个数起两次进程。
    # awk 脚本必须先放进单引号变量：直接内联进 "$(...)" 时，
    # 里面的 $(i + 1) 和 $0 会被 bash 当成本机的命令替换／变量先展开掉。
    read -r eb ib <<<"$(tc -s qdisc show 2>/dev/null | awk -v a="$ifc" -v b="$ifb" "$QD_AWK")"
    dim "  出口队列积压 ${eb:-0} B   入口积压 ${ib:-0} B   （长期为 0 = 没到上限）"
    } >"$f3"
    # 就地覆盖。整帧先拼成一个字符串再一次性写出：
    # 逐行 printf 在 SSH 上会分成多次写，容易出现半帧撕裂的观感。
    # 每行尾部加 ESC[K，数字变短时不会留下上一帧的残字。
    if [ -t 1 ]; then
      ln=''
      while IFS= read -r l2; do ln+="$l2"$'\033[K\n'; done <"$f3"
      printf '\033[H%s' "$ln"
    else
      cat "$f3"
    fi
  done
  trap - INT
  rm -f "$f1" "$f2" "$f3"
  say ""
}

monitor() {
  load_conf
  local ifc="${1:-}"
  [ -n "$ifc" ] || ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || { note "没有可用网卡"; return 1; }
  local rx1 tx1 rx2 tx2 t1 t2 dt stop=0
  trap 'stop=1' INT
  if [ -t 1 ]; then clear; fi
  while [ "$stop" -eq 0 ]; do
    t1=$(date +%s%N)
    read -r rx1 tx1 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    sleep 2
    t2=$(date +%s%N)
    read -r rx2 tx2 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN{print (b-a)/1000000000}')
    if [ -t 1 ]; then printf '\033[H'; fi
    say "${B}实时监控  $ifc${R}   ${D}(Ctrl-C 退出)${R}"
    hr
    awk -v a="$rx1" -v b="$rx2" -v c="$tx1" -v d="$tx2" -v t="$dt" 'BEGIN{
      if (t <= 0) t = 1;
      printf "  下行 %.1f Mbps     上行 %.1f Mbps\n", (b-a)*8/t/1000000, (d-c)*8/t/1000000
    }'
    hr
    tc -s qdisc show dev "$ifc" | sed 's/^/  /'
    # 这一块行数可能变少，擦掉残留
    if [ -t 1 ]; then printf '\033[J'; fi
  done
  trap - INT
  say ""
}

# ---------------------------------------------------------------- 菜单动作 ----
do_name() {
  load_conf
  if [ -z "${1:-}" ]; then
    printf '%s\n' "${NODE_NAME:-(未命名)}"
    return 0
  fi
  if [ ! -r "$CONF" ]; then
    bad "还没有配置，先运行 cake-fairshare init"
    return 1
  fi
  NODE_NAME="$*"
  save_conf
  ok "节点名称已设为：$NODE_NAME"
  dim "  菜单、status、health、日报都会显示这个名字"
}

menu_enable() {
  local act
  load_conf
  say ""
  say "${B}配置整形${R}"
  hr
  say "  1) 一键优化：先分析机器，再套用推荐配置        ← 推荐"
  say "  2) 自定义：手动选网卡、带宽、方向"
  read -rp "选择 [默认 1]: " act
  case "${act:-1}" in
    2) menu_custom ;;
    *) do_optimize; pause ;;
  esac
}

menu_custom() {
  local ifc_list def sel rate mode confirm chosen n pick ifc i ack def_idx=1
  local cur="" ovr=0 r_eg="" r_in=""
  load_conf
  cur="${RATE:-}"
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

  read -rp "总带宽（95/100M/1gbit，按套餐峰值打 95%）[默认 ${cur:-$DEF_RATE}]: " rate
  rate=$(normalize_rate "${rate:-${cur:-$DEF_RATE}}") || { bad "带宽格式无法识别"; pause; return 1; }

  if [ -n "${RATE_EGRESS:-}" ] || [ -n "${RATE_INGRESS:-}" ]; then ovr=1; fi

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

  # 已有单独的上/下行值时，"总带宽"不会生效。必须先问清楚再算预览，
  # 否则用户改了总带宽却看不到任何变化，而预览还显示成新值，纯误导。
  if [ "$ovr" -eq 1 ]; then
    say ""
    printf '  %b!%b 这台机器在第 9 项单独设置过带宽：出口 %s / 入口 %s\n' \
      "$Y" "$R" "${RATE_EGRESS:-跟随基准}" "${RATE_INGRESS:-跟随基准}"
    dim "    单独设置优先，所以本次填的\"总带宽 $rate\"不会生效。"
    read -rp "  是否清空单独设置，统一用 $rate ？[y/N]: " confirm
    case "$confirm" in
      y | Y)
        RATE_EGRESS=""; RATE_INGRESS=""
        ok "已清空单独设置，出/入口统一 $rate"
        ;;
      *) note "保留单独设置（要单独改就走第 9 项）" ;;
    esac
  fi

  r_eg="${RATE_EGRESS:-$rate}"
  r_in="${RATE_INGRESS:-$rate}"

  say ""
  say "${B}即将执行${R}"
  hr
  for ifc in $chosen; do
    say "  tc qdisc replace dev $ifc root cake bandwidth $r_eg dual-dsthost"
    if [ "$mode" = "both" ]; then
      say "  tc qdisc add dev $ifc handle ffff: ingress"
      say "  tc filter add dev $ifc parent ffff: ... action mirred redirect dev ifbN"
      say "  tc qdisc replace dev ifbN root cake bandwidth $r_in dual-srchost"
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
  local rate confirm ifc clear_ovr="" r_eg r_in
  load_conf
  if [ -z "$IFACES" ]; then note "尚未配置，请先执行第 2 项"; pause; return 1; fi
  r_eg="${RATE_EGRESS:-$RATE}"
  r_in="${RATE_INGRESS:-$RATE}"

  say ""
  say "网卡：${B}$IFACES${R}"
  printf '  基准带宽：%s\n' "$RATE"
  if [ -n "${RATE_EGRESS:-}" ] || [ -n "${RATE_INGRESS:-}" ]; then
    printf '  实际生效：出口 %s / 入口 %s  %b（第 9 项单独设置，优先于基准值）%b\n' \
      "$r_eg" "$r_in" "$Y" "$R"
  else
    printf '  实际生效：出口 %s / 入口 %s\n' "$r_eg" "$r_in"
  fi

  read -rp "新带宽（如 180mbit）: " rate
  if [ -z "$rate" ]; then note "已取消"; pause; return 0; fi
  rate=$(normalize_rate "$rate") || { bad "带宽格式无法识别"; pause; return 1; }

  if [ -n "${RATE_EGRESS:-}" ] || [ -n "${RATE_INGRESS:-}" ]; then
    note "只改基准值不会生效，因为单独设置优先"
    read -rp "  是否清空单独设置，让出口和入口都跟随 $rate ？[Y/n]: " clear_ovr
  fi

  read -rp "确认改为 $rate ？[y/N]: " confirm
  if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then note "已取消"; pause; return 0; fi

  RATE="$rate"
  case "${clear_ovr:-Y}" in
    n | N) ;;
    *) RATE_EGRESS=""; RATE_INGRESS="" ;;
  esac
  save_conf
  for ifc in $IFACES; do
    apply_one "$ifc" "$RATE" "$MODE" >/dev/null || bad "$ifc 更新失败"
  done
  if [ -z "${RATE_EGRESS:-}" ] && [ -z "${RATE_INGRESS:-}" ]; then
    ok "已切换到 $RATE（出口与入口都跟随基准值）"
  else
    ok "基准值已改为 $RATE，但单独设置仍生效：出口 ${RATE_EGRESS:-$RATE} / 入口 ${RATE_INGRESS:-$RATE}"
  fi
  dim "  不中断现有连接，队列参数即时生效"
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

install_alias() {
  # 建一个短命令，输入 cake 就等于 cake-fairshare
  [ -x "$SELF_INSTALL" ] || return 0
  # 已经有同名的真实文件（别的软件装的），别去覆盖别人
  if [ -e "$ALIAS_LINK" ] && [ ! -L "$ALIAS_LINK" ]; then
    return 0
  fi
  ln -sfn "$SELF_INSTALL" "$ALIAS_LINK" 2>/dev/null || true
}

install_service() {
  local me
  me=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
  # 经软链接 cake 调用时 $0 指向的就是目标文件本身，
  # 再 install 到自己会边读边写把文件截断，必须跳过
  if [ ! -x "$SELF_INSTALL" ] && [ "$me" != "$(readlink -f "$SELF_INSTALL" 2>/dev/null)" ]; then
    install -m 0755 "$0" "$SELF_INSTALL" 2>/dev/null || return 1
  fi
  install_alias
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

detect_existing_rate() {
  # 读出机器上"已经在用"的整形速率，输出 "出口 入口"（取不到就留空）。
  # 用途：init 时如果用户没指定带宽，沿用它而不是套默认值——
  # 否则在一台已经限速 168/180 的机器上直接套 190，会改变现有速度。
  local ifc="$1" eg="" in="" d ifb=""
  eg=$(tc -s class show dev "$ifc" 2>/dev/null \
    | awk '/^class /{for (i = 1; i <= NF; i++) if ($i == "rate") {print $(i+1); exit}}')
  for d in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    ifb="$d"
    break
  done
  if [ -n "$ifb" ]; then
    in=$(tc -s class show dev "$ifb" 2>/dev/null \
      | awk '/^class /{for (i = 1; i <= NF; i++) if ($i == "rate") {print $(i+1); exit}}')
  fi
  # 根队列已经是 cake 时上面取不到，退一步解析常见的一键限速脚本
  if [ -z "$eg" ] && [ -r /root/bandwidth-limit.sh ]; then
    eg=$(sed -n 's/^UP_MBPS="\([0-9][0-9]*\)".*/\1mbit/p' /root/bandwidth-limit.sh | head -n1)
    [ -z "$in" ] && in=$(sed -n 's/^DOWN_MBPS="\([0-9][0-9]*\)".*/\1mbit/p' /root/bandwidth-limit.sh | head -n1)
  fi
  printf '%s %s\n' "$eg" "$in"
}

do_init() {
  local rate="" ifc a clean=0 explicit=0 d_eg="" d_in=""
  for a in "$@"; do
    case "$a" in
      --clean) clean=1 ;;
      "" ) ;;
      *) rate="$a"; explicit=1 ;;
    esac
  done
  ifc=$(primary_iface)
  [ -n "$ifc" ] || die "找不到默认路由网卡，请手动用菜单第 2 项配置"
  require_root

  # 没显式给带宽时，先看机器上本来就限速多少，沿用而不是覆盖
  if [ "$explicit" -eq 0 ]; then
    read -r d_eg d_in <<<"$(detect_existing_rate "$ifc")"
    if [ -n "$d_eg" ]; then
      rate=$(normalize_rate "$d_eg") || rate=""
    fi
  fi
  if [ -z "$rate" ]; then
    rate=$(normalize_rate "$DEF_RATE") || die "带宽格式无法识别：$DEF_RATE"
  fi

  if [ -r "$CONF" ]; then
    cp "$CONF" "${CONF}.bak.$(date +%Y%m%d%H%M%S)"
    note "已备份原配置"
  fi
  IFACES="$ifc"; RATE="$rate"; MODE="both"
  RATE_EGRESS=""; RATE_INGRESS=""
  CAKE_OPTS=""; CAKE_OPTS_INGRESS="$DEF_CAKE_OPTS_INGRESS"
  if [ "$explicit" -eq 0 ] && [ -n "$d_eg" ]; then
    RATE_EGRESS=$(normalize_rate "$d_eg" 2>/dev/null) || RATE_EGRESS=""
    if [ -n "$d_in" ]; then
      RATE_INGRESS=$(normalize_rate "$d_in" 2>/dev/null) || RATE_INGRESS=""
    fi
    ok "沿用机器上现有的整形速率：出口 ${RATE_EGRESS:-$RATE} / 入口 ${RATE_INGRESS:-$RATE}"
    dim "  想改就显式指定：cake-fairshare init 190mbit（或菜单第 7 / 9 项）"
  fi
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
  install_alias

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
  say "  此处填了值就覆盖基准带宽；填 - 则恢复\"跟随基准值\"。"
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

  local rx_m tx_m eo ed io cn eb ib
  rx_m=$(awk -v a="$lrx" -v b="$rx" -v t="$dt" 'BEGIN{printf "%.2f",(b-a)*8/t/1000000}')
  tx_m=$(awk -v a="$ltx" -v b="$tx" -v t="$dt" 'BEGIN{printf "%.2f",(b-a)*8/t/1000000}')
  eo=$(qdisc_stat "$ifc" overlimits)
  ed=$(qdisc_stat "$ifc" dropped)
  # backlog 才是判断"速率设得对不对"的指标：长期 0 = 从未把队列填满
  eb=$(qdisc_stat "$ifc" backlog)
  ifb=$(get_state "$ifc" IFB)
  io=""; ib=""
  if [ -n "$ifb" ]; then
    io=$(qdisc_stat "$ifb" overlimits)
    ib=$(qdisc_stat "$ifb" backlog)
  fi
  cn=$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')

  # 记录连接数最多的 3 个客户端 IP（用于区分"多设备"与"多人共用出口"）
  # 必须按"本地端口是监听端口"筛选：established 里同时包含 XrayR 出站到目标站的连接，
  # 不过滤会把 CDN/苹果这类目标的 IP 当成客户端（实测某节点首位是苹果的 17.253.x.x）。
  local a1="" c1="" a2="" c2="" a3="" c3="" lports=""
  if [ "${cn:-0}" -gt 0 ]; then
    lports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*://' \
      | grep -vx '22' | sort -u | tr '\n' ',')
    if [ -n "$lports" ]; then
      read -r c1 a1 c2 a2 c3 a3 <<<"$(ss -Htn state established 2>/dev/null \
        | awk -v lp=",$lports" '{
            n = split($3, a, ":")
            if (index(lp, "," a[n] ",") > 0) print $4
          }' \
        | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://' \
        | sort | uniq -c | sort -rn | head -3 \
        | awk '{printf "%s %s ", $1, $2}')"
    fi
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$rx_m" "$tx_m" \
    "${eo:-0}" "${ed:-0}" "${io:-0}" "${cn:-0}" \
    "${a1:-}" "${c1:-0}" "${a2:-}" "${c2:-0}" "${a3:-}" "${c3:-0}" \
    "${eb:-0}" "${ib:-0}" >>"$SAMPLE_LOG"
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
  if [ -n "${NODE_NAME:-}" ]; then
    say "${B}带宽健康报告${R}  ${D}[$NODE_NAME]${R}"
  else
    say "${B}带宽健康报告${R}"
  fi
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
      if ($8 != "" && $9 + 0 > pmax[$8]) pmax[$8] = $9 + 0
      if ($10 != "" && $11 + 0 > pmax[$10]) pmax[$10] = $11 + 0
      if ($12 != "" && $13 + 0 > pmax[$12]) pmax[$12] = $13 + 0
      # 14/15 列是出口/入口 backlog（旧版日志没有这两列，按 0 处理）
      if ($14 + 0 > mebk) mebk = $14 + 0
      if ($15 + 0 > mibk) mibk = $15 + 0
      first = (first == "" ? ts : first)
      last = ts
    }
    END {
      printf "  %-13s %6s %8s %10s %10s %10s\n", "时段", "样本", "连接峰值", "下行峰值", "下行均值", "上行均值"
      for (i = 1; i <= h; i++) {
        k = order[i]
        # 不在这里判"是否被外部限速"：连接数含出站到目标站的连接，
        # 空闲时连接很多但流量很低是常态，据此判定必然误报（实测 307 连接 / 26 Mbps 被误标）。
        printf "  %-13s %6d %8d %10.1f %10.1f %10.1f\n", substr(k,6) ":00", cnt[k], mc[k], mx[k], st[k]/cnt[k], sr[k]/cnt[k]
      }
      printf "\n  记录区间：%s  ~  %s\n", first, last
      printf "  下行峰值：%.1f Mbps（%s）\n", gmax, gmax_t
      printf "  上行峰值：%.1f Mbps\n", gramax
      if (ce > 0) printf "  出口峰值占用：%.0f%%（%.1f / %.1f Mbps）\n", gmax * 100 / ce, gmax, ce
      if (gmax > ce * 1.05) printf "  %s\n", "注：峰值高于整形上限，说明该时段整形被临时关闭过（例如手动测速）"

      printf "  队列最大积压：出口 %d 字节 / 入口 %d 字节\n", mebk, mibk
      if (mebk <= 0 && mibk <= 0)
        printf "  %s\n", "→ 队列从未被填满：上限比实际需求宽，不会成为瓶颈（也就没有提速空间被浪费）"
      else if (mebk > 0 || mibk > 0)
        printf "  %s\n", "→ 出现过排队：上限确实在起作用，公平分配已生效"

      if (gmax < ce * 0.5 && mebk <= 0)
        printf "  %s\n", "提示：峰值不到上限一半且从不排队，说明这台机器当前用不满这个带宽"

      np = 0
      for (ip in pmax) { np++; pl[np] = ip }
      if (np > 0) {
        printf "\n  连接最集中的客户端 IP：\n"
        shown = 0
        for (i = 1; i <= np && shown < 3; i++) {
          bi = i
          for (j = i + 1; j <= np; j++) if (pmax[pl[j]] > pmax[pl[bi]]) bi = j
          t = pl[i]; pl[i] = pl[bi]; pl[bi] = t
          if (pmax[pl[i]] >= 5) {
            printf "    %-22s 峰值 %d 条连接\n", pl[i], pmax[pl[i]]
            shown++
          }
        }
        if (shown == 0) printf "    （没有单个 IP 超过 5 条连接）\n"
      }
    }
  ' "$SAMPLE_LOG"
  hr

  show_speedtest_history

  say ""
  hr
  if [ "${ST_ALERTS:-0}" -eq 0 ]; then
    ok "历史测速未发现异常，带宽表现正常"
  else
    note "历史测速中有 ${ST_ALERTS} 次明显偏低（已用黄色标出），其余时间正常"
    dim "  短暂一两次通常是上游抖动或当时本机流量占满；频繁出现才需要考虑换线路或找服务商"
  fi
  dim "  说明：采样是「实际用量」，空闲时速度当然是 0，用量低不等于被限速。"
  dim "        采样也看不出上游是否在限速——被云网关丢掉的包，系统里根本看不到。"
  dim "        判断有没有被限速只能靠「历史测速记录」，偏低的那几条已经标出来了。"
}

install_daily_timer() {
  cat >"$REPORT_UNIT" <<'EOF'
[Unit]
Description=CAKE bandwidth daily report
After=cake-fairshare.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cake-fairshare daily
EOF
  cat >"${REPORT_UNIT%.service}.timer" <<'EOF'
[Unit]
Description=Daily CAKE bandwidth health report at 23:00

[Timer]
OnCalendar=*-*-* 23:00:00
Persistent=true
Unit=cake-fairshare-report.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cake-fairshare-report.timer >/dev/null 2>&1
}

daily_report() {
  load_conf
  mkdir -p "$(dirname "$DAILY_LOG")" 2>/dev/null
  {
    printf '\n===== %s%s =====\n' "${NODE_NAME:+$NODE_NAME  }" "$(date '+%F %H:%M')"
    health_report
  } >>"$DAILY_LOG" 2>&1
}

show_daily() {
  if [ ! -s "$DAILY_LOG" ]; then
    note "还没有日报"
    dim "  开启后每天 23:00 自动生成；也可以现在按 5 生成一次"
    return 1
  fi
  say ""
  say "${B}带宽日报${R} ${D}（$DAILY_LOG，显示最近 120 行）${R}"
  hr
  tail -n 120 "$DAILY_LOG" | sed 's/^/  /'
}

install_log_timer() {
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
  systemctl enable --now cake-fairshare-log.timer >/dev/null 2>&1
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
  say "  5) 立即生成一次日报"
  say "  6) 开启每天 23:00 自动日报"
  say "  7) 关闭自动日报"
  say "  8) 查看日报"
  read -rp "选择 [默认 1]: " act
  case "${act:-1}" in
    1)
      if install_log_timer; then
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
    5)
      daily_report && ok "已追加到 $DAILY_LOG"
      ;;
    6)
      if install_daily_timer; then
        ok "已开启：每天 23:00 生成日报"
        dim "  查看： systemctl list-timers cake-fairshare-report.timer"
      else
        bad "开启失败，排查： systemctl status cake-fairshare-report.timer"
      fi
      ;;
    7)
      systemctl disable --now cake-fairshare-report.timer >/dev/null 2>&1
      rm -f "${REPORT_UNIT%.service}.timer" "$REPORT_UNIT"
      systemctl daemon-reload
      ok "已关闭自动日报（历史文件保留）"
      ;;
    8)
      show_daily
      ;;
  esac
  pause
}

# ---------------------------------------------------------------- 主菜单 ----
# ---------------------------------------------------------- 智能分析与优化 ----

client_ip_count() {
  local lports
  lports=$(ss -Hltn 2>/dev/null | awk '{print $4}' | sed -E 's/.*://' | grep -vx '22' | sort -u | tr '\n' ',')
  if [ -z "$lports" ]; then printf '0\n'; return 0; fi
  ss -Htn state established 2>/dev/null \
    | awk -v lp=",$lports" '{ n = split($3, a, ":"); if (index(lp, "," a[n] ",") > 0) print $4 }' \
    | sed -E 's/:[0-9]+$//' | sort -u | wc -l | tr -d ' '
}

speedtest_peaks() {
  # 输出 "下行峰值 上行峰值 记录条数"
  local dir="${SPEEDTEST_DIR:-/root/speedtest_history}" f dl ul mxd=0 mxu=0 n=0
  if [ -d "$dir" ]; then
    for f in $(ls -1t "$dir"/* 2>/dev/null | head -n 30); do
      dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)
      ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -n1)
      [ -n "$dl" ] || continue
      n=$((n + 1))
      mxd=$(awk -v a="$mxd" -v b="$dl" 'BEGIN{print (b > a) ? b : a}')
      if [ -n "$ul" ]; then
        mxu=$(awk -v a="$mxu" -v b="$ul" 'BEGIN{print (b > a) ? b : a}')
      fi
    done
  fi
  printf '%s %s %s\n' "$mxd" "$mxu" "$n"
}

sample_peaks() {
  # 输出 "出口峰值 入口峰值 最大积压 样本数"
  if [ ! -r "$SAMPLE_LOG" ]; then
    printf '0 0 0 0\n'
    return 0
  fi
  awk -F, '
    { if ($3 + 0 > mt) mt = $3 + 0
      if ($2 + 0 > mr) mr = $2 + 0
      if ($14 + 0 > mb) mb = $14 + 0
      if ($15 + 0 > mbi) mbi = $15 + 0 }
    END { printf "%.1f %.1f %d %d\n", mt, mr, (mb > mbi ? mb : mbi), NR }' "$SAMPLE_LOG"
}

recommend_rate() {
  # 计算推荐带宽 → REC_EG / REC_IN / REC_WHY / REC_SUGGEST / REC_HINT
  #
  # 安全原则（血泪教训）：**机器已经在限速时，绝不自动改这个数字**。
  # 因为测速历史里可能包含"临时关掉整形"测出来的值（实测见过 190M 的机器测出 415M），
  # 拿它 ×95% 会推荐到远超套餐的数值，一键点下去就可能被平台限速。
  # 只有从未限过速的机器（新装），才用测速峰值当作起点。
  local cur_eg cur_in pu pd _n has_conf=0 d_eg d_in
  # 注意：load_conf 会把 RATE 默认成 DEF_RATE，所以不能只看 RATE 是否有值，
  # 必须看配置文件到底存不存在，否则新机器永远走不到"按测速取值"这一支。
  [ -r "$CONF" ] && has_conf=1
  cur_eg=$(unit_num "${RATE_EGRESS:-$RATE}")
  cur_in=$(unit_num "${RATE_INGRESS:-$RATE}")
  read -r pu pd _n <<<"$(speedtest_peaks)"

  REC_EG=0; REC_IN=0; REC_WHY=""; REC_SUGGEST=0; REC_HINT=""

  if [ "$has_conf" -eq 1 ] && [ "${cur_eg:-0}" -gt 0 ] 2>/dev/null; then
    REC_EG=$cur_eg
    REC_IN=${cur_in:-$cur_eg}
    REC_WHY="沿用当前出口 ${cur_eg} / 入口 ${REC_IN} Mbps（已在限速，不自动改动这个数字）"
    if awk -v p="$pu" -v c="$cur_eg" 'BEGIN{exit !(p > c * 2)}'; then
      REC_HINT="测速历史里出方向到过 ${pu} Mbps，是当前上限的 $((pu / cur_eg * 100 / 100)) 倍多——那次多半是关掉整形测的，不能当稳态能力"
    elif awk -v p="$pu" -v c="$cur_eg" 'BEGIN{exit !(p > c * 1.02)}'; then
      REC_SUGGEST=$(awk -v p="$pu" 'BEGIN{printf "%d", p * 0.95}')
      REC_HINT="测速历史里出方向到过 ${pu} Mbps，比当前上限 ${cur_eg} 高；若套餐带宽确实更大，可上调到 ${REC_SUGGEST} Mbps"
    else
      REC_HINT=""
    fi
  else
    # 新机器：机器上可能还留着别的限速脚本，先沿用它的速率，其次才看测速
    read -r d_eg d_in <<<"$(detect_existing_rate "$(primary_iface)")"
    if [ -n "$d_eg" ]; then
      REC_EG=$(unit_num "$d_eg")
      REC_IN=$(unit_num "${d_in:-$d_eg}")
      [ "$REC_IN" -gt 0 ] 2>/dev/null || REC_IN=$REC_EG
      REC_WHY="机器上已有整形脚本，沿用它的速率：出口 ${REC_EG} / 入口 ${REC_IN} Mbps"
    elif awk -v p="$pu" 'BEGIN{exit !(p > 0)}'; then
      REC_EG=$(awk -v p="$pu" 'BEGIN{printf "%d", p * 0.95}')
      REC_IN=$REC_EG
      REC_WHY="没有历史整形，按测速历史出方向峰值 ${pu} Mbps 的 95% 取"
    else
      REC_EG=$(unit_num "$DEF_RATE")
      REC_IN=$REC_EG
      REC_WHY="没有测速记录，先用默认 ${DEF_RATE}；跑一次测速后再优化会自己调准"
    fi
  fi
  [ "${REC_IN:-0}" -le 0 ] 2>/dev/null && REC_IN=$REC_EG
  return 0
}

render_analysis() {
  local ifc a4 eg in pu pd sn sb _x sam_n conn cip
  load_conf
  ifc=$(printf '%s' "${IFACES:-}" | awk '{print $1}')
  [ -n "$ifc" ] || ifc=$(primary_iface)
  eg=$(unit_num "${RATE_EGRESS:-$RATE}")
  in=$(unit_num "${RATE_INGRESS:-$RATE}")
  read -r pu pd sn <<<"$(speedtest_peaks)"
  read -r sb _x sam_bk sam_n <<<"$(sample_peaks)"
  conn=$(ss -Htn state established 2>/dev/null | wc -l | tr -d ' ')
  cip=$(client_ip_count)
  a4=$(ip -4 -br addr show dev "$ifc" 2>/dev/null | awk '{print $3}' | head -n1)

  say ""
  say "${B}智能分析${R}"
  hr
  printf '  节点      %s · %s\n' "${NODE_NAME:-未命名}" "$(os_pretty)"
  local memt swap
  memt=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
  if [ -n "$(swapon --show 2>/dev/null)" ]; then swap="有 swap"; else swap="无 swap"; fi
  printf '  硬件      %s 核 / %sMB 内存 / %s\n' "$(nproc 2>/dev/null)" "${memt:-?}" "$swap"
  case "$a4" in
    10.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].* | 192.168.*)
      printf '  网卡      %s   %s   %bEIP/NAT：出方向才是平台限速点%b\n' "$ifc" "$a4" "$Y" "$R"
      ;;
    *)
      printf '  网卡      %s   %s\n' "$ifc" "$a4"
      ;;
  esac
  if is_active; then
    printf '  整形      %b● 运行中%b   出口 %s / 入口 %s Mbps\n' "$G" "$R" "${eg:-?}" "${in:-?}"
  else
    printf '  整形      %b○ 未启用%b\n' "$Y" "$R"
  fi
  if [ "${sn:-0}" -gt 0 ] 2>/dev/null; then
    printf '  测速      %s 次，下行峰值 %s / 上行峰值 %s Mbps\n' "$sn" "$pu" "$pd"
  else
    printf '  测速      无记录（跑一次 speedtest 后推荐值会准得多）\n'
  fi
  if [ "${sam_n:-0}" -gt 0 ] 2>/dev/null; then
    printf '  采样      %s 条，出口峰值 %s Mbps，最大积压 %s 字节\n' "$sam_n" "$sb" "${sam_bk:-0}"
  else
    printf '  采样      无数据\n'
  fi
  printf '  并发      %s 个客户端 IP / %s 条连接\n' "${cip:-0}" "${conn:-0}"
  hr
}

do_optimize() {
  local ifc ans shapers
  load_conf
  require_root

  ifc=$(printf '%s' "${IFACES:-}" | awk '{print $1}')
  [ -n "$ifc" ] || ifc=$(primary_iface)
  if [ -z "$ifc" ]; then bad "找不到默认路由网卡，请手动用第 2 项自定义"; return 1; fi

  render_analysis
  recommend_rate

  say ""
  printf '  推荐      %b出口 %s / 入口 %s Mbps%b\n' "$B" "$REC_EG" "$REC_IN" "$R"
  printf '  理由      %s\n' "$REC_WHY"
  if [ -n "$REC_HINT" ]; then
    printf '  提示      %s\n' "$REC_HINT"
  fi
  if [ "${REC_SUGGEST:-0}" -gt 0 ] 2>/dev/null; then
    read -rp "  是否同时把带宽上调到 ${REC_SUGGEST} Mbps ？（默认不动）[y/N]: " ans
    case "${ans:-N}" in
      y | Y) REC_EG=$REC_SUGGEST; REC_IN=$REC_SUGGEST ;;
    esac
  fi

  shapers=$(find_shaper_units 2>/dev/null)
  local miss=""
  systemctl is-enabled cake-fairshare >/dev/null 2>&1 || miss="${miss}开机自启 "
  systemctl is-enabled cake-fairshare-log.timer >/dev/null 2>&1 || miss="${miss}每分钟采样 "
  systemctl is-enabled cake-fairshare-report.timer >/dev/null 2>&1 || miss="${miss}每日日报 "
  [ -n "${CAKE_OPTS_INGRESS:-}" ] || miss="${miss}ack-filter "
  if [ -n "$miss" ]; then
    printf '  待补齐    %b%s%b\n' "$Y" "$miss" "$R"
  else
    printf '  待补齐    %b无，已经是最优状态%b\n' "$G" "$R"
  fi
  hr

  say ""
  say "${B}将要执行${R}"
  hr
  say "  · 网卡      $ifc"
  say "  · 带宽      出口 ${REC_EG} / 入口 ${REC_IN} Mbps"
  if [ -z "${CAKE_OPTS_INGRESS:-}" ]; then
    say "  · 入口参数  补上 ack-filter（跨国链路压缩上行 ACK）"
  fi
  if [ -n "$shapers" ]; then
    say "  · 停用冲突  $(printf '%s' "$shapers" | awk -F'|' '{printf "%s ", $1}')"
  fi
  case "$miss" in *开机自启*) say "  · 开机自启  安装" ;; esac
  case "$miss" in *每分钟采样*) say "  · 每分钟采样  开启" ;; esac
  case "$miss" in *每日日报*) say "  · 每日日报  开启（每天 23:00）" ;; esac
  say ""
  read -rp "  确认执行？[Y/n]: " ans
  case "${ans:-Y}" in
    n | N) note "已取消"; return 0 ;;
  esac

  say ""
  if [ -n "$shapers" ]; then cleanup_conflicts; fi

  IFACES="$ifc"; RATE="${REC_EG}mbit"; MODE="both"
  RATE_EGRESS=""
  if [ "${REC_IN}" -ne "${REC_EG}" ]; then
    RATE_INGRESS="${REC_IN}mbit"
  else
    RATE_INGRESS=""
  fi
  [ -n "${CAKE_OPTS_INGRESS:-}" ] || CAKE_OPTS_INGRESS="ack-filter"
  save_conf
  ok "配置：网卡 $IFACES  出口 ${RATE_EGRESS:-$RATE}  入口 ${RATE_INGRESS:-$RATE}"

  if do_apply; then
    ok "整形已生效"
  else
    bad "启用失败，见上方提示"
    return 1
  fi

  case "$miss" in
    *开机自启*)
      if install_service; then ok "已设置开机自启"; else bad "开机自启设置失败"; fi
      ;;
  esac
  case "$miss" in
    *每分钟采样*)
      if install_log_timer; then ok "已开启每分钟采样"; fi
      ;;
  esac
  case "$miss" in
    *每日日报*)
      if install_daily_timer; then ok "已开启每日 23:00 日报"; fi
      ;;
  esac

  install_alias
  say ""
  dim "  验证：本菜单第 3 项（状态）/ 第 11 项（一周后看趋势）"
  dim "  短命令：直接输入 cake 即可进菜单"
  return 0
}

do_analyze() {
  load_conf
  require_root
  render_analysis
  recommend_rate
  say ""
  printf '  推荐      %b出口 %s / 入口 %s Mbps%b\n' "$B" "$REC_EG" "$REC_IN" "$R"
  printf '  理由      %s\n' "$REC_WHY"
  if [ -n "$REC_HINT" ]; then
    printf '  提示      %s\n' "$REC_HINT"
  fi
  say ""
  dim "  一键应用： cake-fairshare optimize"
}

draw_menu() {
  load_conf
  if [ -t 1 ]; then clear; fi
  say ""
  if [ -n "${NODE_NAME:-}" ]; then
    printf '%b  CAKE 公平带宽分配 v%s%b   %b%s · %s%b\n' "$B" "$VERSION" "$R" "$D" "$NODE_NAME" "$(os_pretty)" "$R"
  else
    printf '%b  CAKE 公平带宽分配 v%s%b   %b%s%b\n' "$B" "$VERSION" "$R" "$D" "$(os_pretty)" "$R"
  fi
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
  say "  2) 一键优化 / 自定义配置（先分析再套用推荐值）"
  say "  3) 查看当前状态快照"
  say "  4) 实时监控（总体 / 按客户端看每个 IP 的带宽）"
  say "  5) 停止整形并恢复原始 qdisc"
  say "  6) 开机自启（安装 / 移除 / 查看）"
  say "  7) 只改带宽（不动网卡与方向）"
  say "  8) IPv6 与多 IP 用户说明（进阶）"
  say "  9) 高级：分方向微调 / cake 参数（一般不用动）"
  say " 10) 采样日志与现场诊断"
  say " 11) 带宽健康报告（是否被限速，可给小白看）"
  say "  0) 退出"
  hr
  # 主动提示：缺什么就直接说，不用用户自己去逐项翻
  local tips=""
  if [ -r "$CONF" ]; then
    is_active || tips="$tips 未启用整形"
    [ -n "${CAKE_OPTS_INGRESS:-}" ] || tips="$tips 未开 ack-filter"
    systemctl is-enabled cake-fairshare-log.timer >/dev/null 2>&1 || tips="$tips 未开采样"
    systemctl is-enabled cake-fairshare-report.timer >/dev/null 2>&1 || tips="$tips 未开日报"
  fi
  if [ -n "$tips" ]; then
    printf '  %b建议%b%s  → 选 2 一键补齐\n' "$Y" "$R" "$tips"
    hr
  fi
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
      4) menu_monitor ;;
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
  cake                          同上，短命令（软链接，装自启时自动创建）
  cake-fairshare apply          按配置启用（无交互，供 systemd 用）
  cake-fairshare stop           撤销整形并恢复原 qdisc
  cake-fairshare status         状态快照
  cake-fairshare monitor [网卡] 实时监控（整机）
  cake-fairshare clients [秒] [行数]   按客户端实时监控（默认 2 秒 / 8 行）
  cake-fairshare log            采样一次（供 systemd timer 调用）
  cake-fairshare report [N]     查看最近 N 条采样
  cake-fairshare check          现场诊断（判断是否自身占满）
  cake-fairshare health         带宽健康报告（限速历史）
  cake-fairshare daily          生成一次日报（供 timer 调用）
  cake-fairshare name [名称]    设置/查看节点名称
  cake-fairshare optimize       分析机器并一键套用推荐配置（最常用）
  cake-fairshare analyze        只分析、给推荐，不改任何东西
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
  optimize)       require_root; do_optimize ;;
  analyze|advise) require_root; do_analyze ;;
  stop)           require_root; do_stop ;;
  status)         require_root; show_status ;;
  monitor)        require_root; load_conf; monitor "${2:-}" ;;
  clients)        require_root; load_conf; monitor_clients "${2:-2}" "${3:-10}" ;;
  log)            require_root; sample_once ;;
  sample)         require_root; sample_once ;;
  report)         require_root; show_report "${2:-30}" ;;
  check)          require_root; load_conf; diagnose "${2:-}" ;;
  health)         require_root; health_report ;;
  daily)          require_root; load_conf; daily_report ;;
  name)
    shift
    require_root
    do_name "$@"
    ;;
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
