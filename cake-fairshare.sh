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

VERSION="2.0.0"
CONF_DIR="/etc/cake-fairshare"
CONF="${CONF_DIR}/config"
UNIT="/etc/systemd/system/cake-fairshare.service"
SELF_INSTALL="/usr/local/sbin/cake-fairshare"
LOG_FILE="/var/log/cake-fairshare.log"

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
  IFACES=""; RATE="95mbit"; MODE="both"
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

# ---------------------------------------------------------------- 核心动作 ----
apply_one() {
  local ifc="$1" rate="$2" mode="$3"
  local qdisc="cake" orig ifb="" idx=0

  orig=$(root_qdisc "$ifc")
  if [ "$orig" = "mq" ]; then
    if cake_mq_supported; then
      qdisc="cake_mq"
      ok "$ifc 为多队列网卡，改用 cake_mq"
    else
      bad "$ifc 的根 qdisc 是 mq（多发送队列），当前内核无法直接挂 cake"
      note "方案一（立即可用，可回滚）：把该网卡发送队列降为 1"
      note "    ethtool -L $ifc combined 1"
      note "方案二（长期）：升级到带 cake_mq 的内核"
      logline "FAIL $ifc mq-without-cake_mq"
      return 1
    fi
  fi

  clear_state "$ifc"
  put_state "$ifc" ORIG_QDISC "$orig"

  if ! tc qdisc replace dev "$ifc" root "$qdisc" bandwidth "$rate" dual-dsthost 2>/dev/null; then
    bad "在 $ifc 上挂 $qdisc 失败"
    logline "FAIL $ifc tc-replace"
    clear_state "$ifc"
    return 1
  fi
  ok "出口整形：$ifc  $qdisc bandwidth $rate dual-dsthost"

  if [ "$mode" = "both" ]; then
    while ip link show "ifb$idx" >/dev/null 2>&1; do idx=$((idx + 1)); done
    ifb="ifb$idx"
    if ip link add "$ifb" type ifb 2>/dev/null && ip link set "$ifb" up 2>/dev/null; then
      tc qdisc del dev "$ifc" ingress >/dev/null 2>&1
      tc qdisc add dev "$ifc" handle ffff: ingress 2>/dev/null
      tc filter add dev "$ifc" parent ffff: protocol all u32 \
          match u32 0 0 action mirred egress redirect dev "$ifb" >/dev/null 2>&1
      tc qdisc replace dev "$ifb" root cake bandwidth "$rate" dual-srchost 2>/dev/null
      put_state "$ifc" IFB "$ifb"
      ok "入口整形：$ifc -> $ifb  cake bandwidth $rate dual-srchost"
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

  if [ -n "$orig" ] && [ "$orig" != "mq" ] && [ "$orig" != "noqueue" ]; then
    if tc qdisc replace dev "$ifc" root "$orig" 2>/dev/null; then
      ok "$ifc 已恢复原 qdisc：$orig"
    else
      tc qdisc del dev "$ifc" root >/dev/null 2>&1
      note "$ifc 恢复 $orig 失败，已清空根队列（内核将回落默认值）"
    fi
  else
    tc qdisc del dev "$ifc" root >/dev/null 2>&1
    ok "$ifc 已清除整形"
  fi
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
    printf '%b可用%b\n' "$G" "$R"
  else
    printf '%b不可用%b %b（内核较旧；网卡单队列时不影响）%b\n' "$Y" "$R" "$D" "$R"
  fi
  hr
  say "  网卡"
  local def ifc mark v6tag
  def=$(primary_iface)
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
    printf '  当前配置  : 网卡=%s  带宽=%s  方向=%s\n' "$IFACES" "$RATE" "$MODE"
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
  dim "  overlimits/drops 持续增长 = 限速已生效在压；backlog 长期堆满 = 带宽设高了。"
}

