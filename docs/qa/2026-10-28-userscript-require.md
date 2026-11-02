# 用户反馈 #37：UserScript 外部依赖

## 问题与处理

1.2.5（51）此前能解析、保存 `@require` 声明，但不会下载或执行依赖，正文使用依赖中的变量时会触发 `ReferenceError`。

- 网页安装、本地导入和编辑保存均先准备依赖，全部成功后再保存脚本。失败会显示依赖地址和原因，保留原有代码、开关与 GM 存储。
- 依赖按声明顺序在正文前执行，和正文共享作用域；文件之间添加换行与分号，避免末尾注释影响下一文件。依赖未准备完成时不执行正文。
- 依赖源码随脚本持久化，网页导航不再请求 CDN；编辑复用未变更的依赖，重新安装会重新下载。删除或移除声明时一并移除相应缓存。
- 启动时重新读取旧脚本的依赖声明，自动补载已开启脚本的缺失依赖。下载失败会停用该脚本并显示原因，再次开启可重试；原本关闭的脚本在开启时补载。
- 下载使用无共享 Cookie、无共享凭据的独立会话。依赖通过 HTTPS 获取，旧 HTTP 地址升级为 HTTPS；相对路径以脚本下载地址解析，本地文件没有来源地址时需使用绝对地址。不依赖 `@connect`，不改变正文网络 API 的权限。
- 限制为 32 个依赖、单文件 5 MiB、合计 20 MiB；拒绝非成功响应、HTML、非 UTF-8、超限内容以及不支持的协议。
- 支持 URL 片段中的 MD5、SHA-1、SHA-256、SHA-384、SHA-512 校验，兼容十六进制、Base64、`=` / `-` 分隔及多校验值。不支持 `tampermonkey://` 内置库地址。
- 更新全部 50 个运行时语言及英语回退、旧语言别名的相关提示和错误文案。版本号与 App Store 文案保持本次修改前的状态。

## 验证

- `UserScriptRequirementsTests`：下载、相对路径、BOM、离线缓存、顺序与作用域、两种 WKWebView 注入时机、完整性与大小限制、导入、失败回滚、旧存储迁移、启停和删除。
- 同时运行 `ExtensionLifecycleTests` 及原有 15 项 UserScript 回归测试。
- 最终共 31 项测试全部通过，0 失败，包含真实 iOS WKWebView 执行。
- 结果包：`/tmp/soulo-require-final-tests.xcresult`。
- 额外使用原始下载器与执行代码验证真实 CDN：jQuery 3.7.1（87,533 字节）下载及 SHA-256 校验通过；Day.js 1.11.13 与 UTC 插件在 JavaScriptCore 中执行，日期结果符合预期。日志：`/tmp/soulo-require-real-cdn.log`。
- `python3 scripts/check_localization.py --strict` 通过：881 个键、50 个语言。
- `python3 scripts/export_metadata_json.py --check` 通过；`git diff --check` 通过。

## 参考

- [Tampermonkey：@require 与完整性校验](https://www.tampermonkey.net/documentation.php#meta:require)
- [Apple：WebView 的 ATS 例外不适用于 URLSession](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowsarbitraryloadsinwebcontent)
