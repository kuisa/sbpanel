# sbpanel

sing-box 的 Web 控制面板：**启停 / 热重载**、**可视化编辑 `config.json`**、**导出 / 导入 / 备份恢复**、**入站→出站绑定与链式（detour）**、**CPU / 内存 / 磁盘 / 出口 IP 监控**、**证书工具**。

安装时自动装**固定版本 sing-box 1.12.12**（amd64 / arm64），一键脚本在系统里没有可用的 sing-box 时自动下载（含 systemd / OpenRC 单元和一份只监听本机的示例配置），所以一台干净的机器也能一条命令跑起来。

sing-box 二进制**不放进仓库**（GitHub 网页上传单文件上限 25MB，44MB 的二进制传不上去），
默认从自建文件站 `https://netjett-de.kof95zip.pp.ua` 下载裸二进制，取不到时回落到
GitHub 官方 Release 流式解压，再不行才用官方安装脚本。

两种运行方式，功能与界面完全一致：

| | 二进制版 | Node 版 |
|---|---|---|
| 依赖 | 无（静态编译，拷一个文件就能跑） | Node 18+ |
| 文件 | `dist/sbpanel-linux-amd64`、`dist/sbpanel-linux-arm64` | `node/` |
| 适合 | 丢到 VPS / NAT 小机上常驻 | 想改代码、二次开发 |

---

## 一键安装

**方式一：一条命令（推荐，不用先克隆）**

```bash
curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash
```

适用 Debian / Ubuntu / CentOS / Arch 等（有 systemd 的系统直接跑这条即可）。

**Alpine（含 NAT 小鸡）**：先补上 bash 和 curl（Alpine 默认没有），再跑：

```bash
apk update && apk add --no-cache bash curl wget
curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash
```

> 脚本自己也会检测 Alpine 并尝试 `apk add bash curl wget`；但你手动先装好更稳妥。
> 用 `sudo bash` 而不是 `sudo sh` —— Alpine 上 `/bin/sh` 是 busybox，脚本按 bash 写。

**方式二：克隆后本地跑（可以改脚本再装）**

```bash
git clone https://github.com/kuisa/sbpanel.git
cd sbpanel
sudo ./install.sh
```

两种方式装完都会打印**面板地址、用户名和密码**。

### 常用参数

```bash
sudo ./install.sh --user admin --password 'kof97boss'   # 指定账号密码
sudo ./install.sh --port 3223                           # 换端口
sudo ./install.sh --singbox-url https://.../sing-box     # 用你自己的 sing-box 直链
sudo ./install.sh --no-singbox                          # 不装 sing-box（你自己已经有）
sudo ./install.sh --force-singbox                       # 已装也覆盖成仓库里的版本
sudo ./install.sh --service none                        # 不用 systemd/OpenRC 管 sing-box，面板自己拉起进程
sudo ./install.sh --node                                # 面板用 Node 版运行
```

一条命令带参数（注意 `-s --`）：

```bash
curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash -s -- --user admin --password 'kof97boss' --port 3223
```

### 各系统差异

| 系统 | 服务管理 | 说明 |
|---|---|---|
| Debian / Ubuntu / CentOS / Arch | systemd | `systemctl {status,restart,stop} sbpanel` |
| **Alpine** | OpenRC | 先 `apk add bash curl wget`；服务用 `rc-service sbpanel {status,restart,stop}` |
| 容器 / chroot（无真 init） | 无 | 脚本会直接拉起面板并如实报告 `direct(手动)` |

**sing-box 来源**（按顺序回落）：`--singbox-url` → 自建文件站（`https://netjett-de.kof95zip.pp.ua/samd64b` / `sarm64b`，固定 **1.12.12** 裸二进制）→ 官方 GitHub Release → 官方安装脚本。**不需要 dpkg、不需要编译**，任何 Linux 都能装。已装过 sing-box 的机器不会被动（除非 `--force-singbox`）。

