(() => {
  'use strict';
  const button = document.getElementById('theme-toggle');
  const languageButton = document.getElementById('language-toggle');
  const navigation = document.querySelector('[data-shared-nav]');
  let directoryLocales = null;
  try {
    const content = document.getElementById('directory-locales');
    if (content) directoryLocales = JSON.parse(content.textContent);
  } catch {}

  const labels = {
    zh: {
      sources: '搜索源',
      movies: '影视导航',
      magnets: '磁力搜索',
      pans: '网盘搜索',
      reading: '阅读导航', music: '音乐资源', tools: '在线工具', menu: '目录',
      privacy: '隐私政策',
      support: '技术支持',
      navigation: '主导航',
      home: 'Soulo 首页',
      light: '切换至浅色外观',
      dark: '切换至深色外观'
    },
    en: {
      sources: 'Sources',
      movies: 'Movies',
      magnets: 'Magnets',
      pans: 'Cloud',
      reading: 'Reading', music: 'Music', tools: 'Tools', menu: 'Menu',
      privacy: 'Privacy',
      support: 'Support',
      navigation: 'Main navigation',
      home: 'Soulo home',
      light: 'Switch to light appearance',
      dark: 'Switch to dark appearance'
    }
  };

  const pageText = {
    zh: {
      'breadcrumb.home': '首页',
      sources: '搜索源',
      movies: '影视导航',
      magnets: '磁力搜索',
      pans: '网盘搜索',
      privacy: '隐私政策',
      'sources.skip': '跳到搜索源目录',
      'sources.summaryCount': '85 个搜索源',
      'sources.summaryCategories': '9 个分类',
      'sources.guideLink': '导入方法',
      'sources.previewQuery': '今天想了解的事',
      'sources.previewBili': '哔哩哔哩',
      'sources.previewCaption': '一个问题，多种视角。',
      'sources.searchLabel': '搜索平台、域名或分类',
      'sources.searchPlaceholder': '搜索平台、域名或分类',
      'sources.allCategories': '全部分类',
      'sources.sidebarPrompt': '想找影视网站？',
      'sources.sidebarAction': '逛逛影视导航',
      'sources.previewHint': '点击平台预览搜索',
      'sources.viewConfig': '查看配置',
      'sources.configDesc': '将这份 JSON 粘贴到 Soulo 的批量导入页面。',
      'sources.emptyTitle': '没有找到匹配的平台',
      'sources.emptyDesc': '试试平台名称、域名，或“AI”“影视”等分类。',
      'sources.reset': '查看全部',
      'sources.guideTitle': '三步，收进 Soulo。',
      'sources.step1Title': '挑选并复制',
      'sources.step1Desc': '点击平台旁的复制图标，或复制整个分类与筛选结果。',
      'sources.step2Title': '打开批量导入',
      'sources.step2Desc': '在 Soulo 的搜索平台管理页面，打开“批量导入”。',
      'sources.step3Title': '粘贴并保存',
      'sources.step3Desc': '粘贴配置，选择分组，导入自己的常用平台。',
      'movies.skip': '跳到影视网站目录',
      'movies.heroAction': '打开观影收藏夹',
      'movies.ticketBadge': '好戏开场',
      'movies.favoritesNote': '保存在当前浏览器',
      'movies.searchLabel': '搜索网站、分类或域名',
      'movies.searchPlaceholder': '搜索网站、分类或域名',
      'movies.allSites': '全部网站',
      'movies.myFavorites': '我的收藏',
      'movies.allCategories': '全部分类',
      'movies.sidebarPrompt': '想在 Soulo 中搜索？',
      'movies.sidebarAction': '浏览可导入的搜索源',
      'movies.resetFilters': '查看全部网站',
      'movies.aboutTitle': '一份按用途整理的影视收藏夹。',
      'movies.aboutDesc': 'Soulo 影视导航收录综合影视、电影下载、追剧、动漫、找片搜索、网盘资源、字幕台词、影评片单、纪录直播和影视工具。每个入口都标注网站名称、域名与用途，点击后在新标签页打开。',
      'movies.faq1Q': '怎么找到想要的网站？',
      'movies.faq1A': '按左侧分类浏览，或搜索网站名称、域名和用途。点击网站卡片打开对应网站，点击爱心将入口加入当前浏览器的收藏。',
      'movies.faq2Q': '收藏保存在哪里？',
      'movies.faq2A': '收藏保存在当前浏览器的本地存储中，无需注册；清除网站数据或更换浏览器后不会保留。',
      'magnets.skip': '跳到磁力搜索目录',
      'magnets.heroAction': '浏览磁力索引库',
      'magnets.ticketBadge': '磁力直连',
      'magnets.favoritesNote': '保存在当前浏览器',
      'magnets.searchLabel': '搜索磁力站、分类或域名',
      'magnets.searchPlaceholder': '搜索磁力站、分类或域名',
      'magnets.allSites': '全部网站',
      'magnets.myFavorites': '我的收藏',
      'magnets.allCategories': '全部分类',
      'magnets.sidebarPrompt': '想直接在线看片？',
      'magnets.sidebarAction': '打开影视导航目录',
      'magnets.resetFilters': '查看全部网站',
      'magnets.aboutTitle': '一份经过连通性验证的磁力与种子索引。',
      'magnets.aboutDesc': 'Soulo 磁力搜索收录 DHT 磁力搜索引擎、4K 与 1080P 影视种子站、新番动漫花园、国际 BitTorrent 社区。站点可访问性可能变化，配合 Soulo 内置的磁力（magnet:）与 BT 种子（.torrent）下载能力，查找与下载一气呵成。',
      'magnets.faq1Q': '如何在 Soulo 中下载磁力链接或 BT 种子？',
      'magnets.faq1A': '在任意磁力站点点击或复制 magnet:?xt= 开头的磁力链接，或下载 .torrent 种子文件，Soulo 内置下载管理器即可直接解析文件列表、选择剧集并高速下载。',
      'magnets.faq2Q': '收藏的磁力网站保存在哪里？',
      'magnets.faq2A': '点击卡片右下角的爱心即可收藏常用磁力站，收藏独立保存在当前浏览器的本地存储中，并置顶展示在页面上方。',
      'pans.skip': '跳到网盘搜索目录',
      'pans.heroAction': '浏览网盘搜索目录',
      'pans.ticketBadge': '极速转存',
      'pans.clusterBadge': '多盘聚合',
      'pans.favoritesNote': '保存在当前浏览器',
      'pans.searchLabel': '搜索网盘站、分类或域名',
      'pans.searchPlaceholder': '搜索网盘站、分类或域名（如夸克、百度、阿里）',
      'pans.allSites': '全部网站',
      'pans.myFavorites': '我的收藏',
      'pans.allCategories': '全部分类',
      'pans.sidebarPrompt': '想找 BT 种子或磁力链？',
      'pans.sidebarAction': '打开磁力搜索目录',
      'pans.resetFilters': '查看全部网站',
      'pans.aboutTitle': '一份经过连通性验证的网盘资源搜索目录。',
      'pans.aboutDesc': 'Soulo 网盘搜索收录多盘聚合搜索引擎、影视云盘社区、考研考公与电子书学习盘搜，以及主流云盘网页端入口。配合 Soulo 内置的电子书阅读器、压缩包解压与视频增强播放，找资源、转存与阅读观看一步到位。',
      'pans.faq1Q': '如何高效搜索夸克、百度或阿里云盘资源？',
      'pans.faq1A': '优先使用“多盘聚合”分类下的千帆搜索、盘搜Pro、阿立盘搜或易搜，输入片名、书名或课程名即可同时检索多个主流网盘的公开分享链接。',
      'pans.faq2Q': '收藏的网盘搜索网站保存在哪里？',
      'pans.faq2A': '点击卡片右下角的爱心即可收藏常用网盘搜索站，收藏独立保存在当前浏览器的本地存储中，并自动置顶展示在页面上方。',
      'privacy.skip': '跳到主要内容',
      'privacy.eyebrow': '隐私优先架构',
      'privacy.title': '隐私政策',
      'privacy.heroDesc': 'Soulo 默认将搜索历史、书签与个人偏好保存在你的设备本地——无需注册账号，不经过搜索中转服务器，也不接入任何第三方追踪 SDK。',
      'privacy.updated': '更新于 2026 年 9 月',
      'privacy.appNameLabel': '应用名称：',
      'privacy.pillar1Title': '默认保存在设备端',
      'privacy.pillar1Desc': '搜索记录与书签仅存储在本地设备',
      'privacy.pillar2Title': '搜索请求直连目标平台',
      'privacy.pillar2Desc': '直接发往你选择的平台，绝不经过中转',
      'privacy.pillar3Title': '零第三方追踪 SDK',
      'privacy.pillar3Desc': '不集成任何第三方统计或广告框架',
      'privacy.navOverview': '概览与浏览数据',
      'privacy.navStorage': '本地存储与 iCloud',
      'privacy.navPermissions': '系统权限说明',
      'privacy.navContent': '第三方网页与过滤',
      'privacy.navAi': '端侧智能与 AI',
      'privacy.navNetwork': '网络服务与删除',
      'privacy.navContact': '联系我们',
      'privacy.sidebarPrompt': '探索可导入的搜索源',
      'privacy.sidebarAction': '浏览搜索源目录',
      'privacy.s1Title': '1. Soulo 的工作方式',
      'privacy.s1Body': 'Soulo 是一款多平台搜索浏览器，帮助你在 Google、百度、YouTube、哔哩哔哩以及第三方 AI 服务之间快速切换搜索。当你发起搜索时，Soulo 会在内置浏览器中直接打开你选择的平台；搜索词直连发送至目标平台并受该平台自身隐私政策约束，不会经过 Soulo 服务器中转。',
      'privacy.s2Title': '2. 浏览数据与可选联系方式',
      'privacy.s3Title': '3. 本地数据存储',
      'privacy.s3Intro': '以下数据默认存储在你的设备本地（你主动开启 iCloud 同步的设置项见下一节说明）：',
      'privacy.s4Title': '4. iCloud 同步',
      'privacy.s4Body': '如果你在设置中开启 iCloud 同步，外观、首页、浏览器、隐私偏好、壁纸设置、搜索平台配置、工具栏布局与站点规则会通过 Apple 的 iCloud 键值存储（Key-Value Store）进行同步。搜索与浏览历史、书签、缓存、Cookie 与登录状态、下载文件、无痕浏览状态、使用统计及本地壁纸图片文件绝不会同步。同步数据受 Apple 加密保护且仅能通过你的 Apple ID 访问，Soulo 无法获取你的 iCloud 凭据。',
      'privacy.s5Title': '5. 系统权限说明',
      'privacy.s6Title': '6. 第三方网页内容与扩展脚本',
      'privacy.s6Body1': '搜索结果通过内置 WebView 展示自第三方平台，各平台拥有独立的隐私政策与数据处理规则。若你开启广告过滤，Soulo 会在 WebView 内拦截已知广告请求并隐藏页面广告元素。',
      'privacy.s7Title': '7. 广告过滤',
      'privacy.s7Body': 'Soulo 内置可选的广告拦截功能。开启后，应用会拦截向已知广告域名发起的请求，并通过 CSS/JavaScript 隐藏广告占位。该功能完全在应用内 WebView 本地运行，不影响系统其他应用或浏览器。',
      'privacy.s8Title': '8. 端侧智能功能与第三方 AI 平台',
      'privacy.s8Intro': 'Soulo 使用 Apple 原生系统框架实现本地智能辅助功能：',
      'privacy.s8Body': '上述功能均在设备端运行，不会将输入内容发送至 Soulo 服务器。当你主动选择某个第三方 AI 平台进行提问时，Soulo 会将搜索词直接发送给该平台以获取回答；该平台将按其自身隐私政策处理你的提问。',
      'privacy.s9Title': '9. 未成年人隐私',
      'privacy.s9Body': 'Soulo 无需注册即可使用，我们不会有意收集 13 周岁以下儿童的个人信息。你访问的第三方网站拥有各自的内容规范与年龄限制。',
      'privacy.s10Title': '10. 数据清除与删除',
      'privacy.s11Title': '11. 可选意见反馈',
      'privacy.s12Title': '12. 网络服务与局域网互传',
      'privacy.s12Body1': '网站图标优先从目标站点获取；若无法获取，可能会向 DuckDuckGo 或 Google 请求对应域名的图标（请求中不包含完整网页 URL 或搜索词）。在线壁纸、规则订阅与 Google 网页翻译在触发时会直连对应服务商。',
      'privacy.s12Body2': 'Wi-Fi 局域网传输仅在你开启传输会话时向同一局域网开放，默认启用配对验证；传输完成后请及时关闭会话。导入的文件仅保存在你的设备本地。',
      'privacy.s13Title': '13. 政策更新',
      'privacy.s13Body': '我们可能会根据功能演进适时更新本隐私政策，更新后的版本将在页面顶部标注最新生效日期。',
      'privacy.s14Title': '14. 联系我们'
    },
    en: {
      'breadcrumb.home': 'Home',
      sources: 'Sources',
      movies: 'Movies',
      magnets: 'Magnets',
      pans: 'Cloud Drives',
      privacy: 'Privacy Policy',
      'sources.skip': 'Skip to search sources directory',
      'sources.summaryCount': '85 search sources',
      'sources.summaryCategories': '9 categories',
      'sources.guideLink': 'How to import',
      'sources.previewQuery': 'What you want to explore today',
      'sources.previewBili': 'Bilibili',
      'sources.previewCaption': 'One question, multiple perspectives.',
      'sources.searchLabel': 'Search platforms, domains, or categories',
      'sources.searchPlaceholder': 'Search platforms, domains, or categories',
      'sources.allCategories': 'All Categories',
      'sources.sidebarPrompt': 'Looking for streaming sites?',
      'sources.sidebarAction': 'Explore Movies Directory',
      'sources.previewHint': 'Click a card to preview search',
      'sources.viewConfig': 'View JSON Config',
      'sources.configDesc': 'Paste this JSON into Batch Import inside Soulo.',
      'sources.emptyTitle': 'No matching platforms found',
      'sources.emptyDesc': 'Try a platform name, domain, or category like "AI" or "Video".',
      'sources.reset': 'Show All',
      'sources.guideTitle': 'Import into Soulo in three steps.',
      'sources.step1Title': 'Pick & copy',
      'sources.step1Desc': 'Click the copy button on any platform, category, or filtered result.',
      'sources.step2Title': 'Open Batch Import',
      'sources.step2Desc': 'In Soulo search platform settings, open "Batch Import".',
      'sources.step3Title': 'Paste & save',
      'sources.step3Desc': 'Paste the configuration, choose a group, and save your platforms.',
      'movies.skip': 'Skip to movies directory',
      'movies.heroAction': 'Open Watchlist Directory',
      'movies.ticketBadge': 'Now Showing',
      'movies.favoritesNote': 'Saved in this browser',
      'movies.searchLabel': 'Search sites, categories, or domains',
      'movies.searchPlaceholder': 'Search sites, categories, or domains',
      'movies.allSites': 'All Sites',
      'movies.myFavorites': 'Favorites',
      'movies.allCategories': 'All Categories',
      'movies.sidebarPrompt': 'Want to search inside Soulo?',
      'movies.sidebarAction': 'Browse importable search sources',
      'movies.resetFilters': 'Show All Sites',
      'movies.aboutTitle': 'A movie directory organized by how you watch.',
      'movies.aboutDesc': 'Soulo Movies curates streaming sites, downloads, series, anime, search engines, cloud shares, subtitles, reviews, documentaries, and playback tools. Each entry shows its name, domain, and purpose, opening in a new tab.',
      'movies.faq1Q': 'How do I find the site I need?',
      'movies.faq1A': 'Browse categories on the left or search by name, domain, or tag. Click any card to visit the site, or click the heart icon to save it to your browser favorites.',
      'movies.faq2Q': 'Where are my favorites stored?',
      'movies.faq2A': 'Favorites are stored locally in your current browser with no sign-up required. Clearing browser data or switching browsers will reset them.',
      'magnets.skip': 'Skip to magnet directory',
      'magnets.heroAction': 'Browse Magnet Index',
      'magnets.ticketBadge': 'Magnet Ready',
      'magnets.favoritesNote': 'Saved in this browser',
      'magnets.searchLabel': 'Search magnet sites, categories, or domains',
      'magnets.searchPlaceholder': 'Search magnet sites, categories, or domains',
      'magnets.allSites': 'All Sites',
      'magnets.myFavorites': 'Favorites',
      'magnets.allCategories': 'All Categories',
      'magnets.sidebarPrompt': 'Want to stream online instead?',
      'magnets.sidebarAction': 'Open Movies Directory',
      'magnets.resetFilters': 'Show All Sites',
      'magnets.aboutTitle': 'A verified directory of magnet & torrent search sites.',
      'magnets.aboutDesc': 'Soulo Magnets curates accessible DHT magnet search engines, 4K & 1080P movie torrent sites, anime trackers, and international BitTorrent indexes. Paired with Soulo\'s built-in magnet: and .torrent download manager, finding and downloading torrents is seamless.',
      'magnets.faq1Q': 'How do I download magnet links or .torrent files in Soulo?',
      'magnets.faq1A': 'Tap or copy any magnet:?xt= link or download a .torrent file from any listed site — Soulo\'s built-in download manager parses the file list, lets you pick episodes, and downloads directly.',
      'magnets.faq2Q': 'Where are my favorite magnet sites stored?',
      'magnets.faq2A': 'Click the heart icon on any card to pin your go-to magnet sites to the top of this page. Favorites are stored locally in your browser.',
      'pans.skip': 'Skip to cloud drive directory',
      'pans.heroAction': 'Browse Cloud Search Directory',
      'pans.ticketBadge': 'Instant Save',
      'pans.clusterBadge': 'Multi-Cloud',
      'pans.favoritesNote': 'Saved in this browser',
      'pans.searchLabel': 'Search cloud drive sites, categories, or domains',
      'pans.searchPlaceholder': 'Search cloud sites, domains, or Quark / Baidu / AliPan',
      'pans.allSites': 'All Sites',
      'pans.myFavorites': 'Favorites',
      'pans.allCategories': 'All Categories',
      'pans.sidebarPrompt': 'Looking for BT torrents or magnets?',
      'pans.sidebarAction': 'Open Magnet Search Directory',
      'pans.resetFilters': 'Show All Sites',
      'pans.aboutTitle': 'A verified directory of cloud drive search engines & communities.',
      'pans.aboutDesc': 'Soulo Cloud Search curates multi-cloud search engines (Quark, Baidu, AliPan, Xunlei, UC, 115), 4K movie sharing communities, study & eBook cloud indexes, and official web drives. Paired with Soulo\'s built-in eBook reader, archive extractor, and video player, saving and opening files is effortless.',
      'pans.faq1Q': 'How do I search across Quark, Baidu, and AliPan at once?',
      'pans.faq1A': 'Start with the "Multi-Cloud Search" category — sites like Qianfan, PanSo Pro, AliSo, and YiSo let you enter a movie title, book, or course keyword once and filter results by cloud provider.',
      'pans.faq2Q': 'Where are my favorite cloud search sites stored?',
      'pans.faq2A': 'Click the heart icon on any card to pin your favorite cloud search sites to the top of this page. Favorites are stored locally in your browser.',
      'privacy.skip': 'Skip to main content',
      'privacy.eyebrow': 'Privacy-First Architecture',
      'privacy.title': 'Privacy Policy',
      'privacy.heroDesc': 'Soulo keeps your search history, bookmarks, and preferences on your device by default — with no account system, no search relay servers, and no third-party tracking SDKs.',
      'privacy.updated': 'Updated September 2026',
      'privacy.appNameLabel': 'App Name: ',
      'privacy.pillar1Title': 'On-device by default',
      'privacy.pillar1Desc': 'History and bookmarks stay stored locally',
      'privacy.pillar2Title': 'Direct search requests',
      'privacy.pillar2Desc': 'Sent straight to the platform you choose',
      'privacy.pillar3Title': 'Zero tracking SDKs',
      'privacy.pillar3Desc': 'No third-party analytics or ad frameworks',
      'privacy.navOverview': 'Overview & Data',
      'privacy.navStorage': 'Local Storage & iCloud',
      'privacy.navPermissions': 'Permissions',
      'privacy.navContent': 'Web Content & Blocking',
      'privacy.navAi': 'On-Device AI',
      'privacy.navNetwork': 'Network & Deletion',
      'privacy.navContact': 'Contact Us',
      'privacy.sidebarPrompt': 'Explore search templates',
      'privacy.sidebarAction': 'Browse search sources',
      'privacy.s1Title': '1. How Soulo Works',
      'privacy.s1Body': 'Soulo is a multi-platform search browser that helps you switch between search engines such as Google, Baidu, YouTube, Bilibili, and third-party AI services. When you search, Soulo opens the selected platform directly in the built-in browser. Your query is sent to that platform under its own privacy policy, not relayed through a Soulo search server.',
      'privacy.s2Title': '2. Browsing Data & Optional Contact Details',
      'privacy.s3Title': '3. Local Data Storage',
      'privacy.s3Intro': 'The following data is stored locally on your device by default (except settings you choose to sync via iCloud as described below):',
      'privacy.s4Title': '4. iCloud Sync',
      'privacy.s4Body': 'If you enable iCloud Sync in Settings, appearance, home screen, browser, privacy preferences, wallpaper settings, search platform configuration, toolbar layout, and site rules are synced through Apple\'s iCloud Key-Value Store. Search and browsing history, bookmarks, cache, cookies and login sessions, downloads, private browsing state, usage stats, and local wallpaper image files are never synced. Synced data is encrypted by Apple and accessible only via your Apple ID; Soulo cannot access your iCloud credentials.',
      'privacy.s5Title': '5. Permissions We Request',
      'privacy.s6Title': '6. Third-Party Web Content & UserScripts',
      'privacy.s6Body1': 'Search results are loaded from third-party platforms in an embedded WebView. Each platform has its own privacy policy and data practices. If ad blocking is enabled, Soulo blocks known ad requests and hides ad elements inside the WebView.',
      'privacy.s7Title': '7. Ad Blocking',
      'privacy.s7Body': 'Soulo includes an optional built-in ad blocker. When enabled, it blocks requests to known ad domains and hides ad placeholders using CSS/JavaScript rules. This runs entirely locally within the in-app WebView and does not affect other apps or browsers.',
      'privacy.s8Title': '8. On-Device Intelligence & Third-Party AI Platforms',
      'privacy.s8Intro': 'Soulo uses Apple system frameworks for local intelligence features:',
      'privacy.s8Body': 'These features run on-device and do not send your input to Soulo servers. When you actively choose a third-party AI platform to ask a question, Soulo sends your query directly to that platform so it can respond under its own privacy policy.',
      'privacy.s9Title': '9. Children\'s Privacy',
      'privacy.s9Body': 'Soulo requires no registration and does not knowingly collect personal information from children under 13. Third-party websites you visit have their own content policies and age restrictions.',
      'privacy.s10Title': '10. Data Retention & Deletion',
      'privacy.s11Title': '11. Optional Feedback',
      'privacy.s12Title': '12. Network Services & Local Wi-Fi Transfer',
      'privacy.s12Body1': 'Website icons are fetched from the target site first; if unavailable, Soulo may request the domain icon from DuckDuckGo or Google (without full page URLs or search queries). Online wallpapers, filter subscriptions, and Google Web Translate connect directly to their respective providers when triggered.',
      'privacy.s12Body2': 'Wi-Fi Local Transfer is only available on your local network while a transfer session is open, with pairing verification enabled by default. Close the session when finished; imported files stay on your device.',
      'privacy.s13Title': '13. Changes to This Policy',
      'privacy.s13Body': 'We may update this Privacy Policy from time to time. The updated version will be indicated by the "Updated" date at the top of this page.',
      'privacy.s14Title': '14. Contact Us'
    }
  };

  const pageHtml = {
    zh: {
      'sources.heroTitle': '把好用的搜索，<br />放在顺手的地方。',
      'sources.heroDesc': '从 AI 问答到学术资料，找到适合你的入口。<br />挑选、复制、导入，建立自己的搜索列表。',
      'sources.guideDesc': '支持单个平台、整个分类，<br />也支持只复制当前筛选结果。',
      'sources.footnote': '模板中的 <code>%@</code> 会由 Soulo 替换为经过编码的关键词。部分平台可能需要登录，或根据地区调整搜索页面。',
      'movies.heroTitle': '今晚，<br />看点什么？',
      'movies.heroDesc': '电影、追剧、动漫，还有下一部心头好。<br />把找片的时间，留给好故事。',
      'magnets.heroTitle': '磁力与种子，<br />一触即达。',
      'magnets.heroDesc': '聚合可用 DHT 磁力引擎、4K 影视种子与新番动漫花园。<br />配合 Soulo 内置 BT 引擎，复制磁力链即可直接下载。',
      'pans.heroTitle': '云盘与好物，<br />一搜即存。',
      'pans.heroDesc': '聚合夸克、百度、阿里、迅雷与 115 网盘搜索引擎。<br />4K 影视、电子书、课程资料与软件，快速找到可用分享。',
      'privacy.highlight': '<strong>核心承诺：</strong>Soulo 是一款多平台搜索浏览器，不运营任何接收或中转你搜索请求的后端服务器。浏览历史与书签默认保存在你的设备上。可选的设置同步、反馈提交及网络功能详见下文说明。',
      'privacy.s2List': '<li><strong>不上传浏览记录：</strong>Soulo 不会将浏览历史或书签自动发送至任何服务器。仅当你主动提交意见反馈时，相关反馈内容才会发送至 DKluge。</li><li><strong>可选联系方式：</strong>使用 Soulo 无需注册账号。在提交反馈时，你可以自愿填写邮箱或其他联系方式以便我们回复。</li><li><strong>无追踪框架：</strong>应用内不集成任何第三方统计、广告 SDK 或用户追踪框架。</li>',
      'privacy.s3List': '<li><strong>搜索历史：</strong>近期搜索关键词通过 SwiftData 保存在本地以便快速回顾，你可随时在「设置 → 隐私」中清除。</li><li><strong>书签收藏：</strong>你收藏的网页保存在本地，支持逐条删除或一键清空。</li><li><strong>平台配置：</strong>搜索平台的启用状态、排序和自定义分组保存在本地 UserDefaults 中。</li><li><strong>偏好设置：</strong>语言、外观模式、壁纸设置及首页自定义项保存在本地 UserDefaults 中。</li>',
      'privacy.s5List': '<li><strong>麦克风：</strong>用于语音搜索，以及在你明确授权某个安全网站后用于网页通话或录音功能。根据设备、语言与系统版本不同，Apple 可能在设备端或通过其语音服务完成语音转文字。Soulo 绝不会自动向网站授予权限，也不会录制、存储或向 Soulo 服务器上传音频。</li><li><strong>相机：</strong>仅在你明确授权某个安全网站后可用，用于视频通话、扫码或拍照。Soulo 绝不会自动授予网站权限，也不会录制、存储或上传视频内容。</li><li><strong>相册：</strong>用于选择自定义首页壁纸及保存图片至相册，照片绝不会上传至服务器。</li>',
      'privacy.s6Body2': '<strong>用户自定义脚本（UserScript）：</strong>UserScript 是一项可选的进阶功能。你主动安装的脚本可根据其代码读取或修改匹配的网页并发起网络请求。Soulo 不会自动安装脚本，也不会将脚本数据发送至 Soulo 服务器。请仅安装来自可信作者的脚本。',
      'privacy.s8Pills': '<li><strong>拼写检查：</strong>UITextChecker（设备端）</li><li><strong>语言识别：</strong>NLLanguageRecognizer（设备端）</li><li><strong>文字识别：</strong>Vision 框架 OCR（设备端）</li><li><strong>剪贴板识别：</strong>NLTagger 内容类型检测（设备端）</li>',
      'privacy.s10Body': '卸载应用即可移除设备上的全部本地数据，无需注销账号。你也可以在应用「设置」中单独清除搜索历史、书签和网页缓存。如需删除已提交的反馈记录，请发送邮件至 <a href="mailto:contact@dkluge.com">contact@dkluge.com</a>。',
      'privacy.s11Body': '当你在意见反馈页面点击提交时，Soulo 会将反馈类别、正文、可选联系方式以及应用版本、设备型号、系统版本、屏幕尺寸与语言设置发送至 api.dkluge.com，仅用于排查问题与回复反馈。如需删除已提交的反馈，请联系 <a href="mailto:contact@dkluge.com">contact@dkluge.com</a>。',
      'privacy.s14Body': '如果你对本隐私政策有任何疑问，请通过邮件联系我们：<a href="mailto:contact@dkluge.com">contact@dkluge.com</a>'
    },
    en: {
      'sources.heroTitle': 'Keep your best searches<br />right within reach.',
      'sources.heroDesc': 'From AI answers to academic papers, find the right entry point.<br />Pick, copy, and import to build your own search list.',
      'sources.guideDesc': 'Copy a single platform, a full category,<br />or just your current filtered results.',
      'sources.footnote': 'The <code>%@</code> placeholder is replaced by Soulo with your URL-encoded query. Some platforms may require sign-in or region-specific settings.',
      'movies.heroTitle': 'Tonight,<br />what\'s on?',
      'movies.heroDesc': 'Movies, series, anime, and your next favorite story.<br />Spend less time searching, more time watching.',
      'magnets.heroTitle': 'Magnets & torrents,<br />ready in one tap.',
      'magnets.heroDesc': 'Verified DHT search engines, 4K movie torrents, and anime trackers.<br />Copy any magnet link to download directly in Soulo.',
      'pans.heroTitle': 'Cloud drives & files,<br />found in one search.',
      'pans.heroDesc': 'Search across Quark, Baidu, AliPan, Xunlei, and 115 cloud drives.<br />Find 4K movies, eBooks, courses, and archives ready to save.',
      'privacy.highlight': '<strong>Key takeaway:</strong> Soulo is a multi-platform search browser. We do not operate a backend server that receives or relays your search queries. Browsing history and bookmarks stay on your device by default. Optional settings sync, feedback submission, and network features are described below.',
      'privacy.s2List': '<li><strong>No browsing history uploads:</strong> Soulo does not automatically send your browsing history or bookmarks to any server. Information is sent to DKluge only when you actively submit feedback.</li><li><strong>Optional contact info:</strong> No account is required to use Soulo. You may optionally provide an email or contact handle when submitting feedback so we can reply.</li><li><strong>No tracking SDKs:</strong> The app contains no third-party analytics, advertising SDKs, or user-tracking frameworks.</li>',
      'privacy.s3List': '<li><strong>Search History:</strong> Recent search queries are stored locally via SwiftData for quick recall and can be cleared anytime in Settings → Privacy.</li><li><strong>Bookmarks:</strong> Saved web pages are stored locally and can be deleted individually or all at once.</li><li><strong>Platform Configuration:</strong> Enabled states, ordering, and custom groups are stored locally in UserDefaults.</li><li><strong>User Preferences:</strong> Language, theme, wallpaper, and home customization settings are stored locally in UserDefaults.</li>',
      'privacy.s5List': '<li><strong>Microphone:</strong> Used for voice search and, after you explicitly allow a secure website, web audio/call features. Depending on device, language, and OS version, Apple may process speech-to-text on-device or via Apple speech services. Soulo never grants website access automatically and never records, stores, or uploads audio to Soulo servers.</li><li><strong>Camera:</strong> Used only after you explicitly allow a secure website for video calls, QR scanning, or photo capture. Soulo never grants access automatically and never records, stores, or uploads video.</li><li><strong>Photo Library:</strong> Used to pick custom home wallpapers and save images to your library. Photos are never uploaded to any server.</li>',
      'privacy.s6Body2': '<strong>UserScripts:</strong> UserScripts are an optional advanced feature. Scripts you choose to install can read or modify matching web pages and make network requests according to their code. Soulo never installs scripts automatically or sends script data to Soulo servers. Only install scripts from authors you trust.',
      'privacy.s8Pills': '<li><strong>Spell Checking:</strong> UITextChecker (on-device)</li><li><strong>Language Detection:</strong> NLLanguageRecognizer (on-device)</li><li><strong>Text Recognition:</strong> Vision framework OCR (on-device)</li><li><strong>Clipboard Detection:</strong> NLTagger content detection (on-device)</li>',
      'privacy.s10Body': 'Uninstalling the app removes all local data from your device — no account deletion request is needed. You can also clear search history, bookmarks, and web cache individually in Settings. To request deletion of submitted feedback, email <a href="mailto:contact@dkluge.com">contact@dkluge.com</a>.',
      'privacy.s11Body': 'When you tap Submit in Feedback, Soulo sends the feedback category, message, optional contact info, and diagnostic context (app version, device model, OS version, screen size, and language) to api.dkluge.com solely to troubleshoot issues and reply. To delete submitted feedback, contact <a href="mailto:contact@dkluge.com">contact@dkluge.com</a>.',
      'privacy.s14Body': 'If you have any questions about this Privacy Policy, please contact us at: <a href="mailto:contact@dkluge.com">contact@dkluge.com</a>'
    }
  };

  const sourceCategories = {
    ai: {zh: ['AI 搜索', '可通过 URL 直接携带问题的 AI 搜索服务。'], en: ['AI Search', 'AI search services that accept queries directly via URL.']},
    general: {zh: ['通用搜索', '覆盖中文、英文、日文和韩文的网页搜索。'], en: ['General Search', 'Web search engines covering Chinese, English, Japanese, and Korean.']},
    academic: {zh: ['学术搜索', '论文、期刊、预印本和机构知识库。'], en: ['Academic', 'Papers, journals, preprints, and institutional repositories.']},
    social: {zh: ['社交与内容', '站内内容搜索，部分平台需要登录。'], en: ['Social & Community', 'In-platform content search; some platforms require sign-in.']},
    developer: {zh: ['开发者', '代码仓库、技术问答和中文开发社区。'], en: ['Developer', 'Code repositories, Q&A sites, and developer communities.']},
    shopping: {zh: ['购物', '商品与二手交易平台搜索。'], en: ['Shopping', 'Product search and secondhand marketplaces.']},
    comic: {zh: ['漫画与插画', '视频、漫画与插画站内搜索。'], en: ['Comics & Art', 'Anime, manga, and illustration platform search.']},
    video: {zh: ['影视', '官方视频平台及已验证的影视资源搜索。'], en: ['Video & Media', 'Official streaming platforms and verified media search.']},
    book: {zh: ['图书', '电子书与图书资源搜索。'], en: ['Books', 'E-books and book catalog search.']}
  };

  const movieCategories = {
    streaming: {zh: ['综合影视', '电影、剧集和综艺，一个入口慢慢挑。'], en: ['Streaming', 'Movies, series, and variety shows in one place.']},
    movies: {zh: ['电影下载', '收藏电影，也收藏值得重看的故事。'], en: ['Movie Downloads', 'Collect films and stories worth rewatching.']},
    series: {zh: ['追剧专区', '日剧、韩剧与海外剧，接上喜欢的下一集。'], en: ['Series & Drama', 'J-dramas, K-dramas, and global series to binge next.']},
    anime: {zh: ['动漫番剧', '新番时间表、动画与二次元社区。'], en: ['Anime', 'Seasonal schedules, animation catalogs, and ACG communities.']},
    search: {zh: ['找片搜索', '有了片名，就从这里找起。'], en: ['Movie Search', 'Already have a title in mind? Start searching here.']},
    cloud: {zh: ['网盘资源', '按关键词查找云盘资源与分享社区。'], en: ['Cloud Drives', 'Find cloud drive links and sharing communities by keyword.']},
    subtitles: {zh: ['字幕与台词', '补一份字幕，或找回那句忘不掉的对白。'], en: ['Subtitles & Quotes', 'Download subtitles or find a movie by a memorable line.']},
    discovery: {zh: ['影评与片单', '不知道看什么时，给自己一点灵感。'], en: ['Reviews & Lists', 'Curated watchlists and ratings when you need inspiration.']},
    documentary: {zh: ['纪录与直播', '真实世界的故事，还有正在发生的现场。'], en: ['Docs & Live TV', 'Real-world documentaries and live broadcasts.']},
    tools: {zh: ['影视工具', '播放器与影视资源接口。'], en: ['Media Tools', 'Players and media resource utilities.']}
  };

  const magnetCategories = {
    engine: {zh: ['磁力引擎', '输入片名、番号或关键词，直接检索 DHT 磁力链与种子元数据。'], en: ['Magnet Engines', 'Search DHT magnet links and torrent metadata by title or keyword.']},
    movie: {zh: ['影视种子', '4K 原盘、蓝光 1080P 电影与热播剧集 BT 种子及磁力下载。'], en: ['Movie & TV Torrents', '4K UHD, 1080P Blu-ray movies, and series BT/magnet downloads.']},
    anime: {zh: ['动漫追番', '新番动画、字幕组发布与 ACG 磁力种子花园。'], en: ['Anime Torrents', 'Seasonal anime magnets, fansub releases, and ACG trackers.']},
    global: {zh: ['国际种子', '海外美剧、无损音乐与全球综合 BitTorrent 磁力索引。'], en: ['Global Torrents', 'International TV series, lossless music, and BitTorrent indexes.']},
  };

  const panCategories = {
    engine: {zh: ['多盘聚合', '一次输入关键词，同时检索夸克、百度、阿里、迅雷、UC 与 115 等多网盘分享链接。'], en: ['Multi-Cloud Search', 'Search Quark, Baidu, AliPan, Xunlei, UC, and 115 shared links with a single query.']},
    community: {zh: ['影视网盘站', '按海报、片单或社区帖子整理的夸克、阿里与百度网盘高清影视资源站。'], en: ['Movie Cloud Communities', 'HD movies, series, and anime organized by posters and community threads on Quark & AliPan.']},
    special: {zh: ['学习与专项', '针对电子书、公开课、考公考研题库、4K 原盘片单与实用软件的专项网盘索引。'], en: ['Study & Specialized', 'Dedicated cloud indexes for eBooks, courses, exam prep, 4K UHD lists, and software.']},
    official: {zh: ['网盘工作台', '主流云盘官方网页版入口，方便直接管理转存文件、云端解压与原画在线播放。'], en: ['Official Web Drives', 'Official web consoles for managing saved files, cloud extraction, and original-quality playback.']}
  };

  const pageTitles = {
    zh: {
      sources: 'Soulo 搜索源目录 - 可直接导入的搜索模板',
      movies: '影视导航 - 电影、追剧、动漫与字幕网站目录 | Soulo',
      magnets: '磁力搜索 - BT 种子、影视磁力链与动漫资源导航 | Soulo',
      pans: '网盘搜索 - 夸克、百度、阿里与多盘聚合资源导航 | Soulo',
      privacy: '隐私政策 - Soulo'
    },
    en: {
      sources: 'Soulo Search Sources - Importable Search Templates',
      movies: 'Movies Directory - Streaming, Anime, Subtitles & Watchlists | Soulo',
      magnets: 'Magnet Search - BT Torrents, 4K Movies & Anime Directory | Soulo',
      pans: 'Cloud Drive Search - Quark, Baidu, AliPan & Multi-Cloud Directory | Soulo',
      privacy: 'Privacy Policy - Soulo'
    }
  };

  let language = 'zh';
  const system = matchMedia('(prefers-color-scheme: dark)');
  let theme = 'dark';
  try {
    const savedTheme = localStorage.getItem('soulo-theme');
    if (savedTheme === 'light' || savedTheme === 'dark') theme = savedTheme;
  } catch {}
  try {
    const savedLang = localStorage.getItem('soulo-language');
    if (savedLang === 'zh' || savedLang === 'en') language = savedLang;
  } catch {}

  function applyTheme() {
    const dark = theme !== 'light';
    document.documentElement.dataset.resolvedTheme = dark ? 'dark' : 'light';
    document.documentElement.dataset.theme = theme;
    if (button) {
      button.setAttribute('aria-pressed', String(dark));
      button.setAttribute('aria-label', labels[language][dark ? 'light' : 'dark']);
      button.title = button.getAttribute('aria-label');
      button.innerHTML = dark
        ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg>'
        : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><path d="M20.4 14.3A8.7 8.7 0 0 1 9.7 3.6a8.7 8.7 0 1 0 10.7 10.7Z"/></svg>';
    }
    document.querySelectorAll('meta[name="theme-color"]').forEach(meta => {
      meta.content = dark ? '#111217' : '#f6f7fb';
    });
  }

  function applyNavigationLanguage() {
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    if (navigation) {
      navigation.lang = language === 'zh' ? 'zh-CN' : 'en';
      navigation.querySelectorAll('[data-nav-i18n]').forEach(link => {
        link.textContent = labels[language][link.dataset.navI18n];
      });
      navigation.querySelector('nav')?.setAttribute('aria-label', labels[language].navigation);
      navigation.querySelector('.brand')?.setAttribute('aria-label', labels[language].home);
    }
    document.querySelectorAll('.site-footer [data-i18n]').forEach(el => {
      const key = el.dataset.i18n;
      if (labels[language][key]) el.textContent = labels[language][key];
    });
    const extra = directoryLocales?.[language] || {};
    const dict = {...pageText[language], ...extra};
    document.querySelectorAll('[data-page-i18n]').forEach(el => {
      const val = dict[el.dataset.pageI18n];
      if (val !== undefined) el.textContent = val;
    });
    const htmlDict = {...pageHtml[language], ...extra};
    document.querySelectorAll('[data-page-i18n-html]').forEach(el => {
      const val = htmlDict[el.dataset.pageI18nHtml];
      if (val !== undefined) el.innerHTML = val;
    });
    document.querySelectorAll('[data-page-i18n-placeholder]').forEach(el => {
      const val = dict[el.dataset.pageI18nPlaceholder];
      if (val !== undefined) el.setAttribute('placeholder', val);
    });

    // Translate category names and descriptions on sources.html and movies.html
    Object.entries(sourceCategories).forEach(([id, map]) => {
      const [name, desc] = map[language];
      document.querySelectorAll(`[data-source-category="${id}"] > span:first-of-type`).forEach(el => { el.textContent = name; });
      const section = document.querySelector(`.source-category[data-category="${id}"]`);
      if (section) {
        const titleEl = section.querySelector('.category-title-text');
        const descEl = section.querySelector('.category-desc');
        const copyEl = section.querySelector('.category-copy-text');
        if (titleEl) titleEl.textContent = name;
        if (descEl) descEl.textContent = desc;
        if (copyEl) copyEl.textContent = language === 'en' ? 'Copy' : '复制';
      }
    });

    const activeCategories = directoryLocales?.categories || (document.body.classList.contains('magnets-page')
      ? magnetCategories
      : document.body.classList.contains('pans-page')
        ? panCategories
        : movieCategories);
    Object.entries(activeCategories).forEach(([id, map]) => {
      const [name, desc] = map[language];
      document.querySelectorAll(`.category-link[data-category="${id}"] > span:first-of-type`).forEach(el => { el.textContent = name; });
      const section = document.querySelector(`.movie-category[data-section="${id}"]`);
      if (section) {
        const titleEl = section.querySelector('h2');
        const descEl = section.querySelector('.movie-section-heading > p');
        if (titleEl) titleEl.textContent = name;
        if (descEl) descEl.textContent = desc;
      }
    });

    document.querySelectorAll('[data-text-zh][data-text-en]').forEach(el => {
      const text = language === 'en' ? el.dataset.textEn : el.dataset.textZh;
      el.textContent = text;
      if (el.hasAttribute('title')) el.title = text;
    });
    document.querySelectorAll('[data-label-zh][data-label-en]').forEach(el => {
      el.setAttribute('aria-label', language === 'en' ? el.dataset.labelEn : el.dataset.labelZh);
    });

    if (document.body.classList.contains('sources-page')) document.title = pageTitles[language].sources;
    else if (document.body.classList.contains('magnets-page')) document.title = pageTitles[language].magnets;
    else if (document.body.classList.contains('pans-page')) document.title = pageTitles[language].pans;
    else if (document.body.classList.contains('movies-page')) document.title = pageTitles[language].movies;
    else if (document.body.classList.contains('privacy-page')) document.title = pageTitles[language].privacy;
    if (extra['page.title']) {
      document.title = extra['page.title'];
      document.querySelectorAll('meta[property="og:title"],meta[name="twitter:title"]').forEach(el => { el.content = extra['page.title']; });
      document.querySelectorAll('meta[name="description"],meta[property="og:description"],meta[name="twitter:description"]').forEach(el => { el.content = extra['page.description']; });
      const locale = document.querySelector('meta[property="og:locale"]');
      if (locale) locale.content = language === 'en' ? 'en_US' : 'zh_CN';
    }

    if (languageButton) {
      languageButton.textContent = language === 'zh' ? 'EN' : '中文';
      languageButton.setAttribute('aria-label', language === 'zh' ? 'Switch page language to English' : '切换页面语言为中文');
      languageButton.title = language === 'zh' ? 'Switch to English' : '切换为中文';
    }
    applyTheme();
    window.dispatchEvent(new CustomEvent('soulo:langchange', {detail: {lang: language}}));
  }

  languageButton?.addEventListener('click', () => {
    language = language === 'zh' ? 'en' : 'zh';
    try { localStorage.setItem('soulo-language', language); } catch {}
    applyNavigationLanguage();
  });
  button?.addEventListener('click', () => {
    theme = document.documentElement.dataset.resolvedTheme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('soulo-theme', theme); } catch {}
    applyTheme();
  });
  system.addEventListener('change', applyTheme);
  window.addEventListener('storage', event => {
    if (event.key === 'soulo-theme') { theme = event.newValue === 'light' ? 'light' : 'dark'; applyTheme(); }
    if (event.key === 'soulo-language') { language = event.newValue === 'en' ? 'en' : 'zh'; applyNavigationLanguage(); }
  });
  applyNavigationLanguage();
})();
