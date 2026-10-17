#!/usr/bin/env bash
# sbpanel 一键安装脚本（面板 + 可选的 sing-box）
#
#   装完直接给你面板地址和密码。随包附带了固定版本 sing-box（1.12.12，amd64 / arm64），
#   系统里没有 sing-box 时会自动装上（含 systemd 单元和一份只监听本机的示例配置）。
#   sing-box 支持三种来源：裸二进制、.gz 压缩二进制（NAT 小鸡上只用 gunzip 即可）、官方 .deb；
#   也可以用 --singbox-url 指一个自己的直链。
#
# 用法:
#   sudo ./install.sh                                # 默认：端口 3222，密码自动生成
#   sudo ./install.sh --user admin --password 'your-pass'   # 指定面板账号密码
#   sudo ./install.sh --password 'your-pass'                # 只指定密码（用户名默认 admin）
#   sudo ./install.sh --port 3223 --config /etc/sing-box/config.json
#   sudo ./install.sh --no-singbox                   # 不装 sing-box（你自己已经有/自己装）
#   sudo ./install.sh --force-singbox                # 已装也用包里的版本覆盖
#   sudo ./install.sh --singbox-url https://.../sing-box   # 用你自己的直链下 sing-box
#   sudo ./install.sh --service none                 # 不用 systemd 管 sing-box，面板自己拉起进程
#   sudo ./install.sh --node                         # 面板用 Node 版运行（需要 node >= 18）
#
# 一条命令：
#   curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash
#
set -euo pipefail

REPO="kuisa/sbpanel"
PORT=3222
PASSWORD=""
USER_NAME="${PANEL_USER:-}"
CONFIG="/etc/sing-box/config.json"
SB_SERVICE="sing-box"
ENVF="/etc/sbpanel.env"
UNIT="/etc/systemd/system/sbpanel.service"
BINDIR="/usr/local/bin"
NODE_DIR="/opt/sbpanel-node"
SB_BIN="/usr/bin/sing-box"
USE_NODE=0
WITH_SINGBOX=1
FORCE_SINGBOX=0
SINGBOX_URL="${SINGBOX_URL:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)          PORT="$2"; shift 2 ;;
    --password)      PASSWORD="$2"; shift 2 ;;
    --user)          USER_NAME="$2"; shift 2 ;;
    --config)        CONFIG="$2"; shift 2 ;;
    --service)       SB_SERVICE="$2"; shift 2 ;;
    --singbox-url)   SINGBOX_URL="$2"; shift 2 ;;
    --node)          USE_NODE=1; shift ;;
    --no-singbox)    WITH_SINGBOX=0; shift ;;
    --force-singbox) FORCE_SINGBOX=1; shift ;;
    -h|--help)       usage ;;
    *) echo "未知参数: $1（用 --help 看用法）"; exit 1 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo ./install.sh）"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构: $(uname -m)（目前提供 amd64 / arm64）" ;;
esac
log "系统架构: $ARCH"

# 往 /usr/bin/sing-box 落一个二进制。先删再写：目标可能正在被运行中的 sing-box 占用，
# 直接覆盖会 ETXTBSY（Text file busy）。
put_bin() {
  rm -f "$SB_BIN"
  install -m 0755 "$1" "$SB_BIN" 2>/dev/null || { cat "$1" > "$SB_BIN"; chmod 0755 "$SB_BIN"; }
}

