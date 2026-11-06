#!/bin/sh
# sbpanel 卸载脚本 —— 把原版 install.sh 装进去的东西全部清掉
#
# 用法:
#   sh uninstall.sh              # 卸载（先备份配置，保留日志）
#   sh uninstall.sh --purge      # 卸载 + 删日志 + 删备份，一点不留
#   sh uninstall.sh --dry-run    # 只看会删什么，不动手
#   sh uninstall.sh --yes        # 不询问，直接干
#
# 注意：只清 sbpanel/sing-box 自己装的东西，不碰这台机器上别的东西。
# 如果你还在用它当代理，卸载后面板里的节点配置就没了——所以默认先备份。

set -u

PURGE=0
DRY=0
ASSUME_YES=0

for a in "$@"; do
  case "$a" in
    --purge)   PURGE=1 ;;
    --dry-run) DRY=1 ;;
    --yes|-y)  ASSUME_YES=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a"; exit 1 ;;
  esac
done

# ---------- 输出 ----------
if [ -t 1 ]; then C_OK='\033[32m'; C_WARN='\033[33m'; C_DIM='\033[2m'; C_0='\033[0m'; else C_OK=''; C_WARN=''; C_DIM=''; C_0=''; fi
log()  { printf "${C_OK}==>${C_0} %s\n" "$*"; }
warn() { printf "${C_WARN}[!]${C_0} %s\n" "$*"; }
dim()  { printf "${C_DIM}    %s${C_0}\n" "$*"; }

# 真正执行删除/停止；--dry-run 时只打印
run() {
  if [ "$DRY" = "1" ]; then dim "[dry-run] $*"; else eval "$@"; fi
}

[ "$(id -u)" = "0" ] || { warn "请用 root 运行"; exit 1; }

BINDIR="/usr/local/bin"
CONFIG_DIR="/etc/sing-box"
CONFIG="$CONFIG_DIR/config.json"
ENVF="/etc/sbpanel.env"
NODE_DIR="/opt/sbpanel-node"
RUNDIR="/var/run/sbpanel"
PANEL_LOG="/var/log/sbpanel.log"
SB_LOG="/var/log/sing-box.log"
PANEL_PID="$RUNDIR/sbpanel.pid"
SB_PID="$RUNDIR/sing-box.pid"
SB_BIN="$BINDIR/sing-box"
SB_SERVICE="sing-box"
AUTHF="/etc/sbpanel-auth.json"   # 面板凭据：账号 + 密码哈希 + 会话
STATE_DIR="/var/lib/sing-box"    # systemd 的 StateDirectory=sing-box 建的
CERT_DIR="$CONFIG_DIR/certs"     # 面板「证书」功能生成的证书目录

# 原版 install.sh 支持 --config / --service 改路径，按默认路径硬删会漏。
# 它把实际用的路径写进了 /etc/sbpanel.env，先读出来再删。
if [ -f "$ENVF" ]; then
  env_get() { grep -E "^$1=" "$ENVF" 2>/dev/null | head -1 | cut -d= -f2- || true; }
  _v="$(env_get SINGBOX_CONFIG)"
  [ -n "$_v" ] && { CONFIG="$_v"; CONFIG_DIR="$(dirname "$_v")"; }
  _v="$(env_get SINGBOX_SERVICE)"
  [ -n "$_v" ] && [ "$_v" != "none" ] && SB_SERVICE="$_v"
  _v="$(env_get SINGBOX_BIN)"
  [ -n "$_v" ] && SB_BIN="$_v"
fi

# 环境变量优先级更高（面板自己也认这两个）
[ -n "${PANEL_AUTH_FILE:-}" ]   && AUTHF="$PANEL_AUTH_FILE"
[ -n "${SINGBOX_CERT_DIR:-}" ]  && CERT_DIR="$SINGBOX_CERT_DIR"

