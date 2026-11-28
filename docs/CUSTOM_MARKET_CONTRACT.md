# Soulo 自定义市场接口契约（六类作品完整版）

状态：实施稿。App、官网、管理后台和后端四端以此文件为准；字段、校验或错误码变更时先更新本文件。向后兼容第一阶段已部署的 `platform`（搜索平台）接口与数据。

## 1. 范围与分工

- **三端分工**：官网（`soulo.dkluge.com/custom-market.html`）负责逛市场、预览和拉起安装；App 负责创作、投稿、Apple 登录、我的投稿、原生确认安装与治理；管理后台（`soulo.dkluge.com/market-admin.html`）负责人工审核、模块展示开关、举报处理与已安装版本停用。
- **六类作品（`module`）**：
  - `home`：首页（HTML）
  - `newTab`：新标签页（HTML）
  - `widget`：小组件（JSON）
  - `platform`：搜索平台（JSON）
  - `script`：用户脚本（`.user.js` 源码）
  - `webExtension`：浏览器扩展（`manifest` + 源码文件集合）
- **展示开关**：`script` 与 `webExtension` 各自拥有独立的市场展示开关（默认开启，管理后台可按需隐藏）。
- **App 图标**：作为 App 内独立设置项，提供随 App 打包的多套内置风格，不进入市场。

## 2. 约定

| 项目 | 内容 |
| --- | --- |
| 生产地址 | `https://api2.dkluge.com/api/soulo/custom-market/v1` |
| 本地地址 | `http://localhost:<port>/api/soulo/custom-market/v1` |
| 数据格式 | JSON，UTF-8，字段名使用 camelCase，时间为 ISO 8601 UTC |
| 作品 ID | 小写 UUID v4，由服务端生成 |
| 版本号 | 每个作品内从 1 递增的整数，由服务端分配 |
| 响应格式 | 使用 `@SkipTransform` 与 `SouloApiErrorFilter`，返回真实 HTTP 状态码与 `{ "error": { "code", "message", "field"? } }` |
| 鉴权 | `Authorization: Bearer <token>`（现有账号体系令牌），`POST /api/auth/apple` 登录、`POST /api/user/refresh-token` 刷新 |
| 缓存 | 公开目录/详情返回 `ETag` 与 `Cache-Control: no-cache`；已上架版本预览图返回 `Cache-Control: public, max-age=31536000, immutable`；未上架版本预览图仅作者与管理员可访问且 `Cache-Control: private, no-store` |

## 3. 作品包格式（`soulo.custom.v1`）、大小上限与安全边界

所有作品包顶层字段固定为：

```json
{
  "schema": "soulo.custom.v1",
  "module": "home | newTab | widget | platform | script | webExtension",
  "minSouloVersion": "1.2.23",
  "<module>": { ... }
}
```

不允许出现未声明字段。

### 3.1 各类作品包大小上限与字段规则

| `module` | 包大小上限（UTF-8 JSON） | 载荷结构与校验规则 |
| --- | --- | --- |
| `platform` | **16 KB** | `{ "name": "1-40字", "homeURL": "可选 HTTPS 公开域名", "url": "HTTPS 公开域名，恰含一个 %@ 于路径或查询值" }`（与第一阶段完全一致） |
| `widget` | **8 KB** | `{ "version": 1, "title": "1-28字", "subtitle?": "≤60字", "palette": "wallpaper\|ink\|paper\|forest", "destination": "合法目标", "symbol?": "SF Symbol", "tapURL?": "HTTPS 公开域名", "shortcuts?": "≤3项", "feed?": { "url": "HTTPS 公开域名", "path": "≤12段", "fallback": "1-160字", "prefix?": "≤24字", "suffix?": "≤24字", "refreshMinutes?": "30-1440" } }` |
| `home` | **64 KB** | `{ "html": "单文件 HTML，UTF-8 ≤ 64 KB" }`。禁止 `<iframe>`、`<frame>`、`<object>`、`<embed>`、`<base>`、`<link>`、非白名单 `<meta>`、外链 `src`/`href` 远程脚本或样式、`@import` 远程资源。允许 `<meta name="soulo-home" content="wallpaper-and-search">`、`<meta name="soulo-zoom" content="disabled">`、`soulo-asset://` 内置图标与图片及内联 `data:` 图片。 |
| `newTab` | **64 KB** | `{ "html": "单文件 HTML，UTF-8 ≤ 64 KB" }`。同 `home` 规则，允许 `<meta name="soulo-wallpaper" content="current">` 与 `<meta name="soulo-zoom" content="disabled">`。 |
| `script` | **256 KB** | `{ "source": "完整 .user.js 源码，UTF-8 ≤ 256 KB" }`。须包含合法 `==UserScript==` 元数据块，必填 `@name` 与至少一条 `@match`（或 `@include`），可选 `@description`、`@namespace`、`@version`、`@run-at`、`@grant`、`@connect`。禁止 `@require` 远程脚本、禁止混淆代码与运行时加载远程代码。 |
| `webExtension` | **512 KB** | `{ "manifest": { "manifest_version": 2 \| 3, "name": "...", "version": "...", ... }, "files": { "<相对路径>": "<UTF-8 源码>" \| { "base64": "<PNG>" } } }`。最多 32 个文件，单文件 ≤ 128 KB，禁止路径穿越/隐藏文件/重复 `manifest.json`，禁止 `unsafe-eval` 与远程脚本 CSP，禁止混淆代码与运行时加载远程代码。 |

扩展中心提交的推荐使用 `webExtension: { "installURL": "https://…" }`。审核后台显示原始来源，Soulo 安装时从该来源下载并展示实际权限。支持符合格式的 Chrome、Edge、Firefox 商店详情地址和 Soulo 官网扩展 ZIP。现有的 `manifest` 与 `files` 包继续可用。

脚本推荐仍提交可审查源码，并可在 `script.sourceURL` 保存来源链接。同一作者再次推荐同一个原始链接时，在原作品下建立新版本。当前待审版本会被撤回，已经公开的版本会保留至新版本通过审核。

### 3.2 自定义首页与新标签页的 JavaScript 接口及网络权限边界

- **渲染隔离**：App 在非持久化 `WKWebView`（`WKWebsiteDataStore.nonPersistent()`）中渲染，强制注入 CSP：`default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data: soulo-asset:; base-uri 'none'; form-action 'none'`。
- **网络权限**：自定义首页与新标签页**禁止一切后台网络请求**（`fetch`、`XMLHttpRequest`、`WebSocket`、远程图片/字体/样式/脚本均被 CSP 阻断）。仅允许用户主动点击/回车后通过 `Soulo.open(url)` 或 `Soulo.search(query)` 跳转至浏览器正常页面。
- **允许的 JS 接口（`window.Soulo`，只读冻结）**：
  - `Soulo.getContext()`：读取接口版本、当前页面类型（`home` / `newTab`）、允许的原生动作、图标与内置图片名列表。
  - `Soulo.search(query)`：需可信用户手势（`event.isTrusted`，800 ms 内），触发 Soulo 搜索或打开网址。
  - `Soulo.open(url)`：需可信用户手势，仅允许 `http://` / `https://` 且无凭据的网址。
  - `Soulo.perform(action)`：需可信用户手势，仅允许白名单内的原生页面/工具动作；破坏性操作仍由原生页面二次确认。
  - `Soulo.icon(name)` / `Soulo.image(name)`：返回 `soulo-asset://symbol/<name>` 或白名单内的 `soulo-asset://image/<name>`。

### 3.3 预览图存储与校验规则