**小内存机器**：下载全程 `curl -o <目标>.part` 直写目标盘再原子 `mv`，不经过 `/tmp`（64M/128M 小鸡的 `/tmp` 是 tmpfs，放不下 44MB 二进制，会 OOM 连 sshd 一起被杀）。

安装脚本做了什么：

1. 系统里没有 `sing-box`（或已有的跑不起来：无执行位 / 段错误 / `version` 无输出）→ 取对应架构的裸二进制装到 `/usr/local/bin/sing-box`，建 `sing-box` 用户、装服务单元（systemd 或 OpenRC）、写一份只监听 `127.0.0.1:7890` 的示例配置并启动；已有的健康二进制不动
2. 面板二进制装到 `/usr/local/bin/sbpanel`（从仓库 `dist/` 下载；本地有包就用本地的）
3. 写 `/etc/sbpanel.env`（权限 600，放端口 / 账号 / 密码 / 配置路径）——**已存在时会沿用其中的密码和用户名**
4. 按系统装服务：systemd 用 `sbpanel.service`；Alpine 用 `/etc/init.d/sbpanel`（OpenRC）；都没有则直接拉起
5. 打印访问地址、用户名、密码

## IPv6 / 双栈注意事项

**`0.0.0.0` 只监听 IPv4，IPv6 连不上。** sing-box 的 `listen` 是单协议绑定，实测行为：

| 写法 | 实际监听 | IPv4 | IPv6 |
|---|---|---|---|
| `"listen": "0.0.0.0"` | `0.0.0.0:端口` | ✓ | **✗** |
| `"listen": "::"` | `*:端口`（双栈） | ✓ | ✓ |
| 不写 `listen` | `127.0.0.1:端口` | 仅本机 | ✗ |

**IPv6-only 机器（NAT 小鸡常见）必须把 `0.0.0.0` 改成 `::`**，否则节点对外不可达。面板新建入站时默认填的是 `0.0.0.0`，需要手工改。

```bash
# 一次性全改（先备份）
cp /etc/sing-box/config.json /etc/sing-box/config.json.bak.$(date +%s)
sed -i 's/"listen": *"0\.0\.0\.0"/"listen": "::"/g' /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box
```

要点：

- `/proc/sys/net/ipv6/bindv6only = 0`（绝大多数 Linux 默认）时 `::` 是双栈，**一个 socket 同时收 v4 和 v6**，直接替换即可，不用写两条入站
- 若为 `1`，`::` 只收 v6，需要额外加一条 `0.0.0.0` 的入站
- 改之前先 `ss -lntp | grep :<端口>` 确认没被占用
- 面板新建入站的「监听地址」留空时也会兜底成 `0.0.0.0`，IPv6 机器记得改

## 前置条件

- Linux（amd64 / arm64），只要装了 systemd 的发行版都能用
- **不需要预装 sing-box**（脚本会自己下载固定版本 1.12.12；你已经装了能跑的版本就不动它）
- Node 版额外需要 Node 18+

## 使用

浏览器打开 `http://<主机IP>:3222`，用安装时给你的用户名和密码登录。

### 账号与登录

两种方式，任选：

- **安装脚本设置**：`sudo ./install.sh --user admin --password 'xxx'`，或直接改 `/etc/sbpanel.env` 里的 `PANEL_USER` / `PANEL_PASSWORD` 后 `systemctl restart sbpanel`。
- **首次登录网页设置**：如果启动时**一个凭据都没配**（没设 `PANEL_PASSWORD`、也没有凭据文件），面板会只开放设置页 —— 第一次打开就是「设置面板账号」，设好用户名和密码才能进。凭据以 **PBKDF2-SHA256 加盐哈希**存到 `/etc/sbpanel-auth.json`（权限 600，不落明文）。

登录用的是 HTTP Basic，**用户名和密码都会校验**（早期版本用户名可以随便填，现在不行了）。

改账号密码：面板右上角 **「账号」**。凭据来自 `PANEL_PASSWORD` 时会提示你去改 `/etc/sbpanel.env`；来自凭据文件时可以直接在弹窗里改（要输原密码，改完用新账号登录）。

### 页面

