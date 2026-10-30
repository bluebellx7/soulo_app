(() => {
  'use strict';
  const data = JSON.parse(document.getElementById('source-data').textContent);
  const sources = data.sources;
  const categories = data.categories;
  const cards = [...document.querySelectorAll('.source-card')];
  const sections = [...document.querySelectorAll('.source-category')];
  const links = [...document.querySelectorAll('[data-source-category]')];
  const input = document.getElementById('filterInput');
  const copyVisible = document.getElementById('copyVisibleButton');
  const preview = document.getElementById('jsonPreview');
  const panel = document.getElementById('jsonPanel');
  const toast = document.getElementById('toast');
  const timers = new WeakMap();
  let category = 'all';
  let toastTimer;
  const visible = () => cards.filter(card => !card.hidden).map(card => sources[Number(card.dataset.index)]);
  const config = items => JSON.stringify(items.map(source => ({name: source.name, url: source.url})), null, 2);

  function announce(message) {
    clearTimeout(toastTimer);
    toast.textContent = message;
    toast.classList.add('is-visible');
    toastTimer = setTimeout(() => toast.classList.remove('is-visible'), 2600);
  }
  function filter() {
    const terms = input.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    let count = 0;
    sections.forEach(section => {
      let matches = 0;
      section.querySelectorAll('.source-card').forEach(card => {
        card.hidden = !(category === 'all' || section.dataset.category === category) || !terms.every(term => card.dataset.search.includes(term));
        if (!card.hidden) { matches++; count++; }
      });
      section.hidden = matches === 0;
      section.querySelector('.category-count').textContent = String(matches);
    });
    links.forEach(link => {
      const active = link.dataset.sourceCategory === category;
      link.classList.toggle('is-active', active);
      if (active) link.setAttribute('aria-current', 'true'); else link.removeAttribute('aria-current');
    });
    const selected = categories.find(c => c.id === category);
    document.getElementById('filterMeta').textContent = selected ? `${selected.name} · ${count} 个搜索源` : terms.length ? `找到 ${count} 个搜索源` : `共 ${count} 个可导入的搜索源`;
    copyVisible.querySelector('span').textContent = terms.length || category !== 'all' ? '复制结果' : '复制全部';
    copyVisible.setAttribute('aria-label', `复制当前 ${count} 个搜索源的配置`);
    copyVisible.disabled = count === 0;
    document.getElementById('emptyState').hidden = count !== 0;
    if (panel.open) preview.textContent = config(visible());
  }
  async function copyText(text) {
    if (navigator.clipboard?.writeText) {
      try { await navigator.clipboard.writeText(text); return; } catch {}
    }
    const field = document.createElement('textarea');
    const focused = document.activeElement;
    field.value = text;
    field.setAttribute('readonly', '');
    field.style.cssText = 'position:fixed;left:-9999px;top:0';
    document.body.appendChild(field);
    field.select();
    try { if (!document.execCommand('copy')) throw new Error('Clipboard unavailable'); }
    finally { field.remove(); focused?.focus({preventScroll: true}); }
  }
  async function copy(items, button) {
    if (!items.length) return;
    const text = config(items);
    preview.textContent = text;
    try { await copyText(text); }
    catch {
      panel.open = true;
      preview.focus();
      announce('请在配置预览中选择文字并复制。');
      return;
    }
    clearTimeout(timers.get(button));
    button.dataset.copyState = 'copied';
    announce(items.length === 1 ? `已复制 ${items[0].name}` : `已复制 ${items.length} 个搜索源`);
    timers.set(button, setTimeout(() => { delete button.dataset.copyState; }, 1800));
  }
  links.forEach(link => link.addEventListener('click', event => {
    event.preventDefault();
    category = link.dataset.sourceCategory;
    input.value = '';
    filter();
    document.getElementById('source-tools').scrollIntoView({block: 'start'});
  }));
  cards.forEach(card => card.querySelector('.source-copy').addEventListener('click', event => copy([sources[Number(card.dataset.index)]], event.currentTarget)));
  sections.forEach(section => section.querySelector('.category-copy').addEventListener('click', event => {
    const items = [...section.querySelectorAll('.source-card')].filter(card => !card.hidden).map(card => sources[Number(card.dataset.index)]);
    copy(items, event.currentTarget);
  }));
  input.addEventListener('input', () => { category = 'all'; filter(); });
  copyVisible.addEventListener('click', () => copy(visible(), copyVisible));
  panel.addEventListener('toggle', () => { if (panel.open && !preview.textContent) preview.textContent = config(visible()); });
  document.getElementById('source-reset').addEventListener('click', () => { category = 'all'; input.value = ''; filter(); input.focus(); });
  document.addEventListener('keydown', event => {
    const editing = event.target instanceof Element && (event.target.matches('input,textarea,select') || event.target.isContentEditable);
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.altKey && !editing) { event.preventDefault(); input.focus(); }
    if (event.key === 'Escape' && document.activeElement === input) { input.value = ''; filter(); input.blur(); }
  });
  filter();
})();
