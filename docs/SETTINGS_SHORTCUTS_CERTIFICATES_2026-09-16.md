# 设置、桌面快捷操作与站点证书

## 界面

- 收藏菜单简化为“导入 / 导出”（英文 Import / Export）；导出范围仍为全部收藏。AGENTS.md 增加后续菜单用语保持简短的约定。
- 设置“同步”分组改为“其它”，保留 iCloud 同步，下方加入“长按快捷操作”。
- 版本行改为带箭头的详情入口；隐私政策、开源许可、服务条款移入。版本页使用已有 Soulo Logo，增加浅色模式的对比和边界，保留名称、版本及 build。
- 版本、快捷操作和证书页的图标复用设置页 IconBadge：中性灰图标、圆角底色、浅边框，适应深浅外观。

## 桌面快捷操作

- 可从搜索、扫一扫、隐私标签页、清除缓存、文件、收藏、下载、搜索历史中选最多 4 项。
- 已选项可移除、拖动排序；有空位时可从“更多操作”添加，支持还原默认组合。
- 允许不选任何应用快捷操作；无效旧配置回到默认，重复项和超出上限的项会被规范化。
- UserDefaults 本机持久化，更新 `UIApplication.shortcutItems`，重启/回到前台时重新注册。
- 文件、收藏、下载、历史入口复用资料库导航；新增功能不通过 Safari 打开。
- iOS 自带的编辑主屏幕、移除 App 等选项不属于应用可配置项。

## 证书与复制

- 锁面板 → 连接安全 → 查看证书。读取当前 WKWebView 的 `serverTrust`，检查页面来源匹配，展示实际证书链。
- 显示颁发对象、颁发者、生效/到期日期、序列号、公钥、SAN 域名/IP、SHA-256 指纹；支持指纹复制。
- 无证书时明确提示等待加载或刷新，不额外请求其它服务器、不显示其它站点证书；HTTP 不提供此入口。
- DER 解析仅用于展示，保留 WebKit 默认验证，不增加信任例外。输入限制 1 MB/证书，最多展示 16 张证书。
- 地址文本和复制按钮垂直居中；文本最多三行，但复制始终使用完整 URL；点击显示短暂完成反馈。

## 验证

- `/tmp/soulo-shortcut-choice-tests.xcresult`：5 项通过。覆盖配置默认值、去重/无效值/空选择、4 项限制、新入口映射、持久化及系统注册；证书主题、颁发者、UTC/Generalized 时间、DNS/IPv4/IPv6、公钥和 OpenSSL 指纹对照；异常 DER 和不覆盖系统信任。
- `SouloTests/ReadingFixtures/site-certificate.der` 是自签名测试证书，无私钥，仅属于测试 target；解析它不会赋予信任。
- `/tmp/soulo-settings-final-ui.xcresult` 的 `testLiveCertificateAndCopyAlignment` 通过：在 Apple 的 HTTPS 页面查看真实证书并复制地址。
- 初次真实网页测试遇到 PAC 查询超时。系统日志显示 `nw_pac_timeout_callback` 在 60 秒后直连；调整测试等待时间后通过。未修改用户系统代理或 App 的网络/证书验证策略。
- `/tmp/soulo-custom-actions-hitarea-ui.xcresult`：版本入口、Logo、法律页面、拖动排序、还原、移除/添加操作、桌面长按菜单及“文件”跳转均通过（91 秒）。测试结束已还原默认快捷操作。
- `/tmp/soulo-shortcut-custom-final-ui.xcresult` 的深色外观检查通过；浅色版本页、快捷操作页截图已目视检查。
- UI 复测修复了新增行空白区域不能点击，以及项目跨分组后排序状态可能沿用的问题：新增行使用完整矩形命中区域，已选项明确允许移动。
- `/tmp/soulo-shortcut-hitarea-build.log` 构建通过，已安装模拟器；`git diff --check` 通过。
- 严格本地化与商店元数据生成一致性检查通过。版本仍为 1.1.6 (24)。

API 依据：[Apple 快捷操作顺序](https://developer.apple.com/documentation/uikit/uiapplication/shortcutitems)、[WKWebView serverTrust](https://developer.apple.com/documentation/webkit/wkwebview/servertrust)。

## 连接详情紧凑布局

- 标题与协议/端口合并为一行；展开间距 12 → 4 pt，上下内边距 14 → 8 pt。标题过长单行省略，链接仍可复制完整内容。
- 证书和复制入口均保留 44 pt 点击区域，收起状态保持原有布局。
- 相同模拟器、相同 Apple HTTPS 页面截图对比：完整卡片约 680 → 506 px（减少 26%），分隔线以下详情约 516 → 375 px（减少 27%）。
- `/tmp/soulo-compact-security-build2.log` 构建通过；`/tmp/soulo-compact-security-ui.xcresult` 真实证书打开、复制反馈检查通过，已目视复核截图。
