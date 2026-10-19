#!/bin/sh
# sbpanel 一键安装脚本（面板 + sing-box）——纯 POSIX sh，busybox / bash / dash 都能直接跑
# 兼容 systemd / OpenRC(Alpine) / 无服务管理器
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
#   curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo sh
#   bash <(curl -Ls https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh)   # 也可以这样
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
# 自建文件站（OVH 托管，放裸二进制，不受 GitHub 单文件 25MB 上传限制）
SB_MIRROR="https://netjett-de.kof95zip.pp.ua"
SB_VER="1.12.12"
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

# ---------- Alpine 依赖 ----------
# 脚本本身只用 POSIX sh 语法（busybox 可直接跑），所以不需要「装完 bash 再自举」。
# 装 bash/curl/wget 只是为了后续操作方便（某些流程与用户习惯用到 bash）。
if [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1; then
  log "检测到 Alpine（$(cat /etc/alpine-release)）：确保 bash / curl / wget 可用"
  command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true
  command -v bash >/dev/null 2>&1 || apk add --no-cache bash >/dev/null 2>&1 || true
  command -v wget >/dev/null 2>&1 || apk add --no-cache wget >/dev/null 2>&1 || true
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

# 检查配置里的监听端口是否已被别的进程占用（Alpine 上 ss 可能没有，退回 netstat）
port_owner() { # port_owner <port> -> "进程名" 或空
  local p="$1" out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -tulnH "sport = :$p" 2>/dev/null | sed -n 's/.*users:((("\([^"]*\)".*/\1/p' | head -1)"
    [ -z "$out" ] && out="$(ss -tulnH "sport = :$p" 2>/dev/null | head -1 | tr -s " ")"
  fi
  if [ -z "$out" ] && command -v netstat >/dev/null 2>&1; then
    out="$(netstat -tuln 2>/dev/null | awk -v P=":$p" '$4 ~ P {print $NF; exit}')"
  fi
  printf '%s' "$out" | tr -d '\n'
}

check_port_conflicts() { # check_port_conflicts <config.json>
  local cfg="$1" ports p owner bad=0
  [ -f "$cfg" ] || return 0
  ports="$(grep -o '"listen_port"[[:space:]]*:[[:space:]]*[0-9]\+' "$cfg" 2>/dev/null | grep -o '[0-9]\+$' | sort -un)"
  for p in $ports; do
    owner="$(port_owner "$p")"
    if [ -n "$owner" ]; then
      warn "端口 $p 已被占用（$owner），sing-box 会因此启动失败"
      bad=1
    fi
  done
  if [ "$bad" = "1" ]; then
    warn "请在面板「入站」里改掉冲突的监听端口，或先停掉占用端口的服务。"
  fi
  return 0
}

show_start_failure() { # 启动失败时把关键日志打出来，省得用户自己翻
  local unit="$1"
  echo "----- sing-box 最近日志 -----"
  if [ "$HAS_SYSTEMD" = "1" ]; then
    journalctl -u "$unit" -n 8 --no-pager 2>/dev/null | tail -8
  elif [ -f /var/log/sing-box.log ]; then
    tail -8 /var/log/sing-box.log
  fi
  echo "-----------------------------"
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
# 二进制「真的能跑」才算已安装：残缺文件、没有执行位、段错误都视为未安装
sb_works() {
  [ -f "$1" ] && [ -x "$1" ] || return 1
  case "$("$1" version 2>/dev/null | head -1)" in
    "sing-box version "*) return 0 ;;
    *) return 1 ;;
  esac
}

# 下载到指定文件（直接落到目标盘，绝不经过 /tmp）
fetch_to() { # fetch_to <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$2" "$1"
  else
    return 127
  fi
}

