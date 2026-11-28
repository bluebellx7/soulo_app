(() => {
  'use strict';
  const PRODUCTION_API = 'https://api2.dkluge.com/api/soulo/custom-market/v1';
  const APP_STORE = 'https://apps.apple.com/app/id6761165330';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const BLOCKED_KEY = 'soulo-market-blocked-authors';

  const list = document.getElementById('market-list');
  const platformDirectory = document.getElementById('market-platform-directory');
  const status = document.getElementById('market-status');
  const more = document.getElementById('market-more');
  const search = document.getElementById('market-search');
  const sortEl = document.getElementById('market-sort');
  const categoriesEl = document.getElementById('market-categories');
  const blockedBar = document.getElementById('market-blocked-bar');
  const dialog = document.getElementById('market-detail-dialog');
  const qrDialog = document.getElementById('market-qr-dialog');
  const dialogBody = document.getElementById('market-dialog-body');
  if (!list || !status || !more || !search || !categoriesEl) return;

  // Local API override is honoured ONLY when served from localhost/127.0.0.1.
  const local = ['localhost', '127.0.0.1'].includes(location.hostname);
  const queryParams = new URLSearchParams(location.search);
  const override = local ? queryParams.get('api') : null;
  const API = override && /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/api\/soulo\/custom-market\/v1$/.test(override) ? override : PRODUCTION_API;

  const MODULE_ORDER = ['home', 'newTab', 'widget', 'platform', 'script', 'webExtension'];
  const MODULE_NAMES = {
    home: ['首页', 'Home'],
    newTab: ['新标签页', 'New Tab'],
    widget: ['小组件', 'Widget'],
    platform: ['搜索平台', 'Search Platform'],
    script: ['用户脚本', 'User Script'],
    webExtension: ['浏览器扩展', 'Extension']
  };
  const MODULE_MARKS = { home: '⌂', newTab: '+', widget: '▦', platform: '⌕', script: '</>', webExtension: '❖' };
  const REPORT_CATEGORIES = [
    ['malicious', '恶意代码或安全风险', 'Malicious code or security risk'],
    ['inappropriate', '不当或违规内容', 'Inappropriate content'],
    ['copyright', '侵权或冒用', 'Copyright or impersonation'],
    ['broken', '无法使用或失效', 'Broken or non-functional'],
    ['spam', '垃圾广告', 'Spam'],
    ['other', '其他问题', 'Other']
  ];

  const words = {
    loading: ['正在加载…', 'Loading…'],
    empty: ['还没有上架的作品。', 'No works have been listed yet.'],
    noMatch: ['没有找到匹配的作品。', 'No matching works found.'],
    error: ['暂时无法加载市场，请稍后重试。', 'The market could not be loaded. Please try again later.'],
    retry: ['重试', 'Retry'],
    install: ['在 Soulo 中安装', 'Install in Soulo'],
    detail: ['详情', 'Details'],
    getApp: ['获取 / 更新 Soulo', 'Get / Update Soulo'],
    by: ['作者：', 'By '],
    needs: ['需要 Soulo ', 'Requires Soulo '],
    scan: ['扫码安装', 'Scan to install'],
    scanShort: ['扫码', 'Scan'],
    scanHint: ['打开 Soulo 的扫码功能，扫描后即可预览并安装。', 'Scan this code in Soulo to preview and install.'],
    copyPrompt: ['复制 AI 提示词', 'Copy AI Prompt'],
    manualCopy: ['请选择并复制以下内容', 'Select and copy the text below'],
    applyPlatform: ['添加到 Soulo', 'Add to Soulo'],
    scanCode: ['作品安装二维码', 'Work installation QR code'],
    sourceLink: ['查看安装来源', 'View original source'],
    directory: ['搜索源目录', 'Search Directory'],
    directoryCount: ['{n} 个搜索平台', '{n} search platforms'],
    categoryUse: ['搜索用途', 'Search use'],
    anyUse: ['不限', 'Any'],
    trialSearch: ['试搜', 'Try'],
    copyConfig: ['复制配置', 'Copy setup'],
    copyResults: ['复制当前结果', 'Copy results'],
    copied: ['配置已复制', 'Setup copied'],
    store: ['官方商店', 'Official store'],
    archive: ['原始下载', 'Original download'],
    marketPlatforms: ['市场投稿', 'Market submissions'],
    testedOn: ['验证版本', 'Tested on'],
    storePermissions: ['安装时，Soulo 会显示扩展实际申请的权限。', 'Soulo shows the permissions requested by the downloaded extension before installation.'],
    ratingEveryone: ['全年龄', 'Everyone'],
    ratingTeen: ['12+ 进阶', '12+ Teen'],
    permissionsTitle: ['适用权限与访问网站范围', 'Permissions & Website Access'],
    noExtraPerms: ['无额外敏感权限或网站访问声明。', 'No extra permissions or website access declared.'],
    permsLabel: ['声明权限', 'Permissions'],
    sitesLabel: ['访问网站范围', 'Website Scope'],
    scriptWarn: ['此作品包含可执行脚本，安装前请确认来源与权限。', 'This work includes executable script code. Review its permissions before installing.'],
    integrity: ['完整性校验 (SHA-256)', 'Integrity (SHA-256)'],
    size: ['包体积', 'Package size'],
    version: ['版本', 'Version'],
    module: ['分类', 'Category'],
    rating: ['内容分级', 'Content Rating'],
    author: ['作者', 'Author'],
    reportOpen: ['举报此作品', 'Report Work'],
    reportSubmit: ['提交举报', 'Submit Report'],
    reportDetailPlaceholder: ['请说明具体问题（至少 5 个字）', 'Describe the issue (at least 5 characters)'],
    reportContactPlaceholder: ['联系方式（选填）', 'Contact info (optional)'],
    reportSent: ['举报已提交，感谢反馈。', 'Report submitted. Thank you.'],
    reportFail: ['提交失败，请检查内容后重试。', 'Failed to submit report. Please check your input.'],
    blockAuthor: ['屏蔽该作者', 'Block Author'],
    unblockAuthor: ['取消屏蔽该作者', 'Unblock Author'],
    blockedBanner: ['已在本浏览器隐藏 {n} 位已屏蔽作者的作品。', 'Hiding works from {n} blocked author(s) in this browser.'],
    clearBlocked: ['清空屏蔽', 'Clear blocked'],
    unavailable: ['该作品已下架、被隐藏或不存在。', 'This work is unavailable or has been unlisted.'],
    revoked: ['该作品版本已被管理员停用，无法安装。', 'This work version has been disabled and cannot be installed.'],
    close: ['关闭', 'Close'],
    sortNewest: ['最新上架', 'Newest'],
    sortUpdated: ['最近更新', 'Recently updated'],
    sortName: ['名称', 'Name']
  };
  const zh = () => !document.documentElement.lang.startsWith('en');
  const say = key => words[key][zh() ? 0 : 1];
  const modName = mod => (MODULE_NAMES[mod] || [mod, mod])[zh() ? 0 : 1];

  function loadBlocked() {
    try {
      const raw = JSON.parse(localStorage.getItem(BLOCKED_KEY) || '[]');
      return Array.isArray(raw) ? raw.filter(x => typeof x === 'string') : [];
    } catch { return []; }
  }
  function saveBlocked(values) {
    try { localStorage.setItem(BLOCKED_KEY, JSON.stringify([...new Set(values)])); } catch {}
  }

  const state = {
    module: 'home',
    sort: 'newest',
    visibleModules: ['home', 'newTab', 'widget', 'platform', 'script', 'webExtension'],
    items: [],
    cursor: null,
    query: '',
    request: 0,
    phase: 'loading',
    blocked: loadBlocked(),
    activeDetail: null
  };

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function resolvePreviewURL(path) {
    if (!path || typeof path !== 'string') return null;
    if (/^works\/[0-9a-f-]+\/versions\/\d+\/preview(\?v=[0-9a-f]+)?$/i.test(path)) {
      return `${API}/${path}`;
    }
    return null;
  }

  function httpsSource(raw) {
    try {
      const url = new URL(raw);
      if (url.protocol === 'https:' && !url.username && !url.password) return url.href;
    } catch {}
    return null;
  }

  function installLink(item) {
    if (!UUID.test(item.id) || !Number.isInteger(item.version) || item.version < 1) return null;
    return `soulo://custom-market/work/${item.id.toLowerCase()}?version=${item.version}`;
  }

  function scanButton(item) {
    const btn = el('button', 'catalog-button market-scan');
    btn.type = 'button';
    btn.title = say('scan');
    btn.setAttribute('aria-label', say('scan'));
    const icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    icon.setAttribute('viewBox', '0 0 24 24');
    icon.setAttribute('aria-hidden', 'true');
    const path = document.createElementNS(icon.namespaceURI, 'path');
    path.setAttribute('fill-rule', 'evenodd');
    path.setAttribute('d', 'M2 2h8v8H2zm2 2v4h4V4zm10-2h8v8h-8zm2 2v4h4V4zM2 14h8v8H2zm2 2v4h4v-4zm10-2h3v3h-3zm5 0h3v3h-3zm-5 5h3v3h-3zm5 0h3v3h-3z');
    icon.append(path);
    btn.append(icon, el('span', '', say('scanShort')));
    btn.addEventListener('click', () => showInstallCode(item));
    return btn;
  }

  function showInstallCode(item) {
    const url = new URL(`/custom-market/work/${item.id.toLowerCase()}`, 'https://soulo.dkluge.com');
    const card = el('div', 'market-dialog-card');
    const header = el('div', 'market-dialog-head');
    const title = el('h2', '', say('scan'));
    title.id = 'market-qr-title';
    const close = el('button', 'market-dialog-close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', say('close'));
    close.addEventListener('click', () => qrDialog.close());
    header.append(title, close);
    card.append(header);

    if (typeof window.qrcode === 'function') {
      const qr = window.qrcode(0, 'M');
      qr.addData(url.href);
      qr.make();
      const canvas = el('canvas', 'market-qr-code');
      const count = qr.getModuleCount();
      const scale = 8;
      canvas.width = canvas.height = (count + 8) * scale;
      canvas.setAttribute('role', 'img');
      canvas.setAttribute('aria-label', say('scanCode'));
      const context = canvas.getContext('2d');
      context.fillStyle = '#fff';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = '#141321';
      for (let row = 0; row < count; row++) {
        for (let col = 0; col < count; col++) {
          if (qr.isDark(row, col)) context.fillRect((col + 4) * scale, (row + 4) * scale, scale, scale);
        }
      }
      card.append(canvas, el('p', 'market-inline-note', say('scanHint')));
    }

    const link = el('a', 'market-qr-link', item.name);
    link.href = url.href;
    card.append(link);
    qrDialog.replaceChildren(card);
    qrDialog.showModal();
  }

  function formatBytes(n) {
    if (!Number.isFinite(n) || n <= 0) return '—';
    return n < 1024 ? `${n} B` : `${(n / 1024).toFixed(1)} KB`;
  }

  function renderCategories() {
    const tabs = state.visibleModules;
    if (!tabs.includes(state.module)) state.module = tabs[0] || 'home';
    categoriesEl.replaceChildren(...tabs.map(mod => {
      const btn = el('button', 'market-cat', modName(mod));
      btn.type = 'button';
      btn.role = 'tab';
      btn.dataset.module = mod;
      btn.setAttribute('aria-selected', String(state.module === mod));
      btn.addEventListener('click', () => {
        if (state.module === mod) return;
        state.module = mod;
        const url = new URL(location.href);
        url.searchParams.set('module', mod);
        url.hash = '';
        history.replaceState(null, '', url);
        load(false);
      });
      return btn;
    }));
  }

  function renderBlockedBar() {
    if (!blockedBar) return;
    if (!state.blocked.length) {
      blockedBar.hidden = true;
      blockedBar.replaceChildren();
      return;
    }
    blockedBar.hidden = false;
    const msg = el('span', '', say('blockedBanner').replace('{n}', String(state.blocked.length)));
    const clear = el('button', 'catalog-button', say('clearBlocked'));
    clear.type = 'button';
    clear.addEventListener('click', () => {
      state.blocked = [];
      saveBlocked([]);
      render();
    });
    blockedBar.replaceChildren(msg, clear);
  }

  function badgesFor(item) {
    const wrap = el('div', 'market-badges');
    wrap.append(el('span', 'market-pill', modName(item.module)));
    if (item.contentRating === 'teen') wrap.append(el('span', 'market-pill teen', say('ratingTeen')));
    return wrap;
  }

  let officialExtensions;
  const sourceCategoriesEN = {
    ai: 'AI Search', general: 'General Search', academic: 'Academic',
    social: 'Social & Content', developer: 'Developer', shopping: 'Shopping',
    comic: 'Comics & Art', video: 'Video & Streaming', book: 'Books & Reading'
  };
  const requestedCategory = /^#category-([a-z]+)$/.exec(location.hash)?.[1];
  let sourceCategory = requestedCategory || '';
  let sourceCatalog;
  let sourceRequest;

  function openWorkButton(item, className, text) {
    const button = el('button', className, text);
    button.type = 'button';
    button.dataset.openWork = item.id;
    button.addEventListener('click', () => openDetail(item.id));
    return button;
  }

  function workImage(item) {
    const url = resolvePreviewURL(item.previewImageUrl);
    if (!url) return null;
    const image = el('img', 'market-preview-img');
    image.src = url;
    image.alt = '';
    image.loading = 'lazy';
    image.decoding = 'async';
    return image;
  }

  function storeName(url) {
    if (!url) return '';
    const host = new URL(url).hostname;
    return {
      'chromewebstore.google.com': 'Chrome', 'chrome.google.com': 'Chrome',
      'microsoftedge.microsoft.com': 'Edge', 'addons.mozilla.org': 'Firefox',
      'www.addons.mozilla.org': 'Firefox', 'soulo.dkluge.com': 'Soulo'
    }[host] || host;
  }

  function originalLink(url) {
    const link = el('a', 'catalog-button', say(storeName(url) === 'Soulo' ? 'archive' : 'store'));
    link.href = url;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    return link;
  }

  function card(item) {
    const article = el('article', 'extension-card market-card');
    article.dataset.work = item.id;
    article.dataset.module = item.module;
    const landing = ['home', 'newTab'].includes(item.module);
    const extension = item.module === 'webExtension';
    const source = httpsSource(item.sourceURL);
    const cover = workImage(item);
    const official = source && officialExtensions?.byURL.get(source);

    const body = el('div', 'market-card-body');
    const identity = el('div', 'extension-identity');
    if (extension) {
      const avatar = el('span', 'market-extension-icon');
      avatar.append(el('span', 'market-mark', MODULE_MARKS.webExtension));
      if (cover) {
        cover.addEventListener('load', () => { avatar.dataset.loaded = 'true'; });
        avatar.append(cover);
        if (cover.complete && cover.naturalWidth) avatar.dataset.loaded = 'true';
      }
      identity.append(avatar);
    }
    const heading = el('div', 'market-identity-text');
    const title = el('h2');
    title.append(openWorkButton(item, 'market-title-button', item.name));
    const titleLine = el('div', 'extension-heading');
    titleLine.append(title);
    if (source) titleLine.append(el('span', 'extension-source', storeName(source)));
    heading.append(titleLine);
    const subtitle = official && (zh() ? official.subtitle : official.subtitle_en);
    if (subtitle) heading.append(el('p', 'extension-subtitle', subtitle));
    else heading.append(el('p', 'extension-subtitle', `${item.authorName} · v${item.version}`));
    if (item.contentRating === 'teen') heading.append(el('span', 'market-pill teen', say('ratingTeen')));
    identity.append(heading);
    body.append(identity);
    const summary = official ? (zh() ? official.description : official.description_en) || item.summary : item.summary;
    if (summary) body.append(el('p', 'extension-description', summary));
    if (official) {
      const features = (zh() ? official.tested : official.tested_en) || [];
      if (features.length) {
        const checklist = el('ul', 'extension-tested');
        for (const feature of features) checklist.append(el('li', '', feature));
        body.append(checklist);
      }
      body.append(el('p', 'extension-version', `${say('testedOn')} · ${official.version} / Soulo ${official.souloVersion || officialExtensions.minVersion}`));
    }

    if (!extension && cover) {
      const frame = openWorkButton(item, 'market-preview-wrap', '');
      frame.setAttribute('aria-label', `${say('detail')} · ${item.name}`);
      frame.append(cover);
      article.append(frame);
      if (landing) article.classList.add('market-card-portrait');
    }
    article.append(body);

    const actions = el('div', 'extension-actions');
    const link = installLink(item);
    if (link) {
      const install = el('a', 'catalog-button primary', say('install'));
      install.href = link;
      install.dataset.installWork = item.id;
      actions.append(install);
    }
    actions.append(source ? originalLink(source) : openWorkButton(item, 'catalog-button', say('detail')));
    if (link) actions.append(scanButton(item));
    article.append(actions);
    return article;
  }

  async function loadOfficialExtensions() {
    if (officialExtensions) return officialExtensions;
    const res = await fetch('extensions.json', {credentials:'omit'});
    if (!res.ok) return new Map();
    const catalog = await res.json();
    const index = new Map(catalog.extensions.map(item => [new URL(item.url, 'https://soulo.dkluge.com/').href, item]));
    return officialExtensions = {byURL:index, minVersion:catalog.souloVersion};
  }

  function safeSearchSource(item) {
    const url = typeof item?.url === 'string' ? item.url : '';
    return typeof item?.name === 'string' && url.split('%@').length === 2 && httpsSource(url.replace('%@', 'Soulo'));
  }

  async function loadSourceCatalog() {
    const response = await fetch('sources.json', {credentials:'omit'});
    if (!response.ok) throw new Error('Directory unavailable');
    const data = await response.json();
    if (!Array.isArray(data.sources) || !Array.isArray(data.categories)) throw new Error('Malformed directory');
    sourceCatalog = {categories:data.categories, sources:data.sources.filter(safeSearchSource)};
  }

  const sourceIcons = JSON.parse(document.getElementById('market-platform-icons')?.textContent || '{}');
  const copyTimers = new WeakMap();

  async function copyText(value, button) {
    let copied = false;
    try {
      await navigator.clipboard.writeText(value);
      copied = true;
    } catch {
      const field = el('textarea', 'market-copy-buffer');
      const parent = button.closest('dialog') || document.body;
      field.readOnly = true;
      field.value = value;
      parent.append(field);
      field.select();
      try { copied = document.execCommand('copy'); } catch {}
      field.remove();
      button.focus({preventScroll:true});
    }
    if (copied) {
      const label = button.dataset.copyLabel || button.textContent;
      button.dataset.copyLabel = label;
      button.textContent = say('copied');
      clearTimeout(copyTimers.get(button));
      copyTimers.set(button, setTimeout(() => { button.textContent = label; }, 1800));
      return;
    }
    const sheet = el('dialog', 'market-dialog');
    const panel = el('div', 'market-dialog-card');
    const header = el('div', 'market-dialog-head');
    const title = el('h2', '', say('manualCopy'));
    const close = el('button', 'market-dialog-close', '×');
    close.type = 'button';
    close.setAttribute('aria-label', say('close'));
    close.addEventListener('click', () => sheet.close());
    header.append(title, close);
    const field = el('textarea', 'market-copy-field');
    field.readOnly = true;
    field.value = value;
    field.setAttribute('aria-label', say('manualCopy'));
    sheet.setAttribute('aria-label', say('manualCopy'));
    panel.append(header, field);
    sheet.append(panel);
    document.body.append(sheet);
    sheet.addEventListener('close', () => {
      sheet.remove();
      button.focus({preventScroll:true});
    }, {once:true});
    sheet.showModal();
    field.select();
  }

  function copySourceConfig(items, button) {
    return copyText(JSON.stringify(items.map(({name,url}) => ({name,url})), null, 2), button);
  }

  function sourceCategoryName(category) {
    return zh() ? category.name : sourceCategoriesEN[category.id] || category.name;
  }

  function renderSourceCard(source) {
    const trialURL = new URL(source.url.replace('%@', 'Soulo'));
    const domain = trialURL.hostname.replace(/^www\./, '');
    const row = el('article', 'market-source-card');
    const identity = el('div', 'market-source-identity');
    const firstLetters = source.name.match(/[A-Za-z]+/g)?.slice(0, 2).map(word => word[0]).join('').toUpperCase();
    const mark = el('span', 'market-source-mark', firstLetters || Array.from(source.name)[0]);
    mark.setAttribute('aria-hidden', 'true');
    const path = sourceIcons.sources?.[domain];
    if (path) {
      const img = el('img');
      img.src = path;
      img.alt = '';
      img.loading = 'lazy';
      img.decoding = 'async';
      img.addEventListener('error', () => img.remove());
      mark.append(img);
    }
    const name = el('div', 'market-source-name');
    name.append(el('h3', '', source.name), el('span', '', domain));
    identity.append(mark, name);
    const actions = el('div', 'market-source-actions');
    const trial = el('a', 'catalog-button', say('trialSearch'));
    trial.href = trialURL.href;
    trial.target = '_blank';
    trial.rel = 'noopener noreferrer';
    actions.append(trial);
    if (window.souloCanAddSearchPlatform === true) {
      const apply = el('a', 'catalog-button', say('applyPlatform'));
      apply.href = `soulo://add-search-platform?template=${encodeURIComponent(source.url)}&name=${encodeURIComponent(source.name)}`;
      actions.append(apply);
    } else {
      const copy = el('button', 'catalog-button', say('copyConfig'));
      copy.type = 'button';
      copy.addEventListener('click', () => copySourceConfig([source], copy));
      actions.append(copy);
    }
    row.append(identity, actions);
    return row;
  }

  function renderSourceDirectory() {
    platformDirectory.hidden = state.module !== 'platform';
    if (platformDirectory.hidden) return;
    if (!sourceCatalog) {
      if (!sourceRequest) sourceRequest = loadSourceCatalog().then(renderSourceDirectory).catch(() => {
        sourceRequest = null;
        const retry = el('button', 'catalog-button', say('retry'));
        retry.type = 'button';
        retry.addEventListener('click', renderSourceDirectory);
        platformDirectory.replaceChildren(el('p', 'market-inline-note', say('error')), retry);
      });
      platformDirectory.replaceChildren(el('p', 'market-inline-note', say('loading')));
      return;
    }

    const heading = el('div', 'market-directory-top');
    const title = el('div');
    const h2 = el('h2', '', say('directory'));
    h2.id = 'market-platform-title';
    title.append(h2);
    const controls = el('div', 'market-directory-actions');
    const select = el('select');
    select.setAttribute('aria-label', say('categoryUse'));
    select.append(Object.assign(el('option', '', say('anyUse')), {value:''}));
    for (const category of sourceCatalog.categories) {
      select.append(Object.assign(el('option', '', sourceCategoryName(category)), {value:category.id}));
    }
    select.value = sourceCategory;
    select.addEventListener('change', () => {
      sourceCategory = select.value;
      renderSourceDirectory();
      platformDirectory.querySelector('select').focus({preventScroll:true});
    });
    const copy = el('button', 'catalog-button', say('copyResults'));
    copy.type = 'button';
    controls.append(select, copy);
    heading.append(title, controls);

    const terms = state.query.toLowerCase().split(/\s+/).filter(Boolean);
    const results = sourceCatalog.sources.filter(item => {
      const category = sourceCatalog.categories.find(c => c.id === item.category);
      return (!sourceCategory || item.category === sourceCategory)
        && terms.every(term => `${item.name} ${item.url} ${category?.name || ''} ${sourceCategoriesEN[item.category] || ''}`.toLowerCase().includes(term));
    });
    if (state.sort === 'name') results.sort((a,b) => a.name.localeCompare(b.name, zh() ? 'zh-CN' : 'en'));
    title.append(el('p', 'market-inline-note', say('directoryCount').replace('{n}', String(results.length))));
    copy.disabled = !results.length;
    copy.addEventListener('click', () => copySourceConfig(results, copy));
    const sections = [];
    for (const category of sourceCatalog.categories) {
      const items = results.filter(source => source.category === category.id);
      if (!items.length) continue;
      const section = el('section', 'market-source-group');
      const heading = el('h3', 'market-source-group-title');
      heading.id = `market-sources-${category.id}`;
      section.setAttribute('aria-labelledby', heading.id);
      const symbol = el('span', 'market-source-group-icon');
      symbol.innerHTML = sourceIcons.categories?.[category.id] || '';
      heading.append(symbol, document.createTextNode(sourceCategoryName(category)));
      const grid = el('div', 'market-sources-grid');
      grid.append(...items.map(renderSourceCard));
      section.append(heading, grid);
      sections.push(section);
    }
    platformDirectory.replaceChildren(heading, ...sections);
    if (!sections.length) platformDirectory.append(el('p', 'market-inline-note', say('noMatch')));
  }

  function visibleItems() {
    if (!state.blocked.length) return state.items;
    const set = new Set(state.blocked);
    return state.items.filter(item => !item.authorRef || !set.has(item.authorRef));
  }

  function render() {
    renderCategories();
    renderBlockedBar();
    renderSourceDirectory();
    list.dataset.category = state.module;
    const shown = visibleItems();
    list.replaceChildren(...shown.map(card));
    list.setAttribute('aria-busy', String(state.phase === 'loading'));
    more.hidden = !state.cursor || state.phase === 'error';
    more.disabled = state.phase === 'loading';
    status.replaceChildren();
    status.dataset.error = String(state.phase === 'error');
    if (state.phase === 'loading') status.textContent = say('loading');
    else if (state.phase === 'error') {
      status.append(say('error') + ' ');
      const retry = el('button', 'catalog-button market-retry', say('retry'));
      retry.type = 'button';
      retry.addEventListener('click', () => load(state.items.length > 0));
      status.append(retry);
    } else if (state.module === 'platform' && shown.length) {
      status.append(el('h2', 'market-submissions-heading', say('marketPlatforms')));
    } else if (!shown.length && state.module !== 'platform') status.textContent = say(state.query ? 'noMatch' : 'empty');
  }

  async function load(append) {
    const request = ++state.request;
    if (!append) { state.items = []; state.cursor = null; }
    state.phase = 'loading';
    render();
    const params = new URLSearchParams({ module: state.module, sort: state.sort, limit: '30' });
    if (state.query) params.set('q', state.query);
    if (append && state.cursor) params.set('cursor', state.cursor);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(`${API}/works?${params}`, { credentials: 'omit', referrerPolicy: 'no-referrer', signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (state.module === 'webExtension') await loadOfficialExtensions().catch(() => {});
      if (request !== state.request) return;
      if (!Array.isArray(data.items)) throw new Error('Malformed response');
      if (Array.isArray(data.visibleModules)) {
        state.visibleModules = MODULE_ORDER.filter(m => data.visibleModules.includes(m));
      }
      state.items = append ? state.items.concat(data.items) : data.items;
      state.cursor = typeof data.nextCursor === 'string' ? data.nextCursor : null;
      state.phase = 'ready';
      render();
    } catch {
      if (request !== state.request) return;
      state.phase = 'error';
      render();
    } finally { clearTimeout(timer); }
  }

  function setWorkParam(workId) {
    try {
      const url = new URL(location.href);
      if (workId) url.searchParams.set('work', workId);
      else url.searchParams.delete('work');
      history.replaceState(null, '', url.toString());
    } catch {}
  }

  function closeDialog() {
    state.activeDetail = null;
    if (dialog && dialog.open) dialog.close();
    setWorkParam(null);
  }

  async function openDetail(workId, selectCategory = false) {
    if (!dialog || !dialogBody || !UUID.test(workId)) return;
    const id = workId.toLowerCase();
    setWorkParam(id);
    dialogBody.replaceChildren(el('p', '', say('loading')));
    if (!dialog.open) dialog.showModal();
    try {
      const res = await fetch(`${API}/works/${id}`, { credentials: 'omit', referrerPolicy: 'no-referrer' });
      if (res.status === 410) {
        const data = await res.json().catch(() => null);
        renderDetailError(say('revoked') + (data?.error?.message ? ` (${data.error.message})` : ''));
        return;
      }
      if (res.status === 404) { renderDetailError(say('unavailable')); return; }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const work = await res.json();
      if (selectCategory && state.visibleModules.includes(work.module) && state.module !== work.module) {
        state.module = work.module;
        load(false);
      }
      state.activeDetail = work;
      renderDetail(work);
    } catch {
      renderDetailError(say('error'));
    }
  }

  function renderDetailError(message) {
    const head = el('div', 'market-dialog-head');
    const title = el('h2', '', 'Soulo');
    title.id = 'market-dialog-title';
    const close = el('button', 'market-dialog-close', '×');
    close.type = 'button'; close.setAttribute('aria-label', say('close'));
    close.addEventListener('click', closeDialog);
    head.append(title, close);
    dialogBody.replaceChildren(head, el('p', 'market-inline-note error', message));
  }

  function workPrompt(work) {
    const pkg = work.package;
    const content = pkg?.[work.module];
    const text = work.module === 'home' || work.module === 'newTab'
      ? content?.html
      : work.module === 'script'
        ? content?.source || (content?.sourceURL && JSON.stringify(content, null, 2))
        : content && JSON.stringify(content, null, 2);
    if (!text) return null;
    const reference = (work.module === 'webExtension' && !content.manifest)
      || (work.module === 'script' && !content.source && content.sourceURL);
    const intro = zh()
      ? `请帮我修改 Soulo 的${modName(work.module)}「${work.name}」。先问我想改什么，再给我一份完整、可导入 Soulo 的结果。保留原格式、Soulo 接口和所需权限。`
      : `Help me edit the Soulo ${modName(work.module)} “${work.name}”. Ask what I want to change, then return a complete result I can import into Soulo. Preserve the format, Soulo interfaces and required permissions.`;
    const scope = reference
      ? (zh() ? '这份配置指向原始安装地址。修改源码需要我提供有权分享的源文件。' : 'This configuration links to the original install source. Ask me for source files I can share before editing the code.')
      : (zh() ? '以下是作品的源内容。' : 'Here is the original source.');
    return `${intro}

${scope}

${text}`;
  }

  function renderDetail(work) {
    const nodes = [];
    const head = el('div', 'market-dialog-head');
    const title = el('h2', '', work.name);
    title.id = 'market-dialog-title';
    const close = el('button', 'market-dialog-close', '×');
    close.type = 'button'; close.setAttribute('aria-label', say('close'));
    close.addEventListener('click', closeDialog);
    head.append(title, close);
    nodes.push(head, badgesFor(work));

    const previewUrl = resolvePreviewURL(work.previewImageUrl);
    if (previewUrl) {
      const img = el('img', 'market-dialog-preview');
      img.src = previewUrl; img.alt = work.name;
      nodes.push(img);
    }
    if (work.summary) nodes.push(el('p', 'extension-description', work.summary));

    const dl = el('dl', 'market-meta-list');
    const addMeta = (k, v) => {
      dl.append(el('dt', '', k));
      const dd = el('dd');
      if (v instanceof Node) dd.append(v); else dd.textContent = v;
      dl.append(dd);
    };
    addMeta(say('module'), modName(work.module));
    addMeta(say('author'), work.authorName);
    addMeta(say('version'), `v${work.version}`);
    addMeta(say('rating'), work.contentRating === 'teen' ? say('ratingTeen') : say('ratingEveryone'));
    addMeta(say('needs'), work.minSouloVersion);
    addMeta(say('size'), formatBytes(work.packageBytes));
    if (work.packageSha256) addMeta(say('integrity'), el('code', '', work.packageSha256));
    nodes.push(dl);

    const permBox = el('div', 'market-perm-box');
    permBox.append(el('h3', '', say('permissionsTitle')));
    if (work.hasScript) permBox.append(el('p', 'market-inline-note', say('scriptWarn')));
    const perms = Array.isArray(work.permissions) ? work.permissions : [];
    const sites = Array.isArray(work.sites) ? work.sites : [];
    if (work.sourceURL) {
      permBox.append(el('p', 'market-inline-note', say('storePermissions')));
    } else if (!perms.length && !sites.length) {
      permBox.append(el('p', 'market-inline-note', say('noExtraPerms')));
    } else {
      if (perms.length) {
        permBox.append(el('strong', '', say('permsLabel')));
        const ul = el('ul');
        perms.forEach(p => ul.append(el('li', '', p)));
        permBox.append(ul);
      }
      if (sites.length) {
        permBox.append(el('strong', '', say('sitesLabel')));
        const ul = el('ul');
        sites.forEach(s => ul.append(el('li', '', s)));
        permBox.append(ul);
      }
    }
    nodes.push(permBox);

    const actions = el('div', 'market-detail-actions');
    const link = installLink(work);
    if (link) {
      const install = el('a', 'catalog-button primary', say('install'));
      install.href = link;
      install.dataset.installWork = work.id;
      actions.append(install, scanButton(work));
    }
    const app = el('a', 'catalog-button', say('getApp'));
    app.href = APP_STORE; app.target = '_blank'; app.rel = 'noopener noreferrer';
    actions.append(app);
    const prompt = workPrompt(work);
    if (prompt) {
      const copy = el('button', 'catalog-button', say('copyPrompt'));
      copy.type = 'button';
      copy.addEventListener('click', () => copyText(prompt, copy));
      actions.append(copy);
    }
    nodes.push(actions);
    const source = httpsSource(work.sourceURL || work.package?.script?.sourceURL);
    if (source) {
      const link = el('a', 'market-qr-link', say('sourceLink'));
      link.href = source;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      nodes.push(link);
    }

    // Governance: report + block author
    const gov = el('div', 'market-report-box');
    const govRow = el('div', 'market-gov-row');
    const reportToggle = el('button', 'catalog-button', say('reportOpen'));
    reportToggle.type = 'button';
    govRow.append(reportToggle);

    if (work.authorRef) {
      const isBlocked = state.blocked.includes(work.authorRef);
      const blockBtn = el('button', 'catalog-button', say(isBlocked ? 'unblockAuthor' : 'blockAuthor'));
      blockBtn.type = 'button';
      blockBtn.addEventListener('click', () => {
        if (state.blocked.includes(work.authorRef)) {
          state.blocked = state.blocked.filter(x => x !== work.authorRef);
        } else {
          state.blocked = [...state.blocked, work.authorRef];
        }
        saveBlocked(state.blocked);
        render();
        renderDetail(work);
      });
      govRow.append(blockBtn);
    }
    gov.append(govRow);

    const form = el('form', 'market-report-form');
    form.hidden = true;
    const catSelect = el('select');
    REPORT_CATEGORIES.forEach(([value, labelZh, labelEn]) => {
      const opt = el('option', '', zh() ? labelZh : labelEn);
      opt.value = value;
      catSelect.append(opt);
    });
    const detailInput = el('textarea');
    detailInput.maxLength = 1000;
    detailInput.placeholder = say('reportDetailPlaceholder');
    const contactInput = el('input');
    contactInput.maxLength = 200;
    contactInput.placeholder = say('reportContactPlaceholder');
    const sendBtn = el('button', 'catalog-button primary', say('reportSubmit'));
    sendBtn.type = 'submit';
    const reportMsg = el('p', 'market-inline-note');
    form.append(catSelect, detailInput, contactInput, sendBtn, reportMsg);
    reportToggle.addEventListener('click', () => { form.hidden = !form.hidden; });
    form.addEventListener('submit', async ev => {
      ev.preventDefault();
      sendBtn.disabled = true;
      reportMsg.className = 'market-inline-note';
      reportMsg.textContent = say('loading');
      try {
        const res = await fetch(`${API}/works/${work.id}/reports`, {
          method: 'POST',
          credentials: 'omit',
          referrerPolicy: 'no-referrer',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            version: work.version,
            category: catSelect.value,
            detail: detailInput.value.trim(),
            contact: contactInput.value.trim() || undefined
          })
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        reportMsg.className = 'market-inline-note ok';
        reportMsg.textContent = say('reportSent');
        detailInput.value = '';
      } catch {
        reportMsg.className = 'market-inline-note error';
        reportMsg.textContent = say('reportFail');
      } finally { sendBtn.disabled = false; }
    });
    gov.append(form);
    nodes.push(gov);

    dialogBody.replaceChildren(...nodes);
  }

  if (dialog) {
    dialog.addEventListener('cancel', () => setWorkParam(null));
    dialog.addEventListener('click', ev => { if (ev.target === dialog) closeDialog(); });
  }

  let timer;
  function applySearch() {
    const query = search.value.trim();
    if (query === state.query) return;
    state.query = query;
    load(false);
  }
  search.addEventListener('input', () => {
    clearTimeout(timer);
    timer = setTimeout(applySearch, 300);
  });
  search.form?.addEventListener('submit', event => {
    event.preventDefault();
    clearTimeout(timer);
    applySearch();
    search.blur();
  });
  if (sortEl) {
    sortEl.addEventListener('change', () => {
      state.sort = sortEl.value || 'newest';
      load(false);
    });
  }
  more.addEventListener('click', () => load(true));

  function applyLanguage() {
    const placeholder = zh() ? search.dataset.placeholderZh : search.dataset.placeholderEn;
    if (placeholder) search.placeholder = placeholder;
    if (sortEl) {
      const labels = { newest: say('sortNewest'), updated: say('sortUpdated'), name: say('sortName') };
      sortEl.querySelectorAll('option').forEach(opt => { if (labels[opt.value]) opt.textContent = labels[opt.value]; });
    }
    render();
    if (state.activeDetail && dialog?.open) renderDetail(state.activeDetail);
  }
  window.addEventListener('soulo:langchange', applyLanguage);

  // Check initial work deep link (?work=<uuid> or /custom-market/work/<uuid>)
  const pathMatch = /\/custom-market\/work\/([0-9a-f-]{36})$/i.exec(location.pathname);
  const initialWork = queryParams.get('work') || (pathMatch ? pathMatch[1] : null);
  const initialModule = queryParams.get('module');
  if (initialModule && MODULE_ORDER.includes(initialModule)) state.module = initialModule;
  else if (requestedCategory) state.module = 'platform';

  applyLanguage();
  load(false);
  if (initialWork && UUID.test(initialWork)) openDetail(initialWork, !initialModule);
})();