- **格式与尺寸**：投稿可附带 `previewImage`：`{ "mimeType": "image/jpeg" | "image/png" | "image/webp", "dataBase64": "..." }`。原始二进制 ≤ **200 KB**，通过文件头魔数验证真实格式（禁止 SVG），宽高均在 **64–1280 px** 之间。首页、新标签页、小组件在 App 发布流程中自动生成预览图。
- **存储与访问控制**：校验后的二进制与 MIME、SHA-256 随版本原子存入 PostgreSQL（`SouloMarketVersion`），由专用接口 `GET /works/{id}/versions/{version}/preview` 返回，并附带 `X-Content-Type-Options: nosniff` 与 `Content-Security-Policy: default-src 'none'; sandbox`。未上架版本预览图仅作者与管理员凭令牌可访问，杜绝待审素材外泄。

### 3.4 文件完整性校验（`packageSha256`）

- 服务端在投稿校验通过后，将规范化作品包按**键名递归升序排序、无多余空白的规范 JSON**序列化，计算 UTF-8 字节的 **SHA-256（64 位小写十六进制）**，记为 `packageSha256` 存入版本记录。
- 审核通过时重新校验作品包格式及哈希；公开读取 `GET /works/{id}` 或 `GET /works/{id}/versions/{version}/package` 时再次比对存储哈希，不匹配时拒绝提供并返回 500 `INTEGRITY_MISMATCH`。
- `GET /works/{id}` 返回 `package` 与 `packageSha256`；`GET /works/{id}/versions/{version}/package` 返回作品包并在响应头附带 `X-Soulo-Package-SHA256`。App 在展示与安装前独立用相同规范化规则重算 SHA-256，与 `packageSha256` 不一致时拒绝安装。

### 3.5 用户脚本与浏览器扩展源码可审查规则

投稿与审核均执行确定性源码检查，拒绝以下模式（422 `VALIDATION_FAILED`）：
- **运行时远程代码加载**：`eval(`、`new Function(`、`Function(`、字符串参数的 `setTimeout`/`setInterval`、`document.write(`、动态创建 `<script>` 并赋远程 `src`、`importScripts(`、动态 `import("http...")`、HTML 中的 `<script src="http...">`、用户脚本的外部 `@require`、扩展 CSP 中的 `unsafe-eval` 或远程脚本来源。
- **代码混淆**：`eval(function(p,a,c,k,e,`、`_0x[0-9a-f]{4,}` 标识符混淆、密集十六进制/Unicode 转义、超长压缩单行（单行 > 1500 字符，或 > 1 KB 文件平均行长 > 400 字符）、JS 文件内嵌 > 4 KB 连续 base64 数据块、JSFuck 模式。

## 4. 状态与三种管控动作的区别

版本状态 `status`：`pending`、`approved`、`rejected`、`withdrawn`、`superseded`、`unpublished`、`revoked`。

| 管控动作 | 接口 | 市场目录与新安装 | 已安装设备的表现 | 恢复方式 |
| --- | --- | --- | --- | --- |
| **市场隐藏**（模块级） | `PATCH /admin/settings`（`showScript` / `showWebExtension`） | 该分类从目录、配置及详情接口隐藏（404），不可新安装 | 已安装作品不受影响，继续正常运行 | 重新开启开关即刻恢复展示，无需重审 |
| **作品下架**（作品级） | `POST /admin/works/{workId}/unpublish` | 该作品状态改为 `unpublished`，移出目录并禁止新安装 | 已安装版本不受影响，继续保留 | 作者提交新版本通过审核后重新上架 |
| **已安装版本停用**（版本级） | `POST /admin/works/{workId}/versions/{version}/revoke` | 该版本状态改为 `revoked`（若为当前上架版本则同步清零 `published_version`），禁止安装 | App 同步停用状态后自动停用对应已安装作品并告知原因 | 作者修复并提交新版本审核通过后，用户可重新安装/更新 |

## 5. 接口清单

### 5.1 公开接口（免登录；可选携带 Bearer 令牌以自动过滤已屏蔽作者）

