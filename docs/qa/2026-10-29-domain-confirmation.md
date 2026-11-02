# 搜索结果跳转重复确认

用户反馈：百度搜索结果首页点击链接后，“离开当前网站？”可能反复出现，页面最终显示加载失败，按继续后又能打开。

## 复现与定位

- `/tmp/soulo-domain-search-bridge-reproduction.xcresult`：真实界面点击的结果卡片同时声明跟踪地址与目标地址；经过有内容的中间文档后，目标地址错误地弹出确认，预期到达目标的用例失败。中间文档提交时，协调器清除了整个点击记录。
- `/tmp/soulo-domain-repeat-reproduction.xcresult`：确认 POST 导航后，服务器重定向到另一域名仍会再创建确认，用例失败。继续按钮没有把已确认的导航标记为用户授权链。
- 同包中连续 6 次自动请求、一个确认再继续的测试在修改前已通过。本轮没有基于这一猜测改写确认队列或重放表单。

## 修改

- 保留受信任点击记录中的已声明地址，最多 10 秒；跨中间文档只允许同一 WKWebView 的主文档点击前往已声明的准确地址，匹配时忽略 fragment。
- 原先广义链接、表单和控制点击的 3 秒识别仍要求原始 frame。没有声明的其他域名仍需确认，不把中间页后的一切自动跳转都放行。
- 继续按钮授权本次原生导航的服务器重定向链；主文档提交后结束该授权。嵌入式登录/POST 弹窗同样保留本次确认至其文档提交。
- 不修改常驻可信域名、用户开关、POST 请求体或 opener 上下文。

## 验证

- `/tmp/soulo-domain-repeat-fixed.xcresult`：已确认 POST 的重定向、重复请求、已声明目标经过中间文档、不相关目标仍需确认，共 4 项通过。
- `/tmp/soulo-domain-confirmation-final.xcresult` 中 49 项导航、域名、frame request 与表单回归全部通过；已声明/未声明目标及登录弹窗的 3 项界面检查通过。整包因现有新标签界面检查失败，不能算整包通过。
- 排查界面测试发现顶部标签栏和标签概览使用相同的无障碍标题，且同一测试多次打开的来源页也同名。失败页面树中选择的是此前已跳转的第 17 个标签，当前来源页仍是第 19 个；不能代表当前来源页恢复失败。现限定查询 `tabs.groups` 中的卡片，夹具标题加入当前端口及每轮唯一 query。仅修改测试，不修改生产标签逻辑。
- 实站使用公开查询 `MDN JavaScript Array`，实际触摸结果标题。`/tmp/soulo-domain-confirmation-clean-ui.xcresult` 的失败日志与页面树已证明目标 `lia.disi.unibo.it/materiale/JS/developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Array.html` 正文加载，且没有确认框；原测试错误地只接受 `developer.mozilla.org`，把百度返回的大学镜像站误报为未到达。首轮只查地址的另一次用例截图仍在加载，也不作为正文通过证据。现检查离开百度、目标正文标题可操作，并保留截图。百度未返回目标结果时单独记为跳过。
- `/tmp/soulo-domain-confirmation-scoped-ui.xcresult` 中 POST 新标签保留来源页通过（68.613 秒），真实百度点击通过（25.160 秒）。已查看附件 `08C190A6-63F1-427A-B1FE-9B7757574F47.png`，确认显示目标文档的 Array 标题、介绍和 Syntax 正文。该包仍因同一测试内来源页同名而失败，不计为整包通过。
- 最终 `/tmp/soulo-domain-confirmation-isolated-ui.xcresult` 的普通跨站界面回归通过（104.123 秒，0 失败、0 跳过）：直接链接、所选链接的服务器重定向、原生地址输入、自动跳转取消/继续、两侧触摸新标签按钮、返回唯一来源页、关闭确认后的自动跳转。测试先显式恢复开关初始状态，避免此前中断测试遗留的偏好影响结果。最终功能验证通过；前面的失败测试包仍按失败保留。
- 本地化严格检查和商店 JSON 一致性检查通过，版本保持 1.2.6 (51)，不变更本轮已维护的商店文案。

## 安装

- iPhone 17 真机构建成功，`devicectl` 安装回执 `/tmp/soulo-domain-confirmation-device-installed.json` 为 success；应用 UUID 为 `9C55AEEB-27D1-45B0-A8BE-33A117E372B2`。
- 原测试模拟器 `466D547B-562B-4CED-A1F4-329EE4E9539F` 已安装相同生产修复，安装后恢复为关闭状态。
- 仅自动化专用模拟器 `1E6318D8-B5BE-4513-B033-56104F368D72` 清理过积累的测试标签；原偏好备份为 `/tmp/soulo-domain-qa-fixture-tabs-backup.plist`，用户设备及其他项目模拟器未清理。
