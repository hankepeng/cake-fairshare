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

VERSION="3.6.13"
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
SPEEDTEST_UNIT="/etc/systemd/system/cake-fairshare-speedtest.service"
SPEEDTEST_DIR_DEF="/root/speedtest_history"

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
  AUTO_TEST_IDLE_PCT="15"; AUTO_TEST_MAXWAIT="900"; AUTO_TEST_SERVER_ID=""
  QUOTA_GB=""; QUOTA_MODE="both"
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
    printf '# 自动测速：空闲阈值（占上限百分比）与最长等待秒数\n'
    printf 'AUTO_TEST_IDLE_PCT="%s"\n' "${AUTO_TEST_IDLE_PCT:-15}"
    printf 'AUTO_TEST_MAXWAIT="%s"\n' "${AUTO_TEST_MAXWAIT:-900}"
    printf '# 固定测速服务器 id（speedtest -L 查看）；留空则每次自动选最近的，\n'
    printf '# 填了才能让每次数据可比（自动选会换服务器，速度差异很大）\n'
    printf 'AUTO_TEST_SERVER_ID="%s"\n' "${AUTO_TEST_SERVER_ID:-}"
    printf '# 套餐月流量上限（GB，留空则不提醒）；用于健康报告的用量预估\n'
    printf 'QUOTA_GB="%s"\n' "${QUOTA_GB:-}"
    printf '# 套餐计费方向：both=出+入都算；egress=只算服务器发出（AWS Lightsail 等）\n'
    printf 'QUOTA_MODE="%s"\n' "${QUOTA_MODE:-both}"
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
  local qdisc="cake" orig cur cur_bw="" prev_orig prev_ifb ifb="" idx=0
  local r_eg r_in
  r_eg="${RATE_EGRESS:-$rate}"
  r_in="${RATE_INGRESS:-$rate}"

  # 带宽值非法时 tc 会失败，但错误被 2>/dev/null 吞掉，
  # 只报"检查 CAKE_OPTS"会把人带偏。先自己校验一遍。
  case "$r_eg" in
    [0-9]*mbit | [0-9]*gbit) ;;
    *)
      bad "出口带宽值无效：'${r_eg:-空}'（应形如 190mbit / 1gbit）"
      logline "FAIL $ifc bad-egress-rate '[${r_eg}]'"
      return 1
      ;;
  esac

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

  # 对已存在的 cake 做 replace 实际是 change，CAKE 的 capacity estimate 会
  # 沿用旧值（实测从 190 改到 1000 后仍显示 190Mbit）。带宽变了就重建根队列，
  # 让估算值随新配置重置；带宽没变则保持原队列，不重置统计。
  if [ "$cur" = "cake" ] || [ "$cur" = "cake_mq" ]; then
    cur_bw=$(tc qdisc show dev "$ifc" 2>/dev/null \
      | awk 'NR==1 {for (i=1; i<=NF; i++) if ($i=="bandwidth") print $(i+1)}')
    if [ -n "$cur_bw" ] && [ "$(unit_num "$cur_bw")" != "$(unit_num "$r_eg")" ]; then
      tc qdisc del dev "$ifc" root >/dev/null 2>&1
      logline "APPLY recreate $ifc bandwidth $cur_bw -> $r_eg"
    fi
  fi

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
      # 入口这三步原来不校验返回值：任意一步失败，仍在后面打印"✓ 入口整形"，
      # 实际入口方向完全没生效，排查时会被这条假成功带偏。
      if ! tc qdisc add dev "$ifc" handle ffff: ingress 2>/dev/null; then
        bad "入口 ingress 队列创建失败，仅出口方向生效"
        ip link del "$ifb" >/dev/null 2>&1
        logline "FAIL $ifc ingress-add"
        return 0
      fi
      if ! tc filter add dev "$ifc" parent ffff: protocol all u32 \
          match u32 0 0 action mirred egress redirect dev "$ifb" >/dev/null 2>&1; then
        bad "入口重定向规则添加失败，仅出口方向生效"
        tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
        ip link del "$ifb" >/dev/null 2>&1
        logline "FAIL $ifc ingress-filter"
        return 0
      fi
      # shellcheck disable=SC2086
      if ! tc qdisc replace dev "$ifb" root cake bandwidth "$r_in" dual-srchost ${CAKE_OPTS:-} ${CAKE_OPTS_INGRESS:-} 2>/dev/null; then
        bad "在 $ifb 上挂 cake 失败（检查入口带宽 / CAKE_OPTS），仅出口方向生效"
        tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
        ip link del "$ifb" >/dev/null 2>&1
        logline "FAIL $ifb cake-replace rate=$r_in opts=[${CAKE_OPTS:-}|${CAKE_OPTS_INGRESS:-}]"
        return 0
      fi
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
  local rc=0 ifc
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
  local ifc
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
    NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /:[0-9]+$/ && $4 ~ /:[0-9]+$/ {
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
  [ -n "$lports" ] || { note "没找到正在监听的代理端口（XrayR 没跑？）"; rm -f "$f1" "$f2" "$f3"; return 1; }
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
  # 默认选中"默认路由那块"而不是列表第一项：
  # 多网卡机器上第一项常是内网卡，直接回车会配错地方。
  def=$(primary_iface)
  i=0
  for ifc in $ifc_list; do
    i=$((i + 1))
    [ "$ifc" = "$def" ] && def_idx=$i
  done

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
  # 根队列已经是 cake 时，带宽只能从 qdisc 的 bandwidth 字段读出来
  eg=$(tc qdisc show dev "$ifc" 2>/dev/null | head -n1 \
    | awk '{for (i = 1; i <= NF; i++) if ($i == "bandwidth") {print $(i+1); exit}}')
  for d in $(ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^ifb[0-9]+$/ {print $2}'); do
    ifb="$d"
    break
  done
  if [ -n "$ifb" ]; then
    in=$(tc qdisc show dev "$ifb" 2>/dev/null | head -n1 \
      | awk '{for (i = 1; i <= NF; i++) if ($i == "bandwidth") {print $(i+1); exit}}')
  fi
  # 还没换成 cake（例如仍是一键脚本的 htb）时，才按 class 速率取
  if [ -z "$eg" ]; then
    eg=$(tc -s class show dev "$ifc" 2>/dev/null \
      | awk '/^class /{for (i = 1; i <= NF; i++) if ($i == "rate") {print $(i+1); exit}}')
  fi
  if [ -z "$in" ] && [ -n "$ifb" ]; then
    in=$(tc -s class show dev "$ifb" 2>/dev/null \
      | awk '/^class /{for (i = 1; i <= NF; i++) if ($i == "rate") {print $(i+1); exit}}')
  fi
  # 根队列不是 cake 且取不到 class 速率时，退一步解析常见的一键限速脚本
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
  # 节点名默认取主机名；重装已有配置时保留原来的名字
  if [ -z "${NODE_NAME:-}" ] && [ -r "$CONF" ]; then
    NODE_NAME=$(sed -n 's/^NODE_NAME="\(.*\)"$/\1/p' "$CONF" | head -n1)
  fi
  [ -n "${NODE_NAME:-}" ] || NODE_NAME=$(hostname -s 2>/dev/null || hostname)
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
  bootstrap_extras
  say ""
  say "下一步（可选）："
  dim "  cake-fairshare          # 交互菜单（第 7/9 项改带宽、第 10 项看采样）"
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
  # 两个方向的计数器都要防回绕：只查 rx 的话，网卡重置后 tx 会算出负速率写进日志
  { [ "$rx" -ge "${lrx:-0}" ] && [ "$tx" -ge "${ltx:-0}" ]; } || return 0

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
        | awk -v lp=",$lports" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
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
  elif awk -v v="$tx_m" -v c="$egr" 'BEGIN{exit !(v < c * 0.05)}'; then
    note "当前几乎空闲（出口占用 ${pct}%），此刻无法判断是否被限速"
    dim "  请在真正卡顿的时候再跑 cake check；想测链路能力用第 12 项或有空时看 cake health"
  else
    bad "本机几乎空闲却慢 —— 整形不是瓶颈，问题在上游链路、跨境路由或平台侧限速"
    dim "  排查顺序： ping/mtr 到客户端 → 看是否晚高峰 → 对比历史采样日志"
  fi
}


# ------------------------------------------------------------ 健康报告 ----
show_speedtest_history() {
  local dir="${SPEEDTEST_DIR:-/root/speedtest_history}"
  [ -d "$dir" ] || return 0
  local files f ts dl ul maxdl maxul judge hh tag total tag_peak
  total=$(ls -1 "$dir"/speedtest_* 2>/dev/null | wc -l | tr -d ' ')
  [ "${total:-0}" -gt 0 ] || return 0
  files=$(ls -1t "$dir"/speedtest_* 2>/dev/null | head -12 | sort)
  [ -n "$files" ] || return 0
  read -r maxdl maxul <<<"$(speedtest_baseline "$dir")"
  awk -v m="$maxdl" 'BEGIN{exit !(m > 0)}' || return 0

  ST_ALERTS=0; ST_PEAK_LOWS=0; ST_RECORDS=$total
  say ""
  say "  ${B}历史测速记录${R} ${D}（$dir   基准：下行 ${maxdl} / 上行 ${maxul} Mbps）${R}"
  for f in $files; do
    ts=$(head -1 "$f" 2>/dev/null)
    dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    [ -n "$dl" ] || continue
    # 测速记录里带 # judge=（新版才会写）：recovered/mild/low-all
    judge=$(grep -m1 '^# judge=' "$f" 2>/dev/null | sed 's/^# judge=//; s/ .*//')
    tag=""
    case "$judge" in
      low-all) tag="偏低（多点复核仍低）" ;;
      mild) tag="偏低" ;;
    esac
    if [ -z "$judge" ]; then
      # 旧记录没有 judge 字段，按历史基准 30% 的旧规则兜底
      if awk -v v="$dl" -v m="$maxdl" 'BEGIN{exit !(v < m*0.3)}'; then
        tag="下行异常偏低"
      fi
      if [ -n "$ul" ] && awk -v v="$ul" -v m="$maxul" 'BEGIN{exit !(v < m*0.3)}'; then
        if [ -n "$tag" ]; then tag="上下行都异常偏低"; else tag="上行异常偏低"; fi
      fi
    fi
    # 20:00~01:00 是国际链路高峰，这个时段的偏低多为正常波动，跟平峰偏低分开统计
    hh="${ts: -5:2}"
    case "$hh" in
      19 | 20 | 21 | 22 | 23 | 00) tag_peak=1 ;;
      *) tag_peak=0 ;;
    esac
    if [ -n "$tag" ]; then
      if [ "$tag_peak" = "1" ]; then
        tag="高峰偏低（常见波动）"
        ST_PEAK_LOWS=$((ST_PEAK_LOWS + 1))
      else
        ST_ALERTS=$((ST_ALERTS + 1))
      fi
      printf '    %-18s 下行 %7s   上行 %7s Mbps   %b%s%b\n' "$ts" "$dl" "${ul:-?}" "$Y" "$tag" "$R"
    else
      printf '    %-18s 下行 %7s   上行 %7s Mbps\n' "$ts" "$dl" "${ul:-?}"
    fi
  done
}

