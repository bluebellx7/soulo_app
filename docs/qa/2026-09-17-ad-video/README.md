# 广告与视频横屏验证（2026-09-17）

环境：iPhone 17 Pro 模拟器，iOS 26.2。

## 当前视频行为

视频旁的“横屏播放”按钮使用四角展开和播放图形。点按后由原视频进入全屏，再等待全屏控制器支持横屏后切换方向。关闭后等待原窗口恢复，再恢复原来的方向和网页中视频的尺寸。网页工具菜单中不再提供旋转整页的入口。

- 使用原视频元素，不提取链接到新播放器、不重新加载媒体。
- 全屏前按视频比例准备渲染尺寸，修复 WebKit 在全屏中仍保留内嵌画面尺寸的问题；退出或失败时还原本次添加的尺寸样式。
- 独立播放器保留横屏播放入口，全屏内使用手机方向图标切换横竖屏。
- 网页按钮覆盖动态视频和跨域 iframe；隔离脚本环境，并拒绝合成点击。

[视频全屏横屏](web-landscape.png) · [真实网站播放器](pbpbw-player-fullscreen.png) · [关闭后恢复网页](pbpbw-player-restored.png)

## App 横屏布局

- 首页搜索框水平居中，标题位于上方，内容可以滚动。
- 浏览地址栏在横屏中加宽并保持工具栏居中，保留系统手势区域；侧边背景与浏览页保持一致。
- 独立播放器采用视频预览、控制区并排布局，控制区可滚动。

[首页](home-landscape.png) · [浏览页](browser-landscape.png) · [播放器预览](native-landscape-preview.png) · [独立播放器全屏](native-landscape.png)

## 验证结果

- `WebViewModelTests` 和 `WebMediaPlaybackBridgeTests` 共 77 项通过，后续媒体桥接 8 项复跑通过。
- UI：网页视频全屏/横屏/关闭恢复、跨域 iframe、独立播放器全屏及恢复、播放器横屏预览、首页及浏览页横屏均通过。
- 最后针对真实播放页 `https://www.pbpbw.com/player/235867-1-1.html` 与本地高清测试视频复跑全屏流程，两项通过；检查截图，视频按比例展开。退出后断言按钮恢复原来的尺寸与横向位置。
- `python3 scripts/check_localization.py --strict` 通过（862 keys × 50 locales）；`git diff --check` 通过。
- 陀螺仪权限策略保持 HTTPS 返回 WebKit `.prompt`、其他协议拒绝。真实传感器授权弹窗尚未进行真机验证。

## 广告回归（同日上一轮）

地址：https://www.pbpbw.com/html/235867.html

同一页面分别关闭、开启广告过滤，各等待 20 秒：关闭时出现中部广告和底部悬浮广告；开启时两处均未出现，剧集列表正常。另验证等待 12 秒、滚动到底部、重新打开页面，页脚正常。

底部广告由透明点击层与多张背景图拼片组成。标记器将边界匹配的拼片与点击层作为一组处理，默认整站，预览/取消/保存/恢复已验证。`site-render.js` 与 `site-config.js` 广告加载器按 pbpbw.com 限域拦截并保留白名单。

[开启过滤的真实页面](pbpbw-filter-on.png)

## 连续标记与保存

保存后显示“恢复”“继续标记”“完成”。“继续标记”直接开启下一次选择，保留已保存规则，每次默认整站；“完成”退出操作区。

- 14 项 `ManualAdBlockTests` 通过，覆盖持久化、动态元素、规则范围、白名单与恢复。
- UI 连续保存两个区域，确认第一条没有被第二次选择撤销；完成后重新打开页面、终止并重新启动 App，再访问同站另一条路径，两处均保持隐藏，延迟插入的第二处也隐藏，正常内容保留。
- 首页横屏居中通过 UI 检查，截图已更新。

[继续标记入口](manual-ad-continue.png) · [重启后仍隐藏](manual-ads-persisted.png)

## 按域名管理标记

“已标记广告”按域名折叠，当前网站置顶并默认展开，其它网站默认折叠。展开后可恢复单条标记，或使用“恢复整站标记”移除该域名的所有整站及单页规则；其它域名和子域名不受影响。底部“撤销”可一次恢复刚移除的整批规则。

