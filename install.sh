#!/usr/bin/env bash
# sbpanel 一键安装脚本（面板 + sing-box），兼容 systemd / OpenRC(Alpine) / 无服务管理器
#
# 装完直接打印面板地址、用户名和密码。
# sing-box 用仓库里的 1.12.12 压缩二进制（amd64 / arm64），不需要 dpkg，Alpine 也能装。
#
# 用法:
#   sudo ./install.sh                                   # 默认端口 3222，密码自动生成
#   sudo ./install.sh --user admin --password 'xxx'      # 指定账号密码
#   sudo ./install.sh --port 3223
#   sudo ./install.sh --singbox-url https://.../sb.gz    # 用自己的 sing-box 直链
#   sudo ./install.sh --no-singbox                       # 不装 sing-box
#   sudo ./install.sh --force-singbox                    # 已装也覆盖成仓库版本
#   sudo ./install.sh --service none                     # 不让面板管理 sing-box 的 systemd/rc 服务
#   sudo ./install.sh --node                             # 面板用 Node 版运行（需 node>=18）
#
# 一条命令（不需要先克隆仓库，所有文件从仓库 raw 地址取）:
#   curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash
#
set -eu

REPO="kuisa/sbpanel"
BRANCH="main"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
REL="https://github.com/${REPO}/releases/latest/download"

PORT=3222
PASSWORD=""
USER_NAME="${PANEL_USER:-}"
CONFIG="/etc/sing-box/config.json"
SB_SERVICE="sing-box"
ENVF="/etc/sbpanel.env"
BINDIR="/usr/local/bin"
SB_BIN="/usr/local/bin/sing-box"
NODE_DIR="/opt/sbpanel-node"
USE_NODE=0
WITH_SINGBOX=1
FORCE_SINGBOX=0
SINGBOX_URL="${SINGBOX_URL:-}"
HERE="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo /tmp)"

usage() { sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0; }

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

[ "$(id -u)" = "0" ] || die "请用 root 运行（sudo ./install.sh 或 curl ... | sudo sh）"

# ---------- Alpine 依赖（Alpine 自带 bash/curl/wget 都没有，先装上）----------
if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
  [ -z "${SB_REEXEC:-}" ] && log "检测到 Alpine（$(cat /etc/alpine-release)）：安装 bash curl wget"
  apk update >/dev/null 2>&1 || true
  apk add --no-cache bash curl wget >/dev/null 2>&1 || warn "apk add 失败，继续用现有工具"
  # 装上 bash 后用 bash 重新执行自己，保证后续语法可用
  if command -v bash >/dev/null 2>&1 && [ -z "${SB_REEXEC:-}" ]; then
    export SB_REEXEC=1
    exec bash "$0" "$@"
  fi
fi

# ---------- 环境探测 ----------
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) ARCH="$(uname -m)" ;;
esac
log "系统架构: $ARCH"

HAS_SYSTEMD=0
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then HAS_SYSTEMD=1; fi
HAS_OPENRC=0
if [ "$HAS_SYSTEMD" = "0" ] && command -v rc-service >/dev/null 2>&1; then HAS_OPENRC=1; fi
IS_ALPINE=0; [ -f /etc/alpine-release ] && IS_ALPINE=1
if [ "$HAS_SYSTEMD" = "1" ]; then
  log "服务管理: systemd"
elif [ "$HAS_OPENRC" = "1" ]; then
  log "服务管理: OpenRC$( [ "$IS_ALPINE" = "1" ] && echo '（Alpine）')"
else
  log "服务管理: 无（没有 systemd/OpenRC，安装后需手动启动）"
fi

# ---------- 下载与落盘（兼容 curl / wget，Alpine 上可能只有 busybox wget）----------
fetch() { # fetch <url> <outfile>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 20 -O "$2" "$1"
  else
    return 127
  fi
}

put_file() { # put_file <src> <dst> <mode>
  rm -f "$2"
  cp -f "$1" "$2" 2>/dev/null || cat "$1" > "$2"
  chmod "$3" "$2" 2>/dev/null || true
}

has_local() { [ -f "$HERE/$1" ]; }
get_repo_file() { # get_repo_file <相对路径> <输出文件>  —— 优先本地，否则从仓库 raw 下
  if [ -f "$HERE/$1" ]; then cp -f "$HERE/$1" "$2"; return 0; fi
  fetch "$RAW/$1" "$2"
}

