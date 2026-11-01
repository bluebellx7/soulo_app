/* Baidu search: result typography and browser-only result navigation.
 * No result scanning, URL rewriting, scroll handlers, timers or media changes.
 * The native bridge is isolated from website JavaScript.
 */
(() => {
  if (globalThis.__souloSiteOptimization) return;
  const styleID = 'soulo-baidu-search-style', marker = 'data-soulo-baidu-search';
  const cardSelector = '.c-result,#content_left>.result,#content_left>.result-op';
  const controls = 'button,input,textarea,select,video,audio,[contenteditable="true"],[role="button"],[role="slider"],.cosc-feedback,[data-feedback],[data-soulo-video-rotate],[data-soulo-hold-speed],#soulo-episode-dock';
  let options = {enabled:false,navigationEnabled:true,hosts:[],pathSuffixes:[],queryKeys:[]}, originalMarker;
  const css = `
html[data-soulo-baidu-search] { --soulo-baidu-title:#174ea6; --soulo-baidu-text:#202124; --soulo-baidu-muted:#687080; }
html[data-soulo-baidu-search]:is(.soulo-force-dark,[data-theme="dark"]) { --soulo-baidu-title:#a8c7fa; --soulo-baidu-text:#e8eaed; --soulo-baidu-muted:#aeb7c4; }
html[data-soulo-baidu-search] :is(#results,#content_left) :is([tpl^="www_"],[tpl^="se_st_"],[tpl="se_com_default"],[tpl="se_com_default_new"],.result:not([tpl])) :is(h3,.c-title) {
 font-family:-apple-system,BlinkMacSystemFont,'PingFang SC',sans-serif!important; font-size:19px!important; font-weight:500!important; line-height:1.45!important; color:var(--soulo-baidu-title)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) :is([tpl^="www_"],[tpl^="se_st_"],[tpl="se_com_default"],[tpl="se_com_default_new"],.result:not([tpl])) :is(h3,.c-title) :is(a,span,em) {
 color:inherit!important; font-size:inherit!important; font-weight:inherit!important; font-style:normal!important; text-decoration:none!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) :is([tpl^="www_"],[tpl^="se_st_"],[tpl="se_com_default"],[tpl="se_com_default_new"],.result:not([tpl])) :is([data-module="abstract"],.c-abstract,[class*="summary-text"]) {
 font-size:14.5px!important; line-height:1.65!important; color:var(--soulo-baidu-text)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) :is([tpl^="www_"],[tpl^="se_st_"],[tpl="se_com_default"],[tpl="se_com_default_new"],.result:not([tpl])) :is([data-module="abstract"],.c-abstract,[class*="summary-text"]) :is(span,em) {
 color:var(--soulo-baidu-text)!important; font-style:normal!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) :is([tpl^="www_"],[tpl^="se_st_"],[tpl="se_com_default"],[tpl="se_com_default_new"],.result:not([tpl])) :is(.c-showurl,.cosc-source-text) {
 font-size:12px!important; color:var(--soulo-baidu-muted)!important; }
html[data-soulo-baidu-search] :is(#results,#content_left) h3 a:active { opacity:.7; }
html[data-soulo-baidu-search] :is(#results,#content_left) a:focus-visible { outline:2px solid var(--soulo-baidu-title); outline-offset:3px; }
html[data-soulo-baidu-search] :is(.c-invoke-willshow-class,[class*="invoke-tip"]) { display:none!important; }
html[data-soulo-baidu-search] [style*="position: fixed"][style*="bottom: 0"]:has([ref="open"]),
html[data-soulo-baidu-search] [style*="position:fixed"][style*="bottom:0"]:has([ref="open"]) { display:none!important; }
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
    try { const url = new URL(value,document.baseURI); return /^https?:$/.test(url.protocol) && !url.username && !url.password ? url : null; }
    catch (_) { return null; }
  }
  function redirect(url) {
    return (url.hostname === 'baidu.com' || url.hostname.endsWith('.baidu.com'))
      && (url.pathname === '/link' || url.pathname === '/url' || /\/tc\/?$/.test(url.pathname));
  }
  function webFallback(element) {
    if (!element) return null;
    for (const key of ['data-url','data-landurl','data-land-url','data-href','rl-link-data-url','rl-link-href','mu']) {
      const value = element.getAttribute(key);
      if (!/^(https?:)?\/\//i.test(value || '')) continue;
      const url = http(value); if (url && !url.hostname.endsWith('.recommend_list.baidu.com')) return url.href;
    }
    for (const key of ['data-log','data-click']) {
      const value = element.getAttribute(key); if (!value || value.length > 16384) continue;
      try {
        const data = JSON.parse(value);
        for (const key of ['mu','landurl','land_url','url']) {
          if (!/^(https?:)?\/\//i.test(data[key] || '')) continue;
          const url = http(data[key]); if (url && !url.hostname.endsWith('.recommend_list.baidu.com')) return url.href;
        }
      } catch (_) {}
    }
    return null;
  }
  function destination(element) {
    const card = element.closest(cardSelector); if (!card || /video|vid_recommend/i.test(card.getAttribute('tpl') || '')) return null;
    const anchor = element.closest('a[href]');
    if (anchor?.hasAttribute('download')) return null;
    const invoke = anchor?.matches('.c-invoke-class,[data-rgitem-type="search"]');
    if (invoke && !element.closest('video,audio,input,textarea,button:disabled,[data-feedback],.cosc-feedback')) {
      const explicit = webFallback(anchor); if (explicit) return explicit;
      if (anchor.matches('[data-rgitem-type="search"]')) {
        const query = (anchor.getAttribute('data-word') || anchor.textContent).trim();
        if (query && query.length <= 200) { const url = new URL('/s',location.origin); url.searchParams.set('word',query); return url.href; }
      }
    }
    if (anchor && (!anchor.getAttribute('href')?.trim() || anchor.getAttribute('href').trim().startsWith('#'))) return null;
    if (element.closest(controls)) return null;
    const tpl = card.getAttribute('tpl') || card.getAttribute('srcid') || '';
    if (!/^www_|^se_st_|^se_com_default(?:_new)?$/.test(tpl) && (tpl || !card.closest('#content_left'))) return null;
    const title = card.querySelector('h3,.c-title,[data-module="title"],[role="heading"]');
    if (anchor) {
      const url = http(anchor.getAttribute('href'));
      if (url && !redirect(url)) return url.href;
      if (!title || !(title.contains(anchor) || anchor.contains(title))) return url?.href || null;
      // Resolve only this trusted result activation. The document's URLs stay intact.
      return webFallback(anchor) || webFallback(card) || webFallback(title?.closest('article')) || url?.href || null;
    }
    if (!title?.contains(element)) return null;
    return webFallback(title) || webFallback(card) || webFallback(title.closest('article'));
  }
  function restore() {
    document.getElementById(styleID)?.remove();
    if (originalMarker !== undefined) {
      if (originalMarker === null) document.documentElement?.removeAttribute(marker);
      else document.documentElement?.setAttribute(marker,originalMarker);
      originalMarker = undefined;
    }
  }
  function apply() {
    if (!document.documentElement) return;
    if (!options.enabled || !matchesPage()) { restore(); return; }
    if (originalMarker === undefined) originalMarker = document.documentElement.getAttribute(marker);
    if (document.documentElement.getAttribute(marker) !== '') document.documentElement.setAttribute(marker,'');
    if (!document.getElementById(styleID)) {
      const style = document.createElement('style'); style.id = styleID; style.textContent = css;
      (document.head || document.documentElement).append(style);
    }
  }
  window.addEventListener('click',event => {
    if (!options.enabled || !options.navigationEnabled || !event.isTrusted || event.defaultPrevented || !matchesPage()
        || event.button > 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || getSelection()?.toString()) return;
    const element = event.target instanceof Element ? event.target : event.target?.parentElement;
    if (!element) return;
    const bridge = globalThis.webkit?.messageHandlers?.souloSiteOptimizationNavigate;
    if (!bridge) return;
    const url = destination(element); if (!url) return;
    event.preventDefault(); event.stopImmediatePropagation(); bridge.postMessage({url});
  },true);
  window.addEventListener('pageshow',() => {
    apply(); globalThis.webkit?.messageHandlers?.souloSiteOptimizationNavigate?.postMessage({action:'ready'});
  });
  window.addEventListener('popstate',apply);
  document.addEventListener('DOMContentLoaded',apply,{once:true});
  globalThis.__souloSiteOptimization = {
    configure(next) { options = {...options,...next}; apply(); },
    finishNavigation() {} // Native browser chrome owns loading feedback.
  };
})();
