#!/usr/bin/env bash
# sbpanel 直接运行脚本（不装 systemd，前台跑，Ctrl+C 退出）
#
#   sudo ./run.sh                   # 有二进制就用二进制，否则用 Node 版
#   sudo ./run.sh --node            # 强制用 Node 版
#   PANEL_PORT=3223 PANEL_PASSWORD=xxx sudo -E ./run.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
USE_NODE=0
[ "${1:-}" = "--node" ] && USE_NODE=1

export PANEL_PORT="${PANEL_PORT:-3222}"
export PANEL_HOST="${PANEL_HOST:-0.0.0.0}"
export PANEL_PASSWORD="${PANEL_PASSWORD:-}"
export SINGBOX_CONFIG="${SINGBOX_CONFIG:-/etc/sing-box/config.json}"
export SINGBOX_BIN="${SINGBOX_BIN:-sing-box}"
export SINGBOX_SERVICE="${SINGBOX_SERVICE:-sing-box}"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH="" ;;
esac

if [ "$USE_NODE" = "0" ] && [ -n "$ARCH" ] && [ -x "$HERE/dist/sbpanel-linux-$ARCH" ]; then
  echo "==> 用二进制启动: dist/sbpanel-linux-$ARCH"
  exec "$HERE/dist/sbpanel-linux-$ARCH"
fi

if [ "$USE_NODE" = "0" ] && command -v sbpanel >/dev/null 2>&1; then
  echo "==> 用已安装的 sbpanel 启动"
  exec sbpanel
fi

command -v node >/dev/null 2>&1 || { echo "没找到可执行文件，也没装 node。先跑 ./install.sh 或安装 Node 18+"; exit 1; }
echo "==> 用 Node 版启动: node/server.js"
exec node "$HERE/node/server.js"
