(() => {
  'use strict';
  const messages = {
    zh: {
      skip: '跳到主要内容', navigation: '主导航', features: '功能', sources: '搜索源', browser: '浏览器',
      eyebrow: '为 iPhone 打造的多平台搜索浏览器', tagline: '一次输入，搜索更多。',
      intro: '在 40+ 搜索、视频、社区和 AI 平台间快速切换。\n广告拦截、下载管理、网页翻译，常用功能一步即达。',
      downloadOn: '下载于', availability: 'iOS 17.0 及以上 · 无需注册 Soulo 账号', scan: '用 iPhone 扫码下载', scanHint: '或直接在 App Store 搜索 Soulo',
      qrLink: '前往 App Store 下载 Soulo', qrAlt: 'Soulo App Store 下载二维码',
      darkScreenshot: 'Soulo 深色首页，展示搜索栏和平台分组', lightScreenshot: 'Soulo 浅色首页，展示自定义壁纸和平台分组', screenshots: 'Soulo App 实际界面',
      featuresTitle: '日常浏览，需要的都在。', featuresIntro: '从搜索到阅读，把常用功能放在顺手的地方。',
      searchTitle: '多平台搜索', searchBody: '关键词只输入一次，快速切换搜索、视频、社区与 AI 平台，也支持添加自己的搜索源。',
      blockTitle: '广告拦截', blockBody: '拦截广告请求、隐藏广告占位，支持订阅规则和站点例外，让浏览更清爽。',
      downloadTitle: '下载管理', downloadBody: '发现网页中的可下载资源，查看下载进度，管理、分享和打开已保存的文件。',
      translateTitle: '网页翻译', translateBody: '选择目标语言，翻译当前网页；还可保存网页长截图或导出 PDF，方便随时查看。',
      customTitle: '扩展与自定义', customBody: '按需安装用户脚本，自定义工具栏、首页壁纸和搜索平台，让浏览器适合你的习惯。',
      privacyTitle: '本地记录与无痕浏览', privacyBody: '历史与收藏默认保存在设备上。支持无痕浏览，也可以随时清除浏览记录与网站数据。',
      sourceNote: '把常用网站加入你的搜索列表。', exploreSources: '浏览搜索源目录', privacy: '隐私政策', support: '技术支持',
      light: '切换至浅色外观', dark: '切换至深色外观',
      metaTitle: 'Soulo 浏览器 — 多平台搜索、广告拦截与下载管理',
      metaDescription: 'Soulo 是一款 iPhone 多平台搜索浏览器。一次输入，切换 40+ 搜索与 AI 平台，支持广告拦截、下载管理、网页翻译和自定义扩展。'
    },
    en: {
      skip: 'Skip to content', navigation: 'Main navigation', features: 'Features', sources: 'Sources', browser: 'Browser',
      eyebrow: 'MULTI-PLATFORM SEARCH, MADE FOR IPHONE', tagline: 'One query. More places to search.',
      intro: 'Switch between 40+ search, video, community, and AI platforms.\nAd blocking, downloads, and page translation, all within reach.',
      downloadOn: 'Download on the', availability: 'iOS 17.0 or later · No Soulo account needed', scan: 'Scan with your iPhone', scanHint: 'Or search for Soulo on the App Store',
      qrLink: 'Download Soulo on the App Store', qrAlt: 'QR code to download Soulo on the App Store',
      darkScreenshot: 'Soulo Home screen in dark appearance, with search and platform groups', lightScreenshot: 'Soulo Home screen with a light wallpaper and platform groups', screenshots: 'ACTUAL SOULO APP SCREENS',
      featuresTitle: 'Your everyday browsing essentials.', featuresIntro: 'From searching to reading, keep useful tools close at hand.',
      searchTitle: 'Multi-platform search', searchBody: 'Enter a query once, then switch between search engines, video, communities, and AI. Add your own search sources, too.',
      blockTitle: 'Ad blocking', blockBody: 'Block ad requests and hide empty ad spaces. Customize subscriptions and site exceptions for cleaner browsing.',
      downloadTitle: 'Download manager', downloadBody: 'Find downloadable resources on a page, track progress, and manage, share, or open your saved files.',
      translateTitle: 'Page translation', translateBody: 'Translate the current page into your chosen language. Save a full-page screenshot or export a PDF for later.',
      customTitle: 'Extensions & customization', customBody: 'Install user scripts when you need them. Arrange your toolbar, choose a wallpaper, and customize your search platforms.',
      privacyTitle: 'Local history & private browsing', privacyBody: 'History and bookmarks stay on your device by default. Browse privately and clear browsing history or website data whenever you choose.',
      sourceNote: 'Add your favorite websites to your search list.', exploreSources: 'Browse search sources', privacy: 'Privacy', support: 'Support',
      light: 'Switch to light appearance', dark: 'Switch to dark appearance',
      metaTitle: 'Soulo Browser — Multi-platform search, ad blocking & downloads',
      metaDescription: 'A multi-platform browser for iPhone. Switch between 40+ search and AI platforms with one query. Includes ad blocking, downloads, page translation, and extensions.'
    }
  };
  const read = key => { try { return localStorage.getItem(key); } catch { return null; } };
  const write = (key, value) => { try { localStorage.setItem(key, value); } catch {} };
  const savedLanguage = read('soulo-language');
  let language = ['zh', 'en'].includes(savedLanguage) ? savedLanguage : (/^zh/i.test(navigator.language) ? 'zh' : 'en');
  const systemTheme = matchMedia('(prefers-color-scheme: dark)');
  let theme = read('soulo-theme') || 'system';
  const themeButton = document.getElementById('theme-toggle');
  const languageButton = document.getElementById('language-toggle');
  function applyTheme() {
    const resolved = ['light', 'dark'].includes(theme) ? theme : (systemTheme.matches ? 'dark' : 'light');
    document.documentElement.dataset.resolvedTheme = resolved;
    document.documentElement.dataset.theme = theme;
    const label = messages[language][resolved === 'dark' ? 'light' : 'dark'];
    themeButton.setAttribute('aria-label', label);
    themeButton.title = label;
    themeButton.setAttribute('aria-pressed', String(resolved === 'dark'));
    document.querySelectorAll('meta[name="theme-color"]').forEach(meta => { meta.content = resolved === 'dark' ? '#22271f' : '#f4f1e9'; });
  }
  function applyLanguage() {
    const t = messages[language];
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    document.querySelectorAll('[data-i18n]').forEach(element => {
      if (element.dataset.i18n === 'intro') {
        element.textContent = t.intro.replaceAll('\n', ' ');
        return;
      }
      element.replaceChildren();
      t[element.dataset.i18n].split('\n').forEach((line, index) => {
        if (index) element.append(document.createElement('br'));
        element.append(document.createTextNode(line));
      });
    });
    document.querySelectorAll('[data-label]').forEach(element => element.setAttribute('aria-label', t[element.dataset.label]));
    document.querySelectorAll('[data-alt]').forEach(element => element.alt = t[element.dataset.alt]);
    document.querySelector('.brand').setAttribute('aria-label', language === 'zh' ? 'Soulo 首页' : 'Soulo home');
    document.getElementById('primary-screenshot').src = `images/soulo-home-${language}.webp`;
    document.getElementById('secondary-screenshot').src = `images/soulo-home-light-${language}.webp`;
    languageButton.textContent = language === 'zh' ? 'EN' : '中文';
    languageButton.setAttribute('aria-label', language === 'zh' ? 'Switch to English' : '切换至中文');
    document.title = t.metaTitle;
    ['meta[property="og:title"]', 'meta[name="twitter:title"]'].forEach(selector => document.querySelector(selector).content = t.metaTitle);
    ['meta[name="description"]', 'meta[property="og:description"]', 'meta[name="twitter:description"]'].forEach(selector => document.querySelector(selector).content = t.metaDescription);
    document.querySelector('meta[property="og:locale"]').content = language === 'zh' ? 'zh_CN' : 'en_US';
    applyTheme();
  }
  languageButton.addEventListener('click', () => { language = language === 'zh' ? 'en' : 'zh'; write('soulo-language', language); applyLanguage(); });
  themeButton.addEventListener('click', () => { theme = document.documentElement.dataset.resolvedTheme === 'dark' ? 'light' : 'dark'; write('soulo-theme', theme); applyTheme(); });
  systemTheme.addEventListener('change', applyTheme);
  applyLanguage();
})();
