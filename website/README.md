# Soulo 静态网站

生产地址：https://soulo.dkluge.com/ 。此目录由现有 Nginx 静态托管，日常发布使用 `bash website/upload.sh`。Git push 与网站部署是两个独立步骤。

## 页面与设计

- `index.html`：产品首页，导航包含搜索源和影视导航；保留中英文切换。
- `sources.html`：85 个搜索模板、9 个分类，支持筛选和 JSON 复制。
- `movies.html`：58 个影视网站、10 个分类，支持筛选、搜索和浏览器本地收藏。
- `privacy.html`：App 隐私政策。

配色使用冷白 `#f6f7fb`、雾灰、墨色 `#242532` 与紫色 `#6957bc`；深色页面使用中性黑 `#111217`、灰紫表面与浅紫文字。正文使用 Avenir Next / 苹方，影视页以电影票图形建立辨识度，目录保留明确的文字层级和紧凑的网站卡片。影视页没有外部字体、图标、前端框架或运行时数据请求。

`favicon.svg` 内嵌原 App 图标的缩小版本，通过 SVG clipPath 形成透明圆角。三个原有页面及影视导航均加载用户提供的百度统计代码。

## 更新目录

影视目录源数据在 `website/movies.json`，页面模板在 `scripts/templates/movies.html`。新增网站时维护唯一 ID、名称、HTTPS 地址、分类、用途简介、标签与图标文字；`source: "user"` 表示用户补充的地址，其余来自顶层列出的来源。`updated` 是整理日期，不能解释为全部站点的可用性保证。

搜索源数据仍在 `sources.html` 的 `SOURCES` 与 `CATEGORIES` 中。生成器同时生成可直接抓取的静态目录；页面 JavaScript 只负责筛选和复制，不再重复生成目录。

```sh
python3 scripts/build_website.py
python3 scripts/build_website.py --check
python3 scripts/check_website.py
```

生成文件 `movies.html` 和 `sources.html` 随源文件一并提交。分类、名称、简介、链接和结构化数据在原始 HTML 中存在，不依赖 JavaScript 执行。禁用 JavaScript 时隐藏收藏和筛选控件，目录链接仍可使用。

## SEO 与 AI 搜索

四个页面具有独立标题、描述、canonical、Open Graph、Twitter 元数据、图标和 JSON-LD。首页描述 WebSite、Organization 与 SoftwareApplication；目录采用 CollectionPage、ItemList 和 BreadcrumbList；隐私页采用 WebPage 与 BreadcrumbList。结构化数据与实际页面内容对应，不添加虚构评分、价格或视频条目。

`sitemap.xml` 包含四个公开页面与真实编辑日期，`robots.txt` 提供站点地图入口并允许既有搜索和 AI 爬虫。`llms.txt` 与 `llms-full.txt` 提供页面链接、产品事实、目录用途、来源与边界；它们是便于读取的补充资料，不是搜索收录所需的特殊协议。摘要区分 App 隐私政策和官网百度统计，避免沿用旧摘要中“官网无分析服务”等不准确表述。

首页中英文共用一个 canonical URL，因此没有伪造相同 URL 的语言替代页面。新增独立英文 URL 后再维护双向 hreflang 与站点地图。

实施依据：

- [Google：AI features and your website](https://developers.google.com/search/docs/appearance/ai-features)：AI 搜索继续遵循可抓取、可索引、实用内容等 SEO 基础。
- [Google：Sitemap overview](https://developers.google.com/search/docs/crawling-indexing/sitemaps/overview)。
- [Google：Introduction to structured data](https://developers.google.com/search/docs/appearance/structured-data/intro-structured-data)。
- 目录地址参考 [i8K 影视导航](https://i8k.tv/) 及用户补充地址；站点简介为重新整理的用途说明。

部署脚本会检查新页面、CSS、JS、SVG、站点地图和摘要的公网 MIME 类型。部署后可在已有 Google Search Console、Bing Webmaster Tools、百度搜索资源平台账户提交站点地图并观察抓取；本次代码改动不包含账户验证或第三方站长平台提交，也不承诺排名与 AI 引用。

## 浏览器验证

使用已安装的 Playwright 和 Chromium/Chrome，先启动本地静态服务：

```sh
python3 -m http.server 8765 --directory website
SOULO_PLAYWRIGHT_MODULE=/path/to/playwright \
SOULO_CHROME_PATH='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' \
node scripts/tests/website_browser_checks.cjs
```

也可让 `SOULO_PLAYWRIGHT_MODULE` 留空并使用环境中安装的 `playwright`；不设置 `SOULO_CHROME_PATH` 时使用 Playwright 默认 Chromium。测试会阻止百度统计请求，覆盖大小写与多关键词搜索、空结果、分类、收藏持久化、主题、中英文导航、复制配置、320/360/390/768/1280px 的四页面布局、关闭 JavaScript 和禁止本地存储。桌面与手机的浅色、深色画面另做截图检查。

2026-10-30 地址抽查：58 个入口中，39 个通过本地 HTTP 请求获得响应；其余涉及反爬 403/429、地区或证书握手、超时等访问差异。HHZY 返回 403，按用户指定保留原地址；部分本地 404 地址可被搜索工具读取，未据一次抓取认定失效。目录不展示未经确认的“可用”“无广告”“永久免费”等标识。外部站点会变化，后续维护应复查原站地址。
