(() => {
  'use strict';
  const button = document.getElementById('theme-toggle');
  const languageButton = document.getElementById('language-toggle');
  const navigation = document.querySelector('[data-shared-nav]');
  const labels = {
    zh: {sources:'搜索源', movies:'影视导航', navigation:'主导航', home:'Soulo 首页', light:'切换至浅色外观', dark:'切换至深色外观'},
    en: {sources:'Sources', movies:'Movies', navigation:'Main navigation', home:'Soulo home', light:'Switch to light appearance', dark:'Switch to dark appearance'}
  };
  let language = /^zh/i.test(navigator.language) ? 'zh' : 'en';
  const system = matchMedia('(prefers-color-scheme: dark)');
  let theme = 'system';
  try { theme = localStorage.getItem('soulo-theme') || 'system'; } catch {}
  try { const saved = localStorage.getItem('soulo-language'); if (saved === 'zh' || saved === 'en') language = saved; } catch {}
  function applyTheme() {
    const dark = theme === 'dark' || (theme !== 'light' && system.matches);
    document.documentElement.dataset.resolvedTheme = dark ? 'dark' : 'light';
    document.documentElement.dataset.theme = theme;
    if (button) {
      button.setAttribute('aria-pressed', String(dark));
      button.setAttribute('aria-label', labels[language][dark ? 'light' : 'dark']);
      button.title = button.getAttribute('aria-label');
      button.innerHTML = dark ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg>' : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><path d="M20.4 14.3A8.7 8.7 0 0 1 9.7 3.6a8.7 8.7 0 1 0 10.7 10.7Z"/></svg>';
    }
    document.querySelectorAll('meta[name="theme-color"]').forEach(meta => { meta.content = dark ? '#111217' : '#f6f7fb'; });
  }
  function applyNavigationLanguage() {
    if (navigation) {
      navigation.lang = language === 'zh' ? 'zh-CN' : 'en';
      navigation.querySelectorAll('[data-nav-i18n]').forEach(link => { link.textContent = labels[language][link.dataset.navI18n]; });
      navigation.querySelector('nav').setAttribute('aria-label', labels[language].navigation);
      navigation.querySelector('.brand').setAttribute('aria-label', labels[language].home);
    }
    if (languageButton) {
      languageButton.textContent = language === 'zh' ? 'EN' : '中文';
      languageButton.setAttribute('aria-label', language === 'zh' ? 'Switch navigation to English' : '切换导航为中文');
      languageButton.title = language === 'zh' ? '切换导航语言，目录内容为中文' : 'Switch navigation language; directory content is in Chinese';
    }
    applyTheme();
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
    if (event.key === 'soulo-theme') { theme = event.newValue || 'system'; applyTheme(); }
    if (event.key === 'soulo-language') { language = event.newValue === 'en' ? 'en' : 'zh'; applyNavigationLanguage(); }
  });
  applyNavigationLanguage();
})();
