/* Baidu search rule. Loaded only by SiteOptimizationController in its isolated world.
 * Contract: configure({enabled, navigationEnabled, hosts, pathSuffixes, queryKeys, loadingText}),
 * finishNavigation(). No remote code, redirect prefetch, unload listener or global prototype hooks.
 */
(() => {
  if (globalThis.__souloSiteOptimization) return;
  const cardSelector = '.c-result, #content_left > .result, #content_left > .result-op';
  const titleSelector = 'h3, .c-title, [data-module="title"], [role="heading"]';
  const ignored = 'button,input,textarea,select,[contenteditable="true"],[role="button"],video,audio,' +
    '[data-feedback],.cosc-feedback,[data-soulo-video-rotate],[data-soulo-video-action],#soulo-episode-dock';
  const originals = new Map(), owned = new Set(), dirtyCards = new Set(), promoRoots = new Set();
  let options = {enabled:false, navigationEnabled:true, hosts:[], pathSuffixes:[], queryKeys:[], loadingText:'Loading'},
    observer = null, timer = 0, feedbackTimer = 0, press = null, hidden = false, pendingCard = null, fullScan = true, lastScroll = 0;
  const css = `
html[data-soulo-baidu-search] { --soulo-result-bg:#fff; --soulo-result-ink:#202124; --soulo-result-muted:#5f6368; --soulo-result-link:#1a0dab; --soulo-result-line:#e8eaed; --soulo-result-press:#f0f5ff; }
html[data-soulo-baidu-search] :is(#results,#content_left) { max-width:760px!important; box-sizing:border-box; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] { color:var(--soulo-result-ink)!important; background:var(--soulo-result-bg)!important; border-radius:0!important; box-shadow:none!important; margin:0!important; padding:19px 16px!important; border-bottom:1px solid var(--soulo-result-line)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is(.cosc-card,.c-container) { background:transparent!important; box-shadow:none!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is(h3,.c-title) { font-size:20px!important; font-weight:400!important; line-height:1.4!important; margin:7px 0 9px!important; color:var(--soulo-result-link)!important; height:auto!important; text-decoration:none!important; -webkit-line-clamp:unset!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is(h3,.c-title) :is(a,span,em) { color:inherit!important; font-size:inherit!important; font-weight:inherit!important; text-decoration:none!important; white-space:normal!important; -webkit-line-clamp:unset!important; text-overflow:clip!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is([data-module="abstract"],.c-abstract,.content-right_8Zs40,[class*="summary-text"]) { font-size:14.5px!important; line-height:1.65!important; color:var(--soulo-result-ink)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is([data-module="abstract"],.c-abstract,[class*="summary-text"]) :is(span,em) { color:var(--soulo-result-ink)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is(.c-abstract,[data-module="abstract"],[class*="summary-text"]) em { color:inherit!important; font-style:normal!important; font-weight:600!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] :is(.c-showurl,.cosc-source-text) { color:var(--soulo-result-muted)!important; font-size:12px!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-pressed] { background:var(--soulo-result-press)!important; }
html[data-soulo-baidu-search] [data-soulo-baidu-title] { cursor:pointer; outline-offset:4px; }
html[data-soulo-baidu-search] [data-soulo-baidu-title]:focus-visible { outline:2px solid #1a73e8; border-radius:3px; }
.soulo-baidu-source { display:flex!important; align-items:center; gap:9px; min-height:25px; margin-bottom:4px; color:var(--soulo-result-ink)!important; font:12px/1.4 Arial,'PingFang SC',sans-serif!important; text-decoration:none!important; max-width:100%; }
.soulo-baidu-source-name { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.soulo-baidu-source-icon { display:grid; place-items:center; flex:0 0 25px; height:25px; border-radius:50%; background:var(--soulo-result-line); color:var(--soulo-result-muted); font-size:13px; text-transform:uppercase; }
.soulo-baidu-status { display:inline-flex; align-items:center; gap:6px; flex-shrink:0; margin-left:auto; color:#1a73e8; font-size:12px; }
.soulo-baidu-status::before { content:''; width:11px; height:11px; border:1.5px solid currentColor; border-right-color:transparent; border-radius:50%; animation:soulo-baidu-loading .8s linear infinite; }
@keyframes soulo-baidu-loading { to { transform:rotate(360deg); } }
html[data-soulo-baidu-search]:is(.soulo-force-dark,[data-theme="dark"]) { --soulo-result-bg:#202124; --soulo-result-ink:#e8eaed; --soulo-result-muted:#bdc1c6; --soulo-result-link:#8ab4f8; --soulo-result-line:#3c4043; --soulo-result-press:#293243; }
html[data-soulo-baidu-search] [data-soulo-baidu-promo] { display:none!important; }
@media (min-width:800px) { html[data-soulo-baidu-search] :is(#results,#content_left) [data-soulo-baidu-card] { padding-left:0!important; padding-right:20px!important; } }
@media (prefers-reduced-motion:reduce) { .soulo-baidu-status::before { animation:none; } }
`;
  function matchesPage() {
    try {
      const page = new URL(location.href);
      return window === window.top && /^https?:$/.test(page.protocol) && options.hosts.includes(page.hostname)
        && (!options.pathSuffixes.length || options.pathSuffixes.some(path => page.pathname.endsWith(path)))
        && (!options.queryKeys.length || options.queryKeys.some(key => page.searchParams.get(key)));
    } catch (_) { return false; }
  }
  function http(value) {
    if (typeof value !== 'string' || !value.trim() || value.length > 8192) return null;
    try {
      const url = new URL(value, document.baseURI);
      return /^https?:$/.test(url.protocol) && !url.username && !url.password ? url : null;
    } catch (_) { return null; }
  }
  function baiduHost(host) { return host === 'baidu.com' || host.endsWith('.baidu.com'); }
  function redirect(url) {
    return baiduHost(url.hostname) && (url.pathname === '/link' || url.pathname === '/url' || /\/tc\/?$/.test(url.pathname));
  }
  function direct(value) {
    const url = http(value);
    if (!url) return null;
    if (!redirect(url)) {
      if (baiduHost(url.hostname) && (/\/s$/.test(url.pathname) || url.hostname.endsWith('.recommend_list.baidu.com'))) return null;
      return url.href;
    }
    for (const key of ['url','target','targetUrl','target_url','landurl','land_url']) {
      const target = url.searchParams.get(key);
      if (!target || !/^https?:\/\//i.test(target)) continue;
      const result = http(target);
      if (result && !redirect(result)) return result.href;
    }
    return null; // Opaque tokens are not URLs. Never guess or prefetch publishers.
  }
  function metadata(element) {
    for (const name of ['data-landurl','data-land-url','data-href','data-url','rl-link-data-url','rl-link-href','mu']) {
      const value = element.getAttribute(name);
      if (!/^(https?:)?\/\//i.test(value || '')) continue;
      const result = direct(value); if (result) return result;
    }
    for (const name of ['data-log','data-click']) {
      const raw = element.getAttribute(name);
      if (!raw || raw.length > 16384) continue;
      try {
        const data = JSON.parse(raw);
        for (const key of ['mu','landurl','land_url','url']) {
          if (!/^(https?:)?\/\//i.test(data[key] || '')) continue;
          const result = direct(data[key]); if (result) return result;
        }
      } catch (_) {}
    }
    return null;
  }
  function webCard(card) {
    const tpl = card.getAttribute('tpl') || card.getAttribute('srcid') || '';
    return !/vid_recommend|video|recommend_list/i.test(tpl)
      && (/^www_|^se_st_|^se_com_default(?:_new)?$/.test(tpl) || (!tpl && card.closest('#content_left')));
  }
  function write(element, name, value) {
    let values = originals.get(element);
    if (!values) { values = new Map(); originals.set(element, values); }
    const current = element.getAttribute(name), record = values.get(name);
    if (!record) values.set(name, {original:current, applied:value});
    else { if (current !== record.applied) record.original = current; record.applied = value; }
    if (current !== value) { if (value === null) element.removeAttribute(name); else element.setAttribute(name, value); }
  }
  function restore() {
    finishNavigation(); observer?.disconnect(); clearTimeout(timer); timer = 0; dirtyCards.clear(); promoRoots.clear(); fullScan = true;
    for (const [element, values] of originals) {
      for (const [name, record] of values) if (element.getAttribute(name) === record.applied) {
        if (record.original === null) element.removeAttribute(name); else element.setAttribute(name, record.original);
      }
    }
    originals.clear(); owned.forEach(node => node.remove()); owned.clear();
  }
  function titleOf(card) { return card.querySelector(titleSelector); }
  function originalValue(element, name) {
    const current = element.getAttribute(name), record = originals.get(element)?.get(name);
    return record && current === record.applied ? record.original : current;
  }
  function restoreAttribute(element, name) {
    const values = originals.get(element), record = values?.get(name);
    if (!record) return;
    if (element.getAttribute(name) === record.applied) {
      if (record.original === null) element.removeAttribute(name); else element.setAttribute(name, record.original);
    }
    values.delete(name); if (!values.size) originals.delete(element);
  }
  function primaryFor(card, title) {
    const container = card.querySelector('article[rl-link-data-url],article[rl-link-href]');
    return metadata(card) || (container && metadata(container)) || (title && metadata(title))
      || (title?.querySelector('a[href]') && direct(originalValue(title.querySelector('a[href]'), 'href')));
  }
  function targetFor(anchor, title, primary) {
    if (anchor.classList.contains('soulo-baidu-source')) return primary;
    const own = metadata(anchor) || direct(originalValue(anchor, 'href'));
    if (own) return own;
    if (title && (title.contains(anchor) || anchor.contains(title))) return primary;
    return null;
  }
  function searchURL(value) {
    const url = http(value);
    if (!url || !options.hosts.includes(url.hostname) || !options.pathSuffixes.some(path => url.pathname.endsWith(path))) return null;
    const query = options.queryKeys.map(key => url.searchParams.get(key)).find(Boolean);
    if (!query) return null;
    const clean = new URL('/s', location.origin); clean.searchParams.set('word', query);
    return clean.href;
  }
  function invokeTarget(anchor, card) {
    if (!anchor || /video|vid_recommend/i.test(card.getAttribute('tpl') || '')) return null;
    for (const attr of ['data-url','data-landurl','rl-link-href']) {
      const raw = anchor.getAttribute(attr);
      const url = searchURL(raw) || (/^(https?:)?\/\//i.test(raw || '') && direct(raw));
      if (url) return url;
    }
    if (anchor.matches('[data-rgitem-type="search"]')) {
      const query = (anchor.getAttribute('data-word') || anchor.textContent).trim();
      if (query && query.length <= 200) { const url = new URL('/s',location.origin); url.searchParams.set('word',query); return url.href; }
    }
    return null;
  }
  function updateRelated(card) {
    for (const anchor of card.querySelectorAll('a.c-invoke-class,a[data-rgitem-type="search"]')) {
      const url = invokeTarget(anchor, card); if (!url) continue;
      write(anchor,'href',url); write(anchor,'target','_self');
    }
    for (const hint of card.querySelectorAll('.c-invoke-willshow-class,[class*="invoke-tip"]')) {
      if (/百度\s*APP.*打开|打开.*百度\s*APP/i.test(hint.textContent)) write(hint,'data-soulo-baidu-promo','');
    }
  }
  function hidePromos(root) {
    if (!root?.querySelectorAll) return;
    const selector = '[ref="open"],[style*="position: fixed"],[style*="position:fixed"]';
    const candidates = [...(root.matches?.(selector) ? [root] : []), ...root.querySelectorAll(selector)];
    for (let candidate of candidates.slice(0,80)) {
      if (candidate.getAttribute('ref') === 'open') {
        candidate = candidate.closest('[style*="position: fixed"],[style*="position:fixed"]');
      }
      if (!candidate || candidate.closest(cardSelector) || candidate.style.bottom === '') continue;
      const text = candidate.textContent.trim();
      if (text.length > 400 || !/去看看|立即打开|打开百度|百度APP|立即下载/.test(text)) continue;
      if (!candidate.querySelector('[ref="open"]') && !/百度|APP/.test(text)) continue;
      if (parseFloat(getComputedStyle(candidate).height) <= 180) write(candidate,'data-soulo-baidu-promo','');
    }
  }
  function scan() {
    timer = 0;
    if (!options.enabled || hidden || !document.documentElement) return;
    if (!matchesPage()) { restore(); return; }
    // Never change result layout during touch/momentum scrolling.
    if (performance.now() - lastScroll < 160) { schedule(); return; }
    observer?.disconnect();
    write(document.documentElement, 'data-soulo-baidu-search', '');
    if (!document.getElementById('soulo-baidu-search-style')) {
      const style = document.createElement('style'); style.id = 'soulo-baidu-search-style'; style.textContent = css;
      (document.head || document.documentElement).append(style); owned.add(style);
    }
    if (fullScan) {
      document.querySelectorAll(cardSelector).forEach((card,index) => { if (index<160) dirtyCards.add(card); });
      promoRoots.add(document.body); fullScan = false;
    }
    for (const root of promoRoots) hidePromos(root);
    promoRoots.clear();
    const started = performance.now();
    let count = 0;
    for (const card of dirtyCards) {
      dirtyCards.delete(card);
      if (!card.isConnected) continue;
      updateRelated(card);
      if (!webCard(card)) {
        if (++count >= 8 || performance.now() - started > 6) break;
        continue;
      }
      const title = titleOf(card);
      write(card, 'data-soulo-baidu-card', '');
      const primary = primaryFor(card, title);
      if (title && primary) {
        write(title, 'data-soulo-baidu-title', '');
        if (!title.closest('a') && !title.querySelector('a,button,input')) { write(title, 'role', 'link'); write(title, 'tabindex', '0'); }
      }
      if (title && !primary) for (const attr of ['data-soulo-baidu-title','role','tabindex']) restoreAttribute(title, attr);
      for (const anchor of card.querySelectorAll('a[href]')) {
        if (anchor.closest(ignored) || anchor.classList.contains('soulo-baidu-source')) continue;
        const target = targetFor(anchor, title, primary);
        if (!target) { restoreAttribute(anchor, 'href'); restoreAttribute(anchor, 'target'); continue; }
        write(anchor, 'href', target); write(anchor, 'target', '_self');
      }
      let source = card.querySelector('.soulo-baidu-source');
      if (!primary || !title) { if (source) { source.remove(); owned.delete(source); } }
      else {
      if (!source) {
        source = document.createElement('a'); source.className = 'soulo-baidu-source';
        source.dataset.souloBaiduOwned = '';
        const icon = document.createElement('span'); icon.className = 'soulo-baidu-source-icon'; icon.setAttribute('aria-hidden','true');
        const name = document.createElement('span'); name.className = 'soulo-baidu-source-name';
        source.append(icon, name);
        const reference = title.closest('a') || title; reference.parentNode.insertBefore(source, reference); owned.add(source);
      }
      const host = new URL(primary).hostname.replace(/^www\./, '');
      if (source.href !== primary) source.href = primary;
      const name = source.querySelector('.soulo-baidu-source-name'), icon = source.querySelector('.soulo-baidu-source-icon');
      if (name.textContent !== host) name.textContent = host;
      if (icon.textContent !== (host[0] || '')) icon.textContent = host[0] || '';
      }
      if (++count >= 8 || performance.now() - started > 6) break;

    }
    for (const element of originals.keys()) if (!element.isConnected) originals.delete(element);
    for (const node of owned) if (!node.isConnected) owned.delete(node);
    observe();
    if (dirtyCards.size) schedule(16);
  }
  function schedule(delay = 100) { if (options.enabled && !hidden && !timer) timer = setTimeout(scan, delay); }
  function changed(element) {
    if (!element || element.closest('[data-soulo-baidu-owned]')) return;
    const card = element.closest(cardSelector);
    if (card) dirtyCards.add(card);
    else {
      element.querySelectorAll(cardSelector).forEach(card => dirtyCards.add(card));
      promoRoots.add(element);
    }
  }
  function observe() {
    if (!options.enabled || hidden || !matchesPage() || !document.documentElement) return;
    if (!observer) observer = new MutationObserver(records => {
      for (const record of records) {
        if (record.type === 'attributes') changed(record.target);
        else {
          const card = record.target.nodeType === 1 && record.target.closest(cardSelector);
          if (card) dirtyCards.add(card);
          for (const node of record.addedNodes) if (node.nodeType === 1) changed(node);
        }
      }
      if (dirtyCards.size || promoRoots.size) schedule();
    });
    observer.observe(document.documentElement, {childList:true,subtree:true,attributes:true,
      attributeFilter:['href','data-log','data-click','data-landurl','data-land-url','data-href','data-url','rl-link-data-url','rl-link-href','mu']});
  }
  function finishNavigation() {
    clearTimeout(feedbackTimer); feedbackTimer = 0;
    if (pendingCard) { restoreAttribute(pendingCard, 'aria-busy'); pendingCard.querySelectorAll('.soulo-baidu-status').forEach(node => node.remove()); }
    pendingCard = null;
  }
  function feedback(card) {
    finishNavigation(); pendingCard = card; write(card, 'aria-busy', 'true');
    const label = document.createElement('span'); label.className = 'soulo-baidu-status';
    label.dataset.souloBaiduOwned = ''; label.setAttribute('role','status'); label.setAttribute('aria-live','polite'); label.textContent = options.loadingText;
    const source = card.querySelector('.soulo-baidu-source');
    if (source) source.append(label); else { card.append(label); owned.add(label); }
    feedbackTimer = setTimeout(finishNavigation, 15000);
  }
  function action(event) {
    if (!options.enabled || !options.navigationEnabled || !matchesPage() || !event.isTrusted || event.defaultPrevented
        || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button > 0 || getSelection()?.toString()) return null;
    const element = event.target instanceof Element ? event.target : event.target.parentElement;
    if (!element) return null;
    const card = element.closest(cardSelector); if (!card) return null;
    const invoke = element.closest('a.c-invoke-class,a[data-rgitem-type="search"]');
    if (invoke && !element.closest('video,audio,input,textarea,[data-feedback],.cosc-feedback,button:disabled')) {
      const url = invokeTarget(invoke,card);
      if (url && (event.type !== 'keydown' || event.key === 'Enter')) return {card,url};
    }
    if (element.closest(ignored) || !webCard(card)) return null;
    const anchor = element.closest('a[href]'); if (anchor?.hasAttribute('download')) return null;
    const title = titleOf(card), primary = primaryFor(card, title);
    // Keep opaque redirects usable through normal browser navigation, without
    // executing Baidu's delegated app-opening/interstitial click handler.
    const fallback = anchor && http(originalValue(anchor, 'href'));
    const url = anchor ? targetFor(anchor,title,primary) || (fallback && redirect(fallback) ? fallback.href : null) : primary;
    if (!url || (event.type === 'keydown' && ((!anchor && !title?.contains(element)) || event.key !== 'Enter'))) return null;
    return {card,url};
  }
  function activate(event) {
    const result = action(event); if (!result) return;
    const bridge = globalThis.webkit?.messageHandlers?.souloSiteOptimizationNavigate;
    if (!bridge) return; // A normal anchor remains usable if the native bridge is unavailable.
    if (press?.moved) { press = null; return; }
    event.preventDefault(); event.stopImmediatePropagation();
    result.card.removeAttribute('data-soulo-baidu-pressed'); feedback(result.card);
    bridge.postMessage({url:result.url}); press = null;
  }
  window.addEventListener('click', activate, true);
  window.addEventListener('keydown', activate, true);
  window.addEventListener('pointerdown', event => {
    const result = action(event); if (!result) return;
    press?.card.removeAttribute('data-soulo-baidu-pressed'); press = {card:result.card,x:event.clientX,y:event.clientY,moved:false};
    result.card.setAttribute('data-soulo-baidu-pressed','');
  }, {capture:true,passive:true});
  window.addEventListener('pointermove', event => {
    if (press && Math.hypot(event.clientX-press.x,event.clientY-press.y)>12) { press.moved = true; press.card.removeAttribute('data-soulo-baidu-pressed'); }
  }, {capture:true,passive:true});
  for (const event of ['pointerup','pointercancel']) window.addEventListener(event, () => {
    press?.card.removeAttribute('data-soulo-baidu-pressed'); if (event === 'pointercancel') press = null;
  }, {capture:true,passive:true});
  window.addEventListener('pagehide', () => { hidden = true; finishNavigation(); observer?.disconnect(); clearTimeout(timer); timer=0; });
  window.addEventListener('pageshow', () => {
    hidden = false; finishNavigation(); observe(); schedule();
    globalThis.webkit?.messageHandlers?.souloSiteOptimizationNavigate?.postMessage({action:'ready'});
  });
  window.addEventListener('popstate', () => { fullScan = true; schedule(); });
  window.addEventListener('scroll', () => { lastScroll = performance.now(); }, {passive:true});
  document.addEventListener('DOMContentLoaded', () => { observe(); schedule(); }, {once:true});
  globalThis.__souloSiteOptimization = {
    configure(next) {
      options = {...options,...next};
      if (!options.enabled) { restore(); press?.card.removeAttribute('data-soulo-baidu-pressed'); press=null; }
      else { fullScan = true; observe(); scan(); }
    },
    finishNavigation
  };
})();