show_traffic_estimate() {
  # 按采样日志估算本月流量：样本里是 Mbps，timer 按分钟对齐，间隔即 60 秒
  load_conf
  [ -r "$SAMPLE_LOG" ] || return 0
  local month first last used used_eg
  month=$(date '+%Y-%m')
  first=""; last=""; used=0; used_eg=0
  IFS='|' read -r first last used used_eg <<<"$(awk -F, -v m="$month" '
    index($1, m) == 1 {
      used    += ($2 + $3) * 60 / 8 / 1024
      used_eg += $3 * 60 / 8 / 1024
      if (first == "") first = $1
      last = $1
    }
    END { if (used > 0.05) printf "%s|%s|%.2f|%.2f\n", first, last, used, used_eg }' "$SAMPLE_LOG")"
  [ -n "${used:-}" ] && awk -v u="$used" 'BEGIN{exit !(u > 0.05)}' || return 0

  # 计费方向：Lightsail 这类只算服务器发出（$3 tx），按双向算会高估近一倍
  local qmode label
  case "${QUOTA_MODE:-both}" in
    egress) qmode="egress"; label="仅出方向" ;;
    *)      qmode="both";   label="出+入合计" ;;
  esac
  [ "$qmode" = "egress" ] && used="${used_eg:-0}"

  local t0 t1 hours days total_days today remain daily proj quota
  t0=$(date -d "$first" +%s 2>/dev/null) || return 0
  t1=$(date -d "$last" +%s 2>/dev/null) || return 0
  hours=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", (b-a)/3600}')
  # 样本覆盖不到 3 小时就外推"日均/月底"会离谱（1 小时 × 24 倍），只报已用
  if awk -v h="$hours" 'BEGIN{exit !(h < 3)}'; then
    say ""
    say "  ${B}本月流量估算${R} ${D}（采样 ${first} 起，${label}）${R}"
    printf '  已用 %.1f GB（覆盖 %.1f 小时；不足 3 小时，暂不推算月底）\n' "$used" "$hours"
    return 0
  fi
  days=$(awk -v h="$hours" 'BEGIN{printf "%.2f", h/24}')
  daily=$(awk -v u="$used" -v d="$days" 'BEGIN{printf "%.2f", u/d}')
  total_days=$(date -d "$month-01 +1 month -1 day" '+%d' 2>/dev/null || echo 30)
  today=$(date '+%-d')
  remain=$((total_days - today))
  [ "$remain" -lt 0 ] && remain=0
  proj=$(awk -v u="$used" -v d="$daily" -v r="$remain" 'BEGIN{printf "%.0f", u + d*r}')
  quota="${QUOTA_GB:-}"
  # 配置里填了非数字（如 "1TB"）时按未设置处理，避免 awk 除零把报告写坏
  case "$quota" in '' | *[!0-9.]*) quota="" ;; esac
  awk -v q="$quota" 'BEGIN{exit !(q+0 > 0)}' || quota=""
  # 覆盖不足 24 小时时，日均样本偏差大，不给月底预测和超量告警
  local enough=1
  awk -v h="$hours" 'BEGIN{exit !(h < 24)}' && enough=0

  say ""
  say "  ${B}本月流量估算${R} ${D}（采样 ${first} 起，${label}）${R}"
  if [ -n "$quota" ]; then
    printf '  已用 %.1f GB / 套餐 %s GB（%.0f%%）   日均 %.1f GB' \
      "$used" "$quota" "$(awk -v u="$used" -v q="$quota" 'BEGIN{printf "%.0f", u*100/q}')" "$daily"
    if [ "$enough" = "1" ]; then
      printf '，预计月底 %.0f GB\n' "$proj"
      if awk -v p="$proj" -v q="$quota" 'BEGIN{exit !(p > q*0.9)}'; then
        note "按当前速率月底会接近/超过套餐（预计 ${proj} / ${quota} GB），建议分流或调低上限"
      fi
    else
      printf '（覆盖 %.1f 小时，不足 24 小时，暂不推算月底）\n' "$hours"
    fi
  else
    printf '  已用 %.1f GB   日均 %.1f GB' "$used" "$daily"
    if [ "$enough" = "1" ]; then printf '，预计月底 %.0f GB\n' "$proj"; else printf '（覆盖 %.1f 小时，暂不推算月底）\n' "$hours"; fi
    dim "  想按套餐提醒：在 /etc/cake-fairshare/config 里设 QUOTA_GB=1024 这类上限"
    dim "  只按出方向计费的机器（如 Lightsail）再加 QUOTA_MODE=\"egress\""
  fi
  dim "  依据是每分钟采样；若中途重启采样 timer，统计会以已有样本为准"
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
      # 连续饱和检测：样本每分钟 1 条，连续 30 条 ≥90% 即持续饱和半小时
      if (ce > 0) {
        if (tx >= ce * 0.9) {
          erun++
          if (erun == 1) erun_t = ts
          if (erun > ermax) { ermax = erun; ermax_t = erun_t; ermax_v = tx }
        } else erun = 0
      }
      if (ci > 0) {
        if (rx >= ci * 0.9) {
          irun++
          if (irun == 1) irun_t = ts
          if (irun > irmax) { irmax = irun; irmax_t = irun_t; irmax_v = rx }
        } else irun = 0
      }
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

      # 连续半小时以上贴着上限，才是"需要分流/提额"的信号；
      # 单条样本冲高不算，避免晚高峰一次突发就报警。
      if (ermax >= 30)
        printf "  %s\n", "→ 饱和告警：出口自 " substr(ermax_t, 6, 11) " 起连续 " ermax " 分钟 ≥90%（峰值 " sprintf("%.1f", ermax_v) " / " sprintf("%.1f", ce) " Mbps），建议分流或临时提高上限"
      if (irmax >= 30)
        printf "  %s\n", "→ 饱和告警：入口自 " substr(irmax_t, 6, 11) " 起连续 " irmax " 分钟 ≥90%（峰值 " sprintf("%.1f", irmax_v) " / " sprintf("%.1f", ci) " Mbps）"

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

  ST_ALERTS=0; ST_PEAK_LOWS=0; ST_RECORDS=0
  show_speedtest_history
  show_traffic_estimate

  say ""
  hr
  if [ "${ST_RECORDS:-0}" -lt 5 ]; then
    note "测速记录只有 ${ST_RECORDS:-0} 条，样本不足，暂不判定是否被限速"
    dim "  开启自动测速（菜单 10 → 9，每 4 小时一次）或手动多测几次后再看"
  elif [ "${ST_ALERTS:-0}" -eq 0 ]; then
    if [ "${ST_PEAK_LOWS:-0}" -gt 0 ]; then
      ok "平峰测速正常；${ST_PEAK_LOWS} 次高峰（19:00~01:00）偏低属常见波动"
    else
      ok "历史测速未发现异常，带宽表现正常"
    fi
  else
    note "历史测速中有 ${ST_ALERTS} 次明显偏低（已用黄色标出），其余时间正常"
    dim "  短暂一两次通常是上游抖动或当时本机流量占满；频繁出现才需要考虑换线路或找服务商"
    [ "${ST_PEAK_LOWS:-0}" -gt 0 ] && dim "另有 ${ST_PEAK_LOWS} 次落在高峰时段，按常见波动统计，未计入异常"
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

