(() => {
  'use strict';
  const cards = [...document.querySelectorAll('.movie-card')];
  const sections = [...document.querySelectorAll('.movie-category')];
  const categoryLinks = [...document.querySelectorAll('[data-category]')];
  const search = document.getElementById('movie-search');
  const allButton = document.getElementById('show-all');
  const favoritesButton = document.getElementById('show-favorites');
  const empty = document.getElementById('movie-empty');
  const meta = document.getElementById('results-meta');
  const toast = document.getElementById('movie-toast');
  const knownIds = new Set(cards.map(card => card.dataset.site));
  let favorites = new Set();
  let category = 'all';
  let favoritesOnly = false;
  let timer;
  try {
    const stored = JSON.parse(localStorage.getItem('soulo-movie-favorites') || '[]');
    if (Array.isArray(stored)) favorites = new Set(stored.filter(id => knownIds.has(id)));
  } catch {}
  function announce(message) {
    clearTimeout(timer);
    toast.textContent = message;
    toast.classList.add('is-visible');
    timer = setTimeout(() => toast.classList.remove('is-visible'), 2300);
  }
  function updateFavorites() {
    document.getElementById('favorite-count').textContent = String(favorites.size);
    cards.forEach(card => {
      const button = card.querySelector('[data-favorite]');
      const saved = favorites.has(card.dataset.site);
      const name = card.querySelector('h3').textContent;
      button.setAttribute('aria-pressed', String(saved));
      button.setAttribute('aria-label', `${saved ? '取消收藏' : '收藏'}${name}`);
      button.title = button.getAttribute('aria-label');
    });
  }
  function filter() {
    const terms = search.value.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    let count = 0;
    sections.forEach(section => {
      let sectionCount = 0;
      section.querySelectorAll('.movie-card').forEach(card => {
        const matches = (category === 'all' || section.dataset.section === category)
          && (!favoritesOnly || favorites.has(card.dataset.site))
          && terms.every(term => card.dataset.search.includes(term));
        card.hidden = !matches;
        if (matches) { sectionCount++; count++; }
      });
      section.hidden = sectionCount === 0;
      section.querySelector('.section-count').textContent = String(sectionCount);
    });
    categoryLinks.forEach(link => {
      const active = link.dataset.category === category;
      link.classList.toggle('is-active', active);
      if (active) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    });
    allButton.setAttribute('aria-pressed', String(!favoritesOnly));
    favoritesButton.setAttribute('aria-pressed', String(favoritesOnly));
    meta.textContent = favoritesOnly ? `我的收藏 · ${count} 个网站` : terms.length || category !== 'all' ? `找到 ${count} 个网站` : `共 ${cards.length} 个影视网站`;
    empty.hidden = count !== 0;
    const noFavorites = favoritesOnly && favorites.size === 0;
    document.getElementById('empty-title').textContent = noFavorites ? '把喜欢的入口留在这里' : '没有找到匹配的网站';
    document.getElementById('empty-description').textContent = noFavorites ? '点击网站卡片上的爱心，建立自己的观影收藏夹。' : '试试网站名称、域名，或“动漫”“字幕”等分类。';
  }
  categoryLinks.forEach(link => link.addEventListener('click', event => {
    event.preventDefault();
    category = link.dataset.category;
    search.value = '';
    filter();
    document.getElementById('directory').scrollIntoView({block: 'start'});
  }));
  cards.forEach(card => card.querySelector('[data-favorite]').addEventListener('click', () => {
    const id = card.dataset.site;
    if (favorites.has(id)) favorites.delete(id); else favorites.add(id);
    let persisted = true;
    try { localStorage.setItem('soulo-movie-favorites', JSON.stringify([...favorites])); }
    catch { persisted = false; }
    updateFavorites();
    filter();
    announce(persisted ? (favorites.has(id) ? '已加入我的收藏' : '已取消收藏') : '当前浏览器无法保存，收藏仅在本页有效');
  }));
  allButton.addEventListener('click', () => { favoritesOnly = false; filter(); });
  favoritesButton.addEventListener('click', () => { favoritesOnly = true; category = 'all'; search.value = ''; filter(); });
  search.addEventListener('input', () => { category = 'all'; filter(); });
  document.getElementById('reset-filters').addEventListener('click', () => { search.value = ''; category = 'all'; favoritesOnly = false; filter(); search.focus(); });
  document.addEventListener('keydown', event => {
    const editing = event.target instanceof Element && (event.target.matches('input, textarea, select') || event.target.isContentEditable);
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.altKey && !editing) { event.preventDefault(); search.focus(); }
    if (event.key === 'Escape' && document.activeElement === search) { search.value = ''; filter(); search.blur(); }
  });
  window.addEventListener('storage', event => {
    if (event.key !== 'soulo-movie-favorites' && event.key !== null) return;
    try {
      const stored = JSON.parse(event.newValue || '[]');
      favorites = new Set(Array.isArray(stored) ? stored.filter(id => knownIds.has(id)) : []);
    } catch { favorites = new Set(); }
    updateFavorites(); filter();
  });
  updateFavorites();
  filter();
})();
