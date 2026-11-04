# Soulo 静态网站

生产地址：https://soulo.dkluge.com/ 。此目录由现有 Nginx 静态托管，日常发布使用 `bash website/upload.sh`。Git push 与网站部署是两个独立步骤。

## 页面与设计

- `index.html`：产品首页，导航包含搜索源、影视导航、磁力搜索、网盘搜索、阅读导航、音乐资源与在线工具；支持中英文切换。
- `sources.html`：85 个搜索模板、9 个分类，支持分类筛选、搜索及单项 / 分类 / 当前结果复制。
- `movies.html`：85 个影视网站、10 个分类，支持筛选、搜索和浏览器本地收藏。
- `magnets.html`：34 个磁力搜索网站、4 个分类，支持筛选、搜索和浏览器本地收藏。
- `pans.html`：28 个网盘搜索网站、4 个分类，支持筛选、搜索和浏览器本地收藏。
- `reading.html`：iBooks、SoBooks 等 10 个电子书资源、找书搜索与阅读工具；支持搜索、分类和本地收藏。
- `music.html`：歌曲搜索、无损资源、数字专辑与配乐音效，共 8 个入口；支持搜索、分类和本地收藏。
- `privacy.html`：App 隐私政策。

配色使用冷白 `#f6f7fb`、雾灰、墨色 `#242532` 与紫色 `#6957bc`；深色页面使用中性黑 `#111217`、灰紫表面与浅紫文字。正文使用 Avenir Next / 苹方，目录保留明确的文字层级和紧凑的网站卡片。站点图标以本地 PNG 提供，图标后方叠加同源图片的模糊背景，悬停或键盘聚焦时轻微展开，效果限制在卡片内部；缺少图标时显示文字标记；目录页没有外部字体、前端框架或运行时目录数据请求。

`favicon.svg` 内嵌原 App 图标的缩小版本，通过 SVG clipPath 形成透明圆角。八个页面均加载百度统计代码。

## 更新目录

影视、磁力与网盘目录源数据分别在 `website/movies.json`、`website/magnets.json` 与 `website/pans.json`，页面模板在 `scripts/templates/movies.html`、`scripts/templates/magnets.html` 与 `scripts/templates/pans.html`。新增网站时维护唯一 ID、名称、HTTPS 地址、分类、用途简介、标签与图标文字；可选的 `icon` 指向 `images/movie-icons/`、`images/magnet-icons/` 或 `images/pan-icons/` 下的本地 PNG。`updated` 是整理日期，不能解释为全部站点的可用性保证。

搜索源数据在 `website/sources.json`，页面模板在 `scripts/templates/sources.html`，样式和交互分别在 `sources.css` 与 `sources.js`。生成器将目录及客户端数据直接写入 HTML；页面 JavaScript 只负责筛选和复制，不发起数据或图标字体请求。复制成功后保留浏览位置，配置预览按需展开；剪贴板不可用时展开预览供手动复制。

所有页面的顶部导航统一使用 `scripts/templates/navigation.html` 和 `website/navigation.css`。由生成器填入当前页面状态，品牌、菜单、语言与主题控件以及响应式尺寸与首页一致。全站支持中英文切换。修改公共导航后运行生成器，将八个页面一并提交。

```sh
python3 scripts/build_website.py
python3 scripts/build_website.py --check
python3 scripts/check_website.py
```

生成文件 `movies.html`、`magnets.html`、`pans.html`、`reading.html`、`music.html` 和 `sources.html` 随源文件一并提交。分类、名称、简介、链接和结构化数据在原始 HTML 中存在，不依赖 JavaScript 执行。禁用 JavaScript 时隐藏收藏和筛选控件，目录链接仍可使用。

## SEO 与 AI 搜索

八个页面具有独立标题、描述、canonical、Open Graph、Twitter 元数据、图标和 JSON-LD。首页描述 WebSite、Organization 与 SoftwareApplication；目录采用 CollectionPage、ItemList 和 BreadcrumbList；隐私页采用 WebPage 与 BreadcrumbList。结构化数据与实际页面内容对应，不添加虚构评分、价格或视频条目。

`sitemap.xml` 包含八个公开页面与真实编辑日期，`robots.txt` 提供站点地图入口并允许既有搜索和 AI 爬虫。`llms.txt` 与 `llms-full.txt` 提供页面链接、产品事实、目录用途与边界；它们是便于读取的补充资料，不是搜索收录所需的特殊协议。摘要区分 App 隐私政策和官网百度统计，避免沿用旧摘要中“官网无分析服务”等不准确表述。

首页中英文共用一个 canonical URL，因此没有伪造相同 URL 的语言替代页面。新增独立英文 URL 后再维护双向 hreflang 与站点地图。

实施依据：

- [Google：AI features and your website](https://developers.google.com/search/docs/appearance/ai-features)：AI 搜索继续遵循可抓取、可索引、实用内容等 SEO 基础。
- [Google：Sitemap overview](https://developers.google.com/search/docs/crawling-indexing/sitemaps/overview)。
- [Google：Introduction to structured data](https://developers.google.com/search/docs/appearance/structured-data/intro-structured-data)。

部署脚本会检查新页面、CSS、JS、SVG、站点地图和摘要的公网 MIME 类型。部署后可在已有 Google Search Console、Bing Webmaster Tools、百度搜索资源平台账户提交站点地图并观察抓取；本次代码改动不包含账户验证或第三方站长平台提交，也不承诺排名与 AI 引用。

## 浏览器验证

使用已安装的 Playwright 和 Chromium/Chrome，先启动本地静态服务：

```sh
python3 -m http.server 8765 --directory website
SOULO_PLAYWRIGHT_MODULE=/path/to/playwright \
SOULO_CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
node scripts/tests/website_browser_checks.cjs
```

也可让 `SOULO_PLAYWRIGHT_MODULE` 留空并使用环境中安装的 `playwright`；不设置 `SOULO_CHROME_PATH` 时使用 Playwright 默认 Chromium。测试会阻止百度统计请求，覆盖大小写与多关键词搜索、空结果、分类、收藏持久化、主题、中英文导航、复制配置、320/360/390/768/1280px 的页面布局、关闭 JavaScript 和禁止本地存储。桌面与手机的浅色、深色画面另做截图检查。

目录收录的站点入口需经过浏览器连通性检查，保留能进入实际内容页的入口，移出错误、证书异常、超时、劫持、用途变更或持续停留验证页的地址。目录不展示未经确认的“无广告”“永久免费”等标识，后续维护应按同样标准复查。

## 阅读、音乐与移动导航

阅读和音乐数据分别位于 `reading.json`、`music.json`，共用 `scripts/templates/content-directory.html`，配色及移动布局位于 `content-directories.css`。条目包含中英文名称、简介和标签；分类与页面文案随生成文件一起嵌入，不在运行时请求目录数据。两页各自使用独立的收藏键。

2026-11-02 的链接检查、修正地址与暂缓收录的原始条目保存在 `docs/website-link-audit-2026-11-02.json`。访问限制不等同于网站永久失效；重新加入前应复核实际内容，不把验证码或未完成加载的页面算作通过。

顶部七个入口采用本地 SVG 图标；在线工具直接链接 `https://www.dkluge.com/zh/bag`。`navigation.js` 在 1080px 及以下提供目录开合、Escape、外侧点击和响应式恢复；禁用 JavaScript 时直接显示链接列表。新页面与顶部导航均须通过 `scripts/tests/website_browser_checks.cjs` 的浏览器检查。