speedtest_bin() {
  command -v speedtest 2>/dev/null || command -v speedtest-cli 2>/dev/null
}

speedtest_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'x86_64\n' ;;
    aarch64 | arm64) printf 'aarch64\n' ;;
    armv7l | armv6l) printf 'armhf\n' ;;
    i386 | i686) printf 'i386\n' ;;
    *) return 1 ;;
  esac
}

fetch_file() {
  # $1=URL $2=目标文件；curl 失败时再用 wget 兜一次
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --max-time 180 "$1" -o "$2" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" --timeout=180 "$1" && return 0
  fi
  return 1
}

install_speedtest_bin() {
  # 官方静态二进制兜底：不依赖发行版仓库，Alpine 等精简系统也能用
  local ver="1.2.0" arch url tmpd
  arch=$(speedtest_arch) || {
    note "CPU 架构 $(uname -m) 没有官方二进制包，无法自动安装"
    logline "SPEEDTEST install fail arch=$(uname -m)"
    return 1
  }

  # Alpine 默认可能缺 wget 与证书；补齐依赖，失败也不阻塞后续判断
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache wget ca-certificates tar >/dev/null 2>&1 || true
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y wget ca-certificates >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y wget ca-certificates >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y wget ca-certificates >/dev/null 2>&1 || true
    fi
  fi
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    bad "缺少 curl/wget，无法下载二进制"
    logline "SPEEDTEST install fail no-downloader"
    return 1
  fi
  if ! command -v tar >/dev/null 2>&1; then
    bad "缺少 tar，无法解压二进制包"
    logline "SPEEDTEST install fail no-tar"
    return 1
  fi

  tmpd=$(mktemp -d) || { bad "创建临时目录失败"; return 1; }
  url="https://install.speedtest.net/app/cli/ookla-speedtest-${ver}-linux-${arch}.tgz"
  say "  下载官方二进制（${arch}）：$url"
  if ! fetch_file "$url" "$tmpd/pkg.tgz" 2>/dev/null || [ ! -s "$tmpd/pkg.tgz" ]; then
    rm -rf "$tmpd"
    bad "二进制下载失败（检查网络/代理）"
    logline "SPEEDTEST install fail bin-download arch=$arch"
    return 1
  fi
  if ! tar -xzf "$tmpd/pkg.tgz" -C "$tmpd" 2>/dev/null || [ ! -f "$tmpd/speedtest" ]; then
    rm -rf "$tmpd"
    bad "二进制包解压失败"
    logline "SPEEDTEST install fail bin-extract arch=$arch"
    return 1
  fi

  mkdir -p /usr/local/bin
  if ! cp "$tmpd/speedtest" /usr/local/bin/speedtest || ! chmod 0755 /usr/local/bin/speedtest; then
    rm -rf "$tmpd"
    bad "无法写入 /usr/local/bin/speedtest"
    logline "SPEEDTEST install fail bin-copy arch=$arch"
    return 1
  fi
  rm -rf "$tmpd"

  [ -x /usr/local/bin/speedtest ] || return 1
  SPEEDTEST_BIN_PATH="/usr/local/bin/speedtest"
  return 0
}