`ManualAdBlockTests` 共 16 项通过，新增验证域名边界、所有生效范围、批量持久化与撤销，以及达到容量限制时不会只撤销一部分。

UI 已验证当前网站默认展开、其它网站默认折叠、切换展开/折叠、恢复当前域名后其它域名保留、整批撤销成功。

[域名分组](manual-ad-domains.png) · [整站恢复后撤销](manual-ad-domain-undo.png)

## 自动跳转开关

广告过滤页面新增“允许自动跳转”，默认开启，独立保存，导航时读取当前设置，无需重启。未设置过的用户使用新默认值，已有选择保持不变。

关闭开关后拦截页面即时脚本、定时脚本、meta refresh、模拟点击、自动提交表单、iframe 顶层跳转和自动弹窗。原生打开网址、历史导航、刷新、已批准导航的服务器重定向保留；真实网页点击通过隔离世界的可信事件识别。

`WebBrowsingRegressionTests`、`ManualAdBlockTests` 和 `WebViewModelTests` 共 95 项通过，覆盖默认策略、即时切换、开启后的自动弹窗与跳转，以及现有广告标记、浏览、历史和刷新逻辑。

## 内置规则与 pianbs 底部广告（9 月 18 日）

`广告过滤 → 内置规则` 展示 235 条规则。网络/CSS 规则可修改匹配条件、适用域名和启停状态，网络规则还可修改资源类型。支持搜索、单条恢复默认和全部恢复默认。保存前由 WebKit 校验，不能保存无效规则。底部拼图识别提供启停开关和识别方式说明。

原有 pbpbw 专用规则仅 2 条，默认限制到 `pbpbw.com` 的 `site-render.js` 和 `site-config.js`，现在均可在 App 编辑。规则默认值位于 `AdBlockService.defaultBuiltInRules`；用户覆盖值由 `BuiltInAdRuleStore` 保存在本机，订阅及手动标记另行管理。

`https://www.pianbs.com/html/226611.html` 的底部广告使用随机未知标签拼接 40 块背景图，外加 10 个透明点击区域和占位节点。图片嵌入 CSS，不能仅靠广告请求域名拦截；随机标签也不能用于下次访问的持久规则。

修复按底部固定定位、图片拼片、覆盖边界及层级识别整组广告，不新增 pianbs 专用域名规则。手动点击一块即可选择整组，保存结构标记，在后续动态插入、随机标签变化时重新识别。选择层置于网页顶层，拦截页面点击与选取期间的非原生导航。操作栏浮动显示在网页上方，不再压缩网页视口，可用“移动面板”切换到下方；保存前重新确认当前节点，支持辅助层移除及随机标签重建。

另一个原因是页面外部脚本长期不返回，旧版过滤依赖文档就绪，标记入口也会因加载中禁用。现在从文档开始监听 DOM，已有内容在加载中即可过滤和标记；切换到新文档时取消旧选择。

- 最终相关单元回归 112 项通过：AdBlockService 13、ManualAdBlock 19、WebBrowsingRegression 11、WebViewModel 69。随后补充的规则编辑后即时重载测试也通过，合计 113 项。测试隔离并恢复用户的内置规则设置。
- 新增“外部脚本阻塞解析”的 HTTP 回归：`document.readyState` 仍为 `loading` 时拼图已隐藏、正文保留、标记器可以启动。
- 编辑持久化、单条/全部恢复、无效正则与资源类型拒绝保存、原生规则与脚本同步启停、随机拼图整体处理与新标签替换均已覆盖。

前一轮实页验证（此处“默认关闭”为当时策略，已被下面追加记录替代）：先开启通用规则确认自动隐藏，再关闭这一条规则并重新打开 pianbs，截图确认广告出现；点击底部广告保存，检查实际持久化选择器为 `[data-soulo-tiled-banner="bottom"]`。重新打开和终止重启 App 后保持隐藏。最后恢复通用规则并清理测试标记。pbpbw 页面等待、滚动与重新打开，以及自动跳转默认关闭、真实点击、启停和重启持久化，两项最终 UI 回归均通过。