- **拓扑 / 链路** — 左边入站、右边出站，蓝线是「入站→出站」绑定，紫线是出站之间的链式。节点下面的下拉框点一下就改，写入 `route.rules` / `detour`；成环会被拒绝，直接型出站不给挂链式（sing-box 会直接报错）。
- **入站 / 出站** — 列表 + 表单编辑（每个值一个输入框，不用手写 JSON），另有「JSON（高级）」页签。协议模板带快速预设，比如 vless 的 `Reality（无需证书）` / `WS + TLS（可套 CDN）` / `TCP + TLS`。
- **原始 JSON** — 全文编辑，外加：
  - **导出到文件**：把当前 `config.json` 下载到本地
  - **导入配置文件**：选一个 JSON 文件覆盖当前配置（先本地校验语法，覆盖前自动备份当前配置）
  - **备份 / 恢复**：列出所有自动备份（`config.json.bak.<时间戳>`），点「恢复」一键回滚（恢复前也会把当前配置另存一份）
- **日志** — `journalctl -u sing-box`，进程模式下读日志文件。

顶部按钮：**启动 / 停止 / 重启 / 热重载 / 配置检查 / 账号**。启动类操作前都会先 `sing-box check`，配置不通过直接拒绝，不会把服务推到一个起不来的配置上。

### 支持的协议

- **入站**：mixed、socks、http、tun、vless、vmess、trojan、shadowsocks、hysteria2、tuic
- **出站**：direct、block、vless、vmess、trojan、shadowsocks、socks、http、hysteria2、tuic

> 兼容性：以上模板都用 `sing-box check` 在 **1.12.12 和 1.14.3** 上都验过，生成的配置两边都通过。sing-box 各版本字段变动频繁，面板只输出两个版本都认的字段（比如入站 `sniff`、`direct` 的 `override_*`、旧版 `wireguard` 出站这类已废弃/被移除的写法没有做进模板，需要的话走 JSON 页签自己写）。

### 证书

hysteria2 / tuic / vless+tls 需要证书。证书目录默认 `<配置文件所在目录>/certs`（可用 `SINGBOX_CERT_DIR` 改）。面板右侧「证书工具…」提供：

- **列出**已有证书（配对好的 cert/key 直接在下拉框里选）
- **自签**：输入域名即生成（EC P-256，10 年，带 SAN），路径自动填进表单
- **粘贴导入**：把自己的 cert / key 文本贴进去，面板写到证书目录（私钥 600）

Reality 模式**不需要证书**，勾了 Reality 面板会自动禁用证书字段（两者同时写 sing-box 会直接报错）；Reality 私钥旁有「生成密钥对」按钮，公钥会弹出来给你填到客户端。

## 不开 systemd 直接跑

```bash
sudo ./run.sh              # 有二进制用二进制，没有就用 Node 版
sudo ./run.sh --node
```

## 环境变量

装完之后改 `/etc/sbpanel.env` 再 `systemctl restart sbpanel` 即可。

| 变量 | 默认 | 说明 |
|---|---|---|
| `PANEL_PORT` | `3222` | 面板端口 |
| `PANEL_HOST` | `0.0.0.0` | 监听地址 |
| `PANEL_USER` | `admin` | 登录用户名 |
| `PANEL_PASSWORD` | 空 | 登录密码；**留空且没有凭据文件时**进入首次设置流程 |
| `PANEL_AUTH_FILE` | `/etc/sbpanel-auth.json` | 凭据文件路径（PBKDF2 加盐哈希，600） |
| `SINGBOX_CONFIG` | `/etc/sing-box/config.json` | sing-box 配置路径 |
| `SINGBOX_BIN` | `sing-box` | 可执行文件路径 |
| `SINGBOX_SERVICE` | `sing-box` | systemd 服务名；填 `none` 则由面板自己管理进程 |
| `SINGBOX_LOG` | `/tmp/sing-box.log` | 进程模式下的日志文件 |
| `SINGBOX_CERT_DIR` | `<配置目录>/certs` | 证书目录 |