ensure_speedtest() {
  # 缺失时自动安装测速 CLI，结果放进 SPEEDTEST_BIN_PATH。
  # 交互、定时器（无 tty）都走这里，不让用户自己去装。
  # 路线：发行版仓库 → 官方静态二进制兜底。
  local url="" pm="" installed=0 tmp=""
  SPEEDTEST_BIN_PATH=$(speedtest_bin)
  [ -n "$SPEEDTEST_BIN_PATH" ] && return 0

  say ""
  say "${B}未检测到 speedtest，正在自动安装${R}"
  logline "SPEEDTEST install begin"

  if command -v apt-get >/dev/null 2>&1; then
    pm=apt
    url="https://install.speedtest.net/app/cli/install.deb.sh"
  elif command -v dnf >/dev/null 2>&1; then
    pm=dnf
    url="https://install.speedtest.net/app/cli/install.rpm.sh"
  elif command -v yum >/dev/null 2>&1; then
    pm=yum
    url="https://install.speedtest.net/app/cli/install.rpm.sh"
  fi

  if [ -n "$pm" ]; then
    say "  尝试官方软件源安装..."
    tmp=$(mktemp) || tmp=""
    if [ -n "$tmp" ] && fetch_file "$url" "$tmp" 2>/dev/null && bash "$tmp" >/dev/null 2>&1; then
      case "$pm" in
        apt)
          apt-get update -qq >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest >/dev/null 2>&1 && installed=1
          # 官方源不可用时退回 Debian 自带的 speedtest-cli（输出格式兼容）
          [ "$installed" -eq 1 ] || { DEBIAN_FRONTEND=noninteractive apt-get install -y speedtest-cli >/dev/null 2>&1 && installed=1; }
          ;;
        dnf) dnf install -y speedtest >/dev/null 2>&1 && installed=1 ;;
        yum) yum install -y speedtest >/dev/null 2>&1 && installed=1 ;;
      esac
    else
      note "官方软件源不可用，改用官方二进制安装"
    fi
    [ -n "$tmp" ] && rm -f "$tmp"
  fi

  SPEEDTEST_BIN_PATH=$(speedtest_bin)
  if [ -n "$SPEEDTEST_BIN_PATH" ]; then
    ok "已自动安装：$SPEEDTEST_BIN_PATH"
    logline "SPEEDTEST install ok path=$SPEEDTEST_BIN_PATH"
    return 0
  fi

  say "  改用官方二进制安装（不依赖系统仓库）..."
  if install_speedtest_bin; then
    ok "已自动安装：$SPEEDTEST_BIN_PATH"
    logline "SPEEDTEST install ok path=$SPEEDTEST_BIN_PATH"
    return 0
  fi

  bad "自动安装失败"
  dim "  可手动安装： curl -fsSL https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz | tar xz && mv speedtest /usr/local/bin/"
  logline "SPEEDTEST install fail"
  return 1
}

set_default_timezone() {
  # 默认北京时间：只在仍是 UTC 时改，用户已经选过的地方时区不动
  command -v timedatectl >/dev/null 2>&1 || return 1
  local cur
  cur=$(timedatectl show -p Timezone --value 2>/dev/null)
  [ -n "$cur" ] || cur=$(cat /etc/timezone 2>/dev/null)
  case "$cur" in
    UTC | Etc/UTC | Etc/GMT | Etc/GMT+0 | Etc/Universal) ;;
    *) return 0 ;;
  esac
  timedatectl set-timezone Asia/Shanghai >/dev/null 2>&1 || return 1
  ok "时区已设为北京时间（Asia/Shanghai）"
  logline "TZ set Asia/Shanghai (was $cur)"
}

