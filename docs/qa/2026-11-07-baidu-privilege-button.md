# 百度网盘按钮与网页导航策略调整

2026-11-07。当前采用用户最终确认的方案：移除导航层的按钮身份判断和广告跳转静默拦截，普通网页按自身行为导航，第三方跳转使用现有确认规则。此前的控件特征识别方案已经撤回。

## 原始问题

页面：`https://pan.baidu.com/wap/svip/privilege/freeget?na_immerse_theme=1&task_scene=reward_video_bidding_scene_hybrid_forward_download_speed&from=pc_acceleration`。

在专用 iPhone 17 / iOS 26.2 模拟器 `4EDA06FB-B649-4C6B-9F77-69D7D4A6D292` 中，取消页面加载时自动请求打开 bdwpin 的提示后，点击底部“开通SVIP 畅享98项特权”：

- 原先关闭过滤能进入 `snsyun.baidu.com/wap/snsdeeplink`。
- 原先开启过滤仍停在 `pan.baidu.com`。

按钮实际为通过事件监听器处理的 div，没有 href、按钮角色、内联 onclick 或手形光标。旧广告导航策略未认出控件，将跨站脚本跳转取消。

最初尝试过补充按钮 class、ARIA、键盘操作和尺寸等识别信号；用户最终选择兼容性优先，因此这些新增识别代码以及原有广告导航拒绝策略均已移除。旧验证产物保留于 `/tmp/soulo-baidu-freeget-qa/` 与 `/tmp/soulo-control-intent-qa-20261107/`，其中旧的 26 场景识别测试不是当前交付的判断规则。

## 最终行为

- 删除 `BrowserAdNavigationPolicy`，不再按照元素是否像按钮、是否来自播放器/背景等特征静默拒绝网页导航。
- `BrowserNavigationGesture` 不再读取控件 class、尺寸、光标、文字或 ARIA 来判断按钮身份。只保留真实交互、明确链接和标准表单目标的记录，供原有下载、媒体与新标签路由使用。
- 站内脚本、普通容器和脚本新窗口遵循网页本身行为。跨域确认继续遵循现有独立开关及目标域名白名单；主动输入地址、明确点击的链接与标准表单继续按既有规则处理。未知跨域脚本请求在确认开启时询问用户，取消后不发送目标请求，继续后恢复原始请求。
- 外部 App 唤起继续使用现有外部 App 确认设置。特殊下载 URI 和已知 App universal link 使用最近真实交互记录，不需要判断点击对象是不是按钮。
- 网络请求规则、订阅和广告元素隐藏仍独立生效。没有修改版本号、工程设置源文件、界面文案或商店元数据。删除源文件后已运行 `xcodegen generate` 更新本地生成工程。

## 新窗口交接

原先新窗口初始请求一律继承已放行状态。当前仅明确选定的目标继承放行；其他脚本新窗口保留打开方来源并执行跨域确认。初始 about:blank 保留来源，以便后续第三方导航仍可询问。

首轮确认专项中，当前页路径通过，新窗口路径有两项失败：首次 SwiftUI 挂载更换协调器，丢失初始来源和等待中的策略选择。通过一次性弱引用，让首次挂载接管内容控制器已持有的启动协调器，保留这次交接；释放运行环境时清理该引用。后续两项专项复测均通过。

继续使用 WebKit 创建的原始窗口、opener 与请求体。直接继续时保留 POST；用户显式选择“新标签打开”时，沿用产品原有的目标地址打开规则，不重复提交表单。

## 当前验证

产物目录：`/tmp/soulo-navigation-confirmation-20261107/`。构建和模拟器测试串行执行，使用 Debug、`ONLY_ACTIVE_ARCH=YES ARCHS=arm64`。

| 产物 | 结果 | 范围 |
| --- | --- | --- |
| `ConfirmationPolicy.xcresult` | 首轮 50 项通过，2 项新窗口确认失败；随后停止并修复 | 含真实百度页面、过滤规则、站内窗口、普通容器及导航策略 |
| `WindowConfirmation.xcresult` | 2 项通过，0 失败、0 跳过 | 普通 div/标准按钮/脚本新窗口的第三方确认；取消、继续、合成链接、about:blank 后跨站；取消后目标请求数为 0 |
| `FinalRegression.xcresult` | 59 项通过，0 失败、0 跳过 | 网络和元素过滤、域名设置、缺失 frame URL、特殊下载、外部 App 确认、嵌入式登录、原始 POST、站内窗口和搜索结果处理 |

真实百度用例显式启用 `TEST_RUNNER_SOULO_LIVE_BAIDU_PRIVILEGE_QA=1`，过滤关闭和开启均进入网盘唤起页。只验证唤起入口，未安装或打开百度网盘、未购买会员或领取广告奖励。

最终检查确认生产代码中不存在 `BrowserAdNavigationPolicy`、`controlResolver` 或 `isControl` 导航判断；`git diff --check` 通过。用户原有资料库、收藏、搜索历史、下载管理与 NativeInput 测试修改，以及网站审计文件均保留。
