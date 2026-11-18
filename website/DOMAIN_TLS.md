# Soulo 域名与 HTTPS 维护

## 2026-11-18 迁移状态

新服务器为 `8.136.248.180`。宿主机 Nginx 通过 `/etc/nginx/conf.d/soulo.conf` 提供 HTTPS，站点根目录为 `/srv/www/soulo/current`。兼容路径 `/privacy_policy.html` 保留旧站的原始页面，由同一虚拟主机独立提供。

新版本发布使用 `bash website/upload.sh`，默认连接 `soulo-deploy@8.136.248.180`。脚本上传 Git 已跟踪的静态文件，服务器核对全部文件的 SHA-256 后切换 `current` 链接，并通过本机 HTTPS 校验首页和资源 MIME 类型。服务器保留上一版发布目录。首次发布前核对新机 ED25519 主机密钥指纹 `SHA256:S2anlKYPY9cdYYBULjCQ0M+nJyBA5MlYYKZKp+bjIzA`。

权威 DNS 的 A 记录为 `8.136.248.180`，TTL 为 600 秒。新机安全组已放行公网 IPv4 入方向 TCP 80 和 443。公网实测 HTTP 跳转返回 301，HTTPS 首页和旧版隐私政策返回 200。DNS 回退地址为旧机 `120.26.56.123`。

新机从 Let’s Encrypt 独立签发证书，有效期至 2027-02-16 UTC。Nginx 从 `/etc/letsencrypt/live/soulo.dkluge.com` 读取证书和私钥。HTTP-01 目录为 `/var/lib/soulo-acme`，`soulo-tls-renew.timer` 每天北京时间 02:00 和 14:00 检查，随机延迟最多 30 分钟。续期演练通过，并执行了 Nginx 配置检查和热加载。新机只在本机没有对应的 HTTP-01 文件时向旧机查询，以便旧机的回退站点和共用续期继续工作。

```bash
systemctl list-timers soulo-tls-renew.timer --all
systemctl show soulo-tls-renew.service -p Result -p ExecMainStatus
journalctl -u soulo-tls-renew.service -n 60 --no-pager
/opt/soulo-certbot/bin/certbot renew --dry-run --cert-name soulo.dkluge.com
```

## 旧服务器与回退

旧服务器 `120.26.56.123` 上的 Nginx 仍从 `/root/app-websites/soulo` 提供站点。以下为原部署和维护方式。

Dkluge、StockClaw、Soulo、IDPhoto 四站共用 node-nginx-1；证书统一由服务器申请、自动续期。完整配置源码和运维手册在 sibling Dkluge 项目：[四站 TLS 运维手册](../../dkluge/docker/nginx/tls/README.md)。

## 证书与续期

Let's Encrypt 公开可信 ECDSA 证书，通过端口 80 的 /.well-known/acme-challenge/ 执行 HTTP-01；其余 HTTP 请求保留路径及查询参数，301 到 HTTPS。保持解析和外部 80/443 可访问。Dkluge 一张证书同时覆盖主域名与 www；另外三个子站目前没有 www DNS，不申请其 www 证书。

`dkluge-tls-renew.timer` 每天服务器时间 02:00、14:00 检查，随机延迟至多 45 分钟，按需续期。Certbot 为一次性受限容器，不常驻。所有四站证书校验成功后原子更新链接并热加载 Nginx，应用无需重启。

在服务器运行：

```bash
systemctl list-timers dkluge-tls-renew.timer --all
systemctl show dkluge-tls-renew.service -p Result -p ExecMainStatus
journalctl -u dkluge-tls-renew.service -n 80 --no-pager
cat /root/dkluge-tls/last-renewal.json
cat /root/dkluge-tls/last-deployment.json
# 手动按需续期
/root/dkluge-tls/bin/certbot.sh renew
# 四站测试 CA 演练；不会把测试证书上线
/root/dkluge-tls/bin/certbot.sh dry-run
```

失败看最新 service 日志，结合实际证书到期日检查；last-renewal.json 仅表示上次成功，不能只看 timer 已启用。生产证书更新失败保留此前有效证书，激活失败恢复原 current 链接。不应强制频繁重签。

## 文件、部署与回滚

真实证书 / 私钥 / ACME 账户在服务器 /root/dkluge-tls/，不可上传 Git 或放进镜像。本域名证书位于 certificates/<主域名>/current，Certbot lineage 位于 letsencrypt/live/<主域名>。Nginx 只读挂载 certificates 和 acme-webroot，续期容器独立写入状态；完整路径和锁机制见共用手册。

日常静态内容使用 website/upload.sh 上传，不再申请 / 上传证书，无需重启 Nginx；原 HTML / CSS / JS / 图片保持。不要在 App 项目中恢复阿里云 ZIP 配置。

迁移备份：/root/dkluge-tls/backups/20261004T040529Z/ 和 20261004T034743Z/，包含源码、旧镜像信息与 rollback.sh。历史回滚前核对旧证书未吊销 / 未到期，并确认不会覆盖之后合法配置；正常续期回滚使用此前生产代次。

切换验收后，本网站旧阿里云证书不再使用，可保留回滚窗口后吊销，无需立即吊销。吊销不可逆，已吊销旧证书不能用于历史迁移回滚。API / OSS / CDN 证书不在本次范围。

2026-10-04 已完成四站切换：证书到期日均为 2027-01-02，四站续期演练成功，timer 已 enabled / active，实际 service 检查成功；公网五个主机名、八组桌面 / 手机页面及静态资源检查通过。所有者随后授权提交 / push 与正式部署；完整验收记录见共用手册，服务器按已推送提交记录基础设施发布。
