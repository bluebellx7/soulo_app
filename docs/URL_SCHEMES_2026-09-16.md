# Soulo URL Scheme

设置 → 关于与支持 → 隐私策略前面的「URL Scheme」。每条示例可复制，页面也说明参数编码和兼容简写。

| 功能 | 格式 |
| --- | --- |
| 启动并回到首页 | `soulo://` 或 `soulo://home` |
| 聚焦首页搜索框 | `soulo://search` |
| 搜索内容或打开地址 | `soulo://search?q=<编码后的文本>`，也接受 `text` / `query` |
| 打开网页 | `soulo://open?url=<编码后的 HTTP/HTTPS 网址>` |
| 新建下载并显示下载列表 | `soulo://download?url=<编码后的 HTTP/HTTPS 文件网址>` |
| 扫一扫 | `soulo://qrcode` 或 `soulo://scan` |
| 文件 | `soulo://files` |
| 收藏 | `soulo://bookmarks` |
| 搜索历史 | `soulo://history` |
| 下载列表 | `soulo://downloads` |

命令不区分大小写。保留 `soulo://bookshelf` 小组件入口，并接受 `soulo://Books` 别名，均打开现有文件页，不恢复独立书库。

简写兼容 `soulo://<搜索内容或网址>`、`soulo://search/<文本>` 和 `soulo://download/<HTTP/HTTPS 网址>`。带多个参数的网址推荐使用 `?url=` 编码形式。例如：

```text
https://example.com/?a=1&b=2
soulo://open?url=https%3A%2F%2Fexample.com%2F%3Fa%3D1%26b%3D2
```

参数只解码一次，保留内部网址的 `%2F`、中文编码、`+`、查询参数和片段。下载只接受 HTTP/HTTPS，沿用现有后台下载服务、失败状态和成功通知，不附带当前网页的 Cookie。需要登录的资源可能应先在浏览器中打开。

所有入口保留当前隐私模式。`soulo://action` 仍专用于既有快捷指令/分享扩展交接；外部文件 Open In 的处理保持在原入口。无效的 open/download 参数不创建网络请求。

## 验证

- 4 项解析测试通过：`/tmp/soulo-url-scheme-tests.xcresult`。覆盖大小写、别名、中文/空格/特殊字符、编码只处理一次、嵌套参数、简写及无效协议。
- 3 项模拟器 UI 测试通过：`/tmp/soulo-url-scheme-ui.xcresult`。覆盖冷启动和前台资料库切换、搜索框聚焦、设置说明及复制、从设置中调用扫一扫、网页实际加载和后台下载成功。
- 本地化严格检查、商店 JSON 一致性及 `git diff --check` 通过。版本保持 1.1.6 (24)。
- UI 回归源码：`docs/qa/URLSchemeUITests.swift`。本地测试服务器提供既有 `index.html` 和文本文件 `Soulo-Scheme-QA.txt`。
