(() => {
  'use strict';
  const PRODUCTION_API = 'https://api2.dkluge.com/api/soulo/custom-market/v1';
  const APP_STORE = 'https://apps.apple.com/app/id6761165330';
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
  const BLOCKED_KEY = 'soulo-market-blocked-authors';

  const list = document.getElementById('market-list');
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

  const MODULE_ORDER = ['all', 'home', 'newTab', 'widget', 'platform', 'script', 'webExtension'];
  const MODULE_NAMES = {
    all: ['全部', 'All'],
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
    scanHint: ['用 iPhone 相机扫码，在 Soulo 中预览并安装。', 'Scan with your iPhone camera to preview and install in Soulo.'],
    scanCode: ['作品安装二维码', 'Work installation QR code'],
    sourceLink: ['查看安装来源', 'View original source'],
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
    module: 'all',
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
    const tabs = ['all', ...state.visibleModules];
    if (!tabs.includes(state.module)) state.module = 'all';
    categoriesEl.replaceChildren(...tabs.map(mod => {
      const btn = el('button', 'market-cat', modName(mod));
      btn.type = 'button';
      btn.role = 'tab';
      btn.dataset.module = mod;
      btn.setAttribute('aria-selected', String(state.module === mod));
      btn.addEventListener('click', () => {
        if (state.module === mod) return;
        state.module = mod;
        renderCategories();
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

  function card(item) {
    const article = el('article', 'extension-card market-card');
    article.dataset.work = item.id;
    article.dataset.module = item.module;
    if (item.sourceURL) article.dataset.reference = 'true';

    const previewUrl = resolvePreviewURL(item.previewImageUrl);
    if (previewUrl) {
      const frame = el('button', 'market-preview-wrap');
      frame.type = 'button';
      frame.setAttribute('aria-label', `${say('detail')} · ${item.name}`);
      frame.addEventListener('click', () => openDetail(item.id));
      const img = el('img', 'market-preview-img');
      img.src = previewUrl;
      img.alt = '';
      img.loading = 'lazy';
      img.decoding = 'async';
      frame.append(img);
      article.append(frame);
    }

    const identity = el('div', 'extension-identity');
    identity.append(el('span', 'market-mark', MODULE_MARKS[item.module] || ([...String(item.name)][0] || '·')));
    const heading = el('div', 'extension-heading');
    heading.append(el('h2', '', item.name));
    if (item.host) heading.append(el('span', 'extension-source', item.host));
    const body = el('div');
    body.append(heading, el('p', 'extension-subtitle', `${say('by')}${item.authorName} · v${item.version}`), badgesFor(item));
    identity.append(body);
    article.append(identity);

    if (item.summary) article.append(el('p', 'extension-description', item.summary));

    const actions = el('div', 'extension-actions');
    const link = installLink(item);
    if (link) {
      const install = el('a', 'catalog-button primary', say('install'));
      install.href = link;
      install.dataset.installWork = item.id;
      actions.append(install);
    }
    const detailBtn = el('button', 'catalog-button', say('detail'));
    detailBtn.type = 'button';
    detailBtn.dataset.openWork = item.id;
    detailBtn.addEventListener('click', () => openDetail(item.id));
    actions.append(detailBtn);

    if (link) actions.append(scanButton(item));
    article.append(actions);
    return article;
  }

  function visibleItems() {
    if (!state.blocked.length) return state.items;
    const set = new Set(state.blocked);
    return state.items.filter(item => !item.authorRef || !set.has(item.authorRef));
  }

  function render() {
    renderCategories();
    renderBlockedBar();
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
    } else if (!shown.length) status.textContent = say(state.query ? 'noMatch' : 'empty');
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
      if (request !== state.request) return;
      if (!Array.isArray(data.items)) throw new Error('Malformed response');
      if (Array.isArray(data.visibleModules)) {
        state.visibleModules = MODULE_ORDER.filter(m => m !== 'all' && data.visibleModules.includes(m));
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

  async function openDetail(workId) {
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

    const actions = el('div', 'extension-actions');
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
    const source = httpsSource(work.sourceURL || work.package?.script?.sourceURL);
    if (source) {
      const link = el('a', 'catalog-button', say('sourceLink'));
      link.href = source;
      link.target = '_blank';
      link.rel = 'noopener noreferrer';
      actions.append(link);
    }
    nodes.push(actions);

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

  applyLanguage();
  load(false);
  if (initialWork && UUID.test(initialWork)) openDetail(initialWork);
})();