# 关键：全程只写 $SB_BIN.part 一个文件，最后原子替换。
# 小内存机器（64M/128M）的 /tmp 常是 tmpfs，把 gz 和解压结果放进去会直接 OOM。
install_singbox_binary() {
  part="$SB_BIN.part"
  rm -f "$part"

  # 1) 显式直链
  if [ -n "$SINGBOX_URL" ]; then
    log "sing-box 来源: --singbox-url"
    if fetch_to "$SINGBOX_URL" "$part" && chmod 0755 "$part" 2>/dev/null && sb_works "$part"; then
      mv -f "$part" "$SB_BIN"; log "已安装 sing-box 到 $SB_BIN"; return 0
    fi
    warn "从 $SINGBOX_URL 取到的 sing-box 不可用，改用其它来源"
    rm -f "$part"
  fi

  # 2) 包内裸二进制
  if has_local "third_party/sing-box/sing-box-linux-$ARCH"; then
    log "sing-box 来源: 包内裸二进制"
    cp -f "$HERE/third_party/sing-box/sing-box-linux-$ARCH" "$part" 2>/dev/null && chmod 0755 "$part" 2>/dev/null
    if sb_works "$part"; then mv -f "$part" "$SB_BIN"; log "已安装 sing-box 到 $SB_BIN"; return 0; fi
    warn "包内裸二进制不可用"; rm -f "$part"
  fi

  # 3) 自建文件站（首选：裸二进制，curl -o 直接写目标盘，内存只占小块缓冲区）
  case "$ARCH" in
    amd64) mirror_url="$SB_MIRROR/samd64b" ;;
    arm64) mirror_url="$SB_MIRROR/sarm64b" ;;
    *)     mirror_url="" ;;
  esac
  if [ -n "$mirror_url" ]; then
    log "sing-box 来源: 文件站（裸二进制，直接写盘）"
    if fetch_to "$mirror_url" "$part"; then
      chmod 0755 "$part" 2>/dev/null
      if sb_works "$part"; then mv -f "$part" "$SB_BIN"; log "已安装 sing-box 到 $SB_BIN"; return 0; fi
      warn "文件站的 sing-box 不可用"; rm -f "$part"
    else
      warn "从文件站下载失败"; rm -f "$part"
    fi
  fi

  # 4) 官方 Release：解到真实磁盘的临时目录再取出来（busybox tar 不支持 --wildcards，
  #    也绝不落到 /tmp —— 那在内存里）
  case "$ARCH" in
    amd64|arm64)
      log "sing-box 来源: 官方 Release v$SB_VER（解压取二进制）"
      exdir="$(dirname "$SB_BIN")/.sb-extract.$$"
      rm -rf "$exdir"; mkdir -p "$exdir"
      tgz="https://github.com/SagerNet/sing-box/releases/download/v$SB_VER/sing-box-$SB_VER-linux-$ARCH.tar.gz"
      if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 20 "$tgz" 2>/dev/null | tar -xz -C "$exdir" 2>/dev/null
      elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O - "$tgz" 2>/dev/null | tar -xz -C "$exdir" 2>/dev/null
      fi
      found="$(find "$exdir" -type f -name sing-box 2>/dev/null | head -1)"
      if [ -n "$found" ]; then
        mv -f "$found" "$part"; chmod 0755 "$part" 2>/dev/null
      fi
      rm -rf "$exdir"
      if sb_works "$part"; then mv -f "$part" "$SB_BIN"; log "已安装 sing-box 到 $SB_BIN"; return 0; fi
      warn "官方 Release 来源不可用"; rm -f "$part"
      ;;
  esac

  # 5) 兜底：官方安装脚本
  warn "拿不到 $ARCH 的 sing-box，改用官方安装脚本（版本较新、体积更大）"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL https://sing-box.app/install.sh | sh || warn "官方脚本安装失败，可稍后手动装"
  fi
  return 1
}

