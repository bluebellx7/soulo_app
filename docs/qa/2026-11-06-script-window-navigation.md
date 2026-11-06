# 自定义按钮与脚本窗口：2026-11-06

## 问题与通用修复

用户报告 `https://ggbgb.na42u.cc/` 中间的入口在广告过滤开启时无响应。实站 DOM 与浏览器对照确认，该入口是没有 `href` 或 `role` 的 React `div`，自身设置 `cursor:pointer`，点击调用 `window.open('/home')`。原有可信手势只识别标准按钮、链接和部分角色，因此将该窗口误判为无用户操作的弹窗。

- 手势观察器继续只接受可信事件，补充识别自定义控件设置指针样式的边界。整个页面继承的指针样式不直接构成按钮；处理局限于事件路径中的有限节点，不扫描整个文档。
- 标准按钮、角色按钮及这类自定义控件的真实操作可以使用脚本计算目标地址，支持同站、跨站和新窗口。空白处点击、伪造点击及 iframe 导航仍由原有广告策略约束。
- 没有增加该网站的域名例外、选择器例外或关闭过滤的处理。

## 新窗口使用正常标签页

移除内嵌浮层及“在当前标签页打开”一行。允许的脚本窗口现在进入完整浏览器标签页。

- 使用 WebKit 提供的新窗口配置，保留进程、网站数据和 `window.opener` 关系；每个标签单独安装脚本桥接，避免切换标签时互相解绑。
- 将已经创建的窗口和模型交给所属窗口的 TabManager，不把原始请求重新发成 GET，也不重复提交 POST。
- `window.close()` 仅关闭由脚本创建的对应标签；原标签和实时输入内容保留。
- 搜索页布局与事件处理拆成独立表达式，解决 SwiftUI 类型推断超时。已逐字比较，布局子树与修改前一致，没有增加布局容器。

## 最终验证

专用 iPhone 17 / iOS 26.2 模拟器的 `FinalNavigation.xcresult`：**51 项通过，0 失败，0 跳过**。

- 45 项单元检查：7 项广告导航、27 项标签管理、11 项跨站导航。
- 6 项界面检查：过滤开/关下的自定义按钮；脚本计算跨站地址的标准按钮和角色按钮；空白点击/伪造点击广告拦截；登录回调和表单提交；实站入口。
- 自定义按钮创建完整标签后，验证 `window.opener` 存在、没有额外浮层、关闭后标签数恢复且原页输入内容保持。
- 表单服务器实际收到一次 `POST /submit.html`，请求体为 `query=chosen`，Origin 保留原页面来源，未重放提交。
- 实站在过滤开启时创建正常标签，当前页面链接指向同站 `/home`。本轮没有对站点后续内容做全量验收。
- 已导出并查看最终新窗口截图，确认使用现有浏览器界面。

最终设备 Release 未签名归档成功。App、分享扩展和小组件均为 `1.2.10 (51)`、arm64，二进制与四份 dSYM 匹配；App、两个扩展、PLzmaSDK 和 ZipArchive 的隐私清单存在且可解析。编译保留此前的 SiteOptimization actor 提示、音量控件废弃提示及 WebKit 异步 API 建议，没有新增编译错误。

元数据生成一致性检查和 `896 keys × 50 locales` 严格本地化检查通过。此次没有修改版本号或商店文案，没有执行上传、提交审核或 Git 推送；本轮结果不代表真机全量验收。

## 自动化命中对照

测试中，XCTest 能读取脚本窗口内按钮的正确位置，但 `.tap()` 计算命中点为 `{-1,-1}`。将测试页补齐移动端 viewport、改用非零初始窗口尺寸后仍存在，不能据此宣称业务窗口无法触摸。

另外创建只使用 UIKit 和 WKWebView 的最小 `RawScriptWindow` 对照 App，无 Soulo 导航、过滤或脚本代码。`RawControlResumed.xcresult` 的一项检查通过，记录为：

```text
RAW_SCRIPT_WINDOW_COUNT_HITTABLE=false FRAME=(8.0, 107.0, 89.0, 20.0)
RAW_SCRIPT_WINDOW_CLOSE_HITTABLE=false FRAME=(100.0, 107.0, 119.0, 20.0)
```

同一对照中，对按钮位置发送真实坐标触摸后，计数从 0 变为 1，关闭窗口返回原页。最终 Soulo 回归据此验证实际坐标触摸后的关闭、标签数量和原页输入；没有以 JavaScript `.click()` 替代真实触摸。该观察仅覆盖本机 iOS 26.2 模拟器与当前 XCTest 环境，不推广为所有系统版本的结论。临时对照 App 已从专用模拟器卸载。

## 本机证据

目录 `/tmp/soulo-ggbgb-adblock-20261106/`：

- `FinalNavigation.xcresult`、`final-navigation.log`、`FinalNavigation-summary.json`、`final-attachments/`
- `ReleaseArchive.xcresult`、`release-archive.log`、`Soulo-1.2.10.xcarchive`、`release-archive-audit.json`
- `RawControlResumed.xcresult`、`raw-control-resumed.log`、`RawScriptWindow.swift`、`RawControlResumed-summary.json`
- `entry-click.json`、`site.html`、`browser-site.html`
- `baseline/`：开始修改时相关文件的副本，保留既有未提交修改。

`Before.xcresult` 复现修复前“过滤关闭通过、开启失败”。两次 `After*` 构建未通过 SwiftUI 类型推断，随后通过布局表达式拆分解决。`RoutingRegression`、`EntryRegression` 和 `WindowGeometry` 的早期结果包含上述 XCTest 命中失败，不能当作整包通过。`RawControl` 被服务重启中断，不计为成功；以完成后的 `RawControlResumed` 与 `FinalNavigation` 为准。