# ---------- sing-box：缺了就装上 ----------
install_singbox() {
  if command -v sing-box >/dev/null 2>&1 && [ "$FORCE_SINGBOX" != "1" ]; then
    log "系统已有 sing-box（$(command -v sing-box)，$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')），跳过（要覆盖加 --force-singbox）"
    return 0
  fi

  local dir="$HERE/third_party/sing-box"
  local raw="$dir/sing-box-linux-$ARCH"
  local gz="$raw.gz"
  local deb; deb="$(ls "$dir"/sing-box_*_linux_"$ARCH".deb 2>/dev/null | head -1 || true)"
  local tmp; tmp="$(mktemp -d)"
  local used=""

  if [ -n "$SINGBOX_URL" ]; then
    # 显式指定的直链优先于包内文件
    log "sing-box 来源：--singbox-url $SINGBOX_URL"
    if curl -fsSL --connect-timeout 20 -o "$tmp/sing-box" "$SINGBOX_URL"; then
      case "$SINGBOX_URL" in
        *.gz) gunzip -c "$tmp/sing-box" > "$tmp/sing-box.raw" && put_bin "$tmp/sing-box.raw" ;;
        *)    put_bin "$tmp/sing-box" ;;
      esac
      used="$SINGBOX_URL"
    else
      warn "从 $SINGBOX_URL 下载失败，改用包内文件"
    fi
  fi
  if [ -z "$used" ] && [ -f "$raw" ]; then
    log "sing-box 来源：包内裸二进制 $(basename "$raw")"
    put_bin "$raw"; used="$raw"
  elif [ -z "$used" ] && [ -f "$gz" ]; then
    command -v gunzip >/dev/null 2>&1 || { warn "没有 gunzip，无法解压 $gz"; rm -rf "$tmp"; return 0; }
    log "sing-box 来源：包内压缩二进制 $(basename "$gz")"
    gunzip -c "$gz" > "$tmp/sing-box"
    put_bin "$tmp/sing-box"; used="$gz"
  elif [ -z "$used" ] && [ -n "$deb" ]; then
    log "sing-box 来源：包内 deb $(basename "$deb")"
    if command -v dpkg-deb >/dev/null 2>&1; then
      dpkg-deb -x "$deb" "$tmp"
    elif command -v ar >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
      ( cd "$tmp" && ar x "$deb" && tar xf data.tar.* )
    fi
    if [ -f "$tmp/usr/bin/sing-box" ]; then
      put_bin "$tmp/usr/bin/sing-box"; used="$deb"
      if [ -f "$tmp/usr/lib/sysusers.d/sing-box.conf" ] && command -v systemd-sysusers >/dev/null 2>&1; then
        systemd-sysusers "$tmp/usr/lib/sysusers.d/sing-box.conf" 2>/dev/null || true
      fi
    else
      warn "deb 解包失败（缺 dpkg-deb / ar+tar），换个来源"
    fi
  fi

  if [ -z "$used" ]; then
    warn "包内没找到 $ARCH 的 sing-box（裸二进制/压缩二进制/deb 都没有），改用官方安装脚本（需联网）"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://sing-box.app/install.sh | sh || warn "官方脚本安装失败，可稍后手动装"
    fi
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"

  # 系统用户
  id -u sing-box >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin sing-box 2>/dev/null || true

  # systemd 单元
  if [ -f "$dir/sing-box.service" ]; then
    install -m 0644 "$dir/sing-box.service" /etc/systemd/system/sing-box.service
  fi

  # 首次配置（只监听本机的安全默认）
  if [ ! -f /etc/sing-box/config.json ]; then
    mkdir -p /etc/sing-box
    if [ -f "$dir/config.example.json" ]; then
      install -m 0644 "$dir/config.example.json" /etc/sing-box/config.json
    else
      printf '%s\n' '{"log":{"level":"info"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7890}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > /etc/sing-box/config.json
    fi
    log "已写入示例配置 /etc/sing-box/config.json（只监听 127.0.0.1:7890，安全默认）"
  fi

  command -v systemctl >/dev/null 2>&1 && { systemctl daemon-reload 2>/dev/null || true; systemctl enable sing-box >/dev/null 2>&1 || true; }
  if [ "$SB_SERVICE" != "none" ] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart sing-box 2>/dev/null || warn "sing-box 启动失败：journalctl -u sing-box -n 30"
  fi
  log "sing-box 就绪：$(sing-box version 2>/dev/null | head -1)"
}

if [ "$WITH_SINGBOX" = "1" ]; then
  install_singbox
else
  log "按要求跳过 sing-box 安装（--no-singbox）"
fi

if [ "$SB_SERVICE" != "none" ]; then
  command -v sing-box >/dev/null 2>&1 || warn "系统里没有 sing-box，面板的启停/检查会不可用（装好后重启面板即可）"
  [ -f "$CONFIG" ] || warn "配置文件 $CONFIG 不存在，面板会显示“配置无效”；放好配置后在面板里检查一下即可"
fi

# ---------- 面板程序本体 ----------
if [ "$USE_NODE" = "1" ]; then
  command -v node >/dev/null 2>&1 || die "没装 node（需要 Node 18+）"
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$NODE_MAJOR" -ge 18 ] || die "Node 版本过低（$(node -v)），需要 18 以上"
  [ -f "$HERE/node/server.js" ] || die "找不到 node/server.js（请在仓库目录里执行本脚本）"
  mkdir -p "$NODE_DIR"
  cp -f "$HERE/node/server.js" "$HERE/node/panel.html" "$HERE/node/package.json" "$NODE_DIR/" 2>/dev/null || true
  EXEC_START="$(command -v node) $NODE_DIR/server.js"
  log "使用 Node 版：$NODE_DIR/server.js"
