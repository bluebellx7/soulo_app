# 悬浮播放器展开与进度拖动

2026-11-10，Soulo 1.2.11 (51)。本轮处理 Soulo 内的小播放器和展开后的播放页；没有将这些结果当作系统画中画窗口的交互验证。

## 问题与修复

1. 悬浮窗展开依赖页面的 `onAppear` / `onDisappear` 标记。资料库保留分页内容后，返回列表时这个标记可能没有恢复，第二次展开失败；下载、历史、书签内容也缺少本页的展开接收器。回归在修改前复现“第一次打开后，返回再打开仍停留在资料库”。
2. 改为通过实际窗口、导航栈顶控制器和视图归属判断是否可以展开，等待返回动画结束，只有当前分区消费一次请求。补齐下载、历史、书签入口，保留当前目录和导航栈。缩略图改为按钮，视频渲染视图不占用点击，点击区域至少 44 pt 高。
3. 旧进度条只能从小滑块开始拖动，从轨道其他位置拖动没有效果。现在统一处理开始、移动和结束，允许点轨道、从轨道开始拖动；扩大到 44 pt 高，松手提交一次跳转。拖动期间播放时钟更新不会覆盖预览位置；取消触摸后重新跟随播放时间。
4. 大文件复测发现，直接扩展系统滑块的默认跟踪仍可能漏掉结束事件，出现滑块移动但没有松手提交。最终使用 44 pt 控件上的单一手势接收开始、移动、结束和取消，保留内部原生 UISlider 的显示和可调辅助功能；物理触摸命中容器，原生滑块保持启用。用“跳转后继续播放、时间前进”验收，不能只看预览位置变化。

## 样本和覆盖

- 本地 H.264/AAC MP4 夹具，时长 8 秒。
- 从连接的 iPhone 只读复制其 MP4，579289130 字节、1361.5 秒，H.264 1920×804 / AAC。原文件未改动；使用通用名称复制到 QA 模拟器中验证。报告不包含原文件名和视频画面。
- 两种播放器均检查：打开文件、返回列表、点击小窗、打开播放页、从滑块和轨道分别拖动、点击轨道、跳转后继续播放、返回下载分区后再次展开。
- 原生回归覆盖资料库四分区重复展开、保留目录导航、取消拖动后的时钟恢复、拖动期间刷新时钟、松手只提交一次以及小播放器不能抢占主视频渲染层。

## 验证记录

- `baseline-library.xcresult`：修改前重复展开失败，符合复现预期。
- `timeline-diagnostic.xcresult`：轨道拖动失败，时间仍停留在原处，符合复现预期。
- `fixed-scrubbing.xcresult`：阶段性验证 4 项原生回归和 1 项双播放器界面回归通过；长片进一步复测暴露了不完整跟踪实现，最终以接管完整跟踪后的结果为准。
- `enabled-gesture-device.xcresult`：最终实现的 4 项原生回归和 1 项界面回归通过，0 失败。界面回归使用来自真机的 1361.5 秒 MP4，在系统和 Soulo 播放器分别完成点击、拖动、跳转后播放时间前进及再次展开，界面用例耗时 59.146 秒。
- `enabled-gesture-short.xcresult`：最终实现的 8 秒夹具双播放器界面回归通过，0 失败，耗时 68.109 秒。
- 辅助功能检查要求原生滑块保持 `isEnabled` 和 `isUserInteractionEnabled`；没有将它禁用以绕过触摸问题。尚未单独执行 VoiceOver 人工操作。
- `python3 scripts/check_localization.py --strict` 通过，沿用现有 50 语言文案。

构建和界面回归均使用 iPhone 17 / iOS 26.2 模拟器。真机 MP4 是输入样本，不等于在真机上执行过新构建的交互测试。原始日志、结果包和只读复制过程记录位于 `/tmp/soulo-mini-player-20261110/`，各次运行日志位于 `/tmp/soulo-mini-player-*-20261110.log`。本轮未更改版本号、商店元数据或原有下载文件。

短片的两种播放器截图已查看，进度条及下方控件布局正常。验证完成后已删除本轮创建的两份 579 MB 视频副本（本机临时文件、QA 模拟器副本），保留真机原文件和测试记录。

## 复跑

默认界面用例通过本地 HTTP 夹具创建一份唯一命名的 MP4，不依赖公网视频或登录。

```sh
xcodebuild test -project Soulo.xcodeproj -scheme Soulo \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=BECE20B7-B626-440B-A31E-797AB97487DF' \
  -parallel-testing-enabled NO \
  -only-testing:SouloUITests/DownloadPlaybackUITests/testMP4MiniPlayerReopensAndTimelineAcceptsFingerDraggingInBothPlayers \
  ONLY_ACTIVE_ARCH=YES ARCHS=arm64
```

已有文件用例要求先将测试副本放进该 QA 模拟器 Soulo 的 `Documents/Downloads`，再用 `TEST_RUNNER_SOULO_MINI_PLAYER_FILE` 指定副本文件名、`TEST_RUNNER_SOULO_MINI_PLAYER_DURATION` 指定实际时长秒数。它仍会测试系统与 Soulo 两种播放器。触摸验证使用实际点击、按下和拖动；不依赖 XCTest 归一化辅助调整对长片的精确定位。