pick_speedtest_server() {
  # 自动固定测速点：最近 3 个候选各测一次，取双向都稳的那个。
  # 调用时机在整形生效之后，测速流量被 CAKE 限住，不会冲击在线用户。
  local bin ids id out dl ul sc best_id="" best=0
  bin=$(speedtest_bin) || return 1
  [ -n "${AUTO_TEST_SERVER_ID:-}" ] && return 0
  ids=$("$bin" -L 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1}' | head -n3)
  [ -n "$ids" ] || return 1
  say "  自动挑选测速点（候选：$(printf '%s' "$ids" | tr '\n' ' ')）"
  for id in $ids; do
    out=$("$bin" -s "$id" --accept-license --accept-gdpr 2>/dev/null)
    dl=$(printf '%s\n' "$out" | grep -m1 'Download:' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
    ul=$(printf '%s\n' "$out" | grep -m1 'Upload:' | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
    [ -n "$dl" ] && [ -n "$ul" ] || continue
    sc=$(awk -v a="$dl" -v b="$ul" 'BEGIN{printf "%d", (a < b ? a : b)}')
    dim "  候选 $id：下行 ${dl} / 上行 ${ul} Mbps"
    if [ "$sc" -gt "$best" ]; then best="$sc"; best_id="$id"; fi
  done
  [ -n "$best_id" ] || return 1
  AUTO_TEST_SERVER_ID="$best_id"
  save_conf
  ok "已固定测速点：$best_id（双向 ${best} Mbps 以上）"
  logline "SPEEDTEST server pinned id=$best_id score=$best"
}

bootstrap_extras() {
  # 首次安装收尾：时区、测速工具与固定测速点、采样与日报一次配好。
  # 自动测速默认**不开**：一次测速要跑几百 MB（900M 机器约 800MB），
  # 常驻每小时跑会持续吃掉套餐流量，交给用户按需在菜单里开。
  set_default_timezone || true
  if ensure_speedtest; then
    pick_speedtest_server || note "测速点自动固定失败，可稍后编辑 $CONF 指定 AUTO_TEST_SERVER_ID"
    install_log_timer >/dev/null 2>&1 && ok "已开启每分钟采样"
    install_daily_timer >/dev/null 2>&1 && ok "已开启每日 23:00 日报"
    note "自动测速默认关闭（每次约几十到几百 MB，避免长期占用套餐流量）"
    dim "  需要时： cake → 10) 采样日志与现场诊断 → 9) 开启自动测速"
  else
    note "测速工具安装失败；采样与日报不受影响"
    install_log_timer >/dev/null 2>&1 && ok "已开启每分钟采样"
    install_daily_timer >/dev/null 2>&1 && ok "已开启每日 23:00 日报"
    dim "  装好测速工具后： cake → 10) 采样日志与现场诊断 → 9) 开启自动测速"
  fi
}

iface_rate_mbps() {
  # 3 秒采样，输出 "入向Mbps 出向Mbps"
  local ifc="$1" a b
  a=$(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
  sleep 3
  b=$(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
  awk -v a="$a" -v b="$b" 'BEGIN{
    split(a, x, " "); split(b, y, " ")
    printf "%.2f %.2f\n", (y[1] - x[1]) * 8 / 3e6, (y[2] - x[2]) * 8 / 3e6
  }'
}

hour_has_record() {
  # 本小时是否已有测速记录。定时器每 4 小时触发一次，
  # 这里保留按小时去重，防止手动重跑定时器时在同一小时内重复写记录。
  local dir="$1" cur f
  cur=$(date '+%Y%m%d_%H')
  for f in "$dir"/speedtest_"$cur"*; do
    [ -f "$f" ] && return 0
  done
  return 1
}

speedtest_baseline() {
  # 历史基准：最近 60 条里的最高下行/上行。
  # 用最大值而不是均值，避免连续掉速后把基准也拉低、反而判成"正常"。
  local dir="$1" f dl ul maxdl=0 maxul=0
  for f in $(ls -1t "$dir"/speedtest_* 2>/dev/null | head -60); do
    dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    [ -n "$dl" ] || continue
    ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    maxdl=$(awk -v a="$maxdl" -v b="$dl" 'BEGIN{print (b>a)?b:a}')
    if [ -n "$ul" ]; then maxul=$(awk -v a="$maxul" -v b="$ul" 'BEGIN{print (b>a)?b:a}'); fi
  done
  printf '%s %s\n' "$maxdl" "$maxul"
}

speedtest_try() {
  # 指定测速点跑一次，完整输出写到 $4，成功时输出 "下行 上行"
  local bin="$1" sid="$2" home_dir="$3" outf="$4" opt dl ul
  opt="--accept-license --accept-gdpr"
  [ -n "$sid" ] && opt="$opt --server-id=$sid"
  # shellcheck disable=SC2086
  HOME="$home_dir" "$bin" $opt >"$outf" 2>&1 || return 1
  dl=$(grep -m1 'Download:' "$outf" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  ul=$(grep -m1 'Upload:' "$outf" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$dl" ] || return 1
  printf '%s %s\n' "$dl" "${ul:-0}"
}

record_speedtest() {
  # 跑一次测速并写入历史目录（供「带宽健康报告」读取）。
  # $1 = auto 时先等链路空闲，避免在晚高峰跟用户抢带宽。
  load_conf
  require_root
  local bin mode="${1:-now}" ifc dir ts f out dl ul waited=0 pct maxwait mb_in mb_out cap_e cap_i d
  local base_dl=0 base_ul=0 judge="" retested=0 tmp_out best_dl best_ul best_out best_score ref_score sid sid_used d u d_score
  ensure_speedtest || return 1
  bin=$SPEEDTEST_BIN_PATH
  ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || ifc=$(primary_iface)
  dir="${SPEEDTEST_DIR:-$SPEEDTEST_DIR_DEF}"
  mkdir -p "$dir" 2>/dev/null

  if [ "$mode" = "auto" ]; then
    pct="${AUTO_TEST_IDLE_PCT:-15}"
    maxwait="${AUTO_TEST_MAXWAIT:-900}"
    case "$maxwait" in '' | *[!0-9]*) maxwait=900 ;; esac
    # 上限 25 分钟：每 4 小时才触发一次，但别让等待无限拉长占住定时器
    [ "$maxwait" -le 1500 ] 2>/dev/null || maxwait=1500
    case "$pct" in '' | *[!0-9]*) pct=15 ;; esac
    [ "$pct" -le 100 ] 2>/dev/null || pct=100

    # 本小时已经测过就不再测（防同一小时内重复写记录）
    if hour_has_record "$dir"; then
      logline "SPEEDTEST skip already-done-this-hour"
      say "  本小时已有测速记录，跳过"
      return 0
    fi

    cap_e=$(unit_num "${RATE_EGRESS:-$RATE}")
    cap_i=$(unit_num "${RATE_INGRESS:-$RATE}")
    say "  等链路空闲：出/入都低于上限的 ${pct}% 才开测，最多等 $((maxwait / 60)) 分钟，仍忙就放弃本次"
    waited=$SECONDS
    while :; do
      read -r mb_in mb_out <<<"$(iface_rate_mbps "$ifc")"
      if awk -v a="$mb_out" -v b="$mb_in" -v ce="$cap_e" -v ci="$cap_i" -v p="$pct" \
        'BEGIN{exit !(a < ce * p / 100 && b < ci * p / 100)}'; then
        break
      fi
      if [ $((SECONDS - waited)) -ge "$maxwait" ]; then
        logline "SPEEDTEST skip busy out=${mb_out}M in=${mb_in}M waited=$((SECONDS - waited))s"
        note "等了 $((maxwait / 60)) 分钟链路一直不空闲（最近一次 出 ${mb_out} / 入 ${mb_in} Mbps），本次跳过，不跟用户抢带宽"
        dim "  半小时后会自动再检查一次"
        return 0
      fi
      # 等待过程要看得见，否则 journal 里只有一行开头，不知道卡在哪
      printf '    %s  出 %s / 入 %s Mbps，仍有负载，30 秒后复查（已等 %d 秒 / 上限 %d 秒）\n' \
        "$(date '+%H:%M:%S')" "$mb_out" "$mb_in" "$((SECONDS - waited))" "$maxwait"
      sleep 30
    done
    logline "SPEEDTEST idle out=${mb_out}M in=${mb_in}M"
    say "  链路空闲（出 ${mb_out} / 入 ${mb_in} Mbps），开始测速"
  fi

  # Ookla CLI 需要 HOME 才能读到 ~/.config/ookla 里的 license，
  # systemd 服务默认不设 HOME，会直接抛 basic_string::_M_construct 崩溃。
  # 这里显式兜一层，避免换个调用方式（cron / timer）就静默失败。
  local st_opt="" home_dir="${HOME:-/root}"
  if [ "$(basename "$bin")" = "speedtest" ]; then
    st_opt="--accept-license --accept-gdpr"
    [ -n "${AUTO_TEST_SERVER_ID:-}" ] && st_opt="$st_opt --server-id=$AUTO_TEST_SERVER_ID"
  fi

  say "  正在测速，约 15~30 秒，期间会短暂占用带宽..."
  # shellcheck disable=SC2086
  if ! out=$(HOME="$home_dir" "$bin" $st_opt 2>&1); then
    note "第一次失败，5 秒后重试一次"
    sleep 5
    # shellcheck disable=SC2086
    if ! out=$(HOME="$home_dir" "$bin" $st_opt 2>&1); then
      logline "SPEEDTEST fail"
      bad "测速失败"
      printf '%s\n' "$out" | head -4 | sed 's/^/    /'
      case "$out" in
        *basic_string* | *logic_error*)
          dim "  这个报错通常是缺少 HOME：  sudo cake speedtest 手动跑一次可验证"
          ;;
      esac
      return 1
    fi
  fi

  dl=$(printf '%s' "$out" | grep -m1 'Download:' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  ul=$(printf '%s' "$out" | grep -m1 'Upload:' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
  if [ -z "$dl" ]; then
    logline "SPEEDTEST fail no-result"
    bad "测速没有返回结果"
    printf '%s\n' "$out" | head -4 | sed 's/^/    /'
    return 1
  fi

  # 防误判：单个测速点自身路由拥塞时，会把「测速点问题」记成「线路偏低」。
  # 结果低于历史基准 30% 就换 2 个备用测速点复核，取最好的一次写记录。
  # 实测新加坡4 出现 1.3 Mbps，而同机四流实测 149 Mbps 的误报就是这样来的。
  # 注意：复核前不落盘。否则复核要 30 秒，会先留下一条偏低记录，
  # 之后又写一条正常记录，历史里两条并存，偏低那条会污染健康报告。
  read -r base_dl base_ul <<<"$(speedtest_baseline "$dir")"
  best_dl="$dl"; best_ul="${ul:-0}"; best_out="$out"
  best_score=$(awk -v a="$best_dl" -v b="$best_ul" 'BEGIN{printf "%.2f", (b+0>0 && b<a)?b:a}')
  sid_used="${AUTO_TEST_SERVER_ID:-}"
  if [ "$(basename "$bin")" = "speedtest" ] && awk -v d="$dl" -v u="${ul:-0}" -v bd="$base_dl" -v bu="$base_ul" \
    'BEGIN{exit !((bd+0>0 && d+0 < bd*0.3) || (bu+0>0 && u+0 < bu*0.3))}'; then
    say "  首次结果偏低（历史基准 下行 ${base_dl} / 上行 ${base_ul} Mbps），换测速点复核..."
    tmp_out="$dir/.retest.$$"
    sid=$("$bin" -L 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1}' | head -n 8)
    for sid in $sid; do
      [ "$sid" = "$sid_used" ] && continue
      [ "$retested" -ge 2 ] && break
      retested=$((retested + 1))
      if read -r d u <<<"$(speedtest_try "$bin" "$sid" "$home_dir" "$tmp_out")"; then
        dim "  复核 $sid：下行 $d / 上行 $u Mbps"
        d_score=$(awk -v a="$d" -v b="$u" 'BEGIN{printf "%.2f", (b+0>0 && b<a)?b:a}')
        if awk -v s="$d_score" -v m="$best_score" 'BEGIN{exit !(s > m)}'; then
          best_dl="$d"; best_ul="$u"; best_score="$d_score"; best_out=$(cat "$tmp_out")
        fi
      fi
    done
    rm -f "$tmp_out"
    # 复核后仍低才算「多点都低」，否则按测速点问题处理，取复核到的正常值写记录
    ref_score=$(awk -v a="$base_dl" -v b="$base_ul" 'BEGIN{
      if (a+0>0 && b+0>0) printf "%.2f", (a<b)?a:b; else printf "%.2f", (a+0>0)?a:b
    }')
    if awk -v s="$best_score" -v r="$ref_score" 'BEGIN{exit !(r>0 && s >= r*0.7)}'; then
      judge="recovered"
      dl="$best_dl"; ul="$best_ul"; out="$best_out"
      ok "复核恢复正常：下行 ${dl} / 上行 ${ul} Mbps（测速点问题，非线路限速）"
    elif awk -v s="$best_score" -v r="$ref_score" 'BEGIN{exit !(r>0 && s >= r*0.3)}'; then
      judge="mild"
      dl="$best_dl"; ul="$best_ul"; out="$best_out"
    else
      judge="low-all"
      dl="$best_dl"; ul="$best_ul"; out="$best_out"
      note "复核仍偏低：${retested} 个测速点都不理想（最低 ${best_score} Mbps）"
    fi
  fi

  ts=$(date '+%Y%m%d_%H%M%S')
  f="$dir/speedtest_${ts}.txt"
  {
    date '+%Y/%m/%d %H:%M'
    printf '%s\n' "$out"
    [ -n "$judge" ] && printf '# judge=%s retested=%d\n' "$judge" "$retested"
  } >"$f"
  # 只留最近 240 条（每 4 小时一条约 40 天）
  ls -1t "$dir"/speedtest_* 2>/dev/null | tail -n +241 | while read -r d; do rm -f "$d"; done

  logline "SPEEDTEST ok dl=${dl:-?} ul=${ul:-?} judge=${judge:-ok} retested=$retested file=$f"
  if [ "$judge" = "recovered" ]; then
    ok "已记录：下行 ${dl} / 上行 ${ul} Mbps（已换点复核，原测速点偏低）"
  else
    ok "已记录：下行 ${dl} / 上行 ${ul} Mbps"
  fi
  dim "  文件：$f"
}

install_speedtest_timer() {
  # $1=0 只写 unit、不启用（升级同步时用：用户没开过的功能不能替用户打开）
  local do_enable="${1:-1}"
  cat >"$SPEEDTEST_UNIT" <<'EOF'
[Unit]
Description=CAKE speedtest (waits for an idle link before running)
After=cake-fairshare.service
Wants=network-online.target

[Service]
Type=oneshot
# Ookla speedtest 需要 HOME 才能读 ~/.config/ookla，缺了会崩（实测过）
Environment=HOME=%h
ExecStart=/usr/local/sbin/cake-fairshare speedtest --auto
TimeoutStartSec=1800
# 测速是后台任务，优先级压低，别跟转发抢 CPU
Nice=10
EOF
  cat >"${SPEEDTEST_UNIT%.service}.timer" <<'EOF'
[Unit]
Description=Speedtest every 4 hours (00/04/08/12/16/20), runs only when the link is idle

[Timer]
OnCalendar=*-*-* 00/4:00:00
AccuracySec=10s
Persistent=false
Unit=cake-fairshare-speedtest.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if [ "$do_enable" != "0" ]; then
    systemctl enable --now cake-fairshare-speedtest.timer >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------- 在线升级 ----

# 升级源。fork 了仓库就改这两个变量（或 export 覆盖）。
UPGRADE_REPO="${UPGRADE_REPO:-hankepeng/cake-fairshare}"
UPGRADE_BASE="${UPGRADE_BASE:-https://raw.githubusercontent.com/hankepeng/cake-fairshare/main}"

script_version_of() {
  grep -m1 '^VERSION=' "$1" 2>/dev/null \
    | sed -E 's/^VERSION="?([^"]*)"?.*/\1/' | tr -d '\r'
}

ver_newer() {
  # $1 是否严格新于 $2（用 sort -V 比较，支持 3.10.0 > 3.9.2）
  local a="$1" b="$2"
  [ -n "$a" ] || return 1
  [ "$a" = "$b" ] && return 1
  [ "$(printf '%s\n%s\n' "$b" "$a" | sort -V | tail -n1)" = "$a" ]
}

fetch_latest() {
  # 下载最新脚本到 $1。0=成功 1=网络失败 2=没有下载工具
  local dest="$1" url i rc
  url="${UPGRADE_BASE%/}/cake-fairshare.sh"
  if command -v curl >/dev/null 2>&1; then
    # 优先走 API：raw 的 CDN 有缓存，刚发版时可能还拿到上一版（踩过一次）
    for i in 1 2 3; do
      if curl -fsSL --connect-timeout 8 --max-time 20 \
        -H "Accept: application/vnd.github.raw" \
        "https://api.github.com/repos/${UPGRADE_REPO}/contents/cake-fairshare.sh?ref=main" \
        -o "$dest" 2>/dev/null && [ -s "$dest" ] && grep -q '^VERSION=' "$dest"; then
        return 0
      fi
      [ "$i" -lt 3 ] && sleep 2
    done
    # API 限流或不可用时退回 raw
    for i in 1 2; do
      if curl -fsSL --connect-timeout 8 --max-time 25 -o "$dest" "$url" 2>/dev/null \
        && [ -s "$dest" ] && grep -q '^VERSION=' "$dest"; then
        return 0
      fi
      [ "$i" -lt 2 ] && sleep 2
    done
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    for i in 1 2 3; do
      if wget -q -O "$dest" --timeout=25 "$url" 2>/dev/null && [ -s "$dest" ]; then
        return 0
      fi
      [ "$i" -lt 3 ] && sleep 2
    done
    return 1
  fi
  rc=2
  return "$rc"
}

sync_units() {
  # 把已安装的 systemd unit 同步到当前脚本的模板。
  # 只补"缺关键行"的那些，不无脑重写——重写会重启服务，白抖一下。
  local changed=""
  if [ -f "$UNIT" ] && ! grep -qs 'ExecStop=/usr/local/sbin/cake-fairshare stop' "$UNIT"; then
    if install_service >/dev/null 2>&1; then changed="${changed} 开机自启"; fi
  fi
  # 注意 grep 的是 .timer 文件：OnUnitActiveSec / OnCalendar 写在 timer 里，
  # 拿 .service 去 grep 永远查不到，会每次升级都白重写一遍。
  if [ -f "${LOG_UNIT%.service}.timer" ] && ! grep -qsF 'OnCalendar=*-*-* *:*:00' "${LOG_UNIT%.service}.timer"; then
    if install_log_timer >/dev/null 2>&1; then changed="${changed} 每分钟采样"; fi
  fi
  if [ -f "${REPORT_UNIT%.service}.timer" ] && ! grep -qs '23:00:00' "${REPORT_UNIT%.service}.timer"; then
    if install_daily_timer >/dev/null 2>&1; then changed="${changed} 每日日报"; fi
  fi
  if [ -f "${SPEEDTEST_UNIT%.service}.timer" ]; then
    # 只在"测速定时器本来就在运行"时同步模板；用 0 参数不启用，
    # 避免升级把用户没开的自动测速擅自打开（3.6.10 起默认就是关的）。
    if ! grep -qs 'Environment=HOME=' "$SPEEDTEST_UNIT" \
      || ! grep -qs '00/4' "${SPEEDTEST_UNIT%.service}.timer"; then
      if install_speedtest_timer 0 >/dev/null 2>&1; then changed="${changed} 自动测速模板"; fi
    fi
  fi
  if [ -n "$changed" ]; then
    ok "已同步 unit 模板：${changed}"
  else
    dim "  unit 模板与当前版本一致，未重启任何服务"
  fi
}

do_upgrade() {
  local mode="ask" tmp new bak ans rc f
  case "${1:-}" in
    --check | check) mode="check" ;;
    --yes | -y) mode="yes" ;;
  esac
  require_root
  tmp=$(mktemp) || { bad "创建临时文件失败"; return 1; }

  say ""
  say "${B}在线升级${R}"
  hr
  printf '  当前版本  %s\n' "$VERSION"
  printf '  升级源    %s\n' "$UPGRADE_REPO"
  printf '  正在检查  '
  fetch_latest "$tmp"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n'
    rm -f "$tmp"
    if [ "$rc" = "2" ]; then
      bad "系统里既没有 curl 也没有 wget，无法在线升级"
      dim "  装一个即可： apt install -y curl"
    else
      bad "连不上 GitHub（可能被墙，或需要代理）"
      dim "  换个网络再试，或手动升级："
      dim "    bash <(curl -fsSL ${UPGRADE_BASE}/install.sh)"
    fi
    logline "UPGRADE fail fetch rc=$rc"
    return 1
  fi
  new=$(script_version_of "$tmp")
  if [ -z "$new" ]; then
    rm -f "$tmp"
    bad "下载内容里读不到版本号，已放弃（可能是网络截断）"
    logline "UPGRADE fail no-version"
    return 1
  fi
  printf '%s\n' "$new"

  if ! ver_newer "$new" "$VERSION"; then
    rm -f "$tmp"
    ok "已是最新版本（$VERSION）"
    return 0
  fi

  # 先做语法检查，别把半截文件装上把工具搞坏
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    bad "新版本语法检查不通过，已放弃（现有版本未受影响）"
    logline "UPGRADE fail syntax new=$new"
    return 1
  fi

  hr
  printf '  %b可升级：%s → %s%b\n' "$G" "$VERSION" "$new" "$R"
  if [ "$mode" = "check" ]; then
    rm -f "$tmp"
    dim "  只检查，未做任何改动。要升级： cake upgrade"
    return 0
  fi
  if [ "$mode" != "yes" ]; then
    if [ ! -t 0 ]; then
      rm -f "$tmp"
      note "非交互环境，请显式确认： cake upgrade --yes"
      return 1
    fi
    read -rp "  现在升级？[Y/n]: " ans
    case "${ans:-Y}" in
      n | N) rm -f "$tmp"; note "已取消"; return 0 ;;
    esac
  fi

  bak="${SELF_INSTALL}.bak.${VERSION}"
  if cp -a "$SELF_INSTALL" "$bak" 2>/dev/null; then
    dim "  旧版已备份：$bak"
  else
    note "备份失败，继续升级（原文件仍在磁盘上）"
  fi

  # 不能直接 install 覆盖正在运行的脚本：同名写入会截断当前进程正在读的文件，
  # 部分环境还会报 Text file busy。先装到同目录临时名，再原子 mv 替换。
  local newbin="${SELF_INSTALL}.new.$$"
  if ! install -m 0755 "$tmp" "$newbin" 2>/dev/null; then
    rm -f "$tmp" "$newbin"
    bad "写入失败（检查 /usr/local/sbin 的权限与磁盘空间），旧版本未受影响"
    logline "UPGRADE fail stage"
    return 1
  fi
  rm -f "$tmp"
  if ! mv -f "$newbin" "$SELF_INSTALL" 2>/dev/null; then
    rm -f "$newbin"
    bad "替换失败，旧版本未受影响"
    logline "UPGRADE fail mv"
    return 1
  fi

  # 落地后再确认一次版本号，防止写了一半
  if [ "$(script_version_of "$SELF_INSTALL")" != "$new" ]; then
    bad "写入后版本号对不上，正在回滚"
    [ -f "$bak" ] && cp -a "$bak" "$SELF_INSTALL" 2>/dev/null
    logline "UPGRADE fail verify"
    return 1
  fi
  ok "已升级：$VERSION → $new"
  logline "UPGRADE ok $VERSION -> $new"

  # 旧备份只留 3 个
  ls -1t "${SELF_INSTALL}".bak.* 2>/dev/null | tail -n +4 | while read -r f; do rm -f "$f"; done

  say ""
  # 后面全部用新二进制执行，确保跑的是新代码
  "$SELF_INSTALL" sync-units 2>/dev/null || true
  if [ -r "$CONF" ]; then
    if "$SELF_INSTALL" apply >/dev/null 2>&1; then
      ok "已按现有配置重新应用（带宽未变）"
    else
      note "重新应用失败，用第 3 项看一下状态"
    fi
  fi
  say ""
  if [ "${MENU_MODE:-0}" -eq 1 ]; then
    dim "  正在重新载入 v${new} 菜单..."
    exec "$SELF_INSTALL"
  fi
  dim "  新版本已生效，下次运行 cake 就是 $new"
  [ -f "$bak" ] && dim "  要回退： install -m 0755 $bak $SELF_INSTALL"
  return 0
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
# 按墙钟整分钟触发：OnUnitActiveSec 会累积 service 运行时间与 5s 精度误差，
# 实测每条约 63 秒，导致按 60 秒积分的流量估算系统性偏低约 5%。
OnCalendar=*-*-* *:*:00
AccuracySec=1s
Unit=cake-fairshare-log.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now cake-fairshare-log.timer >/dev/null 2>&1
  # 已运行的 timer 需要重启才会按新的 OnCalendar 重新排程
  systemctl try-restart cake-fairshare-log.timer >/dev/null 2>&1
}

menu_log() {
  local act n
  say ""
  say "  采样日志：每分钟记录一次上行/下行实速与队列统计，用于事后判断是否被平台限速"
  say "  自动测速：默认关闭。开启后每 4 小时检查一次（00/04/08/12/16/20 点），链路空闲才跑，"
  say "            单次会消耗几十到几百 MB 流量（900M 机器约 800MB）"
  hr
  say "  1) 开启每分钟采样"
  say "  2) 关闭采样"
  say "  3) 查看最近记录"
  say "  4) 立即诊断（我现在占满没有）"
  say "  5) 立即生成一次日报"
  say "  6) 开启每天 23:00 自动日报"
  say "  7) 关闭自动日报"
  say "  8) 查看日报"
  say "  9) 开启自动测速（每 4 小时空闲时跑，忙则跳过）"
  say " 10) 关闭自动测速"
  say " 11) 立即测速一次（马上跑，不等空闲）"
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
    9)
      if install_speedtest_timer; then
        ok "已开启：每 4 小时检查一次（00/04/08/12/16/20 点），链路空闲才测速"
        dim "  查看： systemctl list-timers cake-fairshare-speedtest.timer"
        dim "  若整点链路正忙，最多等 $(( ${AUTO_TEST_MAXWAIT:-900} / 60 )) 分钟后跳过，不会跟用户抢带宽"
      else
        bad "开启失败，排查： systemctl status cake-fairshare-speedtest.timer"
      fi
      ;;
    10)
      systemctl disable --now cake-fairshare-speedtest.timer >/dev/null 2>&1
      rm -f "${SPEEDTEST_UNIT%.service}.timer" "$SPEEDTEST_UNIT"
      systemctl daemon-reload
      ok "已关闭自动测速（历史文件保留）"
      ;;
    11)
      record_speedtest now
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
    | awk -v lp=",$lports" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
        n = split($3, a, ":")
        if (index(lp, "," a[n] ",") > 0) print $4
      }' \
    | sed -E 's/:[0-9]+$//' | sort -u | wc -l | tr -d ' '
}

