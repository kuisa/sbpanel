#!/bin/sh
# sbpanel Ubuntu proot 一键启动 —— 二进制随包附带，全程不联网
#
# 为什么这么写：
#   Ubuntu 基础镜像没有 curl / wget / ip / ss，任何下载和端口探测都会失败。
#   所以二进制直接放包里，脚本零依赖、零网络请求。
#   proot 里 execve 被 ptrace 拦截，所有二进制一律 nohup 拉起。
#
# 用法（解压后在本目录执行）：
#   sh proot-start-ubuntu.sh                    # 装 + 启动，端口 3222，密码自动生成
#   sh proot-start-ubuntu.sh --port 11111 --user admin --password 'xxx'
#   sh proot-start-ubuntu.sh stop | restart | status
#
set -eu

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

# 按名字找进程（pid 文件丢失时的兜底。proot 里没有 pgrep，用 /proc 扫）
find_pids() { # find_pids <comm> → 每行一个 pid
  for d in /proc/[0-9]*; do
    [ -r "$d/comm" ] || continue
    [ "$(cat "$d/comm" 2>/dev/null)" = "$1" ] && echo "${d#/proc/}"
  done
  return 0
}

# 脚本所在目录（二进制就在旁边）
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

case "$(uname -m)" in
  x86_64|amd64)  ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "不支持的架构: $(uname -m)" ;;
esac

# ---------- 参数 ----------
PORT_SET=0; USER_SET=0; PASS_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    start|stop|restart|status) ACTION="$1"; shift ;;
    --port)     PORT="$2"; PORT_SET=1; shift 2 ;;
    --user)     USER_NAME="$2"; USER_SET=1; shift 2 ;;
    --password) PASSWORD="$2"; PASS_SET=1; shift 2 ;;
    --dir)      SELF_DIR="$2"; shift 2 ;;
    -h|--help)  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1" ;;
  esac
done

[ "$(id -u)" = "0" ] || die "请用 root 运行"

# 沿用已保存的配置
if [ -f "$ENVF" ]; then
  [ "$PORT_SET" = "0" ] && { v="$(grep -E '^PANEL_PORT=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"; [ -n "$v" ] && PORT="$v"; }
  [ "$USER_SET" = "0" ] && { v="$(grep -E '^PANEL_USER=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"; [ -n "$v" ] && USER_NAME="$v"; }
  [ "$PASS_SET" = "0" ] && { v="$(grep -E '^PANEL_PASSWORD=' "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true)"; [ -n "$v" ] && PASSWORD="$v"; }
fi

# ---------- 进程管理 ----------
pid_alive() { [ -f "$1" ] && kill -0 "$(cat "$1" 2>/dev/null)" 2>/dev/null; }
stop_pid() {
  if pid_alive "$1"; then
    p="$(cat "$1")"
    kill "$p" 2>/dev/null || true
    i=0; while [ $i -lt 20 ] && kill -0 "$p" 2>/dev/null; do sleep 0.2; i=$((i+1)); done
    kill -9 "$p" 2>/dev/null || true
    log "已停止 $2 (pid $p)"
  fi
  rm -f "$1"
}

# 停掉所有同名进程（含 pid 文件丢失的孤儿，否则它们会占着端口）
kill_by_name() { # kill_by_name <comm> <显示名>
  _n=0
  for _p in $(find_pids "$1"); do
    kill -9 "$_p" 2>/dev/null && _n=$((_n+1))
  done
  [ "$_n" -gt 0 ] && log "已清理 $_n 个残留 ${2} 进程"
  return 0
}

if [ "$ACTION" = "stop" ]; then
  stop_pid "$PANEL_PID" sbpanel
  stop_pid "$SB_PID" sing-box
  kill_by_name sbpanel sbpanel
  kill_by_name sing-box sing-box
  exit 0
fi

if [ "$ACTION" = "status" ]; then
  if pid_alive "$PANEL_PID"; then
    log "sbpanel 运行中 (pid $(cat "$PANEL_PID"))，端口 $PORT"
  else
    warn "sbpanel 未运行"
  fi
  pid_alive "$SB_PID" && log "sing-box 运行中 (pid $(cat "$SB_PID"))" || warn "sing-box 未运行"
  exit 0