install_singbox() {
  # 只有真能跑才跳过；残缺/无执行位/段错误的一律重装，
  # 而且「跳过」也必须往下走去补配置和服务（以前 return 0 导致配置/服务全缺）
  skip=0
  if [ "$FORCE_SINGBOX" != "1" ]; then
    if [ -x "$SB_BIN" ] && sb_works "$SB_BIN"; then
      log "系统已有可用的 sing-box（$SB_BIN，$(sing-box version 2>/dev/null | head -1)），跳过二进制安装（要覆盖加 --force-singbox）"
      skip=1
    elif command -v sing-box >/dev/null 2>&1 && sb_works "$(command -v sing-box)"; then
      SB_BIN="$(command -v sing-box)"
      log "系统已有可用的 sing-box（$SB_BIN，$(sing-box version 2>/dev/null | head -1)），跳过二进制安装（要覆盖加 --force-singbox）"
      skip=1
    fi
  fi
  if [ "$skip" = "0" ]; then
    if command -v sing-box >/dev/null 2>&1; then
      warn "现有 sing-box 无法运行（$(command -v sing-box)），重新安装"
    fi
    install_singbox_binary || true
    if ! sb_works "$SB_BIN"; then
      die "sing-box 安装失败：$SB_BIN 无法运行（可加 --singbox-url 指定下载地址）"
    fi
  fi


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

  # 启动前先看端口有没有被占（最常见的就是 8080 被 webssh/面板类服务占了）
  check_port_conflicts /etc/sing-box/config.json

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
      systemctl restart sing-box 2>/dev/null || true
      sleep 1
      if [ "$(systemctl is-active sing-box 2>/dev/null)" != "active" ]; then
        warn "sing-box 启动失败"
        show_start_failure sing-box
      fi
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
        rc-service sing-box restart >/dev/null 2>&1 || true
        sleep 1
        rc-service sing-box status 2>/dev/null | grep -q started || { warn "sing-box 启动失败"; show_start_failure sing-box; }
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
  # 同样直写目标盘，不经过 /tmp（小内存机器 /tmp 是 tmpfs）
  part="$BINDIR/sbpanel.part"
  got=""
  if has_local "dist/sbpanel-linux-$ARCH"; then
    log "使用仓库内的面板二进制"
    rm -f "$part"
    cp -f "$HERE/dist/sbpanel-linux-$ARCH" "$part" && chmod 0755 "$part" && got=1
  fi
  if [ -z "$got" ]; then
    case "$ARCH" in
      amd64|arm64)
        log "从仓库下载面板二进制（dist/sbpanel-linux-$ARCH）"
        rm -f "$part"
        if fetch_to "$RAW/dist/sbpanel-linux-$ARCH" "$part" && chmod 0755 "$part" && [ -s "$part" ]; then
          got=1
        else
          warn "仓库下载失败，试 GitHub Releases"
          rm -f "$part"
          if fetch_to "$REL/sbpanel-linux-$ARCH" "$part" && chmod 0755 "$part" && [ -s "$part" ]; then
            got=1
          fi
        fi
        ;;
    esac
  fi
  if [ -z "$got" ] && [ -d "$HERE/go" ] && command -v go >/dev/null 2>&1; then
    warn "下载失败，改用本机 Go 编译"
    cp -f "$HERE/node/panel.html" "$HERE/node/setup.html" "$HERE/go/" 2>/dev/null || true
    ( cd "$HERE/go" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$part" . ) && got=1
  fi
  [ -n "$got" ] || die "拿不到面板二进制（$ARCH）。这个架构目前只提供 amd64/arm64；其它架构请用 --node 或自行编译"
  mv -f "$part" "$BINDIR/sbpanel"
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
# 列出本机所有可用的访问地址：公网 IPv4 优先，其次内网 IPv4，最后 IPv6
ALLV4="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
[ -z "$ALLV4" ] && ALLV4="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 || true)"
PUB="$(echo "$ALLV4" | grep -vE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
LAN="$(echo "$ALLV4" | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' | head -1 || true)"
IPV6="$(ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"

echo
echo "──────────────────────────────────────────────"
echo " sbpanel 安装完成"
if [ -n "$PUB" ]; then
  echo " 面板地址 : http://$PUB:$PORT   ← 公网"
elif [ -n "$LAN" ]; then
  echo " 面板地址 : http://$LAN:$PORT   ← 内网/私网（NAT 机器通常从外部映射访问）"
else
  echo " 面板地址 : http://<主机IP>:$PORT"
fi
# 其它可用地址也列出来，方便 NAT / 隧道机器判断该用哪个
OTHERS=""
[ -n "$LAN" ] && [ "$LAN" != "$PUB" ] && OTHERS="$LAN"
[ -n "$IPV6" ] && OTHERS="${OTHERS:+$OTHERS }[$IPV6]"
[ -n "$OTHERS" ] && echo " 其它地址 : $OTHERS"
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
