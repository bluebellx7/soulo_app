#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SERVER="root@120.26.56.123"
REMOTE_DIR="/root/app-websites/soulo"

echo "========== 上传 Soulo 静态网站 =========="

cd "$SCRIPT_DIR"
ssh "$SERVER" "mkdir -p $REMOTE_DIR"
scp -r ./* "$SERVER:$REMOTE_DIR/"

echo "✅ 部署完成"
echo "请访问 https://soulo.dkluge.com 验证"
