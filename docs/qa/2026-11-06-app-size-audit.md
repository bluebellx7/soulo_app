# 1.2.10 安装包体积检查

本次先完成通用图片推广过滤、快捷菜单说明和插画，再检查包含这些改动的同一份代码。所有体积均为本地未签名 arm64 Release 归档内 `.app` 的文件大小总和，不是整个 `.xcarchive`，也不是 App Store 最终下载大小。

## 检查结果与最终决策

当前配置下为 **79,623,091 字节，约 79.6 MB**。主要部分为：

| 内容 | 字节数 |
| --- | ---: |
| MobileVLCKit 核心 | 36,348,088 |
| 主程序 | 26,598,008 |
| Assets.car | 10,498,440 |

播放器核心已只打包设备 arm64 版本，没有把模拟器架构放进 App。框架的开发头文件、静态库、源码、测试截图、日志和 dSYM 不在 App 内。图片已由 Asset Catalog 使用 deepmap2/LZFSE 等格式压缩，语言表已经是二进制 plist；原始 1.5 MB 跟踪数据以约 192 KB 的 LZFSE 文件打包。没有通过删除语言、插画、媒体格式或功能来减小体积。

试验过仅为主 App 的 Release 配置设置 `SWIFT_OPTIMIZATION_LEVEL = -Osize`。它使用标准 Swift 编译器体积优化，保留整模块优化和运行时独占访问检查，没有使用 `-Ounchecked`。依据见 [Xcode 构建设置](https://developer.apple.com/documentation/xcode/build-settings-reference) 和 [Swift 编译器说明](https://www.swift.org/blog/osize/)。

候选包为 78,455,613 字节，减少 **1,167,478 字节，约 1.47%**。包内文件没有增删；播放器二进制、所有图片和本地化表保持一致。6 个 App Intents 声明也保持一致（只对 `resolvableInputTypes` 联合类型的顺序做归一化比较，没有忽略参数顺序）。

**本轮不保留这个编译配置调整。** 收益较小，而候选 Release 的视频 UI 回归持续等待 XCTest 的动画完成通知，未完成同等的验证。没有据此断定产品发生视频卡顿，也没有把这轮运行记为通过。遵循用户优先保持稳定的要求，`project.yml` 已精确恢复到体积检查前的内容，并重新生成 Xcode 工程；没有修改任何原有工程设置。最终保留已有 Release 配置及已经完成的广告、设置和插画改动。

## 验证记录与限制

原配置与候选配置的设备 Release 归档均成功。主 App 和两个扩展版本都是 1.2.10 (51)，设备二进制为 arm64，dSYM UUID 对应，5 份隐私清单可读取。

两种编译配置都进行了模拟器启动及首页菜单点击检查，每组 5 次计量，另含预热：

- 原配置样本为 1.74、4.56、1.84、38.44、2.00 秒。38.44 秒异常发生在启动请求到进程初始化日志及自动化会话建立之间，不能据此断定是首页渲染问题；没有足够证据归因于具体系统或产品组件。
- 候选配置为 1.71、1.69、1.66、1.67、1.69 秒，每次均能点击首页菜单。

原配置波动较大，样本也有限，不能用平均值宣称性能提高，更不能代替真机冷启动验证。没有为测量添加生产日志、计时轮询或常驻服务；临时性能测试代码已从项目源文件恢复，原始测试代码保留在本地 QA 目录。

候选配置的 `ReleaseCoreRegression.xcresult` 是主动中止的运行，不是整组通过：50 个本地功能用例及首页搜索 UI 用例已通过，一个实站用例未加载出页面内容，视频 UI 用例仍在等待动画通知。实站加载问题另做不启用过滤的原生 WebKit 对照，见图片推广与设置说明验收记录。

所有原始数据在 `/tmp/soulo-app-size-20261106/`：`baseline-app-size.json`、`optimized-app-size.json`、`size-comparison.json`、`app-intents-equivalence.json`、`optimized-archive-audit.json`、`launch-comparison.json`、两份设备归档及对应 xcresult。候选归档仅用于比较，不是最终配置的提交包；原配置归档为 `SizeBaseline.xcarchive`。

恢复原配置后的最终检查：`RestoredReleaseControl.xcresult` 39 项通过，`RestoredReleaseFiltering.xcresult` 2 项通过，均为 0 失败、0 跳过。实站关闭过滤与开启过滤的原生 WebKit 对照均能提交导航并加载内容；开启过滤时推广隐藏且 7 个正常导航图保留，新标签页入口也通过。先前一次未加载的原因未确定，未归因于编译优化。本次原配置重新验证通过，体积候选调整仍不保留。