- `GET /config`
  - 返回当前市场可见模块配置：`{ "visibleModules": ["home","newTab","widget","platform","script","webExtension"], "toggles": { "script": true, "webExtension": true } }`。
- `GET /works?module=<all|六类之一>&q=<关键词>&sort=<newest|updated|name>&cursor=<游标>&limit=<1-60>`
  - `module` 缺省或 `all` 时返回所有可见模块的已上架作品；若指定了被隐藏的模块（如 `script` 已隐藏），返回空列表。
  - 返回 `{ "items": [WorkSummary], "nextCursor": string | null, "visibleModules": [...] }`。
  - `WorkSummary` 字段：
    ```json
    {
      "id": "uuid",
      "module": "home",
      "name": "…",
      "summary": "…",
      "authorName": "…",
      "authorRef": "opaque-id-or-null",
      "version": 1,
      "minSouloVersion": "1.2.23",
      "host": "zh.wikipedia.org",
      "hasScript": false,
      "permissions": [],
      "sites": [],
      "contentRating": "everyone",
      "packageSha256": "64-hex",
      "packageBytes": 1234,
      "previewImageUrl": "https://.../works/{id}/versions/1/preview?v=...",
      "publishedAt": "2026-11-28T00:00:00.000Z",
      "installUrl": "soulo://custom-market/work/{id}?version=1",
      "universalUrl": "https://soulo.dkluge.com/custom-market/work/{id}"
    }
    ```
- `GET /works/{id}`
  - 已上架且所属模块未隐藏时返回 `{ ...WorkSummary, "package": {...} }`。
  - 若最新已停用版本存在且无上架版本，返回 410 `VERSION_REVOKED`（附带 `reason`）；其他未上架或模块隐藏返回 404 `NOT_FOUND`。
- `GET /works/{id}/versions/{version}/package`
  - 已上架版本公开可取（若模块被隐藏则返回 404）；待审/退回/已下架/已停用版本仅作者本人与管理员可取。响应头附 `X-Soulo-Package-SHA256`。
- `GET /works/{id}/versions/{version}/preview`
  - 返回预览图二进制，权限规则同 `/package`。
- `POST /works/status`
  - 批量查询已安装版本的状态（用于已安装版本停用同步与更新提示），请求 `{ "items": [{ "workId": "uuid", "version": 1 }] }`（最多 100 项）。
  - 返回 `{ "items": [{ "workId", "version", "status", "revoked": boolean, "revokedReason": string | null, "latestPublishedVersion": number | null }] }`。
- `POST /works/{id}/reports`
  - 举报作品（支持匿名与登录用户，按 IP/用户限流）。请求 `{ "version?": 1, "category": "malicious|copyright|inappropriate|broken|spam|other", "detail": "5-1000字", "contact?": "≤200字" }`。成功返回 201 `{ "id": 12, "status": "open" }`。

### 5.2 作者与用户接口（需登录）

- `POST /submissions`
  - 请求 `{ "workId?": "uuid", "replacesPendingVersion?": 2, "name", "summary?", "authorName", "contentRating?": "everyone|teen", "previewImage?": { "mimeType", "dataBase64" }, "package": { ... } }`。
  - 更新已有 `workId` 时必须保持 `module` 一致（否则 422 `MODULE_MISMATCH`）。
  - 编辑待审稿时一并传入当前的 `replacesPendingVersion`。服务器在同一事务中撤回旧待审稿并创建下一版本，当前上架版本继续提供安装。待审版本已变化时返回 409 `NOT_PENDING`，已有待审稿且没有指定要替换的版本时返回 409 `PENDING_EXISTS`。
  - 24 小时内每账号最多提交 10 次（防滥用，超出 429 `RATE_LIMITED`；第一阶段单测可按配置覆盖）。
  - 返回 201 `{ "workId", "module", "version", "status": "pending", "packageSha256" }`。