# ---------- sing-box ----------
install_singbox() {
  if command -v sing-box >/dev/null 2>&1 && [ "$FORCE_SINGBOX" != "1" ]; then
    log "系统已有 sing-box（$(command -v sing-box)，$(sing-box version 2>/dev/null | head -1 | awk '{print $NF}')），跳过（要覆盖加 --force-singbox）"
    return 0
  fi

  tmp="$(mktemp -d)"
  used=""
  src=""

  # 1) 显式直链
  if [ -n "$SINGBOX_URL" ]; then
    log "sing-box 来源: --singbox-url $SINGBOX_URL"
    if fetch "$SINGBOX_URL" "$tmp/sb"; then
      case "$SINGBOX_URL" in
        *.gz) gunzip -c "$tmp/sb" > "$tmp/sb.raw" 2>/dev/null || gzip -d -c "$tmp/sb" > "$tmp/sb.raw"; src="$tmp/sb.raw" ;;
        *)    src="$tmp/sb" ;;
      esac
      used="url"
    else
      warn "从 $SINGBOX_URL 下载失败，改用包内/仓库文件"
    fi
  fi

  # 2) 包内裸二进制 / 压缩二进制
  if [ -z "$used" ] && has_local "third_party/sing-box/sing-box-linux-$ARCH"; then
    log "sing-box 来源: 包内裸二进制"
    src="$HERE/third_party/sing-box/sing-box-linux-$ARCH"; used="local-raw"
  fi
  if [ -z "$used" ] && has_local "third_party/sing-box/sing-box-linux-$ARCH.gz"; then
    log "sing-box 来源: 包内压缩二进制"
    gunzip -c "$HERE/third_party/sing-box/sing-box-linux-$ARCH.gz" > "$tmp/sb.raw" 2>/dev/null || gzip -d -c "$HERE/third_party/sing-box/sing-box-linux-$ARCH.gz" > "$tmp/sb.raw"
    src="$tmp/sb.raw"; used="local-gz"
  fi

  # 3) 仓库 raw 的压缩二进制（1.12.12，amd64/arm64）
  if [ -z "$used" ]; then
    case "$ARCH" in
      amd64|arm64)
        log "sing-box 来源: 仓库 sing-box-linux-$ARCH.gz（1.12.12）"
        if fetch "$RAW/third_party/sing-box/sing-box-linux-$ARCH.gz" "$tmp/sb.gz"; then
          gunzip -c "$tmp/sb.gz" > "$tmp/sb.raw" 2>/dev/null || gzip -d -c "$tmp/sb.gz" > "$tmp/sb.raw"
          src="$tmp/sb.raw"; used="repo-gz"
        else
          warn "仓库里的 sing-box 下载失败"
        fi
        ;;
    esac
  fi

  # 4) 兜底：官方安装脚本（支持更多架构，但会装较新的版本）
  if [ -z "$used" ]; then
    warn "拿不到 $ARCH 的 sing-box，改用官方安装脚本（需要联网，装的是较新版本）"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://sing-box.app/install.sh | sh || warn "官方脚本安装失败，可稍后手动装"
    fi
    rm -rf "$tmp"
    return 0
  fi

  put_file "$src" "$SB_BIN" 0755
  rm -rf "$tmp"
  log "已安装 sing-box 到 $SB_BIN"

  # 系统用户（systemd 单元要 User=sing-box；OpenRC/无服务则不需要）
  if [ "$HAS_SYSTEMD" = "1" ]; then
    if ! id -u sing-box >/dev/null 2>&1; then
      if command -v useradd >/dev/null 2>&1; then
        useradd -r -s /usr/sbin/nologin sing-box 2>/dev/null || useradd -r -s /sbin/nologin sing-box 2>/dev/null || true
      elif command -v adduser >/dev/null 2>&1; then
        adduser -S -D -H -s /sbin/nologin sing-box 2>/dev/null || true
      fi
    fi
  fi

  # 配置（只监听本机的安全默认）
  if [ ! -f /etc/sing-box/config.json ]; then
    mkdir -p /etc/sing-box
    if get_repo_file "third_party/sing-box/config.example.json" /etc/sing-box/config.json 2>/dev/null; then
      log "已写入示例配置 /etc/sing-box/config.json（只监听 127.0.0.1:7890）"
    else
      printf '%s\n' '{"log":{"level":"info"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7890}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > /etc/sing-box/config.json
      log "已写入最小示例配置 /etc/sing-box/config.json"
    fi
  fi

  # 服务
  if [ "$SB_SERVICE" != "none" ]; then
    if [ "$HAS_SYSTEMD" = "1" ]; then
      cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target network-online.target

[Service]
User=sing-box
StateDirectory=sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
      systemctl daemon-reload 2>/dev/null || true
      systemctl enable sing-box >/dev/null 2>&1 || true
      systemctl restart sing-box 2>/dev/null || warn "sing-box 启动失败：journalctl -u sing-box -n 30"
    elif [ "$HAS_OPENRC" = "1" ]; then
      cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
