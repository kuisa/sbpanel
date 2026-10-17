# 随包附带的 sing-box（固定版本）

| 项目 | 说明 |
|---|---|
| 版本 | **1.12.12**（固定，不自动更新） |
| 文件 | `sing-box-linux-amd64.gz`、`sing-box-linux-arm64.gz`（gzip 压缩的裸二进制） |
| 来源 | 上游 sing-box 官方发行版 |
| 许可 | GPL-3.0-or-later（见同目录 `LICENSE`），源码见 https://github.com/SagerNet/sing-box |

`install.sh` 找 sing-box 的顺序（找到第一个可用的就用）：

1. `--singbox-url <直链>`（显式指定时优先，`.gz` 会自动解压）
2. 本目录的裸二进制 `sing-box-linux-<arch>`
3. 本目录的压缩二进制 `sing-box-linux-<arch>.gz`（只要系统有 `gunzip`，NAT 小鸡也能装）
4. 本目录的官方 `.deb`（有 `dpkg-deb` 或 `ar`+`tar` 时可用）
5. 官方安装脚本 `https://sing-box.app/install.sh`（需要联网）

装的时候会一并处理：放进 `/usr/bin/sing-box`、创建 `sing-box` 系统用户、装 systemd 单元
（`sing-box.service`，就是本目录这份）、在 `/etc/sing-box/config.json` 不存在时写入
`config.example.json`（只监听 `127.0.0.1:7890`，安全默认），最后 `enable --now`。

已经装过 sing-box 的机器不会被动；确实要覆盖用 `sudo ./install.sh --force-singbox`，
不想装用 `sudo ./install.sh --no-singbox`。

**想换版本**：把本目录的两个文件换成新版本的（`sing-box-linux-amd64.gz` / `-arm64.gz`），
脚本按文件名里有没有 `.gz` 自动决定怎么装。也可以直接放裸二进制（不带 `.gz`），脚本会优先用它。

**兼容性说明**：面板的协议模板只用 1.12.12 和 1.14.3 两边都认的字段。
sing-box 版本之间字段变动很频繁，用别的版本时建议在面板里点一下「配置检查」再重启。
