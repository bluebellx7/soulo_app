#!/usr/bin/env bash
set -euo pipefail

SERVER="root@120.26.56.123"
REMOTE_DIR="/root/app-websites/soulo"
SITE_URL="https://soulo.dkluge.com"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR"

echo "========== 上传 Soulo 静态网站 =========="

for file in index.html site.css sources.html privacy.html; do
    if [[ ! -f "$LOCAL_DIR/$file" ]]; then
        echo "❌ 缺少网站文件：$LOCAL_DIR/$file" >&2
        exit 1
    fi
done

ssh "$SERVER" "mkdir -p $REMOTE_DIR"
scp -r "$LOCAL_DIR/." "$SERVER:$REMOTE_DIR/"
ssh "$SERVER" "chmod -R a+rX '$REMOTE_DIR'"

check_content_type() {
    local path="$1"
    local expected="$2"
    local actual
    actual="$(curl -fsSI --retry 3 --max-time 15 "$SITE_URL/$path" \
        | awk 'tolower($1) == "content-type:" { gsub(/\r/, ""); print tolower($2); exit }')"

    if [[ "$actual" != "$expected"* ]]; then
        echo "❌ ${path} 类型错误：${actual:-未返回}（应为 ${expected}）" >&2
        exit 1
    fi
    echo "✓ ${path} → ${actual}"
}

curl -fsS --retry 3 --max-time 15 "$SITE_URL/" >/dev/null
check_content_type "site.css" "text/css"
check_content_type "app-icon.png" "image/png"

echo "✅ 部署完成"
echo "请访问 $SITE_URL 验证"