command="$SB_BIN"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after firewall; }
EOF
      chmod 0755 /etc/init.d/sing-box
      rc-update add sing-box default >/dev/null 2>&1 || true
      if [ -d /run/openrc ]; then
        rc-service sing-box restart >/dev/null 2>&1 || warn "sing-box 启动失败：cat /var/log/sing-box.log"
      else
        warn "无 OpenRC 运行环境：直接启动 sing-box"
        nohup "$SB_BIN" run -c /etc/sing-box/config.json >/var/log/sing-box.log 2>&1 &
      fi
    fi
  fi
  log "sing-box 就绪：$($SB_BIN version 2>/dev/null | head -1)"
}

if [ "$WITH_SINGBOX" = "1" ]; then install_singbox; else log "按要求跳过 sing-box 安装（--no-singbox）"; fi

# ---------- 面板程序 ----------
if [ "$USE_NODE" = "1" ]; then
  command -v node >/dev/null 2>&1 || die "没装 node（需要 Node 18+）"
  NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$NODE_MAJOR" -ge 18 ] || die "Node 版本过低（$(node -v)）"
  mkdir -p "$NODE_DIR"
  for f in server.js panel.html setup.html package.json; do
    get_repo_file "node/$f" "$NODE_DIR/$f" || die "取不到 node/$f"
  done
  EXEC_START="$(command -v node) $NODE_DIR/server.js"
  log "使用 Node 版: $NODE_DIR/server.js"