fi

# ---------- 装二进制（从包里取，不下载） ----------
mkdir -p "$BINDIR" "$RUN_DIR" /var/log /etc/sing-box

install_bin() { # install_bin <源> <目标> <名字>
  if [ ! -s "$1" ]; then
    die "包里找不到 $3（$1）。解压后请在本目录运行本脚本"
  fi
  cp -f "$1" "$2.part"
  chmod 0755 "$2.part"
  mv -f "$2.part" "$2"
  log "$3 已安装 → $2"
}

[ -s "$SB_BIN" ] && [ -x "$SB_BIN" ] || install_bin "$SELF_DIR/sing-box-linux-$ARCH" "$SB_BIN" sing-box
[ -s "$PANEL_BIN" ] && [ -x "$PANEL_BIN" ] || install_bin "$SELF_DIR/sbpanel-linux-$ARCH" "$PANEL_BIN" sbpanel

# ---------- 配置 ----------
if [ ! -f "$CONFIG" ]; then
  printf '%s\n' '{"log":{"level":"info"},"inbounds":[{"type":"mixed","tag":"mixed-in","listen":"127.0.0.1","listen_port":7890}],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[],"final":"direct"}}' > "$CONFIG"
  log "已写入最小配置 $CONFIG"
fi

# ---------- 账号密码 ----------
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

# ---------- 启动 ----------
# 必须先把旧的清干净。否则残留进程还占着端口、还带着旧密码，
# 而脚本又写了一份新密码 —— 横幅打印的密码就登不进去（实测踩过）。
# 这同时让 restart 和 start 行为一致：都是干净重启。
log "清理旧进程"
stop_pid "$PANEL_PID" sbpanel
stop_pid "$SB_PID" sing-box
kill_by_name sbpanel sbpanel
kill_by_name sing-box sing-box
sleep 1

nohup "$SB_BIN" run -c "$CONFIG" >>"$SB_LOG" 2>&1 &
echo $! > "$SB_PID"
sleep 2
pid_alive "$SB_PID" && log "sing-box 已启动 (pid $(cat "$SB_PID"))" \
  || { warn "sing-box 启动失败，日志尾部："; tail -15 "$SB_LOG" 2>/dev/null; }

set -a; . "$ENVF"; set +a
: > "$PANEL_LOG"
nohup "$PANEL_BIN" >>"$PANEL_LOG" 2>&1 &
echo $! > "$PANEL_PID"
# 不用 curl/ss 探端口：直接等日志出现"已启动"，或进程退出
i=0
while [ $i -lt 40 ]; do
  grep -q '已启动' "$PANEL_LOG" 2>/dev/null && break
  pid_alive "$PANEL_PID" || break
  sleep 0.5; i=$((i+1))
done

if ! pid_alive "$PANEL_PID"; then
  warn "sbpanel 启动失败，日志尾部："; tail -20 "$PANEL_LOG" 2>/dev/null
  grep -q 'address already in use' "$PANEL_LOG" 2>/dev/null && \
    warn "端口 $PORT 被占用，换一个：sh $0 --port 其他端口"
  exit 1
fi
log "sbpanel 已启动 (pid $(cat "$PANEL_PID"))"

# ---------- 提示 ----------
IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[ -z "$IP" ] && IP="$(cat /proc/net/fib_trie 2>/dev/null | awk '/32 host/ {c++} c==1 && /\// {gsub(/[ |]/,"");print;exit}' || true)"
[ -z "$IP" ] && IP="<你的服务器IP>"

echo
echo "──────────────────────────────────────────────"
echo " sbpanel 已就绪（Ubuntu proot 模式）"
echo " 面板地址 : http://$IP:$PORT"
echo " 用户名   : $USER_NAME"
echo " 密  码   : $PASSWORD"
echo " 配置文件 : $CONFIG"
echo " 面板日志 : $PANEL_LOG"
echo " sing-box : $SB_LOG"
echo "──────────────────────────────────────────────"
echo "   sh $0 status | restart | stop"
echo "   tail -f $PANEL_LOG"
echo "──────────────────────────────────────────────"
