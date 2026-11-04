(() => {
  'use strict';
  const messages = {
    zh: {
      skip: '跳到主要内容', navigation: '主导航', sources: '搜索源', movies: '影视导航', magnets: '磁力搜索', pans: '网盘搜索', reading: '阅读导航', music: '音乐资源', tools: '在线工具', menu: '目录', browser: '浏览器',
      moviesTitle: '下一部心头好，从这里找。', moviesIntro: '电影、追剧、动漫、字幕和片单，按用途整理的影视网站收藏夹。', exploreMovies: '探索影视导航',
      eyebrow: '为 iPhone 打造的多平台搜索浏览器', tagline: '一次输入，搜索更多。',
      intro: '在 40+ 搜索、视频、社区和 AI 平台间快速切换。\n广告拦截、BT 与资源下载、画中画播放、网页翻译与脚本扩展，一步即达。',
      downloadOn: '下载于', availability: 'iOS 17.0 及以上 · 无需注册 Soulo 账号', scan: '用 iPhone 扫码下载', scanHint: '或直接在 App Store 搜索 Soulo',
      qrLink: '前往 App Store 下载 Soulo', qrAlt: 'Soulo App Store 下载二维码',
      darkScreenshot: 'Soulo 首页，展示山景壁纸和搜索栏', lightScreenshot: 'Soulo 浅色首页，展示自定义壁纸和平台分组', screenshots: 'Soulo App 实际界面',
      featuresTitle: '日常浏览，需要的都在。', featuresIntro: '从搜索到阅读，把常用功能放在顺手的地方。',
      searchTitle: '多平台搜索', searchBody: '关键词只输入一次，快速切换搜索、视频、社区与 AI 平台；支持选中文字搜索、语音输入与自定义搜索源。',
      blockTitle: '广告拦截与标记', blockBody: '拦截广告请求、隐藏广告占位，支持第三方规则订阅、手动点选标记页面广告与按站点管理开关。',
      downloadTitle: 'BT 与资源下载管理', downloadBody: '支持磁力链接与 .torrent 种子 BT 下载、选文件与断点续传；自动嗅探网页音视频、图片与文档并批量保存。',
      videoTitle: '音视频增强播放', videoBody: '网页视频与 HLS 流媒体支持倍速、长按临时加速、悬浮小窗、画中画（PiP）、后台播放、AirPlay 投屏与视频截帧。',
      readerTitle: '电子书与阅读模式', readerBody: '网页阅读模式支持正文提取与下一页自动续读；内置阅读器支持 EPUB、PDF、TXT、MOBI、AZW3 电子书与简繁转换。',
      archiveTitle: '解压与局域网互传', archiveBody: '内置文件管理支持 ZIP、RAR、7z 解压与密码保护压缩，支持列表与封面网格浏览、相册导入及 Wi-Fi 局域网传输。',
      translateTitle: '网页翻译与工具箱', translateBody: '翻译当前网页并在打开新链接时自动延续翻译；支持整页长截图、导出 PDF、图片 OCR 文字识别与带图标二维码。',
      customTitle: '脚本与浏览器扩展', customBody: '导入、编辑和运行 JavaScript 用户脚本（UserScript），安装兼容的 WebExtension 扩展，自定义工具栏、壁纸与首页快捷按钮。',
      privacyTitle: '本地隐私与默认浏览器', privacyBody: '历史与收藏默认存放在设备上，支持无痕浏览、桌面书签 HTML 导入导出与 iCloud 设置同步，可设为系统默认浏览器。',
      sourceNote: '把常用网站加入你的搜索列表。', exploreSources: '浏览搜索源目录', privacy: '隐私政策', support: '技术支持',
      light: '切换至浅色外观', dark: '切换至深色外观',
      metaTitle: 'Soulo 浏览器 — 多平台搜索、广告拦截与 BT 下载管理',
      metaDescription: 'Soulo 是一款 iPhone 多平台搜索浏览器。一次输入切换 40+ 搜索与 AI 平台，支持广告拦截、BT 与资源下载管理、画中画视频播放、电子书阅读、解压互传、网页翻译和脚本扩展。'
    },
    en: {
      skip: 'Skip to content', navigation: 'Main navigation', sources: 'Sources', movies: 'Movies', magnets: 'Magnets', pans: 'Cloud', reading: 'Reading', music: 'Music', tools: 'Tools', menu: 'Menu', browser: 'Browser',
      moviesTitle: 'Find your next favorite story.', moviesIntro: 'Explore a Chinese-language directory of film, series, anime, subtitle, and watchlist websites.', exploreMovies: 'Explore the watch guide',
      eyebrow: 'Multi-platform search, made for iPhone', tagline: 'One query. More places to search.',
      intro: 'Switch between 40+ search, video, community, and AI platforms.\nAd blocking, BT & media downloads, PiP playback, translation, and extensions, all within reach.',
      downloadOn: 'Download on the', availability: 'iOS 17.0 or later · No Soulo account needed', scan: 'Scan with your iPhone', scanHint: 'Or search for Soulo on the App Store',
      qrLink: 'Download Soulo on the App Store', qrAlt: 'QR code to download Soulo on the App Store',
      darkScreenshot: 'Soulo Home screen with a mountain wallpaper and search bar', lightScreenshot: 'Soulo Home screen with a light wallpaper and platform groups', screenshots: 'Actual Soulo app screens',
      featuresTitle: 'Your everyday browsing essentials.', featuresIntro: 'From searching to reading, keep useful tools close at hand.',
      searchTitle: 'Multi-platform search', searchBody: 'Enter a query once, then switch between search engines, video, communities, and AI. Supports text-selection search, voice input, and custom sources.',
      blockTitle: 'Ad blocking & element picker', blockBody: 'Block ad requests and hide empty ad spaces. Subscribe to third-party filter lists, manually pick page elements to hide, and set per-site rules.',
      downloadTitle: 'BT & resource downloads', downloadBody: 'Download magnet links and .torrent files with file selection and pause/resume. Automatically detect and batch-save web video, audio, images, and documents.',
      videoTitle: 'Enhanced video & audio player', videoBody: 'Play web video and HLS streams with speed controls, long-press speed-up, floating window, Picture-in-Picture (PiP), background audio, AirPlay, and frame capture.',
      readerTitle: 'eBook & reader mode', readerBody: 'Read clutter-free articles with automatic next-page loading, or open EPUB, PDF, TXT, MOBI, and AZW3 eBooks with Simplified/Traditional Chinese conversion.',
      archiveTitle: 'Archive manager & Wi-Fi transfer', archiveBody: 'Extract ZIP, RAR, and 7z archives or create password-protected archives. Browse files in list or cover grid view and transfer over local Wi-Fi.',
      translateTitle: 'Page translation & web toolbox', translateBody: 'Translate pages and automatically keep translating followed links. Capture full-page screenshots, export PDFs, run image OCR, and generate QR codes.',
      customTitle: 'UserScripts & WebExtensions', customBody: 'Import, edit, and run JavaScript UserScripts, install compatible WebExtensions, and customize your toolbar, wallpapers, and home shortcuts.',
      privacyTitle: 'Local privacy & default browser', privacyBody: 'History and bookmarks stay on your device by default. Includes private browsing, HTML bookmark import/export, optional iCloud settings sync, and iOS default browser support.',
      sourceNote: 'Add your favorite websites to your search list.', exploreSources: 'Browse search sources', privacy: 'Privacy', support: 'Support',
      light: 'Switch to light appearance', dark: 'Switch to dark appearance',
      metaTitle: 'Soulo Browser — Multi-platform search, ad blocking & BT downloads',
      metaDescription: 'A multi-platform browser for iPhone. Switch between 40+ search and AI platforms with one query. Includes ad blocking, BT & media downloads, PiP video playback, eBook reader, archive extraction, page translation, and extensions.'
    }
  };
  const read = key => { try { return localStorage.getItem(key); } catch { return null; } };
  const write = (key, value) => { try { localStorage.setItem(key, value); } catch {} };
  const savedLanguage = read('soulo-language');
  let language = ['zh', 'en'].includes(savedLanguage) ? savedLanguage : 'zh';
  const savedTheme = read('soulo-theme');
  let theme = ['light', 'dark'].includes(savedTheme) ? savedTheme : 'dark';
  const themeButton = document.getElementById('theme-toggle');
  const languageButton = document.getElementById('language-toggle');
  function applyTheme() {
    const resolved = theme === 'light' ? 'light' : 'dark';
    document.documentElement.dataset.resolvedTheme = resolved;
    document.documentElement.dataset.theme = theme;
    const label = messages[language][resolved === 'dark' ? 'light' : 'dark'];
    themeButton.setAttribute('aria-label', label);
    themeButton.title = label;
    themeButton.setAttribute('aria-pressed', String(resolved === 'dark'));
    themeButton.innerHTML = resolved === 'dark' ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg>' : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><path d="M20.4 14.3A8.7 8.7 0 0 1 9.7 3.6a8.7 8.7 0 1 0 10.7 10.7Z"/></svg>';
    document.querySelectorAll('meta[name="theme-color"]').forEach(meta => { meta.content = resolved === 'dark' ? '#191a23' : '#f6f7fb'; });
  }
  function applyLanguage() {
    const t = messages[language];
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    document.querySelectorAll('[data-i18n]').forEach(element => {
      element.replaceChildren();
      t[element.dataset.i18n].split('\n').forEach((line, index) => {
        if (index) element.append(document.createElement('br'));
        element.append(document.createTextNode(line));
      });
    });
    document.querySelectorAll('[data-label]').forEach(element => element.setAttribute('aria-label', t[element.dataset.label]));
    document.querySelectorAll('[data-alt]').forEach(element => element.alt = t[element.dataset.alt]);
    document.querySelector('.brand').setAttribute('aria-label', language === 'zh' ? 'Soulo 首页' : 'Soulo home');
    const secondaryScreenshot = document.getElementById('secondary-screenshot');
    secondaryScreenshot.src = secondaryScreenshot.dataset[language === 'en' ? 'srcEn' : 'srcZh'];
    languageButton.textContent = language === 'zh' ? 'EN' : '中文';
    languageButton.setAttribute('aria-label', language === 'zh' ? 'Switch to English' : '切换至中文');
    languageButton.title = languageButton.getAttribute('aria-label');
    document.title = t.metaTitle;
    ['meta[property="og:title"]', 'meta[name="twitter:title"]'].forEach(selector => document.querySelector(selector).content = t.metaTitle);
    ['meta[name="description"]', 'meta[property="og:description"]', 'meta[name="twitter:description"]'].forEach(selector => document.querySelector(selector).content = t.metaDescription);
    document.querySelector('meta[property="og:locale"]').content = language === 'zh' ? 'zh_CN' : 'en_US';
    applyTheme();
  }
  languageButton.addEventListener('click', () => { language = language === 'zh' ? 'en' : 'zh'; write('soulo-language', language); applyLanguage(); });
  themeButton.addEventListener('click', () => { theme = document.documentElement.dataset.resolvedTheme === 'dark' ? 'light' : 'dark'; write('soulo-theme', theme); applyTheme(); });
  window.addEventListener('storage', event => {
    if (event.key === 'soulo-theme') { theme = event.newValue === 'light' ? 'light' : 'dark'; applyTheme(); }
    if (event.key === 'soulo-language') { language = event.newValue === 'en' ? 'en' : 'zh'; applyLanguage(); }
  });
  applyLanguage();
})();