monitor() {
  load_conf
  local ifc="${1:-}"
  [ -n "$ifc" ] || ifc=$(printf '%s' "$IFACES" | awk '{print $1}')
  [ -n "$ifc" ] || { note "没有可用网卡"; return 1; }
  local rx1 tx1 rx2 tx2 t1 t2 dt
  trap 'printf "\n"; return 0' INT
  while true; do
    t1=$(date +%s%N)
    read -r rx1 tx1 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    sleep 2
    t2=$(date +%s%N)
    read -r rx2 tx2 < <(awk -v d="$ifc" '$1==d":" {print $2, $10}' /proc/net/dev)
    dt=$(awk -v a="$t1" -v b="$t2" 'BEGIN{print (b-a)/1000000000}')
    clear
    say "${B}实时监控  $ifc${R}   ${D}(Ctrl-C 退出)${R}"
    hr
    awk -v a="$rx1" -v b="$rx2" -v c="$tx1" -v d="$tx2" -v t="$dt" 'BEGIN{
      if (t <= 0) t = 1;
      printf "  下行 %.1f Mbps     上行 %.1f Mbps\n", (b-a)*8/t/1000000, (d-c)*8/t/1000000
    }'
    hr
    tc -s qdisc show dev "$ifc" | sed 's/^/  /'
  done
}

# ---------------------------------------------------------------- 菜单动作 ----
menu_enable() {
  local ifc_list def sel rate mode confirm chosen n pick ifc i
  ifc_list=$(list_ifaces)
  if [ -z "$ifc_list" ]; then bad "没有可用的物理网卡"; pause; return 1; fi
  def=$(primary_iface)

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
  read -rp "选择网卡 [默认 1]（可输入 1 2 或 a）: " sel
  sel=${sel:-1}

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

  read -rp "总带宽（如 95mbit / 100M / 1gbit）[默认 95mbit]: " rate
  rate=$(normalize_rate "${rate:-95mbit}") || { bad "带宽格式无法识别"; pause; return 1; }

  say ""
  say "  限制方向："
  say "    1) 上下行都限（推荐，防止上传抢带宽）"
  say "    2) 只限下行（CPU 更省，仅整形出口）"
  read -rp "  选择 [默认 1]: " mode
  if [ "${mode:-1}" = "2" ]; then mode="down"; else mode="both"; fi

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
    ok "已启用：每人在线可占 ${rate} ÷ 当前在线客户端数"
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

menu_service() {
  local act
  say ""
  say "  1) 安装并开启开机自启"
  say "  2) 关闭并移除自启"
  say "  3) 查看服务状态"
  read -rp "选择 [默认 1]: " act
  case "${act:-1}" in
    1)
      if [ ! -x "$SELF_INSTALL" ]; then
        note "先把脚本安装到 $SELF_INSTALL"
        install -m 0755 "$0" "$SELF_INSTALL" || { bad "安装失败"; pause; return 1; }
        ok "已安装：$SELF_INSTALL"
      fi
      if [ ! -r "$CONF" ]; then bad "还没有配置，请先执行第 2 项"; pause; return 1; fi
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
      if systemctl enable --now cake-fairshare >/dev/null 2>&1; then
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

# ---------------------------------------------------------------- 主菜单 ----
draw_menu() {
  clear
  say ""
  printf '%b  CAKE 公平带宽分配 v%s%b   %b%s%b\n' "$B" "$VERSION" "$R" "$D" "$(os_pretty)" "$R"
  hr
  if is_active; then
    printf '  状态：%b● 运行中%b' "$G" "$R"
  else
    printf '  状态：%b○ 未启用%b' "$Y" "$R"
  fi
  if [ -r "$CONF" ]; then
    printf '      网卡 %s   带宽 %s   方向 %s\n' "$IFACES" "$RATE" "$MODE"
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
  say "  0) 退出"
  hr
}

main_menu() {
  require_root
  local choice
  while true; do
    draw_menu
    read -rp "  请输入编号: " choice
    case "$choice" in
      1) show_env; pause ;;
      2) menu_enable ;;
      3) show_status; pause ;;
      4) monitor ;;
      5) menu_stop ;;
      6) menu_service ;;
      7) menu_rate ;;
      8) menu_advice ;;
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
  -h|--help|help) usage ;;
  *)              usage; exit 1 ;;
esac