# SINGBOX_BIN 可能是裸命令名（没装成时 install.sh 会这么写），别当成相对路径删
case "$SB_BIN" in /*) ;; *) SB_BIN="$BINDIR/sing-box" ;; esac

# install.sh 若发现系统里已有包管理器装的 sing-box，SINGBOX_BIN 会指向那里。
# 那个是系统包，不属于本面板，删了会连带拆掉别人的依赖——只认自己下载的位置。
# 判定：只有位于 /usr/local 下（install.sh 自己 curl 下载到的地方）才拥有。
SB_BIN_OWNED=1
case "$SB_BIN" in
  /usr/local/*) SB_BIN_OWNED=1 ;;
  *) SB_BIN_OWNED=0 ;;
esac

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/sbpanel-backup-$STAMP.tar.gz"

# 先看这机器上到底有没有装过：没装过就别演一遍空戏
FOUND=0
for f in "$BINDIR/sbpanel" "$BINDIR/sbpanel-run" "$SB_BIN" \
         "$CONFIG_DIR" "$CONFIG" "$ENVF" "$AUTHF" "$NODE_DIR" "$RUNDIR" "$STATE_DIR" "$CERT_DIR" \
         "/etc/systemd/system/sbpanel.service" "/etc/systemd/system/$SB_SERVICE.service" \
         "/etc/init.d/sbpanel" "/etc/init.d/$SB_SERVICE"; do
  [ -e "$f" ] && FOUND=1
done
if command -v pgrep >/dev/null 2>&1; then
  pgrep -f "$BINDIR/sbpanel" >/dev/null 2>&1 && FOUND=1
  pgrep -f "$SB_BIN run" >/dev/null 2>&1 && FOUND=1
fi

if [ "$FOUND" = "0" ]; then
  # 没装过，但 --purge 是来清残留日志的，不能拦
  if [ "$PURGE" = "1" ]; then
    log "没检测到安装痕迹，--purge 只清理遗留日志"
  else
    log "这台机器上没有检测到 sbpanel / sing-box 的安装痕迹"
    dim "已检查: $BINDIR/sbpanel, $BINDIR/sing-box, $CONFIG_DIR, $ENVF, $NODE_DIR"
    dim "        systemd 单元 / OpenRC 脚本 / 运行中的进程"
    if [ -f "$PANEL_LOG" ] || [ -f "$SB_LOG" ]; then
      echo
      warn "但发现了遗留日志："
      dim "$PANEL_LOG"
      dim "$SB_LOG"
      dim "要清掉就运行: sh $0 --purge"
    fi
    echo
    echo "无需卸载。"
    exit 0
  fi
fi

echo "──────────────────────────────────────────────"
echo " sbpanel 卸载"
if [ "$DRY" = "1" ]; then
  echo " 模式: 预演（不会真的删）"
elif [ "$PURGE" = "1" ]; then
  echo " 模式: 彻底清除（含日志和备份）"
else
  echo " 模式: 标准卸载（先备份配置，保留日志）"
fi
echo "──────────────────────────────────────────────"

# ---------- 确认 ----------
if [ "$DRY" = "0" ] && [ "$ASSUME_YES" = "0" ] && [ -e /dev/tty ]; then
  # 从 /dev/tty 读，避免 `curl | sh` 时把脚本正文当成回答吃掉
  printf '确定要卸载吗？[y/N] ' > /dev/tty
  ans=""
  read -r ans < /dev/tty 2>/dev/null || ans="n"
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "已取消。"; exit 0 ;;
  esac
fi

# ---------- 1) 先备份配置（节点信息丢了很麻烦） ----------
backed_up=0
if [ "$PURGE" = "0" ] && [ "$DRY" = "0" ]; then
  if [ -f "$CONFIG" ] || [ -f "$ENVF" ] || [ -f "$AUTHF" ]; then
    if command -v tar >/dev/null 2>&1; then
      files=""
      # 打包时统一去掉开头的 /（不可用 -P）：这样无论配置在 /etc 还是
      # install.sh --config 指定的其它位置，都能用 tar xzf ... -C 安全还原到
      # 指定目录，不会意外写回 / 覆盖正在运行的系统文件。
      [ -d "$CONFIG_DIR" ] && files="$files ${CONFIG_DIR#/}"
      [ -d "$CERT_DIR" ] && [ "$CERT_DIR" != "$CONFIG_DIR/certs" ] && files="$files ${CERT_DIR#/}"
      [ -f "$ENVF" ]  && files="$files ${ENVF#/}"
      [ -f "$AUTHF" ] && files="$files ${AUTHF#/}"
      # shellcheck disable=SC2086
      if tar czf "$BACKUP" -C / $files 2>/dev/null; then
        chmod 600 "$BACKUP"
        log "已备份配置到 $BACKUP"
        backed_up=1
      else
        warn "备份失败，但那不影响继续卸载"
      fi
    else
      warn "没有 tar，跳过备份"
    fi
  fi
fi

# ---------- 2) 停服务 ----------
log "停止服务"

# systemd
if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
  for svc in sbpanel "$SB_SERVICE"; do
    if [ -f "/etc/systemd/system/$svc.service" ]; then
      run "systemctl stop $svc >/dev/null 2>&1 || true"
      run "systemctl disable $svc >/dev/null 2>&1 || true"
      dim "systemd: 已停用 $svc"
    fi
  done
fi

# OpenRC（Alpine）
if [ -f /run/openrc/softlevel ] && command -v rc-service >/dev/null 2>&1; then
  for svc in sbpanel "$SB_SERVICE"; do
    if [ -f "/etc/init.d/$svc" ]; then
      run "rc-service $svc stop >/dev/null 2>&1 || true"
      run "rc-update del $svc default >/dev/null 2>&1 || true"
      dim "OpenRC: 已停用 $svc"
    fi
  done
fi

# 无服务管理器 / nohup 起来的（含 proot-start.sh 启的）
for pf in "$PANEL_PID" "$SB_PID"; do
  if [ -f "$pf" ]; then
    p="$(cat "$pf" 2>/dev/null || true)"
    if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
      run "kill $p 2>/dev/null || true"
      sleep 1
      run "kill -9 $p 2>/dev/null || true"
      dim "已按 pid 文件停止 $pf (pid $p)"
    fi
  fi
done

# 兜底：按完整路径精确匹配，避免误杀别的 sing-box
for pat in "$BINDIR/sbpanel-run" "$BINDIR/sbpanel" "$SB_BIN run"; do
  [ "$pat" = "$SB_BIN run" ] && [ "$SB_BIN_OWNED" != "1" ] && continue
  if pgrep -f "$pat" >/dev/null 2>&1; then
    run "pkill -f '$pat' >/dev/null 2>&1 || true"
    dim "已结束残留进程: $pat"
  fi
done
sleep 1

# ---------- 3) 删文件 ----------
log "删除文件"

del() { # del <path> <说明>
  if [ -e "$1" ]; then
    run "rm -rf '$1'"
    dim "删除 $1  ($2)"
  fi
}

# 同一个路径可能被多个规则命中（比如 --config 用默认路径时），只删一次、只报一次
DELETED=""
del_once() { # del_once <path> <说明>
  case " $DELETED " in *" $1 "*) return 0 ;; esac
  DELETED="$DELETED $1"
  del "$1" "$2"
}

# 面板二进制 + 启动包装 + 半成品
del "$BINDIR/sbpanel"      "面板"
del "$BINDIR/sbpanel-run"  "启动包装脚本"
del "$BINDIR/sbpanel.part" "下载残留"
del_once "$BINDIR/sing-box"     "sing-box 内核"
if [ "$SB_BIN_OWNED" = "1" ]; then
  del_once "$SB_BIN" "sing-box 内核（按 install.sh 实际路径）"
else
  dim "跳过 $SB_BIN（系统包管理器装的，不属于本面板）"
fi
del "$BINDIR/sing-box.part" "下载残留"

# Node 版面板
del "$NODE_DIR" "Node 版面板目录"

# install.sh 即使指定了 --config 自定义路径，仍会建默认的 /etc/sing-box（放证书等），
# 只删自定义目录会把默认目录剩下。
DEFAULT_CONFIG_DIR="/etc/sing-box"
if [ "$CONFIG_DIR" != "$DEFAULT_CONFIG_DIR" ]; then
  del_once "$DEFAULT_CONFIG_DIR" "默认配置目录（--config 改了路径也会留下）"
fi

# 单元 / init 脚本
del "/etc/systemd/system/sbpanel.service" "systemd 单元"
del "/etc/systemd/system/$SB_SERVICE.service" "systemd 单元"
del "/etc/init.d/sbpanel" "OpenRC 脚本"
del "/etc/init.d/$SB_SERVICE" "OpenRC 脚本"

if [ "$DRY" = "0" ]; then
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    dim "systemd 已重新加载"
  fi
fi

# 配置和变量文件
# 内核是系统包管理器装的（SB_BIN_OWNED=0）时，这份 config.json 是那个内核正在用的
# 配置，删了它系统 sing-box 重启就没节点。此时保留配置目录，交给用户自己决定。
if [ "$SB_BIN_OWNED" = "1" ]; then
  del_once "$CONFIG_DIR" "配置文件（若已备份可放心删）"
  del_once "$CONFIG"     "配置文件（--config 自定义路径）"
  del_once "$CERT_DIR"   "面板生成的证书（--cert-dir 自定义路径）"
else
  dim "保留 $CONFIG_DIR（系统 sing-box 还在用这份配置，要删请自行 rm -rf）"
fi
del "$ENVF"       "面板环境变量（含登录密码）"
# 凭据文件：账号 + 密码哈希，不删的话重装后旧密码还能登进去
del "$AUTHF"      "面板登录凭据（账号/密码哈希/会话）"
del "$RUNDIR"     "pid 文件目录"
del "$STATE_DIR"  "状态目录（systemd StateDirectory 建的）"

# 日志
if [ "$PURGE" = "1" ]; then
  del "$PANEL_LOG" "面板日志"
  del "$SB_LOG"    "sing-box 日志"
  # 卸载脚本以前留下的备份也一起清掉：purge 就该一点不剩
  if [ "$DRY" = "0" ]; then
    for b in /root/sbpanel-backup-*.tar.gz; do
      [ -e "$b" ] && { rm -f "$b"; dim "删除旧备份 $b"; }
    done
  else
    for b in /root/sbpanel-backup-*.tar.gz; do
      [ -e "$b" ] && dim "[dry-run] 会删除旧备份 $b"
    done
  fi
else
  if [ -f "$PANEL_LOG" ] || [ -f "$SB_LOG" ]; then
    dim "保留日志: $PANEL_LOG $SB_LOG（要一起删就加 --purge）"
  fi
fi

# ---------- 4) 删系统用户 ----------
if [ "$DRY" = "0" ] && id sing-box >/dev/null 2>&1; then
  # 只有系统用户（install.sh 建的才是 -r）才删，防止误删真人在用的账号
  if command -v userdel >/dev/null 2>&1; then
    run "userdel sing-box >/dev/null 2>&1 || true"
    dim "已删除系统用户 sing-box"
  elif command -v deluser >/dev/null 2>&1; then
    run "deluser sing-box >/dev/null 2>&1 || true"
    dim "已删除系统用户 sing-box"
  fi
fi

# ---------- 5) 收尾检查 ----------
echo
log "检查收尾"

left=0
if [ "$DRY" = "1" ]; then
  # 预演根本没删，检查必然全部"还在"，报这些残留毫无意义还会吓人
  dim "预演模式，跳过残留检查（上面有将要执行的 rm 清单）"
else
for f in "$BINDIR/sbpanel" "$BINDIR/sbpanel-run" \
         "$ENVF" "$AUTHF" "$NODE_DIR" "$RUNDIR" "$STATE_DIR" \
         "/etc/systemd/system/sbpanel.service" "/etc/systemd/system/$SB_SERVICE.service" \
         "/etc/init.d/sbpanel" "/etc/init.d/$SB_SERVICE"; do
  [ -e "$f" ] && { warn "还在: $f"; left=1; }
done
# 配置目录只在自己拥有内核时才该被删；系统内核在用就不算残留
if [ "$SB_BIN_OWNED" = "1" ]; then
  for f in "$CONFIG_DIR" "$CONFIG" "$CERT_DIR"; do
    [ -e "$f" ] && { warn "还在: $f"; left=1; }
  done
fi
# SB_BIN 只在自己拥有时才该被删；系统包管理器装的不算残留
[ "$SB_BIN_OWNED" = "1" ] && [ -e "$SB_BIN" ] && { warn "还在: $SB_BIN"; left=1; }
# 自定义 --config 时原版还会留下默认目录
[ "$SB_BIN_OWNED" = "1" ] && [ "$CONFIG_DIR" != "/etc/sing-box" ] && [ -e /etc/sing-box ] && { warn "还在: /etc/sing-box"; left=1; }

for pat in "$BINDIR/sbpanel" "$SB_BIN run"; do
  [ "$pat" = "$SB_BIN run" ] && [ "$SB_BIN_OWNED" != "1" ] && continue
  if pgrep -f "$pat" >/dev/null 2>&1; then
    warn "还有进程在跑: $pat"
    left=1
  fi
done
fi  # end of non-dry-run 检查

echo "──────────────────────────────────────────────"
if [ "$DRY" = "1" ]; then
  echo " 预演结束，没有做任何改动"
elif [ "$left" = "0" ]; then
  echo " 卸载完成，已清理干净"
else
  echo " 卸载基本完成，上面列出的项需要你手动处理"
  echo " （多半是进程还占着文件，先 kill 再删）"
fi
[ "$backed_up" = "1" ] && echo " 配置备份 : $BACKUP"
[ "$PURGE" = "0" ] && echo " 日志保留 : $PANEL_LOG / $SB_LOG"
echo "──────────────────────────────────────────────"
if [ "$backed_up" = "1" ]; then
  echo " 说明: 这脚本只管机器上装的文件，你面板里配的节点"
  echo "       数据在备份包里，需要的话解压取回:"
  echo "       tar xzf $BACKUP -C /     # 直接还原到原位"
  echo "       tar tzf $BACKUP           # 只看里面有什么"
elif [ "$DRY" != "1" ]; then
  echo " 说明: 这次没有生成配置备份（--purge 模式或本来就没配置），"
  echo "       机器上装的文件已按上面清单处理完。"
fi
echo "──────────────────────────────────────────────"