[内置规则列表](builtin-pbpbw-rules.png) · [编辑规则](builtin-rule-editor.png) · [pianbs 自动过滤](pianbs-auto-filtered.png) · [标记后重启](pianbs-manual-hidden-relaunched.png) · [自动跳转默认关闭](automatic-navigation-default-off.png)

## UI 复现

本目录保存 UI 测试源码与网页 fixture。复制到临时目录，在 `App/App.swift` 创建最小 SwiftUI App，把 `AdVideoTests.swift` 放入 `Tests/`，按附带 `project.yml` 执行 `xcodegen generate`。先安装当前 Soulo 到模拟器。

以 127.0.0.1:8917 提供本目录网页。`sample-hd.mp4` 可用以下命令生成（不提交生成的视频）：

```sh
ffmpeg -f lavfi -i 'testsrc2=size=1280x720:rate=15' -t 20 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -movflags +faststart sample-hd.mp4
python3 -m http.server 8917 --bind 127.0.0.1
```

连续标记测试另需复制 `continuous.html` 为 `continuous-next.html`，用于验证整站规则在不同路径上生效。每次运行使用独立区域 ID，避免已有标记干扰测试。

独立播放器测试需要将仓库 `SouloTests/ReadingFixtures/playback-h264-aac.mp4` 复制到 Soulo 沙盒 `Documents/Downloads/QA-Landscape.mp4`，完成后删除此 QA 文件。执行 QA scheme 的 UI 测试。截图使用 `XCUIScreen.main.screenshot()` 并等待动画结束。


## 宽泛规则收紧与标记面板（9 月 18 日追加）

保留 235 个稳定规则 ID 和用户已保存的覆盖值，其中 174 条默认启用、61 条默认停用。默认停用缺少站点依据的 gg、union、adpic、adimg、gpt.js、广告查询参数等匹配；广告域名锚定协议和完整主机边界，路径匹配不再扫查询参数；CSS class 子串改为完整 token，停用会命中 download-panel 的 ad- 子串和 gg 图标前缀，百度专属元素限定到 baidu.com。这些规则仍可在“内置规则”中查看、编辑、启用或恢复默认。广告拼图自动识别额外避开有内容、可访问控件语义及表单/导航栏中的节点。

本轮线上诊断发现测试环境仍保留一条先前创建的 pianbs 结构标记，它在新广告生成后隐藏节点，造成选中状态立即失效的测试干扰；临时隔离并恢复原标记后，实际页面成功识别 51 个广告相关节点，开始和选中期间视口均保持 402 × 778，保存返回结构选择器。网络诊断测试仅临时使用，未保留在单元测试套件中。

新增确定性回归覆盖：真实 WebViewContainer 选中前后视口高度不变、底部广告可点；正常 gg/union 脚本、adpic 图片、带广告域名文字的参数请求加载成功；下载面板、播放器和登录表单可见，同时明确广告脚本/广告区域仍被过滤；可访问的固定工具栏不被拼图识别隐藏；新默认自动跳转及用户关闭后的即时拦截。


另修复了保存可靠性：测试设备 `UserDefaults` 同时保存约 3.3 MB 的逐订阅完整缓存和约 0.68 MB 的合并缓存，加上其它偏好触发 CFPreferences 4 MB 限制。逐订阅完整缓存改用 Application Support 下的 `AdBlock/subscription-rules.json` 原子写入；成功迁移后移除偏好中的旧副本，迁移失败保留旧数据。合并后的运行缓存和用户开关保持原接口。新增迁移、重新实例化、开关保持和写入失败回退测试。


验证结果：`/tmp/soulo-ad-conservative-final.xcresult` 中广告规则 14 项、订阅 9 项、手动标记 20 项均通过；浏览回归其余 12 项通过。新增 HTTP 资源用例明确等待本轮原生规则编译安装后，单独在 `/tmp/soulo-conservative-http-final.xcresult` 通过（避免复用上一用例的订阅缓存或在规则尚未就绪时发送请求），本轮共 56 项通过。`python3 scripts/check_localization.py --strict` 与 `git diff --check` 通过。