## API

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/status` | CPU / 内存 / 磁盘 / 出口 IP / 主机 / 服务状态 / 配置有效性 |
| GET · PUT | `/api/config` | 读取（原文+解析+拓扑）；`{"raw":"..."}` 保存全文（导入也走这个） |
| POST | `/api/config/check` | `sing-box check` |
| POST | `/api/bind` | `{inbound, outbound}` 绑定 / 解绑 |
| POST | `/api/chain` | `{outbound, detour}` 设置 / 取消链式（含环路检测） |
| POST · DELETE | `/api/object` | `{kind,original,data}` 增改；`?kind=&tag=` 删除 |
| POST | `/api/service` | `{action: start\|stop\|restart\|reload}` |
| GET | `/api/logs?lines=` | 日志尾部 |
| GET | `/api/export` | 下载 config.json |
| GET | `/api/backups` | 列出自动备份 |
| POST | `/api/config/restore` | `{file}` 从备份恢复 |
| GET | `/api/certs` | 列证书目录与已配对的 cert/key |
| POST | `/api/certs/selfsigned` | `{domain,name}` 生成自签证书 |
| POST | `/api/certs/upload` | `{name,cert,key}` 粘贴导入证书 |
| POST | `/api/gen/reality` | 生成 Reality 密钥对 |
| GET | `/api/auth/state` | 当前账号与凭据来源 |
| POST | `/api/auth/change` | `{old_password,user,password}` 改账号 |
| POST | `/api/setup` | 首次设置账号（仅未配置凭据时可用） |

写操作（保存 / 绑定 / 链式 / 增改对象 / 恢复）的响应里都带一个 `check` 字段——面板顺带跑一次 `sing-box check` 的结果。

## 从源码构建

```bash
# 二进制（会把 node/ 下的前端拷进 go/ 再编译，前端只有一份源）
cd go && ./build.sh

# 只出本机二进制
cd go && cp ../node/panel.html ../node/setup.html . && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o sbpanel .

# Node 版（零依赖，不用 npm install）
node node/server.js
```

前端只有 `node/panel.html` 和 `node/setup.html` 这两个源文件，Go 版在构建时拷进 `go/` 并嵌进二进制（所以那两份是构建产物，已 gitignore）。

## 目录结构

```
install.sh / run.sh / uninstall.sh   一键安装 / 前台运行 / 卸载
dist/                                面板二进制（amd64、arm64）+ SHA256SUMS
node/                                Node 版 + 前端源文件（panel.html、setup.html）
go/                                  Go 版：main.go auth.go backup.go certs.go util.go go.mod build.sh
third_party/sing-box/                systemd 单元 + 示例配置 + GPL 许可证（不含二进制，
                                     二进制从文件站下载）
```

**二进制一律直写目标盘，绝不经过 `/tmp`**：安装时用 `curl -o /usr/local/bin/sing-box.part`
边下边写，内存只占一小块缓冲区。64M/128M 小机器的 `/tmp` 常是 tmpfs（占内存），
把压缩包下到那里再解压，会被「压缩包 + 解压结果」撑爆，连 sshd 都会被 OOM 杀掉。

想换 sing-box 版本就改 `install.sh` 里的 `SB_VER`，或改 `SB_MIRROR` 指向自己的文件站；
也可以用 `--singbox-url` 指一个直链。

## 安全提醒

- 面板以 root 运行（要改配置文件权限属主、要调 `systemctl`），**登录凭据一定要设**。
- 公网部署建议放在 Nginx / Cloudflare 后面加 HTTPS（Basic 认证在明文 HTTP 上会被中间人看到）。
- 入站绑 `0.0.0.0` 且不带认证 = 在公网上开了个开放代理，注意自查。
- 面板自己的端口别裸奔：至少设密码，必要时只监听内网（`PANEL_HOST=127.0.0.1`）走反代。

## License

面板本身 MIT；`third_party/sing-box/` 里附带的是上游 sing-box 的发行二进制，遵循 GPL-3.0-or-later
（许可证见该目录，源码见 https://github.com/SagerNet/sing-box）。
