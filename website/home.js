(() => {
  'use strict';
  const messages = {
    zh: {
      skip: '跳到主要内容', navigation: '主导航', features: '功能', sources: '搜索源', download: '下载 Soulo',
      eyebrow: '你的多平台搜索浏览器', headline1: '搜索的世界，', headline2: '简单一点。',
      intro: '一次输入，在搜索、视频、社区和 AI 平台间自由切换。\n少一点来回，多一点发现。',
      appStore: '在 App Store 下载', try: '体验平台切换', note: '专为 iOS 打造 · 无需注册 Soulo 账号',
      experience: '平台切换体验', demoLabel: '一个关键词，多种可能', demoEyebrow: '保持好奇，继续探索', demoTitle: '今天，想发现什么？',
      queryLabel: '搜索关键词', submit: '在所选平台搜索（新窗口）', choose: '选择一个平台，带着同一个问题出发',
      demoHint: '点击箭头，在新窗口打开搜索', previewCaption: '网页交互演示', platformCount: 'App 内置 40+ 平台，也支持添加你常用的网站。', viewSources: '浏览搜索源',
      less: 'LESS FRICTION. MORE DISCOVERY.', featuresTitle: '把时间，留给发现。', featuresIntro: '让搜索顺手，让浏览专注。',
      feature1Title: '换个平台，不换思路。', feature1Body: '关键词只输入一次。查资料、看视频、找讨论，随时切换平台，从不同角度找到答案。',
      feature2Title: '少些干扰，多些专注。', feature2Body: '开启广告拦截，让页面清爽一些。配合语音搜索和自定义平台，让常用操作更自然。',
      feature3Title: '你的记录，由你掌握。', feature3Body: '搜索历史与收藏默认保存在设备上。无需注册 Soulo 账号，搜索词直接发送到你选择的平台。',
      yourWeb: 'YOUR WEB, YOUR WAY.', sourceTitle: '你的常用网站，\n都可以更顺手。', sourceBody: '从搜索源目录挑选平台，导入 Soulo。\n把你的兴趣，整理成自己的搜索方式。', exploreSources: '探索搜索源目录',
      categories: '搜索源分类', category1: '搜索与知识', category2: '视频与社区', category3: 'AI 与灵感',
      downloadTitle: '下一次搜索，从这里开始。', downloadBody: '带上好奇心，剩下的交给 Soulo。', ios: '适用于 iOS', privacy: '隐私政策', support: '技术支持',
      light: '切换至浅色外观', dark: '切换至深色外观', sample: '周末去哪里',
      metaTitle: 'Soulo - 多平台搜索浏览器 | 一次输入，切换 40+ 平台', metaDescription: 'Soulo 是一款多平台搜索浏览器。一次输入关键词，在搜索、视频、社区和 AI 平台间自由切换。搜索历史与收藏默认保存在设备上。',
      web: '网页搜索', video: '视频搜索', community: '社区讨论', ai: 'AI 搜索'
    },
    en: {
      skip: 'Skip to content', navigation: 'Main navigation', features: 'Features', sources: 'Sources', download: 'Get Soulo',
      eyebrow: 'YOUR MULTI-PLATFORM SEARCH BROWSER', headline1: 'A world to explore.', headline2: 'A simpler way in.',
      intro: 'One query. Search engines, videos, communities, and AI.\nLess back and forth. More discovery.',
      appStore: 'Download on the App Store', try: 'Try switching platforms', note: 'Made for iOS · No Soulo account needed',
      experience: 'Try platform switching', demoLabel: 'One query. More possibilities.', demoEyebrow: 'STAY CURIOUS. KEEP EXPLORING.', demoTitle: 'What will you discover today?',
      queryLabel: 'Search query', submit: 'Search on the selected platform (new window)', choose: 'Pick a platform. Take the same question with you.',
      demoHint: 'Use the arrow to search in a new window', previewCaption: 'INTERACTIVE WEB DEMO', platformCount: '40+ built-in platforms in the app. Add your own, too.', viewSources: 'Browse sources',
      less: 'LESS FRICTION. MORE DISCOVERY.', featuresTitle: 'Make room for discovery.', featuresIntro: 'Effortless search. Focused browsing.',
      feature1Title: 'New platform. Same curiosity.', feature1Body: 'Enter your query once. Move between articles, videos, and discussions to find a different perspective without typing it again.',
      feature2Title: 'Less noise. More focus.', feature2Body: 'Enable ad blocking for a cleaner page. Voice search and custom platforms help make everyday browsing feel more natural.',
      feature3Title: 'Your history stays yours.', feature3Body: 'History and bookmarks stay on your device by default. No Soulo account needed. Queries go directly to the platform you choose.',
      yourWeb: 'YOUR WEB, YOUR WAY.', sourceTitle: 'Your favorite sites.\nA smoother way to search.', sourceBody: 'Choose platforms from the source directory and import them into Soulo. Make your interests part of your own search setup.', exploreSources: 'Explore the source directory',
      categories: 'Source categories', category1: 'Search & knowledge', category2: 'Video & community', category3: 'AI & inspiration',
      downloadTitle: 'Your next search starts here.', downloadBody: 'Bring your curiosity. Soulo will take it from there.', ios: 'Available for iOS', privacy: 'Privacy', support: 'Support',
      light: 'Switch to light appearance', dark: 'Switch to dark appearance', sample: 'Weekend getaway ideas',
      metaTitle: 'Soulo - A simpler way to search across 40+ platforms', metaDescription: 'One query. Search engines, videos, communities, and AI. Soulo makes it easy to switch platforms, with history and bookmarks stored on your device by default.',
      web: 'Web search', video: 'Video search', community: 'Community', ai: 'AI search'
    }
  };
  const providers = {
    google: { name: 'Google', category: 'web', url: 'https://www.google.com/search', parameter: 'q' },
    bing: { name: 'Bing', category: 'web', url: 'https://www.bing.com/search', parameter: 'q' },
    youtube: { name: 'YouTube', category: 'video', url: 'https://www.youtube.com/results', parameter: 'search_query' },
    bilibili: { name: '哔哩哔哩', category: 'video', url: 'https://search.bilibili.com/all', parameter: 'keyword' },
    zhihu: { name: '知乎', category: 'community', url: 'https://www.zhihu.com/search', parameter: 'q' },
    perplexity: { name: 'Perplexity', category: 'ai', url: 'https://www.perplexity.ai/search', parameter: 'q' }
  };
  const read = key => { try { return localStorage.getItem(key); } catch { return null; } };
  const write = (key, value) => { try { localStorage.setItem(key, value); } catch {} };
  const savedLanguage = read('soulo-language');
  let language = savedLanguage === 'zh' || savedLanguage === 'en' ? savedLanguage : (/^zh/i.test(navigator.language) ? 'zh' : 'en');
  const systemTheme = matchMedia('(prefers-color-scheme: dark)');
  const savedTheme = read('soulo-theme');
  let theme = savedTheme === 'light' || savedTheme === 'dark' ? savedTheme : 'system';
  const query = document.getElementById('search-query');
  const form = document.getElementById('search-form');
  const themeButton = document.getElementById('theme-toggle');
  const languageButton = document.getElementById('language-toggle');
  let queryEdited = false;
  query.addEventListener('input', () => { queryEdited = true; });

  function applyProvider() {
    const provider = providers[document.querySelector('input[name="platform"]:checked').value];
    form.action = provider.url;
    query.name = provider.parameter;
    const name = language === 'en' ? ({ '哔哩哔哩': 'Bilibili', '知乎': 'Zhihu' }[provider.name] || provider.name) : provider.name;
    document.getElementById('demo-selection').textContent = `${name} · ${messages[language][provider.category]}`;
  }
  function applyTheme() {
    const resolved = theme === 'system' ? (systemTheme.matches ? 'dark' : 'light') : theme;
    document.documentElement.dataset.resolvedTheme = resolved;
    document.documentElement.dataset.theme = theme;
    const label = messages[language][resolved === 'dark' ? 'light' : 'dark'];
    themeButton.setAttribute('aria-label', label);
    themeButton.title = label;
    themeButton.setAttribute('aria-pressed', String(resolved === 'dark'));
  }
  function applyLanguage() {
    const t = messages[language];
    document.documentElement.lang = language === 'zh' ? 'zh-CN' : 'en';
    document.querySelectorAll('[data-i18n]').forEach(element => {
      const lines = t[element.dataset.i18n].split('\n');
      element.replaceChildren();
      lines.forEach((line, index) => {
        if (index) element.append(document.createElement('br'));
        element.append(document.createTextNode(line));
      });
    });
    document.querySelectorAll('[data-label]').forEach(element => element.setAttribute('aria-label', t[element.dataset.label]));
    document.querySelector('.brand').setAttribute('aria-label', language === 'zh' ? 'Soulo 首页' : 'Soulo home');
    document.querySelectorAll('.platform-option').forEach(label => {
      const provider = providers[label.querySelector('input').value];
      label.querySelector('.platform-tile span').textContent = language === 'en' ? ({ '哔哩哔哩': 'Bilibili', '知乎': 'Zhihu' }[provider.name] || provider.name) : provider.name;
    });
    if (!queryEdited) query.value = t.sample;
    languageButton.textContent = language === 'zh' ? 'EN' : '中文';
    languageButton.setAttribute('aria-label', language === 'zh' ? 'Switch to English' : '切换至中文');
    document.title = t.metaTitle;
    ['meta[property="og:title"]', 'meta[name="twitter:title"]'].forEach(selector => document.querySelector(selector).content = t.metaTitle);
    ['meta[name="description"]', 'meta[property="og:description"]', 'meta[name="twitter:description"]'].forEach(selector => document.querySelector(selector).content = t.metaDescription);
    document.querySelector('meta[property="og:locale"]').content = language === 'zh' ? 'zh_CN' : 'en_US';
    applyProvider();
    applyTheme();
  }
  document.querySelectorAll('input[name="platform"]').forEach(input => input.addEventListener('change', applyProvider));
  languageButton.addEventListener('click', () => { language = language === 'zh' ? 'en' : 'zh'; write('soulo-language', language); applyLanguage(); });
  themeButton.addEventListener('click', () => { theme = document.documentElement.dataset.resolvedTheme === 'dark' ? 'light' : 'dark'; write('soulo-theme', theme); applyTheme(); });
  systemTheme.addEventListener('change', () => { if (theme === 'system') applyTheme(); });
  form.addEventListener('submit', event => {
    if (!query.value.trim()) { event.preventDefault(); query.value = ''; query.reportValidity(); }
  });
  applyLanguage();
})();
