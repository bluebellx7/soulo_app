#!/usr/bin/env bash
set -euo pipefail

SERVER="${SOULO_DEPLOY_SERVER:-soulo-deploy@8.136.248.180}"
REMOTE_DIR="${SOULO_DEPLOY_DIR:-/srv/www/soulo}"
SITE_URL="${SOULO_SITE_URL:-https://soulo.dkluge.com}"
SITE_URL="${SITE_URL%/}"
SITE_HOST="${SITE_URL#https://}"
LOCAL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! "$REMOTE_DIR" =~ ^/[A-Za-z0-9_./-]+$ || "$REMOTE_DIR/" == */../* ||
      "$SITE_URL" != https://* || ! "$SITE_HOST" =~ ^[A-Za-z0-9.-]+$ ]]; then
    echo "SOULO_DEPLOY_DIR 必须为绝对路径，SOULO_SITE_URL 必须为 HTTPS 站点地址" >&2
    exit 1
fi

for file in index.html home.css home.js site.css site-ui.js navigation.css sources.html sources.css sources.js sources.json privacy.html \
    movies.html movies.css movies.js movies.json resources.html magnets.html magnets.json pans.html pans.json stocks.html stocks.json reading.html reading.json music.html music.json content-directories.css navigation.js favicon.svg robots.txt sitemap.xml llms.txt llms-full.txt \
    images/soulo-home-zh.webp images/soulo-home-en.webp \
    images/soulo-home-light-zh.webp images/soulo-home-light-en.webp images/app-store-qr.svg \
    images/web/app-icon-108.webp images/web/search-home.webp \
    images/web/soulo-home-light-zh-804.webp images/web/soulo-home-light-en-804.webp \
    images/web/illustration-about.webp images/web/illustration-reading.webp images/web/illustration-bookmarks.webp; do
    if [[ ! -f "$LOCAL_DIR/$file" ]]; then
        echo "❌ 缺少网站文件：$LOCAL_DIR/$file" >&2
        exit 1
    fi
done

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soulo-upload.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$work_dir/site"
git_bin=git
if ! git --version >/dev/null 2>&1 && [[ -x /Library/Developer/CommandLineTools/usr/bin/git ]]; then
    git_bin=/Library/Developer/CommandLineTools/usr/bin/git
fi
"$git_bin" -C "$LOCAL_DIR" ls-files --cached --deduplicate -z > "$work_dir/tracked"
while IFS= read -r -d '' file; do
    case "$file" in
        .*|*/.*) continue ;;
        images/*|favicons/*) ;;
        */*) continue ;;
    esac
    case "$file" in
        *.html|*.css|*.js|*.json|*.png|*.webp|*.jpeg|*.jpg|*.svg|*.ico|*.txt|*.xml) ;;
        *) continue ;;
    esac
    if [[ ! -f "$LOCAL_DIR/$file" || -L "$LOCAL_DIR/$file" ]]; then
        echo "无法打包网站文件 $file" >&2
        exit 1
    fi
    mkdir -p -- "$(dirname -- "$work_dir/site/$file")"
    cp -- "$LOCAL_DIR/$file" "$work_dir/site/$file"
done < "$work_dir/tracked"
(
    cd "$work_dir/site"
    find . -type f -exec shasum -a 256 {} + > "$work_dir/sha256"
)
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$work_dir/site.tar.gz" -C "$work_dir" site sha256

SSH_OPTIONS=(
    -T
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o ProxyCommand=none
    -o ProxyJump=none
    -o ConnectTimeout=15
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=3
)
remote_script="$(cat <<'REMOTE'
set -euo pipefail
umask 022
cd -- "$1"
site_host="$2"
stage="$(mktemp -d releases/.staging.XXXXXX)"
trap 'rm -rf -- "$stage"' EXIT
tar -xzf - --no-same-owner -C "$stage"
(cd "$stage/site" && sha256sum --quiet -c ../sha256)
test -s "$stage/site/index.html"
chmod -R a+rX "$stage/site"

origin_curl() {
    curl -q --noproxy '*' -fsS --connect-timeout 5 --max-time 10 \
        --resolve "$site_host:443:127.0.0.1" "$@"
}

check_content_types() {
    local route expected headers actual
    while IFS=' ' read -r route expected; do
        headers="$(origin_curl -I "https://$site_host/$route")" || return 1
        actual="$(printf '%s\n' "$headers" | awk 'tolower($1) == "content-type:" {sub(/[;\r].*/, "", $2); print tolower($2); exit}')"
        if [[ "|$expected|" != *"|$actual|"* ]]; then
            printf '类型错误 %s → %s（应为 %s）\n' "$route" "$actual" "$expected" >&2
            return 1
        fi
    done <<'MIME'
site.css text/css
home.css text/css
home.js text/javascript|application/javascript
app-icon.png image/png
images/web/app-icon-108.webp image/webp
images/web/search-home.webp image/webp
images/web/soulo-home-light-zh-804.webp image/webp
images/web/soulo-home-light-en-804.webp image/webp
images/web/illustration-about.webp image/webp
images/web/illustration-reading.webp image/webp
images/web/illustration-bookmarks.webp image/webp
privacy_policy.html text/html
extensions.html text/html
extensions.json application/json
movies.html text/html
resources.html text/html
stocks.html text/html
stocks.json application/json
magnets.html text/html
pans.html text/html
reading.html text/html
music.html text/html
content-directories.css text/css
navigation.js text/javascript|application/javascript
movies.css text/css
movies.js text/javascript|application/javascript
site-ui.js text/javascript|application/javascript
navigation.css text/css
sources.css text/css
sources.js text/javascript|application/javascript
favicon.svg image/svg+xml
sitemap.xml application/xml|text/xml
llms.txt text/plain
robots.txt text/plain
app-ads.txt text/plain
llms-full.txt text/plain
MIME
}

# Serialize activation and restore the previous release if the origin check fails.
exec 9>.deploy.lock
flock -w 60 9
previous="$(readlink current || true)"
release="releases/$(date -u +%Y%m%dT%H%M%SZ)-${stage##*.}"
mv -T -- "$stage/site" "$release"
ln -s "$release" "$stage/next"
mv -Tf -- "$stage/next" current
if ! origin_curl "https://$site_host/" | cmp - "$release/index.html" ||
        ! check_content_types; then
    if [[ -n "$previous" ]]; then
        ln -s "$previous" "$stage/next"
        mv -Tf -- "$stage/next" current
    else
        rm -- current
    fi
    mv -T -- "$release" "$stage/site"
    echo "新版本 HTTPS 校验失败，已撤销切换" >&2
    exit 1
fi
printf '已启用 %s\n' "$release"
REMOTE
)"

echo "========== 上传 Soulo 静态网站 =========="
printf -v remote_command 'bash -c %q -- %q %q' "$remote_script" "$REMOTE_DIR" "$SITE_HOST"
ssh "${SSH_OPTIONS[@]}" -- "$SERVER" "$remote_command" < "$work_dir/site.tar.gz"

echo "✅ 发布并校验成功"
echo "站点地址 $SITE_URL"
