# Soulo 域名与 HTTPS 维护

更新：2026-10-04。域名：**soulo.dkluge.com**。A 记录指向 **120.26.56.123**，本次未修改 DNS。服务器登录：`ssh root@120.26.56.123`。服务：/root/app-websites/soulo，由 Nginx 直接托管。

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
