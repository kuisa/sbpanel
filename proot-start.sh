#!/bin/sh
# sbpanel proot 一键启动脚本 —— 专给 proot / 用户态容器用
#
# proot 里 execve 被 ptrace 拦截，直接 ./bin 会失败（文件在、有执行位、就是跑不起来）。
# 所以这里所有二进制统一用 nohup 拉起，绝不直接 exec。
#
# 用法:
#   sh proot-start.sh                 # 装 + 启动（默认端口 3222，密码自动生成）
#   sh proot-start.sh --port 11111 --user admin --password 'xxx'
#   sh proot-start.sh stop            # 停掉面板和 sing-box
#   sh proot-start.sh restart         # 重启
#   sh proot-start.sh status          # 看状态
#
set -eu

REPO="kuisa/sbpanel"
BRANCH="main"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
MIRROR="${SB_MIRROR:-https://free.us.kg}"

BINDIR="/usr/local/bin"
SB_BIN="$BINDIR/sing-box"
PANEL_BIN="$BINDIR/sbpanel"
CONFIG="/etc/sing-box/config.json"
ENVF="/etc/sbpanel.env"
RUN_DIR="/var/run/sbpanel"
SB_PID="$RUN_DIR/sing-box.pid"
PANEL_PID="$RUN_DIR/sbpanel.pid"
SB_LOG="/var/log/sing-box.log"
PANEL_LOG="/var/log/sbpanel.log"

PORT=3222
USER_NAME=""
PASSWORD=""
ACTION="start"

