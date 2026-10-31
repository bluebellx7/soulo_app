# 验证组件兼容与错误页地址修复

## 广告过滤与验证

- 移除按完整 URL 中 `login`、`auth`、`security` 等关键词绕过的规则；路径、域名、参数、片段中出现这些词不再使普通页面停用过滤。仍识别真实 Cloudflare 验证资源、挑战响应头及启动脚本、验证票据和微信专用验证码端点。
- 广告过滤仅使用用户维护的站点白名单，隐私保护的兼容域名不再强制关闭广告过滤。站点卡片、管理页和实际规则使用一致状态，可关闭后重新开启；开启继承了父域名例外的站点时，会恢复对应的白名单条目。
- 保留登录输入框、Turnstile、reCAPTCHA、hCaptcha 的必要资源与界面。原生 CSS、JavaScript 备用样式、手动选择和弹层清理使用相同控件保护；后插入验证控件时恢复此前隐藏的容器，同时继续过滤旁边的广告。
- 明确的验证框架及其临时子文档不再注入媒体请求包装、剪贴板包装和选择样式，保留原生 `fetch`、XHR、剪贴板与控件行为。普通页面仍保留原有保护与媒体识别。

## 错误地址

- 分开保存请求地址、实际失败地址和 WebKit 当前仍保留的文档地址。优先使用错误携带的失败 URL，否则使用本次请求地址。
- 过滤加载期间以及失败后的旧 URL 观察回调，防止输入 `pbpbs.com` 后又显示上一页的第一会所地址。
- 错误页、复制链接、重试、底部刷新及错误页缩略图使用本次失败地址；新导航和正常历史切换会清理失败状态。
- 标题改为“无法访问”，同步了 55 个现有本地化文件的对应条目。未修改版本、构建号或 App Store 文案。

## 验证结果

- 最终 184 项单元测试、2 项界面回归全部通过：`/tmp/soulo-compat-and-error-verified-20261031.xcresult`。覆盖动态控件恢复、验证框架原生 API、过滤开关、原生规则编译、登录弹窗、历史返回、快速导航、错误地址及重试。
- 界面回归实际从底部输入框提交新地址，先访问成功页面，再访问已经停止的本地服务器，确认错误页与重试都保留新地址，标题为 `Unable to Access`。
- `python3 scripts/check_localization.py --strict` 通过：890 个键、50 个运行时语言；额外语言文件沿用现有键，无新增缺失项。
- Cloudflare 官方测试 Key 在实际 Soulo WebView 中回调成功；同时确认广告过滤已经安装、整页绕过标志为 false、旁边广告为隐藏状态。结果包：`/tmp/soulo-turnstile-brandverse-control-20261031.xcresult`。
- Brandverse 正式页的表单和 Turnstile 资源可加载，过滤确实开启。观察时，Cookie 选择弹窗仍覆盖部分内容；正式验证票据在 App 和未注入脚本的 WebKit 对照中均为空。未处理该弹窗、未提交账号，也未将此观察作为生产挑战已通过的证据。其真实风控放行仍需正常交互与设备确认。
- 首轮动态控件恢复回归发现 JavaScript 备用 CSS 缺少原生过滤同样的控件保护，修复后完整重跑通过。临时在线诊断代码已从常规测试中移除。

参考：[Cloudflare WebView 要求](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/)、[官方测试 Key](https://developers.cloudflare.com/turnstile/troubleshooting/testing/)、[reCAPTCHA 资源域名](https://developers.google.com/recaptcha/docs/faq)、[hCaptcha 集成说明](https://docs.hcaptcha.com/)。
