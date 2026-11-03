#!/usr/bin/env bash
# =============================================================================
# cake-fairshare 安装脚本
#
#   bash install.sh                    # 使用同目录下的 cake-fairshare.sh
#   bash <(curl -fsSL .../install.sh)  # 在线安装
#
# 安装位置：/usr/local/sbin/cake-fairshare
# =============================================================================

set -euo pipefail

REPO="hankepeng/cake-fairshare"
BRANCH="main"
TARGET="/usr/local/sbin/cake-fairshare"
URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/cake-fairshare.sh"

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
echo
echo "下一步："
echo "  sudo cake-fairshare        # 打开交互菜单，选 1 自检 → 2 启用"
