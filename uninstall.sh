#!/usr/bin/env bash
# 卸载 sbpanel（停服务 + 删文件，不动 sing-box 和你的配置）
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "请用 root 运行"; exit 1; }

echo "==> 停止并禁用服务"
systemctl disable --now sbpanel 2>/dev/null || true
rm -f /etc/systemd/system/sbpanel.service
systemctl daemon-reload 2>/dev/null || true

echo "==> 删除程序与配置"
rm -f /usr/local/bin/sbpanel
rm -rf /opt/sbpanel-node
rm -f /etc/sbpanel.env

echo
echo "已卸载。以下内容没有动："
echo "  - sing-box 本体与它自己的 systemd 服务"
echo "  - sing-box 配置文件（含脚本自动生成的 config.json.bak.* 备份）"
echo "  - 证书目录 <config 目录>/certs"
