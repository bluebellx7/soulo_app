#!/usr/bin/env bash
set -euo pipefail

SERVER="root@120.26.56.123"
REMOTE_DIR="/root/app-websites/soulo"
SITE_URL="https://soulo.dkluge.com"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR"
SSH_CONTROL_DIR=""
SSH_CONTROL_PATH=""

SERVER="${SOULO_DEPLOY_SERVER:-$SERVER}"
REMOTE_DIR="${SOULO_DEPLOY_DIR:-$REMOTE_DIR}"
SITE_URL="${SOULO_SITE_URL:-$SITE_URL}"

cleanup() {
    if [[ -n "$SSH_CONTROL_PATH" ]]; then
        ssh -S "$SSH_CONTROL_PATH" -O exit "$SERVER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SSH_CONTROL_DIR" && -d "$SSH_CONTROL_DIR" ]]; then
        rmdir "$SSH_CONTROL_DIR" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

echo "========== 上传 Soulo 静态网站 =========="

for file in index.html home.css home.js site.css sources.html privacy.html \
    images/soulo-home-zh.webp images/soulo-home-en.webp \
    images/soulo-home-light-zh.webp images/soulo-home-light-en.webp images/app-store-qr.svg; do
    if [[ ! -f "$LOCAL_DIR/$file" ]]; then
        echo "❌ 缺少网站文件：$LOCAL_DIR/$file" >&2
        exit 1
    fi
done

SSH_CONTROL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/soulo-upload.XXXXXX")"
SSH_CONTROL_PATH="$SSH_CONTROL_DIR/control"
SSH_OPTIONS=(
    -o ControlMaster=auto
    -o ControlPersist=60
    -o ControlPath="$SSH_CONTROL_PATH"
    -o ConnectTimeout=15
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
)

ssh "${SSH_OPTIONS[@]}" -MNf "$SERVER"

echo "========== 上传网站文件 =========="
COPYFILE_DISABLE=1 tar --no-xattrs -czf - -C "$LOCAL_DIR" . \
    | ssh "${SSH_OPTIONS[@]}" "$SERVER" \
        "set -e; mkdir -p '$REMOTE_DIR'; tar --no-same-owner -xzf - -C '$REMOTE_DIR'; chmod -R a+rX '$REMOTE_DIR'"

check_content_type() {
    local url_path="$1"
    shift
    local actual
    local expected
    local matched=0
    local attempt

    for attempt in 1 2 3 4 5; do
        actual="$(curl -fsS -D - -o /dev/null --max-time 15 \
            -H 'Cache-Control: no-cache' \
            "$SITE_URL/$url_path?deploy=$(date +%s)" \
            | awk 'tolower($1) == "content-type:" { gsub(/\r/, ""); print tolower($2); exit }')" || actual=""

        for expected in "$@"; do
            if [[ "$actual" == "$expected"* ]]; then
                matched=1
                break
            fi
        done
        [[ "$matched" -eq 1 ]] && break
        sleep 1
    done

    if [[ "$matched" -ne 1 ]]; then
        echo "❌ ${url_path} 类型错误：${actual:-未返回}（应为 $*）" >&2
        exit 1
    fi
    echo "✓ ${url_path} → ${actual}"
}

echo "========== 公网校验 =========="
curl -fsS --retry 3 --max-time 15 -H 'Cache-Control: no-cache' "$SITE_URL/" >/dev/null
check_content_type "site.css" "text/css"
check_content_type "home.css" "text/css"
check_content_type "home.js" "text/javascript" "application/javascript"
check_content_type "app-icon.png" "image/png"

echo "✅ 部署完成"
echo "请访问 $SITE_URL 验证"
