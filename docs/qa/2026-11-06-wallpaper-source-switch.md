# 壁纸切换与 Nature 默认氛围

2026-11-06。用户在第 3 项核验结束时指定壁纸问题，先处理本项，尚未开始原列表的第 4 项。

## 修改

- 壁纸来源按钮原来只修改来源，没有触发相应加载；现在通过 `selectSource` 加载选中来源。
- 来源变化时清除旧候选项并使旧请求失效。请求完成后校验来源和请求标识，旧响应不会覆盖新来源，也不会结束新请求的加载状态。
- 在线请求检查 HTTP 状态，失败时使用已有的错误提示；元数据请求超时为 15 秒。
- 默认氛围列表改为只有 `Nature`；默认搜索词继续为 `Nature`。切离 Bing 时将其系统显示词 `Bing Daily` 恢复为 Nature 查询，避免拿它搜索其他图片源。保存过的自定义氛围列表和查询优先于默认值。
- 为请求会话提供注入入口，默认仍使用系统共享会话；增加受控响应和旧请求延迟返回的回归。

## 验证

设备：专用 iPhone 17 / iOS 26.2 模拟器 `4EDA06FB-B649-4C6B-9F77-69D7D4A6D292`。Debug、`ONLY_ACTIVE_ARCH=YES ARCHS=arm64`。产物位于 `/tmp/soulo-wallpaper-switch-20261106/`。

- `WallpaperFinal.xcresult`：7 项通过，0 失败。包含默认 Nature 且读取不写偏好、保存过的选择优先、Pexels/Pixabay 切换后下载并解码图片、旧响应不覆盖新来源、403 明确报错且可换来源恢复、缓存异步恢复、低电量和后台暂停自动工作。
- `WallpaperUI.xcresult`：1 项通过，0 失败。实际进入设置，点击纯色和渐变来源、选择 Forest 渐变，再返回首页。已查看首页截图，背景改变且氛围显示 Nature。该测试使用本地来源，不代表在线接口的实时可用性。
- 初次命令行诊断中 Pexels、Pixabay 返回 403，Bing 返回 200；后续按下节核实，前两者是 Python 默认请求标识触发 Cloudflare 拦截，不能据此判定 App 原生请求失败。
- 新增测试协议的 Sendable 声明警告已移除，最终构建通过。`git diff --check` 通过。

前 3 项修改及原有网站审计文件保留。完成本项后停止，等待用户指示。

## 403 原因核实

用户追问后，使用现有密钥对比请求标识，并在同一专用模拟器运行原生 iOS URLSession 网络探针。探针使用与 App 相同的接口、Nature 查询、每页 15 项和默认 URLSession 请求标识，不修改 App 的请求头或业务代码。

- Python `urllib` 默认 `User-Agent: Python-urllib/3.9`：两家均返回 HTTP 403，响应体为 `error code: 1010`，服务端为 Cloudflare。
- 相同密钥、相同接口参数，将命令行请求标识改为应用标识或普通浏览器标识：两家均返回 HTTP 200。成功响应中剩余额度正常；无需据此更换密钥。
- 模拟器默认 URLSession：Pexels 和 Pixabay 均 HTTP 200，各解析出 15 个候选项。继续下载当前生产代码选择的图片地址，均 HTTP 200，ImageIO 成功解码；Pexels 为 1965 × 3488，Pixabay 为 854 × 1280。
- Cloudflare [1010 官方说明](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1010/)将此错误定义为根据客户端特征拒绝访问。结合仅改变请求标识的对照，本次命令行 403 来源于客户端标识拦截，不能归因于密钥失效、额度耗尽或壁纸渲染失败。

脱敏证据位于产物目录中的 `provider-403-diagnosis-redacted.json`、`provider-python-default-redacted.json` 和 `provider-native-redacted.jsonl`。包含密钥的临时探针源码与可执行文件在验证后删除。此结论只覆盖本次网络环境；未测试真机及其他网络，也不代表持续可用性保证。
