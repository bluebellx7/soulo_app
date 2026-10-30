(() => {
  'use strict';
  const button = document.getElementById('theme-toggle');
  const system = matchMedia('(prefers-color-scheme: dark)');
  let theme = 'system';
  try { theme = localStorage.getItem('soulo-theme') || 'system'; } catch {}
  function applyTheme() {
    const dark = theme === 'dark' || (theme !== 'light' && system.matches);
    document.documentElement.dataset.resolvedTheme = dark ? 'dark' : 'light';
    document.documentElement.dataset.theme = theme;
    if (button) {
      button.setAttribute('aria-pressed', String(dark));
      button.setAttribute('aria-label', dark ? '切换至浅色外观' : '切换至深色外观');
      button.title = button.getAttribute('aria-label');
      button.innerHTML = dark ? '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg>' : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" width="19" height="19" aria-hidden="true"><path d="M20.4 14.3A8.7 8.7 0 0 1 9.7 3.6a8.7 8.7 0 1 0 10.7 10.7Z"/></svg>';
    }
    document.querySelectorAll('meta[name="theme-color"]').forEach(meta => { meta.content = dark ? '#111217' : '#f6f7fb'; });
  }
  button?.addEventListener('click', () => {
    theme = document.documentElement.dataset.resolvedTheme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('soulo-theme', theme); } catch {}
    applyTheme();
  });
  system.addEventListener('change', applyTheme);
  window.addEventListener('storage', event => {
    if (event.key === 'soulo-theme') { theme = event.newValue || 'system'; applyTheme(); }
  });
  applyTheme();
})();