最终 UI 回归 `/tmp/soulo-conservative-final-ui.xcresult`：自动跳转/真实点击 71.4 秒、pbpbw 页面 31.4 秒、pianbs 浮动标记/重启持久化/恢复自动过滤 126.4 秒，三项通过。已人工检查截图：底部广告完整蓝框选中，重启后管理页面显示整站结构选择器，自动过滤时页面正文和图片仍在，pbpbw 页尾无底部广告。测试产生的 pianbs 标记已恢复，通用拼图规则已重新开启，自动跳转保持开启。

[完整选中广告](pianbs-floating-picker-selected.png) · [重启后的规则记录](pianbs-floating-rule-persisted.png) · [pianbs 自动过滤](pianbs-conservative-auto-filtered.png) · [开启自动跳转](automatic-navigation-enabled.png)


## 底部标记操作栏与原生点击（9 月 18 日后续）

按用户反馈恢复底部操作栏。开始标记时一次预留完整操作区，选中、预览、保存期间高度保持一致，底部固定广告位于操作栏上方。横屏使用较小的可滚动操作区。移除上下移动面板按钮。

标记模式增加原生 UITapGestureRecognizer，将点击坐标换算到网页可视区域，在隔离脚本世界选取元素；退出标记后禁用，卸载网页时移除。网页 JavaScript 事件不再是唯一点击入口。选择拼图时先检查点击层后方的拼片，再应用普通元素的尺寸保护，修复整屏透明点击层导致拒绝选择的问题；没有放宽主页面/表单保护。

`/tmp/soulo-bottom-native-picker-unit.xcresult`：21 项手动标记测试通过，包含整屏透明点击层、底部广告可触达、选中前后网页高度一致、保存重建及恢复。
`/tmp/soulo-bottom-native-picker-ui.xcresult` 中 pianbs 实页流程通过（126 秒）：底部面板位置、完整蓝框、整站保存、重启后规则仍在、恢复标记并重新启用自动过滤；截图已人工查看。该批另一项本地页面测试因 HTML 未声明 UTF-8 而未找到中文标题，已修正测试页面编码后单独复测。

[底部操作栏及整组选择](pianbs-bottom-picker-selected.png) · [重启后的整站规则](pianbs-bottom-rule-persisted.png)


## pianbs 闪烁与 yinsuw 底部图片广告（9 月 18 日追加）

pianbs 自动识别的拼片改用独立构造样式表裁剪，保留节点原有 display、尺寸和内联样式；新增拼片在 MutationObserver 绘制前处理。进入标记暂时清除自动拼片遮罩并暂停动态隐藏，退出通过明确事件恢复。已保存结构标记也在新节点插入时立即匹配。此处替代前面的自动隐藏实现记录。

pianbs 真实 URL `https://www.pianbs.com/html/226611.html` 在生产 WKWebView 中连续采样 20 秒：340 帧均检测到广告拼片，可见广告帧为 0，只观察到一个随机标签名。`/tmp/soulo-bottom-picker-final-unit.xcresult` 24 项通过；`/tmp/soulo-pianbs-default-filter-ui.xcresult` 实际 UI 操作通过（73.7 秒），在自动过滤开启时进入标记，完整选中、等待后保存，重新打开及规则列表核实结构标记。网络探针源码另存为文本，不加入常规单元测试。

[自动过滤开启时选中](pianbs-default-filter-marking-selected.png) · [保存后重新打开](pianbs-default-filter-marking-reopened.png)

新增网站 `https://www.yinsuw.cc/voddetail/dw977F/` 实页复现的是整张 GIF 图片和独立透明点击层，图片根节点的 ID 包含运行时戳，每次加载变化。透明层直接挂在 body，图片根节点位于匿名包装层中，因此不能假定两者是兄弟节点。新增识别同时验证组件 ID 结构、对应的关闭/跳转处理器、图片资源路径、固定底部样式及配对点击层 ID，未写入 yinsuw 网站名或广告图片域名，也未使用通用“底部图片”匹配。保存广告位级结构标记，刷新后重新识别随机 ID，图片和点击层一起隐藏/恢复。

新增内置规则 `paired-image-banner`（CSS 选择器包含 `data-soulo-image-banner`）可在内置规则列表搜索、编辑、关闭。当前共 236 条规则，175 条默认启用、61 条默认停用；旧规则 ID 和用户覆盖值保留。

