# 视频页返回重复页面修复

## 真实路径与原因

在生产 `WebViewRepresentable` 中实际加载 pbkan.com 的详情页和视频页：

- 详情页：`https://www.pbkan.com/html/242237.html`
- 视频页：`https://www.pbkan.com/yun/242237-1-1.html`
- 视频页加载后，WebKit 的历史栈同时包含详情页和与当前视频页网址相同的记录。第一次返回触发的是子框架的历史导航，当前顶层网址仍为视频页；第二次才返回详情页。原探针记录的两次导航目标分别为子框架、主框架。

## 修改

- App 返回按钮跟踪本次返回操作；遇到子框架导航时，等待播放器恢复完成，再继续沿 WebKit 原有历史返回。正常主框架导航和主框架 `popstate` 终止本次自动遍历。
- 复用现有的框架通信脚本报告 `pageshow` / `popstate`，支持普通 iframe 文档导航、缓存恢复及 iframe 内的单页历史。没有新增常驻轮询。
- 等待子框架恢复再继续，避免快速连续调用返回后，WebKit 原生历史指针已变化、页面的单页状态尚未恢复的竞态。
- 每步要求历史深度严格减小；用户触摸网页、打开其他地址、前进、刷新、错误及视图卸载会取消尚未执行的返回任务。
- 保留原生历史和前进能力，保留正常主框架的同网址状态。代码不依赖 pbkan 域名或站点关键词，也不清空历史。
- 此次行为针对 App 的返回按钮；网站自己调用的历史操作和 WebKit 原生侧滑不主动启动这套遍历。

## 验证

- 相关原生套件运行 241 项：236 项通过，5 项条件性检查跳过。显式开启 pbkan 实站检查后再通过 1 项，本轮不同原生用例共 237 项通过。
- 回归覆盖：两次子框架跳转后一次返回、正常前进、iframe 内同文档历史、主框架同网址状态、主框架状态位于 iframe 历史之前、POST、重定向、导航策略及网页脚本。
- 2 项实际 UI 用例通过：在 iframe 中真实点击两次，再只点击一次底部返回，回到列表并可前进；开启摇一摇后的网页输入保持焦点。
- pbkan 实站检查实际执行通过，广告过滤保持开启。一次 `WebViewModel.goBack()` 后到达详情页，历史栈未增加新条目，见 [真实历史记录](2026-10-19-video-history/pbkan-history-after-fix.txt)。
- iOS Release 和签名 Debug 构建通过，版本保持 1.2.3（34）；`git diff --check` 通过。此前的键盘修复和设置行对齐修改保留。
- 本轮交互及实站检查运行于独立模拟器，没有把结果计为 iPhone 自动化验收。
- 最终修复版已保留数据覆盖安装到连接的 iPhone，并正常启动；安装和启动的 `devicectl` 结果均为 success。

## 截图

- [返回前的内嵌播放器](2026-10-19-video-history/player-before-back.png)
- [一次返回后的列表](2026-10-19-video-history/list-after-one-back.png)
- [验证汇总](2026-10-19-video-history/validation-summary.json)

## 本机复查

结果包：`/tmp/soulo-video-history-verified.xcresult`、`/tmp/soulo-video-history-ui.xcresult`、`/tmp/soulo-video-history-live-fixed.xcresult`。

实站用例默认按条件跳过，显式启用 `SOULO_LIVE_HISTORY_QA=1`。本次复制生成的 `.xctestrun` 到同一个 Products 目录，在 `SouloTests` 的 `EnvironmentVariables` 和 `TestingEnvironmentVariables` 中设置该变量，然后运行 `test-without-building`，仅选择 `testLiveVideoFrameHistoryReturnsWithOneBack`。没有修改工程或常规测试环境，也没有将网站可访问性设为日常测试的必要条件。
