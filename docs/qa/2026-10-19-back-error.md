# 返回后误显示加载失败修复

## 可重复的失败路径

1. 生产 WebView 加载表单页，再加载带有未完成资源的页面，返回表单页后，控制时序投递旧 `WKNavigation` 的超时回调。原错误处理没有区分导航对象，已恢复的网页被旧错误覆盖。修复前测试失败，错误信息为连接超时。
2. 网页通过 `pushState` 增加同网址状态，访问测试服务端主动断开连接的地址，出现真实加载错误。点击返回会恢复原网页的同文档状态，这种历史操作没有新文档导航开始事件，原错误一直保留。修复前测试失败，错误信息为网络连接已中断。

修复前结果包：`/tmp/soulo-back-failure-baseline.xcresult`，两项测试均失败。

## 修改

- 导航代理跟踪最近的 `WKNavigation` 及完成状态。提交、完成和错误回调只更新对应的 WebView 和当前有效导航，忽略旧请求及已完成导航的迟到回调。
- 页面开始、提交和完成时同步清理旧错误；错误展示也在回调中同步执行，避免排队的错误状态晚于页面恢复生效。
- 原有异步提交、完成处理增加导航代次和 WebView 校验，防止旧任务覆盖新页面状态。
- 原生返回和前进立即清理旧错误，并将地址恢复到实际文档，再执行 WebKit 历史操作。保留正常历史、前进和 iframe 返回逻辑。
- 允许新代理接手正在加载的保留 WebView；独立回归确认换代理后页面仍能结束加载。
- 真正属于当前请求的网络错误仍正常显示，没有忽略超时、TLS 或断网等有效错误，也没有增加网页脚本或常驻重试。

## 验证

- 常规回归运行 167 项，166 项通过，1 项实站检查按条件跳过；覆盖浏览导航、选集、错误分类和 WebViewModel。
- 另外通过换代理接手加载的回归，以及显式启用的 pbkan 真实视频页返回检查。不同原生用例共 168 项通过；真实页面返回后额外检查 `errorMessage == nil`。
- 界面验证涵盖真实连接中断后点击返回、同文档前进、iframe 播放器一次返回、返回详情后重新打开选集、播放器返回与前进后打开选集。
- iOS Release 和签名 Debug 构建通过，版本保持 1.2.3（34）；`git diff --check` 通过。
- 此前键盘焦点、设置行对齐及选集修复保留，没有改动版本和商店元数据。
- 本次设备查询显示 iPhone 的 CoreDevice tunnel 为 unavailable，无法读取真机状态。本轮交互在独立模拟器运行，签名包尚未覆盖安装到 iPhone。

## 结果包

- `/tmp/soulo-back-failure-fixed.xcresult`
- `/tmp/soulo-back-failure-interaction.xcresult`：换代理及旧回调检查、播放器返回和两个选集回归通过；新界面用例首次在初始网页尚未出现时超过等待时间，随后增加初始页面就绪等待并单独通过。
- `/tmp/soulo-back-failure-live.xcresult`：显式启用实站检查及失败页返回界面检查。
- `/tmp/soulo-final-episode-live.xcresult`：最终构建上的片吧选集实站检查通过（30.724 秒）。上一实站包中该 UI 用例在初始网页尚未出现时超过等待时间，未记作通过；最终验证及新增下载、网格功能见 [后续验证](2026-10-19-downloads-and-tab-grid.md)。

实站检查通过同目录复制的 `.xctestrun` 启用：`SouloTests` 设置 `SOULO_LIVE_HISTORY_QA=1`，`SouloUITests` 设置 `SOULO_LIVE_EPISODES_QA=1`；两者均写入 `EnvironmentVariables` 和 `TestingEnvironmentVariables`。没有修改工程的常规测试环境。
