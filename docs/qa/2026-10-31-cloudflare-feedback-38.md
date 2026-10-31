# 反馈 #38：Cloudflare 验证与登录页过滤状态

## 线上观察

- 反馈版本：Soulo 1.2.6 (53)。反馈 API 上报的 CFNetwork User-Agent 不能用于判断网页中的 WebView User-Agent。
- `https://www.diyihuisuo.com/` 实际返回 HTTP 403、`cf-mitigated: challenge` 和 Cloudflare 验证 HTML，地址仍为首页。原有按 URL 关键词判断的逻辑无法识别这种页面。
- 本机使用实际 `WebViewRepresentable` 和无痕存储，分别关闭、开启广告过滤观察 18 秒；两种状态都停在验证页，均无原生导航错误或捕获到的页面脚本错误。没有完整复现用户“关闭过滤便能通过”的差异，不能将此诊断记为真人验证成功。
- `https://brandverse.ai/user/login?refer=huski.ai` 返回 HTTP 200；站点及 CloudFront 脚本直连检查均成功。Chrome 和实际 Soulo WebView 均能显示邮箱、密码输入框，无捕获到的脚本错误。
- Brandverse 匹配 `/login`，会触发既有登录兼容绕过。站点过滤开关的状态还受该绕过约束，而点击开关只修改站点白名单，无法覆盖绕过规则，因此会显示关闭且无法开启。本次未修改这个登录页策略。
- 上述 Brandverse 的“全局过滤开／关”诊断中，登录兼容绕过均生效，不能据此证明强制启用该登录页的过滤后也正常。

## 修复

- 按 Cloudflare 官方的 `cf-mitigated: challenge` 响应头标记当前验证文档，并结合验证页面 DOM 与专用 URL 判断，供自动隐藏、手动过滤和隐私脚本使用。
- 每一批 WebKit 网络／外观规则都包含验证资源例外，仅覆盖 `challenges.cloudflare.com` 及其子域、各站点 `/cdn-cgi/challenge-platform/`；不放行整个 Cloudflare CDN 或统计域名。
- 原生广告导航规则允许验证框架返回当前主文档的相同来源、相同路径，保留验证参数。禁止借此打开新窗口、广告域名、其他路径或伪装的 Cloudflare 域名。
- 验证文档仅临时暂停外观过滤；进入下一份正常文档后恢复，保留全局开关和站点白名单。派生规则缓存更新至 v5。

## 验证

- 80 项测试通过：规则编译及分批例外、真实 WKWebView 请求放行、验证框架可见、普通广告继续拦截、响应头识别、正常文档恢复、导航边界、手动过滤、弹层和隐私脚本。
- 结果包：`/tmp/soulo-feedback38-regression-final-20261031.xcresult`。首轮使用了 WebKit 不支持的正则分支，已拆成两条独立规则，并完整重跑。
- 随后为验证文档回归补上真实 iframe 发起主页面返回的场景，也通过：`/tmp/soulo-feedback38-frame-return-20261031.xcresult`。
- 实际网站诊断：`/tmp/soulo-feedback38-live-before-report.json`；结果包 `/tmp/soulo-feedback38-live-before-20261031.xcresult` 仅记录观察，不作为网站验证通过的证据。
- 未修改版本、构建号或商店元数据；没有向反馈联系人发送邮件。

依据：[Cloudflare 验证响应识别](https://developers.cloudflare.com/cloudflare-challenges/challenge-types/challenge-pages/detect-response/)、[WebView 集成要求](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/)。
