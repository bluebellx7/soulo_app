(() => {
  'use strict';
  const cards = [...document.querySelectorAll('.movie-card')];
  const cardMap = new Map(cards.map(card => [card.dataset.site, card]));
  const sections = [...document.querySelectorAll('.movie-category')];
  const categoryLinks = [...document.querySelectorAll('[data-category]')];
  const search = document.getElementById('movie-search');
  const allButton = document.getElementById('show-all');
  const favoritesButton = document.getElementById('show-favorites');
  const favoritePicks = document.getElementById('favorite-picks');
  const favoritePicksTitle = document.getElementById('favorite-picks-title');
  const favoritePicksGrid = document.getElementById('favorite-picks-grid');
  const browseLink = document.querySelector('.browse-link');
  const empty = document.getElementById('movie-empty');
  const meta = document.getElementById('results-meta');
  const toast = document.getElementById('movie-toast');
  const knownIds = new Set(cards.map(card => card.dataset.site));
  const storageKey = document.body.dataset.favoritesKey || 'soulo-movie-favorites';
  const isMagnets = document.body.classList.contains('magnets-page');
  const isPans = document.body.classList.contains('pans-page');
  let directoryLocales = null;
  try {
    const content = document.getElementById('directory-locales');
    if (content) directoryLocales = JSON.parse(content.textContent);
  } catch {}
  let favorites = new Set();
  let category = 'all';
  let favoritesOnly = false;
  let timer;
  const isEn = () => document.documentElement.lang === 'en';
  try {
    const stored = JSON.parse(localStorage.getItem(storageKey) || '[]');
    if (Array.isArray(stored)) favorites = new Set(stored.filter(id => knownIds.has(id)));
  } catch {}
  function announce(message) {
    clearTimeout(timer);
    toast.textContent = message;
    toast.classList.add('is-visible');
    timer = setTimeout(() => toast.classList.remove('is-visible'), 2300);
  }
  function renderFavoritePicks() {
    if (!favoritePicks || !favoritePicksGrid) return;
    const savedCards = [...favorites].map(id => cardMap.get(id)).filter(Boolean);
    favoritePicks.hidden = savedCards.length === 0;
    if (favoritePicksTitle) {
      favoritePicksTitle.textContent = isEn()
        ? `My Favorites · ${savedCards.length} saved ${savedCards.length === 1 ? 'site' : 'sites'}`
        : `我的收藏 · ${savedCards.length} 个常用入口`;
    }
    const fragment = document.createDocumentFragment();
    savedCards.forEach(card => {
      const sourceLink = card.querySelector('.movie-card-link');
      const name = card.querySelector('h3').textContent;
      const tag = card.querySelector('.site-tags span')?.textContent || '';
      const domain = card.querySelector('.site-domain')?.textContent || '';
      const pick = document.createElement('a');
      pick.className = 'quick-pick';
      pick.href = sourceLink.href;
      pick.target = '_blank';
      pick.rel = 'noopener noreferrer';
      pick.dataset.favoritePick = card.dataset.site;
      const mark = card.querySelector('.site-mark').cloneNode(true);
      mark.className = mark.className.replace(/\bsite-mark\b/, 'quick-mark');
      const img = mark.querySelector('img');
      if (img) { img.width = 32; img.height = 32; }
      const textWrap = document.createElement('span');
      const titleEl = document.createElement('strong');
      titleEl.textContent = name;
      const subEl = document.createElement('span');
      subEl.textContent = isEn() ? domain : (tag ? `${tag}入口` : domain);
      textWrap.append(titleEl, subEl);
      const arrow = card.querySelector('.movie-card-heading > svg').cloneNode(true);
      pick.append(mark, textWrap, arrow);
      fragment.appendChild(pick);
    });
    favoritePicksGrid.replaceChildren(fragment);
  }
  function updateFavorites() {
    document.getElementById('favorite-count').textContent = String(favorites.size);
    cards.forEach(card => {
      const button = card.querySelector('[data-favorite]');
      const saved = favorites.has(card.dataset.site);
      const name = card.querySelector('h3').textContent;
      button.setAttribute('aria-pressed', String(saved));
      const label = isEn()
        ? `${saved ? 'Remove ' : 'Save '}${name}${saved ? ' from favorites' : ' to favorites'}`
        : `${saved ? '取消收藏' : '收藏'}${name}`;
      button.setAttribute('aria-label', label);
      button.title = label;
    });
    renderFavoritePicks();
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
    if (isEn()) {
      meta.textContent = favoritesOnly
        ? `My Favorites · ${count} ${count === 1 ? 'website' : 'websites'}`
        : terms.length || category !== 'all'
          ? `Found ${count} ${count === 1 ? 'website' : 'websites'}`
          : isMagnets ? `${cards.length} magnet & torrent websites` : isPans ? `${cards.length} cloud drive search websites` : `${cards.length} streaming & movie websites`;
    } else {
      meta.textContent = favoritesOnly ? `我的收藏 · ${count} 个网站` : terms.length || category !== 'all' ? `找到 ${count} 个网站` : isMagnets ? `共 ${cards.length} 个磁力网站` : isPans ? `共 ${cards.length} 个网盘网站` : `共 ${cards.length} 个影视网站`;
    }
    empty.hidden = count !== 0;
    const noFavorites = favoritesOnly && favorites.size === 0;
    if (isEn()) {
      document.getElementById('empty-title').textContent = noFavorites ? (isMagnets ? 'Save your go-to magnet sites here' : isPans ? 'Save your go-to cloud search sites here' : 'Save your go-to watch sites here') : 'No matching websites found';
      document.getElementById('empty-description').textContent = noFavorites ? (isMagnets ? 'Click the heart icon on any card to build your personal magnet directory.' : isPans ? 'Click the heart icon on any card to build your personal cloud drive directory.' : 'Click the heart icon on any card to build your personal watchlist.') : (isMagnets ? 'Try searching by site name, domain, or keywords like DHT, 4K, or Anime.' : isPans ? 'Try searching by site name, domain, or keywords like Quark, Baidu, AliPan, or 4K.' : 'Try searching by site name, domain, or categories like Anime or Subtitles.');
    } else {
      document.getElementById('empty-title').textContent = noFavorites ? '把喜欢的入口留在这里' : '没有找到匹配的网站';
      document.getElementById('empty-description').textContent = noFavorites ? (isMagnets ? '点击网站卡片上的爱心，建立自己的磁力收藏夹。' : isPans ? '点击网站卡片上的爱心，建立自己的网盘收藏夹。' : '点击网站卡片上的爱心，建立自己的观影收藏夹。') : (isMagnets ? '试试网站名称、域名，或“DHT”“4K”“动漫”等关键词。' : isPans ? '试试网站名称、域名，或“夸克”“百度”“阿里”“4K”等关键词。' : '试试网站名称、域名，或“动漫”“字幕”等分类。');
    }
    const extra = directoryLocales?.[isEn() ? 'en' : 'zh'];
    if (extra) {
      if (!favoritesOnly && !terms.length && category === 'all') {
        meta.textContent = extra['directory.total'].replace('{count}', String(cards.length));
      }
      if (noFavorites && isEn()) document.getElementById('empty-title').textContent = extra['directory.emptyFavoritesTitle'];
      document.getElementById('empty-description').textContent = extra[noFavorites ? 'directory.emptyFavorites' : 'directory.emptyDescription'];
    }
  }
  if (browseLink) {
    browseLink.addEventListener('click', event => {
      if (favorites.size > 0 && favoritePicks && !favoritePicks.hidden) {
        event.preventDefault();
        favoritePicks.scrollIntoView({block: 'start', behavior: 'smooth'});
      }
    });
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
    try { localStorage.setItem(storageKey, JSON.stringify([...favorites])); }
    catch { persisted = false; }
    updateFavorites();
    filter();
    if (isEn()) {
      announce(persisted ? (favorites.has(id) ? 'Saved to My Favorites' : 'Removed from My Favorites') : 'Storage unavailable; favorites apply to this session only');
    } else {
      announce(persisted ? (favorites.has(id) ? '已加入我的收藏' : '已取消收藏') : '当前浏览器无法保存，收藏仅在本页有效');
    }
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
    if (event.key !== storageKey && event.key !== null) return;
    try {
      const stored = JSON.parse(event.newValue || '[]');
      favorites = new Set(Array.isArray(stored) ? stored.filter(id => knownIds.has(id)) : []);
    } catch { favorites = new Set(); }
    updateFavorites(); filter();
  });
  window.addEventListener('soulo:langchange', () => {
    updateFavorites();
    filter();
  });
  updateFavorites();
  filter();
})();
