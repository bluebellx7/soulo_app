# iOS 17.0 输入网址后搜索闪退

## 用户日志与定位

两份反馈均来自 iPhone 15 Pro Max（`iPhone16,2`）、iOS 17.0（21A327）：

| 日志 | 商店版本/构建 | 主二进制及 dSYM 的匹配 UUID | 主线程 App offset |
| --- | --- | --- | --- |
| 2026-10-25 18:12 | 1.2.3 / 37 | `397E3A4B-0527-3EB7-B475-55E3F45F7C16` | `6664412`, `6542120` |
| 2026-10-27 08:44 | 1.2.4 / 37 | `FB7EC3C1-CD54-3F93-BB48-768A8166217D` | `6760676`, `6633912` |

两份主线程均为 `EXC_BREAKPOINT / SIGTRAP`，栈顶一致：

```text
Foundation: URLRequest._unconditionallyBridgeFromObjectiveC(_:) + 264
Soulo: WebViewRepresentable.Coordinator.webView(
    _:decidePolicyFor:preferences:decisionHandler:)
WebKit: NavigationState::NavigationClient::decidePolicyForNavigationAction
```

匹配的 dSYM 分别位于本机 2026-10-19 和 2026-10-26 的 Xcode Archives。`atos` 与 DWARF 将专用函数帧定位到编译时的 `WebViewRepresentable.swift:2549`、`:2672`；两个 ObjC 转发帧为编译器生成代码。两版返回地址前的直接调用均经符号化确认为 `Coordinator.allowsNavigation(_:in:nativeRequest:)`，该函数在原生导航的保护分支判断之前读取来源帧请求。

需要保留的溯源边界：归档内 Info.plist 均为构建 34，商店日志均为构建 37；本次依靠主二进制及 dSYM 与用户日志的 UUID 完全一致进行符号化，不以构建号猜测符号匹配。编译时行号也不直接等同于某个 Git 提交的行号，未认证归档与某个提交逐文件相同。

`WKFrameInfo.request` 的 SDK 声明为非空，但这条旧系统路径可返回空的 Objective-C 请求。直接读取 `sourceFrame.request.url` 会先执行非空的 Swift `URLRequest` 桥接，随后对 URL 的可选判断无法保护桥接本身。1.2.4 日志还附有 VM 分配诊断，但实际终止类型及主线程栈均不是 jetsam，不能据此将这两次闪退归因为内存不足。

## 修复

- `WebFrameRequest.swift` 统一提供 `WKFrameInfo.requestURL`，通过 KVC 读取公开的 `request` 属性，保留为可选 `NSURLRequest` 后读取 URL，避免非空 Swift 桥接。没有使用私有属性、私有选择器或方法交换。
- 导航策略、历史/手势验证、脚本消息、媒体下载/检查和图片预览共 19 处来源帧 URL 读取接入同一兼容入口。
- 缺失来源仍为 `nil`；不将目标网址伪装为来源、不增加新的来源猜测、不关闭广告/弹窗防护。原有的页面 URL 兜底仅在原先已有的位置保留。
- `WKNavigationAction.request` 的目标请求、HTTP 方法/正文、隐私请求头、域名确认及正常导航规则不变。
- 首页搜索界面用例实际输入本地 HTTP 网址，再点击系统键盘的 Search 按钮，不以深链或直接调用 ViewModel 代替这条输入路径。

## 验证与初始失败记录

所有本轮模拟器检查仅使用独立的 iPhone 15 Pro Max / iOS 26.2 QA 设备，不操作用户真机、其它模拟器或登录账号。

- **旧读取方式的受控复现：** Objective-C `request` getter 返回 `nil`，旧 `request.url` 读取使测试进程以 `EXC_BREAKPOINT / SIGTRAP` 终止，顶帧为同一个 `URLRequest._unconditionallyBridgeFromObjectiveC`。原始失败结果包 `legacy-bridge-reproduction.xcresult` 与导出的崩溃诊断保留。
- **首轮扩大回归：** 261 项通过、2 项原有实站检查跳过、6 项新夹具失败。诊断明确显示 `WKFrameInfo.dealloc / _protectedFrameInfo / CFRetain`：直接构造 WebKit 子类没有初始化框架内部 C++ 状态。没有因此修改产品逻辑或放宽断言。测试已改为仅提供公开 ObjC getter 的 NSObject 替身，类型转换限制在测试文件内，不更改全局方法或创建无效的 WebKit 对象。
- **修正夹具后 6 项专项全部通过：** 空请求、有请求但无 URL、原始编码查询/片段保留、缺失来源不冒充目标及不放行无手势弹窗、原生输入导航和页面导航的策略各完成一次。结果包 `frame-request-fixed.xcresult`。
- **最终扩大回归和界面检查通过：** 272 项中 270 项通过、2 项原有实站检查跳过、0 失败。其中原生测试 267 项通过、2 项跳过；实际 App 的 3 项屏幕操作全部通过：首页输入网址后点击键盘 Search，等待网页出现并检查链接、菜单、标签及返回首页；深色和浅色首屏加载、后续页面预览及一次返回。已实际查看导出的网页可见截图及深浅加载截图，页面内容不是空白。结果包 `final-regression-and-ui.xcresult`；专项 6 项包含在该统计中，不重复累加。
- **设备 Release 构建通过：** 未签名 `generic/platform=iOS`，实际主二进制 `LC_BUILD_VERSION` 的最低系统为 17.0、SDK 为 26.2。不是签名 Archive、IPA 或商店上传。
- **严格本地化通过：** 877 键 × 50 语言。商店生成 JSON 的 `--check` 通过，50 语言源文案及版本未修改。

本轮没有 iOS 17.0 运行时或反馈用户的原机，不能将 iOS 26.2 模拟器中的空请求注入及界面验证称为 iOS 17.0 原机验收。现有商店二进制不会由源码推送自动修复，仍须后续准备并提交含修复的新包。

## 本地证据

完整用户日志、初始失败、构建日志和 xcresult 仅留本机，不随仓库推送：

`../StockClawWorkspace/artifacts/soulo-ios17-navigation-20261027/`

原始下载日志分别复制到全新的隔离输入目录，解析使用 Python 隔离模式。此前 56 份改动已单独提交，提交内容与本轮起始快照逐文件 SHA 一致；除明确的兼容修复和键盘搜索测试外，其它原有内容保持。
