#!/usr/bin/env bash
# 构建：先把前端从 ../node/ 拷进来（前端只有一份源），再出本机 + amd64/arm64 二进制
set -euo pipefail
cd "$(dirname "$0")"
for f in panel.html setup.html; do
  if [ -f "../node/$f" ]; then cp -f "../node/$f" "./$f"; else echo "缺少 ../node/$f"; exit 1; fi
done
mkdir -p ../dist
CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o sbpanel .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o ../dist/sbpanel-linux-amd64 .
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o ../dist/sbpanel-linux-arm64 .
( cd ../dist && sha256sum sbpanel-linux-* > SHA256SUMS.txt )
echo "构建完成："; ls -lh sbpanel ../dist/