`/tmp/soulo-yinsuw-rules.xcresult` 中 14 项广告服务测试、25 项手动标记测试通过，另含 1 项临时真页诊断。实页检查发现匿名包装层后补正点击层配对，`/tmp/soulo-yinsuw-final-real.xcresult` 的 3 项结构回归和真页探针均通过：20 秒采样 1202 帧，每帧均识别到两个广告层，可见广告帧为 0。测试覆盖随机运行时 ID 替换、整组恢复、普通固定图片保留、标记期间可选择及取消后恢复过滤。截图人工核对正文、封面、播放入口和页面工具仍可见。

[修复前](yinsuw-before.png) · [实际网页过滤后](yinsuw-live-auto-filtered.png)


最终 yinsuw UI 回归 `/tmp/soulo-yinsuw-default-ui.xcresult` 通过（138 秒）：内置规则开启时自动过滤；进入底部标记模式显示广告并完整选择；整站保存；关闭新增自动规则并终止/重启 App 后手动标记仍生效；管理页面核实 `[data-soulo-image-banner="s8d87dabb3fb"]`。最后移除本轮 QA 标记并重新开启内置规则，实际页面保持过滤。严格本地化检查（862 keys × 50 locales）及 `git diff --check` 通过。

[底部完整选择](yinsuw-default-filter-marking-selected.png) · [关闭自动规则并重启后](yinsuw-default-filter-marking-reopened.png) · [保存的整站规则](yinsuw-default-filter-marking-rule.png) · [最终自动过滤](yinsuw-final-auto-filtered.png)


## 隐藏区域点击与管理弹窗整理（9 月 18 日后续）

这一轮替代前面“标记时显示自动过滤广告”的行为：进入标记不再撤销自动拼片遮罩或图片广告规则。旧版图片规则覆盖值仅去掉原默认的标记模式例外，保留用户的启停选择、域名范围和自定义选择器。

在独立模拟器 Soulo-Ad-QA（AF2D4A20-E053-4893-BE57-09F976E3E2D8）真实复现 pianbs：图像和点击层已不可命中，但原底部区域的真实触摸仍触发广告站跳转。增加已确认且实际隐藏的底部广告区域事件保护，在捕获阶段阻断该区域向网页广告处理器传播，保留原生滚动和普通链接默认行为；恢复广告或移除节点后不再拦截该区域。没有关闭“允许自动跳转”总开关。共享模拟器上的首轮点击测试被其它 App 切前台干扰，已废弃该结果，不作为复现依据。

广告过滤弹窗改为“过滤设置、当前网站、规则管理”三组；已标记广告、内置规则、订阅和允许的网站统一为入口，空列表也可进入。订阅开关、更新和重置放入订阅子页面；允许的网站有独立空状态；统计默认折叠。普通字号保持不变，减少主页面重复说明。

`/tmp/soulo-hidden-events-unit.xcresult`：40 项通过。`/tmp/soulo-hidden-events-and-menu-ui.xcresult`：管理弹窗及两站真页操作均通过（总计 123.6 秒）。两站分别点击原底部区域三个位置，页面保持原址；各进入/取消标记两次，截图人工确认广告没有重新显示。管理页检查四个规则入口、订阅详情、允许网站空状态，并核对竖屏、横屏截图。所有真页测试保持广告过滤及允许自动跳转开启。

[整理后的弹窗](ad-management-organized-portrait.png) · [横屏](ad-management-organized-landscape.png) · [pianbs 重复标记](pianbs-picker-keeps-filtering-1.png) · [yinsuw 重复标记](yinsuw-picker-keeps-filtering-1.png)

补充 `/tmp/soulo-hidden-events-controls-ui.xcresult` 真实触摸用例通过（17.5 秒）：本地 fixture 安装整页广告点击处理器，隐藏广告区域点击不会跳转，原生滚动仍更新页面，原区域内的普通链接仍能打开正确目标。当前 UI harness 的手动保存流程改为显式关闭对应自动规则后再标记，避免继续使用旧的“进入标记会显示自动过滤广告”假设。