- `GET /me/submissions`
  - 返回当前账号全部作品与版本（含 `module`、`publishedVersion`、`versions[]` 中含 `summary`、`authorName`、`contentRating`、`hasScript`、`rejectReason`、`revokedReason`、`previewImageUrl`、`packageSha256`）。
- `POST /me/submissions/{workId}/versions/{version}/withdraw`
  - 撤回待审版本。
- `GET /me/blocked-authors`、`POST /me/blocked-authors`（`{ "workId?" / "authorRef?" }`）、`DELETE /me/blocked-authors/{authorRef}`
  - 管理当前账号屏蔽的作者列表。

### 5.3 管理员接口（需 `ADMIN`）

- `GET /admin/settings`、`PATCH /admin/settings`（`{ "showScript?": boolean, "showWebExtension?": boolean }`）
- `GET /admin/reviews?status=pending|approved|rejected|unpublished|revoked&module=all|...&q=&cursor=&limit=`
- `GET /admin/reviews/{workId}/versions/{version}`（包含 `module`、`hasScript`、`permissions`、`sites`、`contentRating`、`packageSha256`、`packageBytes`、`previewImageUrl`、`package`、`checks`、`published`、`changedFields`、`history`、`openReportsCount`）
- `POST /admin/reviews/{workId}/versions/{version}/approve`（`{ "note?": "...", "contentRating?": "everyone|teen" }`）
- `POST /admin/reviews/{workId}/versions/{version}/reject`（`{ "reason": "1-500字" }`）
- `POST /admin/works/{workId}/unpublish`（`{ "reason": "1-500字" }`）
- `POST /admin/works/{workId}/versions/{version}/revoke`（`{ "reason": "1-500字" }`，停用指定已安装版本）
- `GET /admin/reports?status=open|resolved|dismissed&cursor=&limit=`
- `POST /admin/reports/{reportId}/resolve`（`{ "action": "dismiss|unpublish|revoke", "note": "1-500字" }`）

## 6. 安装链接与 Universal Link

- Custom URL Scheme：`soulo://custom-market/work/{workId}?version={n}`
- Universal Link：`https://soulo.dkluge.com/custom-market/work/{workId}`
  - 官网部署 `/.well-known/apple-app-site-association`（AppID `7S2LBJA9VA.com.dkluge.Soulo`，路径 `/custom-market/work/*`）。
  - App Entitlements 配置 `com.apple.developer.associated-domains` = `applinks:soulo.dkluge.com`。
  - Soulo 内置浏览器点击 `soulo://custom-market/work/{workId}` 或 `https://soulo.dkluge.com/custom-market/work/{workId}` 直接弹出原生确认 sheet；外部浏览器点击可经 Universal Link 或 `soulo://` 拉起 Soulo 原生确认页。

## 7. Apple 审核合规核对要点

1. **用户生成内容（Guideline 1.2）**：全量人工先审后发；官网与 App 均提供举报入口（`POST /works/{id}/reports`）、屏蔽作者（`/me/blocked-authors` + 本地屏蔽）、内容分级标识（`everyone`/`teen`），且管理员可即时下架或停用违规版本。
2. **可下载代码与脚本/扩展（Guideline 2.5.2 / 4.7）**：
   - 自定义首页与新标签页在非持久化、零网络权限 CSP 沙盒 WebView 内渲染，原生桥接仅限白名单动作且必须由用户手势触发。
   - 用户脚本与浏览器扩展运行于 Soulo 浏览器网页扩展能力之上，市场强制可审查明文源码、静态阻断混淆与运行时远程加载，且**脚本与扩展各自设有服务端独立隐藏开关**，可根据审核策略随时开关展示。
   - 具备已安装版本远程停用机制，可阻断已发现恶意版本在客户端继续运行。
3. **Sign in with Apple（Guideline 4.8 / 5.1.1）**：浏览和安装免登录；投稿与个人进度支持 Sign in with Apple；账号注销时撤销 Apple 授权（TN3194）待配置 Sign in with Apple 私钥后在正式发版前补齐。
