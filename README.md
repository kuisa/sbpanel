# sbpanel

sing-box 的 Web 控制面板：**启停 / 热重载**、**可视化编辑 `config.json`**、**导出 / 导入 / 备份恢复**、**入站→出站绑定与链式（detour）**、**CPU / 内存 / 磁盘 / 出口 IP 监控**、**证书工具**。

随包附带**固定版本 sing-box 1.12.12**（amd64 / arm64，裸二进制 + gzip），一键脚本在系统里没有 sing-box 时自动装上（含 systemd 单元和一份只监听本机的示例配置），所以一台干净的机器也能一条命令跑起来。

两种运行方式，功能与界面完全一致：

| | 二进制版 | Node 版 |
|---|---|---|
| 依赖 | 无（静态编译，拷一个文件就能跑） | Node 18+ |
| 文件 | `dist/sbpanel-linux-amd64`、`dist/sbpanel-linux-arm64` | `node/` |
| 适合 | 丢到 VPS / NAT 小机上常驻 | 想改代码、二次开发 |

---

## 一键安装

```bash
git clone https://github.com/kuisa/sbpanel.git
cd sbpanel
sudo ./install.sh
```

装完会打印**面板地址、用户名和密码**。也可以一条命令：

```bash
curl -fsSL https://raw.githubusercontent.com/kuisa/sbpanel/main/install.sh | sudo bash
```

常用参数：

```bash
sudo ./install.sh --user admin --password 'kof97boss'   # 指定账号密码
sudo ./install.sh --port 3223                           # 换端口
sudo ./install.sh --singbox-url https://.../sing-box     # 用你自己的 sing-box 直链
sudo ./install.sh --no-singbox                          # 不装 sing-box（你自己已经有）
sudo ./install.sh --force-singbox                       # 已装也用包里的版本覆盖
sudo ./install.sh --service none                        # 不用 systemd 管 sing-box，面板自己拉起进程
sudo ./install.sh --node                                # 面板用 Node 版运行
```

安装脚本做了什么：

1. 系统里没有 `sing-box` → 从 `third_party/sing-box/` 里取对应架构的**压缩二进制**装上（没有 gunzip 才退到用官方 deb 解包），建 `sing-box` 用户、装 systemd 单元、写一份只监听 `127.0.0.1:7890` 的示例配置并 `enable --now`；已有则不动
2. 按架构选 `dist/` 里的面板二进制（没有就去 GitHub Releases 下，再不行用本机 Go 编译）装到 `/usr/local/bin/sbpanel`
3. 写 `/etc/sbpanel.env`（权限 600，放端口 / 账号 / 密码 / 配置路径）——**已存在时会沿用其中的密码和用户名**
4. 写 `/etc/systemd/system/sbpanel.service` 并 `enable --now`
5. 打印访问地址、用户名、密码

## 前置条件

- Linux（amd64 / arm64），只要装了 systemd 的发行版都能用
- **不需要预装 sing-box**（包里带了固定版本；你自己装了的话脚本会检测到并跳过）
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
third_party/sing-box/                固定版本 sing-box 1.12.12（两个架构的 .gz + systemd 单元 +
                                     示例配置 + GPL 许可证），供 install.sh 安装
```

sing-box 想升级就把 `third_party/sing-box/` 里的 `.gz`（或裸二进制）换掉，脚本按
`sing-box-linux-<arch>` / `sbpanel` 之类的命名规则识别；也可以用 `--singbox-url` 指一个直链。

## 安全提醒

- 面板以 root 运行（要改配置文件权限属主、要调 `systemctl`），**登录凭据一定要设**。
- 公网部署建议放在 Nginx / Cloudflare 后面加 HTTPS（Basic 认证在明文 HTTP 上会被中间人看到）。
- 入站绑 `0.0.0.0` 且不带认证 = 在公网上开了个开放代理，注意自查。
- 面板自己的端口别裸奔：至少设密码，必要时只监听内网（`PANEL_HOST=127.0.0.1`）走反代。

## License

面板本身 MIT；`third_party/sing-box/` 里附带的是上游 sing-box 的发行二进制，遵循 GPL-3.0-or-later
（许可证见该目录，源码见 https://github.com/SagerNet/sing-box）。
