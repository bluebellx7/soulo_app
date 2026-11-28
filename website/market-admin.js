(() => {
  'use strict';
  const PRODUCTION_API = 'https://api2.dkluge.com/api';
  const local = ['localhost', '127.0.0.1'].includes(location.hostname);
  const override = local ? new URLSearchParams(location.search).get('api') : null;
  const API = override && /^http:\/\/(localhost|127\.0\.0\.1)(:\d+)?\/api$/.test(override) ? override : PRODUCTION_API;
  const MARKET = `${API}/soulo/custom-market/v1`;
  const SESSION_KEY = `soulo.market.admin.session.v1:${API}`;

  const $ = id => document.getElementById(id);
  const loginSection = $('admin-login'), loginForm = $('login-form'), consoleEl = $('admin-console');
  const queue = $('admin-queue'), detail = $('admin-detail'), more = $('admin-more');
  const statusEl = $('admin-status'), who = $('admin-who'), logout = $('admin-logout');
  const toggleScript = $('toggle-script'), toggleWebExt = $('toggle-webExtension');
  const filtersEl = $('admin-filters'), moduleFilter = $('admin-module'), searchInput = $('admin-search');

  const labels = { pending: '待审', approved: '已上架', rejected: '已退回', withdrawn: '已撤回', superseded: '已被取代', unpublished: '已下架', revoked: '已停用', open: '待处理', resolved: '已处理', dismissed: '已忽略' };
  const modLabels = { home: '首页', newTab: '新标签页', widget: '小组件', platform: '搜索平台', script: '用户脚本', webExtension: '浏览器扩展' };
  const reportCatLabels = { malicious: '恶意安全', copyright: '侵权', inappropriate: '违规内容', broken: '失效故障', spam: '广告垃圾', other: '其他' };
  const checkLabels = {
    https: '搜索地址使用 https',
    placeholder: '地址的路径或查询中恰有一个 %@',
    'host-public': '主机名是公开域名',
    'host-duplicate': '已有已上架作品使用同一主机名',
    'name-duplicate': '已有已上架作品使用同名',
    'text-has-link': '名称或简介含有链接',
    'html-sandbox': '单文件 HTML 沙盒检查通过',
    'widget-schema': '小组件结构与 HTTPS 地址检查通过',
    'source-audit': '源码可读性与反混淆/远程加载检查通过',
    'has-script': '包含可执行 JavaScript，需重点审查源码',
    'broad-site-access': '申请了较宽泛的网站访问权限',
    'sensitive-permissions': '申请了敏感权限'
  };
  const actionLabels = { submit: '提交', approve: '通过', reject: '退回', unpublish: '下架', revoke: '停用已安装版本', withdraw: '撤回' };

  let token = '';
  let tab = 'pending', mod = 'all', q = '', cursor = null, items = [], selected = null, busy = false;
  let activeBlobUrls = [];

  function clearBlobs() {
    activeBlobUrls.forEach(u => URL.revokeObjectURL(u));
    activeBlobUrls = [];
  }

  function say(text, error = false) { statusEl.textContent = text; statusEl.dataset.error = String(error); }
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }
  const when = value => value ? new Date(value).toLocaleString('zh-CN', { hour12: false }) : '';

  function storeSession(session) {
    try {
      if (session) sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
      else sessionStorage.removeItem(SESSION_KEY);
    } catch {}
  }

  function savedSession() {
    try {
      const session = JSON.parse(sessionStorage.getItem(SESSION_KEY) || 'null');
      if (typeof session?.token === 'string' && session.token && typeof session.name === 'string') return session;
    } catch {}
    return null;
  }

  function showLogin(message, keepSavedSession = false) {
    clearBlobs();
    token = ''; items = []; selected = null;
    if (!keepSavedSession) storeSession(null);
    queue.replaceChildren(); detail.replaceChildren();
    consoleEl.hidden = true; loginSection.hidden = false; logout.hidden = true; who.textContent = '';
    if (message) say(message, true);
  }

  async function api(path, options = {}) {
    const requestToken = token;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(`${MARKET}${path}`, {
        method: options.method || 'GET', credentials: 'omit', referrerPolicy: 'no-referrer', signal: controller.signal,
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${requestToken}` },
        body: options.body === undefined ? undefined : JSON.stringify(options.body)
      });
      const data = await response.json().catch(() => null);
      if (requestToken !== token) throw new Error('unauthenticated');
      if (response.status === 401 || response.status === 403) {
        showLogin(response.status === 401 ? '登录已失效，请重新登录。' : '当前账号没有市场审核权限。');
        throw new Error('unauthenticated');
      }
      if (!response.ok) {
        const error = new Error(data?.error?.message || `HTTP ${response.status}`);
        error.code = data?.error?.code;
        throw error;
      }
      return data;
    } finally { clearTimeout(timer); }
  }

  function applySettings(cfg) {
    if (toggleScript) toggleScript.checked = !!cfg.toggles?.script;
    if (toggleWebExt) toggleWebExt.checked = !!cfg.toggles?.webExtension;
  }

  async function loadSettings() {
    try { applySettings(await api('/admin/settings')); } catch {}
  }

  async function openSession(session) {
    token = session.token;
    applySettings(await api('/admin/settings'));
    storeSession(session);
    who.textContent = session.name;
    loginSection.hidden = true; consoleEl.hidden = false; logout.hidden = false;
    say('');
    await loadQueue(true);
  }

  async function saveToggle(patch) {
    try {
      const cfg = await api('/admin/settings', { method: 'PATCH', body: patch });
      applySettings(cfg);
      say('市场展示开关已更新。');
    } catch (error) {
      if (error.message !== 'unauthenticated') say(`开关更新失败：${error.message}`, true);
      await loadSettings();
    }
  }
  toggleScript?.addEventListener('change', () => saveToggle({ showScript: toggleScript.checked }));
  toggleWebExt?.addEventListener('change', () => saveToggle({ showWebExtension: toggleWebExt.checked }));

  loginForm.addEventListener('submit', async event => {
    event.preventDefault();
    const submit = loginForm.querySelector('button[type="submit"]');
    submit.disabled = true; say('正在登录…');
    try {
      const response = await fetch(`${API}/auth/login`, {
        method: 'POST', credentials: 'omit', referrerPolicy: 'no-referrer',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: $('login-username').value.trim(), password: $('login-password').value })
      });
      const data = await response.json().catch(() => null);
      if (!data || data.code !== 0 || !data.data?.token) throw new Error(data?.message?.text || '登录失败');
      $('login-password').value = '';
      await openSession({ token: data.data.token, name: data.data.user?.nickname || data.data.user?.username || '' });
    } catch (error) {
      if (error.message !== 'unauthenticated') showLogin(error.message || '登录失败');
    } finally { submit.disabled = false; }
  });
  logout.addEventListener('click', () => { showLogin(); say('已退出。'); });

  const cached = savedSession();
  if (cached) {
    loginSection.hidden = true;
    say('正在恢复登录…');
    openSession(cached).catch(error => {
      if (error.message !== 'unauthenticated') showLogin('暂时无法验证登录。可刷新重试。', true);
    });
  }

  async function loadQueue(reset, doneMessage) {
    if (reset) {
      clearBlobs();
      items = []; cursor = null; selected = null;
      queue.replaceChildren();
      detail.replaceChildren(el('p', '', '请选择左侧的条目。'));
    }
    if (filtersEl) filtersEl.hidden = tab === 'reports';
    if (!doneMessage) say('正在加载…');
    try {
      if (tab === 'reports') {
        const params = new URLSearchParams({ status: 'open', limit: '30' });
        if (!reset && cursor) params.set('cursor', cursor);
        const data = await api(`/admin/reports?${params}`);
        items = items.concat(data.items);
        cursor = data.nextCursor;
      } else {
        const params = new URLSearchParams({ status: tab, module: mod, limit: '30' });
        if (q) params.set('q', q);
        if (!reset && cursor) params.set('cursor', cursor);
        const data = await api(`/admin/reviews?${params}`);
        items = items.concat(data.items);
        cursor = data.nextCursor;
      }
      renderQueue();
      say(doneMessage || (items.length ? '' : '这里还没有内容。'));
    } catch (error) {
      if (error.message !== 'unauthenticated') say(`加载失败：${error.message}`, true);
    }
  }

  function renderQueue() {
    queue.replaceChildren(...items.map(item => {
      const li = el('li'), button = el('button');
      button.type = 'button';
      if (tab === 'reports') {
        button.setAttribute('aria-current', String(selected && selected.reportId === item.id));
        const top = el('span', 'q-top');
        top.append(el('span', 'badge mod', modLabels[item.module] || item.module));
        if (item.hasScript) top.append(el('span', 'badge fail', '含脚本'));
        top.append(el('span', 'q-title', item.workName || item.workId));
        button.append(top, el('span', 'q-meta', `${reportCatLabels[item.category] || item.category} · v${item.version ?? '?'} · ${when(item.createdAt)}`));
        button.addEventListener('click', () => selectReport(item));
      } else {
        button.setAttribute('aria-current', String(selected && selected.workId === item.workId && selected.version === item.version));
        const top = el('span', 'q-top');
        top.append(el('span', 'badge mod', modLabels[item.module] || item.module));
        if (item.hasScript) top.append(el('span', 'badge fail', '含脚本'));
        top.append(el('span', 'q-title', item.name));
        button.append(top, el('span', 'q-meta', `v${item.version} · ${item.authorName} · ${when(item.submittedAt)}`));
        button.addEventListener('click', () => selectVersion(item));
      }
      li.append(button);
      return li;
    }));
    more.hidden = !cursor;
  }

  document.querySelectorAll('.admin-tabs [role="tab"]').forEach(button => {
    button.addEventListener('click', () => {
      tab = button.dataset.status;
      document.querySelectorAll('.admin-tabs [role="tab"]').forEach(other => other.setAttribute('aria-selected', String(other === button)));
      loadQueue(true);
    });
  });
  moduleFilter?.addEventListener('change', () => { mod = moduleFilter.value; loadQueue(true); });
  let searchTimer;
  searchInput?.addEventListener('input', () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => { q = searchInput.value.trim(); loadQueue(true); }, 250);
  });
  more.addEventListener('click', () => loadQueue(false));

  async function selectVersion(item) {
    selected = { workId: item.workId, version: item.version };
    renderQueue();
    try {
      const data = await api(`/admin/reviews/${item.workId}/versions/${item.version}`);
      renderDetail(data);
      detail.focus({ preventScroll: true });
    } catch (error) {
      if (error.message !== 'unauthenticated') say(`无法打开：${error.message}`, true);
    }
  }

  function row(list, name, value) {
    const dt = el('dt', '', name), dd = el('dd');
    if (value instanceof Node) dd.append(value); else dd.textContent = value;
    list.append(dt, dd);
  }

  async function loadProtectedPreview(path, imgEl) {
    try {
      const res = await fetch(`${MARKET}/${path}`, {
        credentials: 'omit', referrerPolicy: 'no-referrer',
        headers: { Authorization: `Bearer ${token}` }
      });
      if (!res.ok) return;
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      activeBlobUrls.push(url);
      imgEl.src = url;
      imgEl.hidden = false;
    } catch {}
  }

  /** Build a completely isolated HTML preview for admin visual inspection: empty sandbox + CSP default-src 'none'. */
  function buildIsolatedHtmlSrcdoc(rawHtml) {
    const stripped = String(rawHtml || '')
      .replace(/<script\b[\s\S]*?<\/script>/gi, '')
      .replace(/<meta\b[^>]*http-equiv[^>]*>/gi, '');
    return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'"><style>html{background:#192b43;color:#f6f1e8;font:15px -apple-system,sans-serif;}body{margin:0;padding:12px;}</style></head><body>${stripped}</body></html>`;
  }

  function renderDetail(data) {
    clearBlobs();
    const pkg = data.package || {};
    const children = [];
    const headerBadges = el('div');
    headerBadges.append(el('span', 'badge mod', modLabels[data.module] || data.module));
    if (data.hasScript) headerBadges.append(el('span', 'badge fail', '含脚本'));
    if (data.contentRating === 'teen') headerBadges.append(el('span', 'badge warn', '12+ 进阶'));
    if (data.openReportsCount > 0) headerBadges.append(el('span', 'badge fail', `待处理举报 ${data.openReportsCount}`));
    children.push(headerBadges, el('h2', '', data.name), el('p', 'admin-note', `${labels[data.status] || data.status} · v${data.version} · 提交于 ${when(data.submittedAt)}`));

    const info = el('dl');
    row(info, '作者显示名', data.authorName);
    row(info, '作者标识', data.authorUserRef || '账号已删除');
    row(info, '简介', data.summary || '（无）');
    row(info, '内容分级', data.contentRating === 'teen' ? '12+ (teen)' : '全年龄 (everyone)');
    row(info, '最低 Soulo', pkg.minSouloVersion || '—');
    row(info, '包体积', data.packageBytes ? `${(data.packageBytes / 1024).toFixed(2)} KB` : '—');
    row(info, 'SHA-256', el('code', '', data.packageSha256 || '—'));
    if (data.permissions?.length) row(info, '声明权限', data.permissions.join('、'));
    if (data.sites?.length) row(info, '网站范围', data.sites.join('、'));
    if (data.rejectReason) row(info, '退回原因', data.rejectReason);
    if (data.revokedReason) row(info, '停用原因', data.revokedReason);
    children.push(info);

    if (data.previewImageUrl) {
      children.push(el('h3', '', '预览图'));
      const img = el('img', 'admin-preview-img');
      img.alt = data.name;
      img.hidden = true;
      children.push(img);
      void loadProtectedPreview(data.previewImageUrl, img);
    }

    // Module-specific inspection
    if (data.module === 'platform' && pkg.platform) {
      const p = pkg.platform;
      const pInfo = el('dl');
      row(pInfo, '平台名称', p.name);
      row(pInfo, '首页', p.homeURL);
      row(pInfo, '搜索地址', el('code', '', p.url));
      children.push(el('h3', '', '搜索平台配置'), pInfo, el('h3', '', '试搜'));
      const trial = el('div', 'admin-try');
      const keyword = el('input'); keyword.value = '人工智能'; keyword.setAttribute('aria-label', '试搜关键词');
      const open = el('a', 'admin-button', '打开试搜（新标签页）');
      open.target = '_blank'; open.rel = 'noopener noreferrer';
      const refresh = () => {
        const target = p.url.replace('%@', encodeURIComponent(keyword.value.trim() || 'Soulo'));
        try { if (new URL(target).protocol === 'https:') open.href = target; else open.removeAttribute('href'); }
        catch { open.removeAttribute('href'); }
      };
      keyword.addEventListener('input', refresh); refresh();
      trial.append(keyword, open);
      children.push(trial);
    } else if ((data.module === 'home' || data.module === 'newTab') && pkg[data.module]?.html) {
      const rawHtml = pkg[data.module].html;
      children.push(el('h3', '', '隔离 HTML 预览（sandbox 禁用脚本与外链）'));
      const frame = el('iframe', 'admin-sandbox-frame');
      frame.setAttribute('sandbox', '');
      frame.setAttribute('referrerpolicy', 'no-referrer');
      frame.setAttribute('title', '隔离 HTML 预览');
      frame.srcdoc = buildIsolatedHtmlSrcdoc(rawHtml);
      children.push(frame, el('h3', '', 'HTML 源码'), el('pre', 'admin-source', rawHtml));
    } else if (data.module === 'widget' && pkg.widget) {
      children.push(el('h3', '', '小组件配置源码'), el('pre', 'admin-source', JSON.stringify(pkg.widget, null, 2)));
    } else if (data.module === 'script' && pkg.script) {
      children.push(el('h3', '', '用户脚本完整源码（可审查）'), el('pre', 'admin-source', pkg.script.source));
    } else if (data.module === 'webExtension' && pkg.webExtension) {
      children.push(el('h3', '', '扩展 Manifest'), el('pre', 'admin-source', JSON.stringify(pkg.webExtension.manifest, null, 2)));
      children.push(el('h3', '', '扩展全部文件'));
      for (const [filePath, fileVal] of Object.entries(pkg.webExtension.files || {})) {
        children.push(el('p', 'admin-note', filePath));
        if (typeof fileVal === 'string') {
          children.push(el('pre', 'admin-source', fileVal));
        } else if (fileVal && typeof fileVal.base64 === 'string') {
          const icon = el('img', 'admin-ext-icon');
          icon.alt = filePath;
          icon.src = `data:image/png;base64,${fileVal.base64}`;
          children.push(icon);
        }
      }
    }

    children.push(el('h3', '', '自动检查'));
    const checks = el('ul', 'admin-checks');
    for (const check of data.checks || []) {
      const li = el('li');
      li.append(
        el('span', `badge ${check.level}`, { pass: '通过', warn: '注意', fail: '失败' }[check.level] || check.level),
        document.createTextNode(checkLabels[check.id] ? `${checkLabels[check.id]}${check.id === 'sensitive-permissions' || check.id === 'broad-site-access' ? ` (${check.message})` : ''}` : check.message)
      );
      checks.append(li);
    }
    children.push(checks);

    if (data.published) {
      children.push(el('h3', '', `与已上架的 v${data.published.version} 相比`));
      children.push(el('p', '', data.changedFields.length ? `改动：${data.changedFields.join('、')}` : '没有改动。'));
    }

    children.push(el('h3', '', '审核记录'));
    const history = el('ul', 'admin-history');
    for (const entry of data.history || []) {
      history.append(el('li', '', `${when(entry.at)} ${actionLabels[entry.action] || entry.action}${entry.reason ? `：${entry.reason}` : ''}`));
    }
    children.push(history, versionActions(data));
    detail.replaceChildren(...children);
  }

  function versionActions(data) {
    const box = el('div', 'admin-actions');
    const reason = el('textarea'); reason.maxLength = 500; reason.placeholder = '原因（退回、下架、停用必填，最多 500 字）'; reason.setAttribute('aria-label', '原因');
    const ratingSelect = el('select');
    ratingSelect.setAttribute('aria-label', '内容分级');
    ratingSelect.append(Object.assign(el('option', '', '分级：全年龄 (everyone)'), { value: 'everyone' }), Object.assign(el('option', '', '分级：12+ 进阶 (teen)'), { value: 'teen' }));
    ratingSelect.value = data.contentRating === 'teen' ? 'teen' : 'everyone';

    const buttons = el('div', 'row');
    const make = (text, className, handler) => {
      const button = el('button', `admin-button ${className}`, text); button.type = 'button';
      button.addEventListener('click', async () => {
        if (busy) return;
        busy = true; box.querySelectorAll('button').forEach(b => { b.disabled = true; });
        try { await handler(); } catch (error) {
          if (error.message !== 'unauthenticated') say(`操作失败：${error.message}`, true);
          box.querySelectorAll('button').forEach(b => { b.disabled = false; });
        } finally { busy = false; }
      });
      return button;
    };
    const finish = async message => { await loadQueue(true, message); };
    const base = `/admin/reviews/${data.workId}/versions/${data.version}`;
    if (data.status === 'pending') {
      box.append(ratingSelect);
      buttons.append(
        make('通过并上架', 'primary', async () => {
          await api(`${base}/approve`, { method: 'POST', body: { note: reason.value.trim() || undefined, contentRating: ratingSelect.value } });
          await finish(`已通过 ${data.name} v${data.version}`);
        }),
        make('退回', 'danger', async () => {
          if (!reason.value.trim()) { say('请填写退回原因。', true); throw new Error('请填写退回原因'); }
          await api(`${base}/reject`, { method: 'POST', body: { reason: reason.value.trim() } });
          await finish('已退回。');
        })
      );
    }
    if (data.status === 'approved') {
      buttons.append(
        make('下架（仅移出市场）', 'danger', async () => {
          if (!reason.value.trim()) { say('请填写下架原因。', true); throw new Error('请填写下架原因'); }
          await api(`/admin/works/${data.workId}/unpublish`, { method: 'POST', body: { reason: reason.value.trim() } });
          await finish('已下架。');
        }),
        make('停用已安装版本', 'danger', async () => {
          if (!reason.value.trim()) { say('请填写停用原因。', true); throw new Error('请填写停用原因'); }
          await api(`/admin/works/${data.workId}/versions/${data.version}/revoke`, { method: 'POST', body: { reason: reason.value.trim() } });
          await finish(`已停用 v${data.version}。`);
        })
      );
    } else if (data.status === 'unpublished' || data.status === 'superseded') {
      buttons.append(
        make('停用已安装版本', 'danger', async () => {
          if (!reason.value.trim()) { say('请填写停用原因。', true); throw new Error('请填写停用原因'); }
          await api(`/admin/works/${data.workId}/versions/${data.version}/revoke`, { method: 'POST', body: { reason: reason.value.trim() } });
          await finish(`已停用 v${data.version}。`);
        })
      );
    }
    if (!buttons.children.length) { box.append(el('p', 'admin-note', '这个版本不需要操作。')); return box; }
    box.append(reason, buttons);
    return box;
  }

  function selectReport(report) {
    clearBlobs();
    selected = { reportId: report.id };
    renderQueue();
    const children = [];
    const badges = el('div');
    badges.append(el('span', 'badge mod', modLabels[report.module] || report.module));
    if (report.hasScript) badges.append(el('span', 'badge fail', '含脚本'));
    badges.append(el('span', 'badge warn', reportCatLabels[report.category] || report.category));
    children.push(badges, el('h2', '', `举报 #${report.id} · ${report.workName || report.workId}`));
    const info = el('dl');
    row(info, '作品 ID', el('code', '', report.workId));
    row(info, '版本', report.version ? `v${report.version}` : '—');
    row(info, '作者', report.authorName || '—');
    row(info, '举报时间', when(report.createdAt));
    row(info, '举报说明', report.detail);
    if (report.contact) row(info, '联系方式', report.contact);
    children.push(info);

    if (report.version) {
      const inspectBtn = el('button', 'admin-button', `查看作品 v${report.version} 源码与详情`);
      inspectBtn.type = 'button';
      inspectBtn.addEventListener('click', () => selectVersion({ workId: report.workId, version: report.version }));
      children.push(el('div', 'admin-actions', ''));
      children[children.length - 1].append(inspectBtn);
    }

    const box = el('div', 'admin-actions');
    const note = el('textarea'); note.maxLength = 500; note.placeholder = '处理备注（必填，最多 500 字）';
    const buttons = el('div', 'row');
    const handle = async action => {
      if (!note.value.trim()) { say('请填写处理备注。', true); return; }
      try {
        await api(`/admin/reports/${report.id}/resolve`, { method: 'POST', body: { action, note: note.value.trim() } });
        await loadQueue(true, '举报已处理。');
      } catch (error) {
        if (error.message !== 'unauthenticated') say(`处理失败：${error.message}`, true);
      }
    };
    const b1 = el('button', 'admin-button', '忽略举报'); b1.type = 'button'; b1.addEventListener('click', () => handle('dismiss'));
    const b2 = el('button', 'admin-button danger', '下架作品'); b2.type = 'button'; b2.addEventListener('click', () => handle('unpublish'));
    const b3 = el('button', 'admin-button danger', '停用该版本'); b3.type = 'button'; b3.addEventListener('click', () => handle('revoke'));
    buttons.append(b1, b2, b3);
    box.append(note, buttons);
    children.push(box);
    detail.replaceChildren(...children);
  }
})();
