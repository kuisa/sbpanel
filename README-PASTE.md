# sbpanel 出站「粘贴节点」功能

## 改动
- `go/panel.html`、`node/panel.html`：新增分享链接解析器 `parseShare()` 与弹窗粘贴框
- `dist/sbpanel-linux-amd64`、`dist/sbpanel-linux-arm64`：已重新编译（HTML 是 go:embed 进二进制的）
- `dist/SHA256SUMS.txt`：已更新
- `panel-paste.patch`：两个 html 的完整 diff，方便 review

## 用法
出站列表点「📋 粘贴节点」，或在「＋ 新建出站」弹窗顶部粘贴，点「解析填入」。

覆盖协议：hy2/hysteria2、vless（含 reality）、vmess、trojan、ss、tuic。

## 本地重建
```bash
cd go && bash build.sh     # 会从 ../node/ 拷前端再编译出双平台二进制
```

## 直接替换（二进制版部署）
```bash
cp dist/sbpanel-linux-arm64 /usr/local/bin/sbpanel   # 按架构选
systemctl restart sbpanel
```

## install.sh 变更（2026-11-03）
- `SB_MIRROR` 默认改为 `https://oracle-jp.0o0o.pp.ua`（原 netjett-de 已离线，返回 521）
- 新增 `--mirror <url>` 参数，也可用环境变量覆盖：`SB_MIRROR=https://... ./install.sh`
- 文件站路径约定不变：`$SB_MIRROR/samd64b`、`$SB_MIRROR/sarm64b`（裸二进制）
- 已实测新站两文件 sha256 与官方 1.12.12 一致

## 2026-11-03 第二版（链式节点）
- 粘贴后**自动保存**（解析 → 直接写入 config.json，不再需要点保存）；按钮改名「解析并保存」
- 新增协议解析：socks5 / socks / socks4 / socks4a / http / https / anytls
- 链式出站的 hy2 / tuic / vless / vmess / trojan 走同一套解析
- 实测：hy2、tuic、socks5 粘贴后 config.json 结构正确
- 保存前校验：代理类出站缺 server/port 会被拦截，不再写出 {"type":"direct","tag":"xx"} 的空壳

## 版本确认（重要）
替换后在浏览器控制台执行：`SBP_BUILD`
应输出 `paste-v3-20261103`。若输出 undefined，说明加载的还是旧文件（缓存或没替换成功）。

## v7（2026-11-03）
解析器改为**纯字符串处理**，不再依赖 `new URL()`。
原因：部分浏览器对 `hysteria2://user:pass@host:port` 这种自定义协议解析会返回空 host，
导致 server/password 丢失成空壳。现在手工切分 scheme / userinfo / host / port / query / fragment。
所有协议（hy2、vless、vmess、trojan、ss、tuic、socks、http、anytls）均已验证。
