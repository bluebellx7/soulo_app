# 跟踪规则无损压缩检查（2026-11-02）

## 结果与范围

保留原始 `Soulo/Source/Resources/trackerData.json`，构建时生成 `trackerData.lzfse`。完整 JSON 的所有字节、1053 个域名及分类信息均保留，主 App 只打包压缩文件。原始 JSON 仅进入测试 bundle，供独立逐字节和分类对照使用。

| 项目 | 修改前 | 修改后 |
| --- | ---: | ---: |
| 跟踪资源 | 1,575,296 字节 | 192,327 字节 |
| 本地 Release `.app` 全部文件大小之和 | 74,611,019 字节（71.1546 MiB） | 73,228,168 字节（69.8358 MiB） |

资源减少 1,382,969 字节；整个 `.app` 净减少 1,382,851 字节，约 1.32 MiB。主可执行文件仅增加 144 字节；签名及系统生成的 App Intents 文件也有少量大小变化。未修改版本号、商店文案、解码格式、语言和图像资源。

这些是本地未压缩构建产物的文件大小，不是 App Store 下载大小。原始 JSON 本来就能被 IPA 的 ZIP 压缩；用 zlib 默认 DEFLATE 单独估算该资源为 189,585 → 192,393 字节，说明下载体积基本不会获得同等减量。实际商店下载大小应以 App Store Connect 的报告为准。

## 实现

- `scripts/package_tracker_data.py` 使用 macOS 系统 libcompression 的 LZFSE 编码；每次写入前解压并逐字节验证。文件头包含原始长度与 SHA-256。增量构建中会清理旧 `.app` 内的原始 JSON，避免重复打包。
- `project.yml` 排除主 App 原始 JSON，加入压缩构建步骤与明确的输入、输出文件；已按项目方式重新生成 Xcode 工程。
- `TrackerRadarResource` 使用 Apple Compression、CryptoKit 解码与校验，拒绝损坏、截断和超过 16 MiB 的资源。保留旧资源及原始数据测试 bundle 的读取兼容。
- 共享 `TrackerRadarService` 初始化时读取解压，之后使用原有内存映射；未改变请求分类逻辑，网页每次请求不会重复解压。

## 验证

- `TrackerRadarServiceTests`、`PrivacyProtectionServiceTests`、`PrivacyNavigationServiceTests`、`AdBlockServiceTests`、`AdBlockStartupCacheTests`：46 项测试全部通过。
- 原始 JSON 与实际打包资源解压结果逐字节一致；全部 1053 个域名在保护开启、关闭两种状态下，对照分类、归属、类别和 prevalence 均一致。
- 验证错误文件头、错误校验和、错误长度、超限长度、截断数据被拒绝，以及非零起点的 `Data` 切片正确解码。
- 初始化解压探针执行 10 次，中位数 1.435708 ms（本机 iPhone 模拟器 Debug，仅供开销参考，不代表真机耗时）。
- 构建脚本的完整往返、损坏校验、旧生成资源清理检查通过，源 JSON SHA-256 保持 `0b2c37fefac5e907fbf88c7d492f11d91be6e548c850371cced80b86bf881b20`。
- Release 构建成功；实际 `.app` 压缩资源通过 `--check`，无原始 `trackerData.json`、无测试 bundle，`codesign --verify --deep --strict` 通过。
- `python3 scripts/check_localization.py --strict`：894 个键 × 50 种语言通过；`python3 scripts/export_metadata_json.py --check`：50 个商店语言通过。
- 原有已暂存修改的补丁哈希保持不变。本次没有提交、推送、上传或安装到真机，测试结束已关闭本任务使用的模拟器。

构建和测试日志保存在 `/tmp/soulo-tracker-compression-20261102/`，包含 `TrackerFinal.xcresult`、`final-tests.log`、`release-build.log`、前后文件大小列表和本任务源文件差异。

## 其他减包空间与 VLC

当前 VLC 播放器对象在需要扩展解码时才创建，但原生框架仍随 App 打包；不能靠按需初始化减少安装包。App Store 常规分发也不能在首次播放时下载 VLC 原生代码来增加解码功能，见 [Apple 审核指南 2.5.2](https://developer.apple.com/app-store/review/guidelines/#software-requirements)。

已检查的其他资源没有数 MiB 级重复文件。大部分 `.strings` 已编译为二进制；三个插图合计约 2.58 MiB，但调整像素尺寸需要另行视觉检查，不属于本次无损压缩。较大体积仍集中在 VLC 和其他原生库，可评估保留全部功能的编译优化；BT 引擎已使用 `MinSizeRel`，进一步收益需要实际构建验证。