speedtest_peaks() {
  # 输出 "下行峰值 上行峰值 记录条数"
  local dir="${SPEEDTEST_DIR:-/root/speedtest_history}" f dl ul mxd=0 mxu=0 n=0
  if [ -d "$dir" ]; then
    for f in $(ls -1t "$dir"/* 2>/dev/null | head -n 30); do
      dl=$(grep -m1 'Download:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
      ul=$(grep -m1 'Upload:' "$f" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)
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
  # 方向约定（实测校准过）：
  #   speedtest 的 Upload   = 服务器出口 = 用户下载 → 决定 RATE_EGRESS
  #   speedtest 的 Download = 服务器入口 = 用户上传 → 决定 RATE_INGRESS
  # 非对称链路上这两个值可能差好几倍，不能拿 Download 当出口。
  #
  # 安全原则（血泪教训）：**机器已经在限速时，绝不自动改这个数字**。
  # 只有从未限过速的机器（新装），才用测速峰值当作起点。
  local cur_eg cur_in pi pe _n has_conf=0 d_eg d_in
  # 注意：load_conf 会把 RATE 默认成 DEF_RATE，所以不能只看 RATE 是否有值，
  # 必须看配置文件到底存不存在，否则新机器永远走不到"按测速取值"这一支。
  [ -r "$CONF" ] && has_conf=1
  cur_eg=$(unit_num "${RATE_EGRESS:-$RATE}")
  cur_in=$(unit_num "${RATE_INGRESS:-$RATE}")
  read -r pi pe _n <<<"$(speedtest_peaks)"

  REC_EG=0; REC_IN=0; REC_WHY=""; REC_SUGGEST=0; REC_HINT=""

  if [ "$has_conf" -eq 1 ] && [ "${cur_eg:-0}" -gt 0 ] 2>/dev/null; then
    REC_EG=$cur_eg
    REC_IN=${cur_in:-$cur_eg}
    REC_WHY="沿用当前出口 ${cur_eg} / 入口 ${REC_IN} Mbps（已在限速，不自动改动这个数字）"
    if awk -v p="$pe" -v c="$cur_eg" 'BEGIN{exit !(p > c * 2)}'; then
      REC_HINT="测速历史里出口（服务器上行）到过 ${pe} Mbps，是当前上限的 $(awk -v p="$pe" -v c="$cur_eg" 'BEGIN{printf "%d", p / c}') 倍多——那次多半是关掉整形测的，不能当稳态能力"
    elif awk -v p="$pe" -v c="$cur_eg" 'BEGIN{exit !(p > c * 1.02)}'; then
      REC_SUGGEST=$(awk -v p="$pe" 'BEGIN{printf "%d", p * 0.95}')
      REC_HINT="测速历史里出口到过 ${pe} Mbps，比当前上限 ${cur_eg} 高；若套餐带宽确实更大，可上调出口到 ${REC_SUGGEST} Mbps"
    else
      REC_HINT=""
    fi
    if awk -v p="$pi" -v c="$REC_IN" 'BEGIN{exit !(p > c * 1.02 && p <= c * 2)}'; then
      REC_HINT="${REC_HINT:+${REC_HINT}；}入口（服务器下行）测速峰值 ${pi} Mbps，高于当前上限 ${REC_IN}，可考虑单独上调入口"
    fi
  else
    # 新机器：机器上可能还留着别的限速脚本，先沿用它的速率，其次才看测速
    read -r d_eg d_in <<<"$(detect_existing_rate "$(primary_iface)")"
    if [ -n "$d_eg" ]; then
      REC_EG=$(unit_num "$d_eg")
      REC_IN=$(unit_num "${d_in:-$d_eg}")
      [ "$REC_IN" -gt 0 ] 2>/dev/null || REC_IN=$REC_EG
      REC_WHY="机器上已有整形脚本，沿用它的速率：出口 ${REC_EG} / 入口 ${REC_IN} Mbps"
    elif awk -v p="$pe" 'BEGIN{exit !(p > 0)}'; then
      REC_EG=$(awk -v p="$pe" 'BEGIN{printf "%d", p * 0.95}')
      if awk -v p="$pi" 'BEGIN{exit !(p > 0)}'; then
        REC_IN=$(awk -v p="$pi" 'BEGIN{printf "%d", p * 0.95}')
      else
        REC_IN=$REC_EG
      fi
      REC_WHY="没有历史整形，按测速峰值：出口 上行 ${pe} Mbps → ${REC_EG}，入口 下行 ${pi:-同出口} Mbps → ${REC_IN}（均取 95%）"
    elif awk -v p="$pi" 'BEGIN{exit !(p > 0)}'; then
      REC_EG=$(awk -v p="$pi" 'BEGIN{printf "%d", p * 0.95}')
      REC_IN=$REC_EG
      REC_WHY="没有出口测速记录，暂按下行峰值 ${pi} Mbps 的 95% 取"
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
  local ifc ans shapers opt_yes=0 all_ifaces
  case "${1:-}" in
    --yes | -y) opt_yes=1 ;;
  esac
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
    read -rp "  是否把出口上调到 ${REC_SUGGEST} Mbps？（入口保持不变）[y/N]: " ans
    case "${ans:-N}" in
      y | Y) REC_EG=$REC_SUGGEST ;;
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
  if [ "$opt_yes" -ne 1 ]; then
    if [ ! -t 0 ]; then
      note "非交互环境，未执行任何改动。要自动执行请加 --yes： cake optimize --yes"
      return 1
    fi
    read -rp "  确认执行？[Y/n]: " ans || ans="n"
    case "${ans:-Y}" in
      n | N) note "已取消"; return 0 ;;
    esac
  fi

  say ""
  if [ -n "$shapers" ]; then cleanup_conflicts; fi

  # 原来直接 IFACES="$ifc"，会把多网卡机器静默缩成一块，其余网卡的整形配置凭空消失。
  all_ifaces="${IFACES:-$ifc}"
  [ -n "$all_ifaces" ] || all_ifaces="$ifc"
  IFACES="$all_ifaces"; RATE="${REC_EG}mbit"; MODE="both"
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
  say " 12) 立即测速并记录（马上跑，不等空闲）"
  say " 13) 在线升级（检查并升级到 GitHub 最新版）"
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
  MENU_MODE=1
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
      12) record_speedtest now; pause ;;
      13) do_upgrade; pause ;;
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
  cake-fairshare clients [秒] [行数]   按客户端实时监控（默认 2 秒 / 10 行）
  cake-fairshare log            采样一次（供 systemd timer 调用）
  cake-fairshare report [N]     查看最近 N 条采样
  cake-fairshare check          现场诊断（判断是否自身占满）
  cake-fairshare health         带宽健康报告（限速历史）
  cake-fairshare daily          生成一次日报（供 timer 调用）
  cake-fairshare speedtest      立即测速一次并记入历史
  cake-fairshare speedtest --auto   先等链路空闲再测（定时器用这个）
  cake-fairshare name [名称]    设置/查看节点名称
  cake-fairshare optimize [--yes]
                                分析机器并一键套用推荐配置（最常用）
  cake-fairshare analyze        只分析、给推荐，不改任何东西
  cake-fairshare init [带宽] [--clean]
                                一键配置并启用；--clean 自动停用冲突的限速服务
  cake-fairshare preflight      只检查环境，不改任何东西
  cake-fairshare upgrade        检查并升级到最新版（--check 只看不升）
  cake-fairshare sync-units     把 systemd unit 同步到当前版本的模板
  cake-fairshare --help

配置：${CONF}
状态：${CONF_DIR}/state.<网卡>
日志：${LOG_FILE}
EOF
}

case "${1:-}" in
  "")             main_menu ;;
  apply)          require_root; do_apply ;;
  start)          require_root; do_apply ;;
  optimize)
    shift
    require_root
    do_optimize "${1:-}"
    ;;
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
  speedtest)
    shift
    require_root
    case "${1:-}" in
      --auto | auto) record_speedtest auto ;;
      *) record_speedtest now ;;
    esac
    ;;
  name)
    shift
    require_root
    do_name "$@"
    ;;
  upgrade)
    shift
    require_root
    do_upgrade "${1:-}"
    ;;
  sync-units)     require_root; sync_units ;;
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
