# 返回显示与加载进度

用户反馈：视频详情按返回后，当前画面仍停留至顶部加载完成，之后才出现上一页；加载进度先要求金色，随后要求更亮或使用主题蓝色，最终采用主题蓝色。

## 修改

- 历史按钮沿用 WebKit 的原始历史条目，保留表单、SPA 同网址状态和前进列表。删除把当前画面滑走后又露出当前页的延迟动画。
- 点击返回后立即呈现目标历史条目的快照；没有快照时显示现有加载页，避免旧视频看起来仍留在当前页。网页可呈现时收起预览，无需等待所有资源完成。前进沿用原生逐条历史行为。
- 复用现有页面截图，每个运行时最多缓存 6 个，只保存在内存。按历史条目身份区分同网址页面；缓存运行时释放时一并清理，滚动停止后更新快照。
- 缓存文档的 JavaScript 不会重新初始化，`pageshow.persisted` 时重发内容就绪通知。主文档 popstate、取消、失败、转下载和 iframe 历史耗尽均结束过渡，避免留下静态遮罩。
- 按返回时立即挂起离开的媒体，与导航/标签共享既有挂起配对；主文档提交、同文档恢复、取消或 iframe 历史耗尽后解除。
- 顶部进度条最初改为金色；用户追加要求更亮或使用主题蓝后，改用共享 `Color.themePrimary`，底轨与阴影同步跟随主题色，保持现有高度和加载动画。

## 验证

- `/tmp/soulo-history-preview-regression.xcresult`：最初 15 项历史与页面就绪回归通过。
- `/tmp/soulo-history-gold-final.xcresult`：16 项行为/语法回归及 1 项完整界面验证通过，无跳过。涵盖即时目标预览、缓存恢复通知、同网址主状态、iframe 导航与 fragment、自动跳转跳过、迟到失败、前进列表、取消和 iframe 历史耗尽。
- 界面夹具在搜索页挂起一个资源，然后打开详情、按返回，检查实际搜索文字可操作且过渡遮罩已移除。截图保存在结果包，不将静态快照误报为可操作页面。
- 最后补充保留已知条目的缓存图片，避免原生历史游标更新时把它替换为空预览；以 `/tmp/soulo-history-gold-display-final.xcresult` 复查核心返回/前进、iframe 耗尽和界面显示。
- 加载中与返回后的完整截图均已检查：加载条呈金色，返回后的上一页文字可操作。加载截图 `/tmp/soulo-history-gold-display-final-attachments/8402DD1C-71A2-4A99-AB12-1DCECB7E2AF2.png`。
- 最终将目标预览限定于返回，前进保留原生逐条行为；`/tmp/soulo-history-gold-verified.xcresult` 的 5 项核心历史回归与 1 项完整界面检查全部通过。保留此前 17 项覆盖，不把重复执行计为新增用例。
- 构建已安装到原 Soulo 模拟器及连接的 iPhone，保留应用数据，版本仍为 1.2.5 (51)。真机首次安装连接中断，重试成功，最终回执 `/tmp/soulo-history-gold-verified-device-retry-installed.json`；真机未运行本轮界面测试。
- 本地化严格检查、元数据一致性和 `git diff --check` 通过。
- 追加主题蓝调整：`/tmp/soulo-theme-blue-progress.xcresult` 界面验证通过，已目视检查加载条为明亮主题蓝。截图 `/tmp/soulo-theme-blue-progress-attachments/96FC0404-637D-4B6F-A35A-BCB542C8B236.png`；模拟器及连接 iPhone 均已更新，真机安装回执 `/tmp/soulo-theme-blue-progress-device-installed.json`。

本轮保留已有扩展、媒体与用户资源修改，不更改版本或商店元数据。