log()  { printf '==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

# 从管道执行时 $0 是 sh/bash，不是脚本名——留个提示用的名字
SELF="$0"
case "$SELF" in */*|sh|bash|dash|ash|"-sh") SELF="proot-start.sh" ;; esac

# ---------- 参数 ----------
PORT_SET=0
USER_SET=0
PASS_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|restart|status) ACTION="$1"; shift ;;
    --port)     PORT="$2"; PORT_SET=1; shift 2 ;;
    --user)     USER_NAME="$2"; USER_SET=1; shift 2 ;;
    --password) PASSWORD="$2"; PASS_SET=1; shift 2 ;;
    --mirror)   MIRROR="${2%/}"; shift 2 ;;
    -h|--help)  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# 已保存的配置作为默认值：restart/status/直接重跑都不能丢端口和密码
if [ -f "$ENVF" ]; then
  if [ "$PORT_SET" = "0" ]; then
    _v="$(grep -E '^PANEL_PORT=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$_v" ] && PORT="$_v"
  fi
  if [ "$USER_SET" = "0" ]; then
    _v="$(grep -E '^PANEL_USER=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$_v" ] && USER_NAME="$_v"
  fi
  if [ "$PASS_SET" = "0" ]; then
    _v="$(grep -E '^PANEL_PASSWORD=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$_v" ] && PASSWORD="$_v"
  fi
fi

# ---------- 架构 ----------
case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64; SB_URL="$MIRROR/samd64b" ;;
  aarch64|arm64) ARCH=arm64; SB_URL="$MIRROR/sarm64b" ;;
  *) die "不支持的架构: $(uname -m)（只有 amd64 / arm64）" ;;
esac

# ---------- 下载 ----------
fetch() { # fetch <url> <dest>
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 20 --retry 2 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 60 -O "$2" "$1"
  else
    die "没有 curl 也没有 wget"
  fi
}

# 二进制能用吗：一律 nohup 跑，stdin 断开（proot 下这是唯一可靠的方式）
sb_works() {
  [ -s "$1" ] || return 1
  chmod 0755 "$1" 2>/dev/null || true
  nohup "$1" version </dev/null 2>/dev/null | head -1 | grep -q '^sing-box version '
}

# ---------- 状态 ----------
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }

# 端口有没有在服务：401/200/302 都算活着（面板有登录保护，401 是正常的）
port_alive() { # port_alive <port>
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$1/" 2>/dev/null || true)"
    case "$code" in 2??|3??|401|403) return 0 ;; esac
    [ -n "$code" ] && [ "$code" != "000" ] && return 0
    return 1
  elif command -v wget >/dev/null 2>&1; then
    # wget 遇 401 也返回非 0，所以看它有没有拿到状态行
    wget -S -O /dev/null -T 3 "http://127.0.0.1:$1/" 2>&1 | grep -q 'HTTP/'
    return $?
  fi
  return 1
}
stop_pid() { # stop_pid <pidfile> <名字>
  if pid_alive "$1"; then
    p="$(cat "$1")"
    kill "$p" 2>/dev/null || true
    i=0
    while [ $i -lt 20 ] && kill -0 "$p" 2>/dev/null; do sleep 0.2; i=$((i+1)); done
    kill -9 "$p" 2>/dev/null || true
    log "已停止 $2 (pid $p)"
  fi
  rm -f "$1"
}

if [ "$ACTION" = "stop" ]; then
  stop_pid "$PANEL_PID" sbpanel
  stop_pid "$SB_PID" sing-box
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  # 状态查询要沿用已保存的配置，不能用自己的默认值
  if [ -f "$ENVF" ]; then
    saved_port="$(grep -E '^PANEL_PORT=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$saved_port" ] && PORT="$saved_port"
  fi
  if pid_alive "$PANEL_PID"; then
    log "sbpanel 运行中 (pid $(cat "$PANEL_PID"))"
    if port_alive "$PORT"; then
      log "端口 $PORT 响应正常"
    else
      warn "端口 $PORT 无响应（进程在但没在监听，看看日志：$PANEL_LOG）"
    fi
  else
    warn "sbpanel 未运行"
  fi
  pid_alive "$SB_PID" && log "sing-box 运行中 (pid $(cat "$SB_PID"))" || warn "sing-box 未运行"
  exit 0
fi

[ "$ACTION" = "restart" ] && { stop_pid "$PANEL_PID" sbpanel; stop_pid "$SB_PID" sing-box; }

# ---------- 准备目录 ----------
mkdir -p "$BINDIR" "$RUN_DIR" /var/log /etc/sing-box

# ---------- sing-box ----------
if sb_works "$SB_BIN" 2>/dev/null; then
  log "sing-box 已就绪（$(nohup "$SB_BIN" version </dev/null 2>/dev/null | head -1)）"
else
  log "下载 sing-box ($ARCH) ← $SB_URL"
  fetch "$SB_URL" "$SB_BIN.part" || die "下载 sing-box 失败（$SB_URL）"
  chmod 0755 "$SB_BIN.part"
  sb_works "$SB_BIN.part" || die "sing-box 下载后无法运行：$(ls -l "$SB_BIN.part" 2>/dev/null)"
  mv -f "$SB_BIN.part" "$SB_BIN"
  log "sing-box 就绪（$(nohup "$SB_BIN" version </dev/null 2>/dev/null | head -1)）"
fi

# ---------- 面板 ----------
if [ -s "$PANEL_BIN" ] && [ -x "$PANEL_BIN" ]; then
  log "面板二进制已存在：$PANEL_BIN"
else
  log "下载面板二进制 (dist/sbpanel-linux-$ARCH)"
  fetch "$RAW/dist/sbpanel-linux-$ARCH" "$PANEL_BIN.part" || die "下载面板失败"
  [ -s "$PANEL_BIN.part" ] || die "面板二进制是空文件"
  chmod 0755 "$PANEL_BIN.part"
  mv -f "$PANEL_BIN.part" "$PANEL_BIN"
  log "已安装: $PANEL_BIN"
fi

# ---------- 配置 ----------
if [ ! -f "$CONFIG" ]; then
  printf '%s\n' '{"log":{"level":"info"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7890}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG"
  log "已写入最小配置 $CONFIG（只监听 127.0.0.1:7890）"
fi

# ---------- 账号密码（沿用旧的，前面已从 ENVF 加载） ----------
[ -z "$PASSWORD" ] && PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
[ -z "$USER_NAME" ] && USER_NAME="admin"

umask 077
cat > "$ENVF" <<EOF
PANEL_PORT=$PORT
PANEL_HOST=0.0.0.0
PANEL_USER=$USER_NAME
PANEL_PASSWORD=$PASSWORD
SINGBOX_CONFIG=$CONFIG
SINGBOX_BIN=$SB_BIN
SINGBOX_SERVICE=none
SINGBOX_LOG=$SB_LOG
EOF
chmod 600 "$ENVF"
umask 022

# ---------- 启动（全部 nohup，proot 下唯一可靠的方式） ----------
pid_alive "$SB_PID" || stop_pid "$SB_PID" sing-box >/dev/null 2>&1
if pid_alive "$SB_PID"; then
  log "sing-box 已在运行 (pid $(cat "$SB_PID"))"
else
  # shellcheck disable=SC2086
  nohup "$SB_BIN" run -c "$CONFIG" >>"$SB_LOG" 2>&1 &
  echo $! > "$SB_PID"
  sleep 2
  pid_alive "$SB_PID" && log "sing-box 已启动 (pid $(cat "$SB_PID"))" \
    || { warn "sing-box 启动失败，日志尾部："; tail -15 "$SB_LOG" 2>/dev/null; }
fi

pid_alive "$PANEL_PID" || stop_pid "$PANEL_PID" sbpanel >/dev/null 2>&1
if pid_alive "$PANEL_PID"; then
  log "sbpanel 已在运行 (pid $(cat "$PANEL_PID"))"
else
  # 环境变量必须显式带进去：nohup 不读 ENVF
  set -a
  . "$ENVF"
  set +a
  nohup "$PANEL_BIN" >>"$PANEL_LOG" 2>&1 &
  echo $! > "$PANEL_PID"
  # 只等 2 秒不够：面板要先解析配置/初始化，必须等端口真的应答
  i=0
  while [ $i -lt 40 ]; do
    port_alive "$PORT" && break
    pid_alive "$PANEL_PID" || break
    sleep 0.5; i=$((i+1))
  done
  if ! pid_alive "$PANEL_PID"; then
    warn "sbpanel 启动失败（进程已退出），日志尾部："; tail -20 "$PANEL_LOG" 2>/dev/null
    if grep -q 'address already in use' "$PANEL_LOG" 2>/dev/null; then
      warn "端口 $PORT 已被别的进程占用，换一个：sh $SELF --port 其他端口"
    fi
    exit 1
  elif port_alive "$PORT"; then
    log "sbpanel 已启动 (pid $(cat "$PANEL_PID"))"
  else
    warn "sbpanel 进程在 (pid $(cat "$PANEL_PID")) 但端口 $PORT 还没应答，再等等或看日志：$PANEL_LOG"
  fi
fi

# ---------- 提示 ----------
IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)"
[ -z "$IP" ] && IP="127.0.0.1"

echo
echo "──────────────────────────────────────────────"
echo " sbpanel 已就绪（proot 模式）"
echo " 面板地址 : http://$IP:$PORT"
echo " 用户名   : $USER_NAME"
echo " 密  码   : $PASSWORD"
echo " 配置文件 : $CONFIG"
echo " 面板日志 : $PANEL_LOG"
echo " sing-box : $SB_LOG"
echo "──────────────────────────────────────────────"
echo " 常用命令:"
echo "   sh $SELF status    # 看状态"
echo "   sh $SELF restart   # 重启"
echo "   sh $SELF stop      # 停止"
echo "   tail -f $PANEL_LOG"
echo "──────────────────────────────────────────────"
echo " 注意: proot 退出后进程会一起没，下次进来重跑本脚本即可"
