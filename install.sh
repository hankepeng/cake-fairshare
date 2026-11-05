#!/usr/bin/env bash
# =============================================================================
# cake-fairshare 安装脚本
#
#   bash install.sh                 安装 + 自动配置启用
#                                   （节点名=主机名、北京时间、自动装 speedtest
#                                    并固定测速点、开启采样/日报/自动测速三个定时器；
#                                    已有整形就沿用其速率，没有则用默认 190mbit）
#   bash install.sh 95mbit          安装 + 指定带宽
#   bash install.sh --clean         安装 + 自动停用冲突的限速服务
#   bash install.sh 95mbit --clean  两者组合
#   bash install.sh --no-init       只安装，不改动配置
#
#   在线一行搞定：
#   bash <(curl -fsSL https://raw.githubusercontent.com/hankepeng/cake-fairshare/main/install.sh)
#   bash <(curl -fsSL https://raw.githubusercontent.com/hankepeng/cake-fairshare/main/install.sh) --clean
#
# 安装位置：/usr/local/sbin/cake-fairshare
# =============================================================================

set -euo pipefail

REPO="hankepeng/cake-fairshare"
BRANCH="main"
TARGET="/usr/local/sbin/cake-fairshare"
CONF="/etc/cake-fairshare/config"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/cake-fairshare.sh"

RATE=""
CLEAN=0
DO_INIT=1

for a in "$@"; do
  case "$a" in
    --clean)   CLEAN=1 ;;
    --no-init) DO_INIT=0 ;;
    -h|--help)
      sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    "") ;;
    *) RATE="$a" ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "请用 root 运行： sudo bash $0" >&2
  exit 1
fi

if ! command -v tc >/dev/null 2>&1; then
  echo "缺少 iproute2（tc 命令）。" >&2
  echo "  Debian/Ubuntu: apt install -y iproute2" >&2
  echo "  RHEL/Rocky:    dnf install -y iproute iproute-tc" >&2
  exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -f "$(dirname "$0")/cake-fairshare.sh" ]; then
  echo ">> 使用本地 cake-fairshare.sh"
  cp "$(dirname "$0")/cake-fairshare.sh" "$tmp"
else
  echo ">> 下载 ${URL}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$URL" -o "$tmp"
  else
    wget -qO "$tmp" "$URL"
  fi
fi

install -m 0755 "$tmp" "$TARGET"
echo ">> 已安装到 ${TARGET}"

# 短命令：输入 cake 就进菜单
ALIAS="/usr/local/sbin/cake"
if [ ! -e "$ALIAS" ] || [ -L "$ALIAS" ]; then
  ln -sfn "$TARGET" "$ALIAS"
  echo ">> 短命令已就绪：cake"
fi

if [ "$DO_INIT" -eq 0 ]; then
  echo
  echo "已跳过配置。需要时执行： sudo cake-fairshare init"
  exit 0
fi

# 已有配置且没显式给参数时，不覆盖
if [ -f "$CONF" ] && [ -z "$RATE" ] && [ "$CLEAN" -eq 0 ]; then
  echo
  echo ">> 检测到已有配置 ${CONF}，跳过初始化（要重配： sudo cake-fairshare init）"
  "$TARGET" apply || true
  echo
  echo "== 完成（升级模式，配置未改动）=="
  echo "  查看状态： sudo cake-fairshare status"
  exit 0
fi

echo
set -- init
if [ -n "$RATE" ]; then set -- "$@" "$RATE"; fi
if [ "$CLEAN" -eq 1 ]; then set -- "$@" --clean; fi

if ! "$TARGET" "$@"; then
  echo
  echo "!! 配置失败，可运行 sudo cake-fairshare 用交互菜单排查" >&2
  exit 1
fi

echo
echo "== 完成 =="
if [ -r "$CONF" ]; then
  # shellcheck disable=SC1090
  ( . "$CONF" 2>/dev/null
    printf '  节点：%s  网卡：%s  出口：%s  入口：%s\n' \
      "${NODE_NAME:-未命名}" "${IFACES:-?}" \
      "${RATE_EGRESS:-${RATE:-?}}" "${RATE_INGRESS:-${RATE:-?}}" )
fi
echo "  查看状态： sudo cake-fairshare status"
echo "  现场诊断： sudo cake-fairshare check"
echo "  交互菜单： sudo cake-fairshare"
