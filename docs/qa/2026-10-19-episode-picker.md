# 选集按钮偶发无响应修复

## 复现与原因

- 读取连接 iPhone 保存的当前标签，定位到片吧《仙逆》详情页：`https://www.pbpbw.com/html/228208.html`。
- 在生产 App 的 UI 测试中复现：详情页点击选集成功，选择一集进入播放页，点击底部返回后，选集悬浮按钮仍在，点击却不出现面板。
- 导航开始时，原生 `episodeList` 会清空；WebKit 从历史缓存恢复网页时，也保留了脚本上次发送的列表签名。列表未变，脚本因此跳过回传。原生两个按钮入口又都在列表为空时直接忽略操作。
- 修复前的结果包：`/tmp/soulo-episode-return-confirm.xcresult`，失败点为返回后的 `browser.episodes-order` 不出现。

## 修改

- 从历史缓存恢复及同页历史变化时，清除发送签名，重新同步选集。
- 原生主动刷新返回当前选集快照，即使列表内容没有变化也回传；导航完成时主动同步。
- 悬浮选集和播放器选集共用原生入口。数据缺失时，按需重新读取，并校验 WebView、网址及导航代次，丢弃过期回调。网站已经移除列表时显示已有的不可用状态，避免点击被静默忽略。
- 播放器框架恢复时重新报告就绪状态，让原生同步选集可用性。
- 沿用隔离脚本世界和真实用户输入校验，没有增加常驻轮询或站点专用规则。

## 验证

- 33 项不同原生用例通过：17 项选集检测与恢复、12 项媒体工具、4 项原有返回历史回归。包括 native 数据丢失后点击播放器选集重新获得列表。
- 4 项 UI 用例通过：返回详情后连续打开选集、iframe 播放器返回与前进后打开选集、切换上一集与倒序、悬浮拖动及批量下载。
- 另 1 项片吧实站 UI 用例实际执行通过（45.484 秒）：《仙逆》详情页打开选集、选第 01 集、等待播放页出现下一集链接、点击底部返回、再次打开选集并确认第 01 集可见。广告过滤开启，本轮共 5 项 UI 用例通过。
- 签名 Debug、iOS Release 构建通过；JS 语法和 `git diff --check` 通过。
- 修复版 1.2.3（34）已保留数据覆盖安装到连接的 iPhone，并正常启动。安装、启动的 `devicectl` 结果均为 success；本轮交互自动化在独立模拟器进行，未记作 iPhone UI 验收。
- 此前键盘焦点、设置行对齐和视频返回修复保留，没有修改版本或商店文案。

## 结果与截图

- `/tmp/soulo-episode-sync-native.xcresult`
- `/tmp/soulo-episode-sync-history.xcresult`
- `/tmp/soulo-episode-sync-ui.xcresult`
- `/tmp/soulo-episode-sync-live-final.xcresult`
- [返回详情后再次打开选集](2026-10-19-episode-picker/picker-after-return.png)
- [片吧实站返回详情后的选集](2026-10-19-episode-picker/pbpbw-picker-after-return.png)
- [验证汇总](2026-10-19-episode-picker/validation-summary.json)

实站 UI 用例 `testLiveEpisodeDockOpensAfterReturningFromPlayback` 默认跳过。需要显式设置测试运行环境 `SOULO_LIVE_EPISODES_QA=1`；复制生成的 `.xctestrun` 到原 Products 目录，给 `SouloUITests` 的 `EnvironmentVariables` 与 `TestingEnvironmentVariables` 设置变量，再仅运行该用例。测试按实际排序按钮切回正序，避免先前倒序偏好使首集处于屏幕外。
