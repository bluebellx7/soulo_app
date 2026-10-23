# 网页及关键词输入焦点修复

## 原因与修改

- 开启“摇一摇”时，`DeviceShakeDetector` 在 SwiftUI 更新、视图出现、摇动操作后多次调用 `becomeFirstResponder()`。网页或原生输入框刚获取焦点，键盘通知触发父视图刷新，检测器又夺走焦点，导致键盘无法保持。
- 用户真机偏好中该功能设为全屏。相同输入页面，关闭摇动操作时原代码可输入；开启操作时新增 UI 回归用例稳定失败于键盘存在断言。
- 真实设备上的 Core Motion 检测不再请求 first responder，也不接受该焦点角色。没有运动传感器时保留 UIKit 兜底，但只在窗口没有其他 first responder 时获取焦点。
- 摇动操作完成后只恢复运动检测，不夺回焦点。保留原有灵敏度、节流与动作设置；没有注入强制 focus 的网页 JS，也没有关闭用户的摇动功能。
- 最初检查过父视图的收键盘手势；关闭摇动功能的对照测试能够正常输入，最终未修改该手势。

## 验证

- 修复前：`testWebPageTextFieldsKeepFocusWithShakeActionEnabled` 失败；不启用摇动操作的对照用例通过。
- 修复后：76 项 `WebViewModelTests` 通过，包含刷新、视图出现、摇动回调期间保留 `UITextField` / `UITextView` 焦点的回归，以及原有摇动灵敏度与连续触发测试。
- 4 项 UI 用例通过：普通网页输入框和多行输入、开启摇动功能时网页输入、开启全屏摇动动作时底部关键词输入、百度实际搜索“鸡蛋”后继续在网页搜索框输入。
- 百度用例通过屏幕坐标点击真实搜索框，再通过系统键盘写入 `test`，核对输入值及键盘仍存在；关键词用例写入 `eggs` 并核对值及键盘。
- 最终 iOS Release 构建通过。签名 iPhone 应用构建通过，版本保持 1.2.3（34）。
- 真机测试起初缺测试目标的开发团队，使用命令行传入工程现有团队后构建通过，未修改工程配置。随后两次真机 UI 运行器均在执行用例前因 DTX 控制通道断开而退出 74，0 项真机 UI 用例执行，不能计为测试通过。
- `devicectl` 确认 iPhone 已配对、隧道已连接、无需解锁；实际传输为 `localNetwork`，不能把旧设备清单的 USB 标记当作实际线路。已请求数据线连接以继续真机自动回归，未确认该连接问题的根因。
- 最终使用 `devicectl device install app` 将修复版覆盖安装到 iPhone，结果为 success，保留应用数据。随后尝试正常启动时，设备已锁屏，系统以 Locked 拒绝；不声称完成了真机输入测试或已成功打开应用。

## 截图与记录

- [百度网页键盘](2026-10-18-input-focus/baidu-keyboard.png)
- [底部关键词键盘](2026-10-18-input-focus/address-keyword-keyboard.png)
- 本机结果包：`/tmp/soulo-input-focus-shake-before.xcresult`、`/tmp/soulo-input-focus-fixed.xcresult`、`/tmp/soulo-input-focus-regression.xcresult`。
- 真机运行器结果：`/tmp/soulo-input-focus-iphone-signed.xcresult`、`/tmp/soulo-input-focus-iphone-isolated.xcresult`。