else
  tmpd="$(mktemp -d)"
  got=""
  if has_local "dist/sbpanel-linux-$ARCH"; then
    log "使用仓库内的面板二进制"
    put_file "$HERE/dist/sbpanel-linux-$ARCH" "$BINDIR/sbpanel" 0755; got=1
  fi
  if [ -z "$got" ]; then
    case "$ARCH" in
      amd64|arm64)
        log "从仓库下载面板二进制（dist/sbpanel-linux-$ARCH）"
        if fetch "$RAW/dist/sbpanel-linux-$ARCH" "$tmpd/sbpanel"; then
          put_file "$tmpd/sbpanel" "$BINDIR/sbpanel" 0755; got=1
        else
          warn "仓库下载失败，试 GitHub Releases"
          if fetch "$REL/sbpanel-linux-$ARCH" "$tmpd/sbpanel"; then
            put_file "$tmpd/sbpanel" "$BINDIR/sbpanel" 0755; got=1
          fi
        fi
        ;;
    esac
  fi
  if [ -z "$got" ] && [ -d "$HERE/go" ] && command -v go >/dev/null 2>&1; then
    warn "下载失败，改用本机 Go 编译"
    cp -f "$HERE/node/panel.html" "$HERE/node/setup.html" "$HERE/go/" 2>/dev/null || true
    ( cd "$HERE/go" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$tmpd/sbpanel" . ) && { put_file "$tmpd/sbpanel" "$BINDIR/sbpanel" 0755; got=1; }
  fi
  rm -rf "$tmpd"
  [ -n "$got" ] || die "拿不到面板二进制（$ARCH）。这个架构目前只提供 amd64/arm64；其它架构请用 --node 或自行编译"
  EXEC_START="$BINDIR/sbpanel"
  log "已安装: $BINDIR/sbpanel"
fi

# ---------- 账号密码 ----------
if [ -z "$PASSWORD" ] && [ -f "$ENVF" ]; then
  PASSWORD="$(grep -E '^PANEL_PASSWORD=' "$ENVF" | head -1 | cut -d= -f2- || true)"
  [ -n "$PASSWORD" ] && log "沿用现有面板密码"
fi
if [ -z "$USER_NAME" ] && [ -f "$ENVF" ]; then
  USER_NAME="$(grep -E '^PANEL_USER=' "$ENVF" | head -1 | cut -d= -f2- || true)"
fi
if [ -z "$PASSWORD" ]; then
  PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  GENERATED=1
fi
USER_NAME="${USER_NAME:-admin}"

# 面板按这个绝对路径调用 sing-box，避免 PATH 里有别的同名旧版本
if [ -x "$SB_BIN" ]; then
  SB_BIN_EFFECTIVE="$SB_BIN"
elif command -v sing-box >/dev/null 2>&1; then
  SB_BIN_EFFECTIVE="$(command -v sing-box)"
else
  SB_BIN_EFFECTIVE="sing-box"
fi

umask 077
cat > "$ENVF" <<EOF
# sbpanel 运行参数（含密码，权限 600）
PANEL_PORT=$PORT
PANEL_HOST=0.0.0.0
PANEL_USER=$USER_NAME
PANEL_PASSWORD=$PASSWORD
SINGBOX_CONFIG=$CONFIG
SINGBOX_BIN=$SB_BIN_EFFECTIVE
SINGBOX_SERVICE=$SB_SERVICE
SINGBOX_LOG=/var/log/sing-box.log
EOF
chmod 600 "$ENVF"
umask 022

# ---------- 面板服务 ----------
if [ "$HAS_SYSTEMD" = "1" ]; then
  cat > /etc/systemd/system/sbpanel.service <<EOF
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
  systemctl daemon-reload
  systemctl enable sbpanel >/dev/null 2>&1 || true
  systemctl restart sbpanel
  sleep 1.5
  STATE="$(systemctl is-active sbpanel || true)"
elif [ "$HAS_OPENRC" = "1" ]; then
  # 包装脚本：加载 env 后 exec 面板（避免在 init 脚本里处理引号）
  cat > "$BINDIR/sbpanel-run" <<EOF
#!/bin/sh
set -a
. $ENVF
set +a
exec $EXEC_START
EOF
  chmod 0755 "$BINDIR/sbpanel-run"
  cat > /etc/init.d/sbpanel <<EOF
#!/sbin/openrc-run
name="sbpanel"
command="$BINDIR/sbpanel-run"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/sbpanel.log"
error_log="/var/log/sbpanel.log"
depend() { need net; }
EOF
  chmod 0755 /etc/init.d/sbpanel
  rc-update add sbpanel default >/dev/null 2>&1 || true
  if [ -d /run/openrc ]; then
    rc-service sbpanel restart >/dev/null 2>&1 || true
    sleep 1
    if rc-service sbpanel status 2>/dev/null | grep -q started; then
      STATE="active"
    else
      warn "rc-service 未能启动，改为直接拉起"
      nohup "$BINDIR/sbpanel-run" >/var/log/sbpanel.log 2>&1 &
      sleep 1
      STATE="direct(手动)"
    fi
  else
    # 容器 / chroot 里 openrc 没有真正接管 init，rc-service 会拒绝
    warn "检测不到 OpenRC 运行环境（容器/chroot？）：改为直接启动面板"
    nohup "$BINDIR/sbpanel-run" >/var/log/sbpanel.log 2>&1 &
    sleep 1
    STATE="direct(手动)"
  fi
else
  warn "没有 systemd/OpenRC：跳过服务安装。手动启动（后台）:"
  warn "  set -a; . $ENVF; set +a; nohup $EXEC_START >/var/log/sbpanel.log 2>&1 &"
  STATE="manual"
fi

# ---------- 地址提示 ----------
IPLIST="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
[ -z "$IPLIST" ] && IPLIST="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)"
PUB="$(echo "$IPLIST" | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
IPV6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"

echo
echo "──────────────────────────────────────────────"
echo " sbpanel 安装完成"
if [ -n "$PUB" ]; then
  echo " 面板地址 : http://$PUB:$PORT"
elif [ -n "$IPV6" ]; then
  echo " 面板地址 : http://[$IPV6]:$PORT   （本机没有公网 IPv4，走 IPv6）"
else
  echo " 面板地址 : http://<主机IP>:$PORT"
fi
[ -n "$IPLIST" ] && echo " （本机地址: $(echo $IPLIST | tr '\n' ' ')）"
echo " 用户名   : $USER_NAME"
echo " 密  码   : $PASSWORD"
[ "${GENERATED:-0}" = "1" ] && echo " （自动生成的，建议记下来；改 $ENVF 后重启面板生效）"
echo " 配置文件 : $CONFIG"
if [ -x "$SB_BIN_EFFECTIVE" ]; then
  echo " sing-box : $SB_BIN_EFFECTIVE ($("$SB_BIN_EFFECTIVE" version 2>/dev/null | head -1 | awk '{print $NF}'))"
else
  echo " sing-box : 未安装"
fi
echo " 服务状态 : $STATE"
if [ "$HAS_SYSTEMD" = "1" ]; then
  echo " 服务管理 : systemctl {status,restart,stop} sbpanel / sing-box"
  echo " 查看日志 : journalctl -u sbpanel -f"
elif [ "$HAS_OPENRC" = "1" ]; then
  echo " 服务管理 : rc-service sbpanel {status,restart,stop} / rc-service sing-box ..."
  echo " 查看日志 : tail -f /var/log/sbpanel.log"
fi
echo "──────────────────────────────────────────────"