else
  LOCAL_BIN="$HERE/dist/sbpanel-linux-$ARCH"
  if [ -f "$LOCAL_BIN" ]; then
    log "使用仓库内的二进制：$LOCAL_BIN"
    rm -f "$BINDIR/sbpanel"
    install -m 0755 "$LOCAL_BIN" "$BINDIR/sbpanel"
  else
    URL="https://github.com/$REPO/releases/latest/download/sbpanel-linux-$ARCH"
    log "从 GitHub 下载面板二进制：$URL"
    if curl -fsSL --connect-timeout 15 -o /tmp/sbpanel.dl "$URL"; then
      rm -f "$BINDIR/sbpanel"; install -m 0755 /tmp/sbpanel.dl "$BINDIR/sbpanel"; rm -f /tmp/sbpanel.dl
    elif [ -d "$HERE/go" ] && command -v go >/dev/null 2>&1; then
      warn "下载失败，改用本机 Go 编译"
      # 前端只有一份源（node/），Go 构建时要先拷进去
      cp -f "$HERE/node/panel.html" "$HERE/node/setup.html" "$HERE/go/" 2>/dev/null || true
      ( cd "$HERE/go" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /tmp/sbpanel.build . )
      rm -f "$BINDIR/sbpanel"; install -m 0755 /tmp/sbpanel.build "$BINDIR/sbpanel"; rm -f /tmp/sbpanel.build
    else
      die "拿不到面板二进制：GitHub 下载失败，且本机没有 Go 可编译"
    fi
  fi
  EXEC_START="$BINDIR/sbpanel"
  log "已安装：$BINDIR/sbpanel"
fi

# ---------- 面板密码：保留已有的，没给就随机生成 ----------
if [ -z "$PASSWORD" ] && [ -f "$ENVF" ]; then
  PASSWORD="$(grep -E '^PANEL_PASSWORD=' "$ENVF" | head -1 | cut -d= -f2- || true)"
  [ -n "$PASSWORD" ] && log "沿用现有面板密码（$ENVF 里已保存）"
fi
if [ -z "$PASSWORD" ]; then
  PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  GENERATED=1
fi
if [ -z "$USER_NAME" ] && [ -f "$ENVF" ]; then
  USER_NAME="$(grep -E '^PANEL_USER=' "$ENVF" | head -1 | cut -d= -f2- || true)"
fi
USER_NAME="${USER_NAME:-admin}"

umask 077
cat > "$ENVF" <<EOF
# sbpanel 运行参数（本文件含密码，权限 600）
PANEL_PORT=$PORT
PANEL_HOST=0.0.0.0
PANEL_USER=$USER_NAME
PANEL_PASSWORD=$PASSWORD
SINGBOX_CONFIG=$CONFIG
SINGBOX_BIN=sing-box
SINGBOX_SERVICE=$SB_SERVICE
SINGBOX_LOG=/var/log/sing-box.log
EOF
chmod 600 "$ENVF"
log "已写入 $ENVF"

if command -v systemctl >/dev/null 2>&1; then
  cat > "$UNIT" <<EOF
[Unit]
Description=sbpanel - sing-box 控制面板
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENVF
ExecStart=$EXEC_START
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$UNIT"
  systemctl daemon-reload
  systemctl enable sbpanel >/dev/null 2>&1 || true
  systemctl restart sbpanel
  sleep 1.5
  STATE="$(systemctl is-active sbpanel || true)"
  [ "$STATE" = "active" ] || warn "面板服务状态是 $STATE，用 journalctl -u sbpanel -n 30 看日志"
else
  warn "没有 systemd：跳过服务安装。手动启动：$EXEC_START"
fi

# ---------- 访问地址提示 ----------
PUB_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
  | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
ALL_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
  | grep -vE '^127\.' | paste -sd' ' - || true)"
IPV6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"

echo
echo "──────────────────────────────────────────────"
echo " sbpanel 安装完成"
if [ -n "$PUB_IP" ]; then
  echo " 面板地址 : http://$PUB_IP:$PORT"
  [ -n "$ALL_IP" ] && [ "$ALL_IP" != "$PUB_IP" ] && echo " （本机其它地址: $ALL_IP）"
elif [ -n "$IPV6" ]; then
  echo " 面板地址 : http://[$IPV6]:$PORT   （本机没有公网 IPv4，走 IPv6）"
  [ -n "$ALL_IP" ] && echo " （也可用这些 IPv4: $ALL_IP）"
else
  echo " 面板地址 : http://<主机IP>:$PORT"
  [ -n "$ALL_IP" ] && echo " （本机检测到的地址: $ALL_IP）"
fi
echo " 用户名   : $USER_NAME"
echo " 密  码   : $PASSWORD"
[ "${GENERATED:-0}" = "1" ] && echo " （自动生成的，建议记下来；改 $ENVF 后 systemctl restart sbpanel 生效）"
echo " 配置文件 : $CONFIG"
echo " sing-box : $(command -v sing-box 2>/dev/null || echo '未安装')$(command -v sing-box >/dev/null 2>&1 && printf ' (%s)' "$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')")"
echo " 服务管理 : systemctl {status,restart,stop} sbpanel / sing-box"
echo " 查看日志 : journalctl -u sbpanel -f"
echo "──────────────────────────────────────────────"
