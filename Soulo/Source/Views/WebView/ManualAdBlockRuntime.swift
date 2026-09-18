import WebKit

enum ManualAdBlockRuntime {
    static let world = WKContentWorld.world(name: "SouloManualAdBlock")
    static let handler = "souloManualAdPicker"
    static let prefix = "/* SouloManualAdBlock v1 */"
    static let imageBannerSelector = "[data-soulo-image-banner]"

    @MainActor
    static func configuredScript(enabled: Bool, allowlistedHosts: [String], rules: [ManualAdRule]) -> String {
        let payload: [String: Any] = [
            "enabled": enabled,
            "allowlist": WebCompatibilityService.protectionBypassHosts(adding: allowlistedHosts),
            "rules": rules.map { ["host": $0.host, "path": $0.path as Any? ?? NSNull(), "selector": $0.selector] }
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return prefix + "\n" + tiledBannerDetection + "\n" + source + "\nwindow.__souloManualAds.configure(\(json));"
    }

    // Structural detection shared by automatic filtering and the isolated picker.
    // No website names, randomized tags, image URLs, or page text are persisted.
    static let tiledBannerDetection = #"""
    (() => {
      if (window.__souloBannerInteractions) return;
      const regions = new Map();
      function remember(group) {
        for (const el of group.elements) {
          const r = el.getBoundingClientRect();
          if (r.width > 0 && r.height > 0) regions.set(el, {
            left:r.left/innerWidth, right:r.right/innerWidth,
            bottom:innerHeight-r.bottom, height:r.height
          });
        }
        for (const el of regions.keys()) if (!el.isConnected) regions.delete(el);
      }
      function guard(event) {
        if (!event.isTrusted || document.documentElement.hasAttribute('data-soulo-ad-picker-active')) return;
        const p = event.changedTouches?.[0] || event;
        if (!Number.isFinite(p.clientX) || !Number.isFinite(p.clientY)) return;
        let blocked = false;
        for (const [el,r] of regions) {
          if (!el.isConnected) { regions.delete(el); continue; }
          const style = getComputedStyle(el);
          if (style.display !== 'none' && style.visibility !== 'hidden' && style.clipPath === 'none') continue;
          if (p.clientX >= r.left*innerWidth && p.clientX <= r.right*innerWidth
            && p.clientY >= innerHeight-r.bottom-r.height && p.clientY <= innerHeight-r.bottom) { blocked=true; break; }
        }
        if (!blocked) return;
        const target = event.target instanceof Element ? event.target : event.target?.parentElement;
        // Preserve real controls and native link activation. Suppress delegated
        // ad handlers on the formerly covered content, without preventing scroll.
        if (target?.closest('button,input,select,textarea,video,audio,[role="button"],[contenteditable="true"]')) return;
        event.stopImmediatePropagation();
        if (event.type === 'click' && !target?.closest('a[href]')) event.preventDefault();
      }
      ['pointerdown','pointerup','touchstart','touchend','click'].forEach(type =>
        window.addEventListener(type, guard, {capture:true, passive:type !== 'click'}));
      window.__souloBannerInteractions = {remember};
    })();
    (() => {
      if (window.__souloTiledBanners) return;
      const bounds = elements => {
        const rects = elements.map(e => e.getBoundingClientRect());
        const left = Math.min(...rects.map(r => r.left)), top = Math.min(...rects.map(r => r.top));
        const right = Math.max(...rects.map(r => r.right)), bottom = Math.max(...rects.map(r => r.bottom));
        return {left, top, right, bottom, width: right-left, height: bottom-top};
      };
      const tile = e => e instanceof Element && e.style.backgroundPosition
        && getComputedStyle(e).position === 'fixed' && getComputedStyle(e).backgroundImage !== 'none'
        && e.getBoundingClientRect().width > 0 && e.getBoundingClientRect().height > 0;
      function find(seed, hits = [], strict = false) {
        const first = tile(seed) ? seed : hits.find(tile);
        if (!first || !first.parentElement || first.parentElement.children.length > 600) return null;
        const style = getComputedStyle(first), siblings = Array.from(first.parentElement.children);
        if (strict && (!(first instanceof HTMLUnknownElement) && !first.localName.includes('-'))) return null;
        if (strict && Number(style.zIndex) < 10000) return null;
        const tiles = siblings.filter(e => e.localName === first.localName && tile(e)
          && getComputedStyle(e).backgroundImage === style.backgroundImage);
        if (tiles.length < 4 || tiles.length > 80) return null;
        if (strict && tiles.some(e => e.textContent.trim() || e.children.length
          || e.matches('[role], [aria-label], [tabindex]')
          || e.closest('form,nav,[role="toolbar"],[role="navigation"],[contenteditable="true"]'))) return null;
        const r = bounds(tiles);
        const area = tiles.reduce((sum,e) => { const b=e.getBoundingClientRect(); return sum+b.width*b.height; },0);
        if (r.width < innerWidth*.8 || r.height < 30 || r.height > Math.min(260,innerHeight*(strict ? .45 : .65))
          || Math.abs(r.bottom-innerHeight) > 12 || area < r.width*r.height*.85 || area > r.width*r.height*1.15) return null;
        const extras = siblings.filter(e => {
          if (tiles.includes(e) || e.children.length || e.textContent.trim()
            || e.matches('a,button,input,video,audio,iframe,[role="button"]')) return false;
          const s=getComputedStyle(e), b=e.getBoundingClientRect();
          if (b.width <= 0 || b.height <= 0) return false;
          const emptyCover = s.position === 'fixed' && Number(s.zIndex) >= Number(style.zIndex) && Number(s.zIndex) <= Number(style.zIndex)+2
            && s.backgroundImage === 'none' && ['transparent','rgba(0, 0, 0, 0)'].includes(s.backgroundColor)
            && b.left >= r.left-8 && b.right <= r.right+8 && b.top >= r.top-64 && b.bottom <= r.bottom+8;
          const matchingCover = e === seed && s.position === 'fixed' && s.backgroundImage === 'none'
            && Math.abs(b.left-r.left)<8 && Math.abs(b.right-r.right)<8 && Math.abs(b.top-r.top)<8 && Math.abs(b.bottom-r.bottom)<8;
          const spacer = e instanceof HTMLUnknownElement && s.position !== 'fixed'
            && Math.abs(b.width-r.width)<8 && Math.abs(b.height-r.height)<8;
          return emptyCover || matchingCover || spacer;
        });
        return {elements: [...tiles,...extras], bounds:r};
      }
      function all(strict = true) {
        const groups=[], seen=new Set();
        for (const el of Array.from(document.querySelectorAll('[style*="background-position"]')).slice(0,500)) {
          if (seen.has(el)) continue;
          const group=find(el,[],strict);
          if (group) { group.elements.forEach(e=>seen.add(e)); groups.push(group); }
        }
        return groups;
      }
      window.__souloTiledBanners = {find, all};
    })();
    (() => {
      if (window.__souloImageBanners) return;
      function all() {
        const groups = [];
        for (const el of document.querySelectorAll('div[id^="_s_"]')) {
          // Confirm the renderer's slot/runtime ID, image and both handlers.
          // A fixed image or a similarly named ordinary element is insufficient.
          const match = /^_s_(s[a-z0-9]+)_(rt_\d+_\d+)$/.exec(el.id);
          if (!match || el.style.position !== 'fixed' || el.style.bottom !== '0px'
            || el.style.width !== '100%' || Number(el.style.zIndex) < 10000
            || el.textContent.trim() || el.querySelector('form,input,video,audio,iframe,[role],[aria-label],[tabindex]')) continue;
          const children = Array.from(el.children), runtime = match[2];
          const imageLink = children.find(e => e.getAttribute('onclick') === "window['_j_" + runtime + "']()");
          const close = children.find(e => (e.getAttribute('onclick') || '').includes("window['_x_" + runtime + "']('" + el.id + "')"));
          const img = imageLink?.querySelector(':scope > img');
          if (!img || !close || children.length !== 2) continue;
          try { if (!/^https?:$/.test(new URL(img.src).protocol) || !new URL(img.src).pathname.startsWith('/navImgs/files/')) continue; }
          catch (_) { continue; }
          const elements = [el], mask = document.getElementById('mask_' + el.id);
          if (mask && (mask.parentElement === document.body || mask.parentElement === el.parentElement)
            && !mask.children.length && !mask.textContent.trim()
            && mask.style.position === 'fixed' && mask.style.width === '100%'
            && Number(mask.style.zIndex) === Number(el.style.zIndex)-1) elements.push(mask);
          groups.push({slot:match[1], elements, bounds:el.getBoundingClientRect(), selector:'[data-soulo-image-banner="'+match[1]+'"]'});
        }
        return groups;
      }
      function mark(group) {
        window.__souloBannerInteractions.remember(group);
        group.elements.forEach(e => {
          if (e.getAttribute('data-soulo-image-banner') !== group.slot) e.setAttribute('data-soulo-image-banner', group.slot);
        });
        return group;
      }
      window.__souloImageBanners = {all, mark};
    })();
    """#

    // This runs in a separate WebKit content world. Page scripts cannot send a
    // trusted selection or invoke the native save action. DOM changes remain visible.
    static let source = #"""
    (() => {
      if (window.__souloManualAds) return;
      let config = {}, sheet = null, picker = null, frame = 0;
      let selectors = [], pendingRoots = new Set(), inlineOriginals = new Map(), fallbackTimer = 0;
      const tiledSelector = '[data-soulo-tiled-banner="bottom"]';
      function markTiledBanners() {
        if (selectors.some(s => s.startsWith('[data-soulo-image-banner='))) window.__souloImageBanners.all().forEach(window.__souloImageBanners.mark);
        if (!selectors.includes(tiledSelector)) return;
        window.__souloTiledBanners.all(false).forEach(group => {
          window.__souloBannerInteractions.remember(group);
          group.elements.forEach(e => e.setAttribute('data-soulo-tiled-banner','bottom'));
        });
      }
      const protectedSelector = 'html,body,main,article,form,[role="main"],#app,#root,#__next,#__nuxt';
      const normalize = host => String(host || '').toLowerCase().replace(/^www\./, '');
      function allowed() {
        const host = normalize(location.hostname);
        return config.enabled && /^https?:$/.test(location.protocol)
          && !(config.allowlist || []).some(h => host === normalize(h) || host.endsWith('.' + normalize(h)))
          && !/(^|[\/?&#_=.-])(captcha|wappoc|verify|verification|challenge|security|passport|login|auth)([\/?&#_=.-]|$)/i.test(location.href);
      }
      function safe(el) {
        if (!(el instanceof Element) || !el.isConnected || el.matches(protectedSelector)) return false;
        if (el.closest('form,[contenteditable="true"]') || el.querySelector('input[type="password"],input[autocomplete="one-time-code"]')) return false;
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        // Avoid accidentally marking a whole screen or a long content wrapper.
        return !(r.width > innerWidth * .85 && r.height > innerHeight * .65);
      }
      function makeStyle() {
        // Constructed stylesheets work on pages that disallow inline <style>
        // elements through CSP. Supported throughout Soulo's iOS 17+ baseline.
        const css = new CSSStyleSheet();
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, css];
        return { sheet: css, remove() {
          document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== css);
        }};
      }
      function restoreInline(el, old) {
        if (el.style.getPropertyValue('display') !== 'none' || el.style.getPropertyPriority('display') !== 'important') return;
        if (old.value) el.style.setProperty('display', old.value, old.priority);
        else el.style.removeProperty('display');
      }
      function forceInlineIfNeeded(el) {
        if (el.matches(protectedSelector) || el.closest('form,[contenteditable="true"]')) return;
        if (el.style.getPropertyPriority('display') !== 'important' || el.style.getPropertyValue('display') === 'none') return;
        inlineOriginals.set(el, { value: el.style.getPropertyValue('display'), priority: 'important' });
        el.style.setProperty('display', 'none', 'important');
      }
      function inspectRoot(root) {
        if (!(root instanceof Element) || !root.isConnected) return;
        for (const selector of selectors) {
          try {
            if (root.matches(selector)) forceInlineIfNeeded(root);
            root.querySelectorAll(selector).forEach(forceInlineIfNeeded);
          } catch (_) {}
        }
      }
      function flushFallbacks() {
        fallbackTimer = 0;
        markTiledBanners();
        // CSS handles ordinary dynamic nodes. Only inline !important overrides
        // need an extra write; inspect changed subtrees, never rescan the page.
        const roots = Array.from(pendingRoots).slice(0, 40);
        roots.forEach(root => { pendingRoots.delete(root); inspectRoot(root); });
        for (const el of inlineOriginals.keys()) {
          if (!el.isConnected) inlineOriginals.delete(el);
          else if (!selectors.some(s => { try { return el.matches(s); } catch (_) { return false; } })) {
            restoreInline(el, inlineOriginals.get(el)); inlineOriginals.delete(el);
          }
        }
        if (pendingRoots.size) fallbackTimer = setTimeout(flushFallbacks, 100);
      }
      const fallbackObserver = new MutationObserver(records => {
        // Remembered mosaics can be rebuilt under a new random tag. Match them
        // in the mutation checkpoint, before the replacement can be painted.
        if (records.some(r => r.type === 'childList' && [...r.addedNodes].some(n => n instanceof Element))) markTiledBanners();
        for (const record of records) {
          if (record.type === 'attributes') {
            // Attribute-only changes need no descendant query.
            const el = record.target;
            if (selectors.some(s => { try { return el.matches(s); } catch (_) { return false; } })) forceInlineIfNeeded(el);
          } else record.addedNodes.forEach(node => { if (node instanceof Element) pendingRoots.add(node); });
        }
        if (pendingRoots.size && !fallbackTimer) fallbackTimer = setTimeout(flushFallbacks, 100);
      });
      function apply() {
        fallbackObserver.disconnect();
        clearTimeout(fallbackTimer); fallbackTimer = 0; pendingRoots.clear();
        inlineOriginals.forEach((old, el) => restoreInline(el, old)); inlineOriginals.clear();
        if (sheet) sheet.remove();
        sheet = null;
        if (!allowed()) { stop(); return; }
        selectors = (config.rules || []).filter(r => r.host === location.hostname.toLowerCase()
          && (r.path === null || r.path === location.pathname)).map(r => r.selector);
        if (!selectors.length) return;
        markTiledBanners();
        sheet = makeStyle();
        selectors.forEach(s => {
          try {
            if (s.length > 1024 || /[{};\n\r]/.test(s)) return;
            // insertRule parses each selector independently: one stale/bad rule
            // cannot break all rules. CSS automatically handles newly added ads.
            sheet.sheet.insertRule(':is(' + s + '):not(:is(' + protectedSelector + ',form *,[contenteditable="true"] *)) { display: none !important; }');
            document.querySelectorAll(s).forEach(forceInlineIfNeeded);
          } catch (_) {}
        });
        fallbackObserver.observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'id'] });
      }
      function selectorFor(el) {
        const unique = s => { try { const nodes = document.querySelectorAll(s); return nodes.length === 1 && nodes[0] === el; } catch (_) { return false; } };
        const clean = s => s && s.length <= 1024 && !/[{},;\n\r]/.test(s);
        if (el.id) {
          const s = '#' + CSS.escape(el.id);
          if (clean(s) && unique(s)) return s;
        }
        const classes = Array.from(el.classList).filter(c => !/\d{4}|^(active|selected|hover|focus)$/i.test(c)).slice(0, 3);
        if (classes.length) {
          const s = el.localName + classes.map(c => '.' + CSS.escape(c)).join('');
          if (clean(s) && unique(s)) return s;
        }
        let node = el, parts = [];
        for (let depth = 0; node && node !== document.body && depth < 10; depth++, node = node.parentElement) {
          if (node.id) {
            const id = '#' + CSS.escape(node.id);
            if (clean(id) && document.querySelectorAll(id).length === 1) {
              parts.unshift(id);
              const s = parts.join(' > ');
              if (clean(s) && unique(s)) return s;
              parts.shift();
            }
          }
          const index = Array.from(node.parentElement?.children || []).indexOf(node) + 1;
          parts.unshift(CSS.escape(node.localName) + ':nth-child(' + index + ')');
          const s = parts.join(' > ');
          if (clean(s) && unique(s)) return s;
        }
        return null;
      }
      function describe() {
        if (!picker) return null;
        const el = picker.selected;
        return { token: picker.token, url: location.href,
          selected: !!el, selector: el ? selectedSelector() : null,
          larger: !!el && !picker.group && safe(el.parentElement), smaller: picker.parents.length > 0,
          preview: picker.preview, invalid: picker.invalid };
      }
      function notify() {
        try { window.webkit.messageHandlers.souloManualAdPicker.postMessage(describe()); } catch (_) {}
      }
      function refreshTiledSelection() {
        if (picker?.group?.slot) {
          const group = window.__souloImageBanners.all().find(g => g.slot === picker.group.slot);
          if (!group) return false;
          picker.group = window.__souloImageBanners.mark(group);
          picker.selected = group.elements[0];
          return safe(picker.selected);
        }
        if (picker?.group?.selector !== tiledSelector) return true;
        const groups = window.__souloTiledBanners.all(false);
        const group = groups.find(g => g.elements.includes(picker.selected)) || (groups.length === 1 ? groups[0] : null);
        if (!group) return false;
        group.elements.forEach(e => e.setAttribute('data-soulo-tiled-banner','bottom'));
        picker.group = {selector:tiledSelector, ...group};
        picker.selected = group.elements.find(safe) || null;
        return !!picker.selected;
      }
      function draw() {
        frame = 0;
        if (!picker) return;
        if (!picker.preview && !refreshTiledSelection()) {
          // Responsive ads can remove old tiles and insert replacements in a
          // later task. Keep the structural selection until save revalidates it.
          picker.outline.style.display = 'none';
          return;
        }
        const el = picker.selected;
        if (el && !el.isConnected) { select(null); return; }
        picker.outline.style.display = el && !picker.preview ? 'block' : 'none';
        if (el && !picker.preview) {
          const r = picker.group?.bounds || el.getBoundingClientRect();
          Object.assign(picker.outline.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        }
      }
      function scheduleDraw() { if (!frame) frame = requestAnimationFrame(draw); }
      function restorePreview() {
        if (picker?.previewSheet) picker.previewSheet.remove();
        picker?.previewOriginals?.forEach((old, el) => restoreInline(el, old));
        if (picker) { picker.previewSheet = null; picker.previewOriginals = null; picker.preview = false; }
      }
      function select(el, keepParents = false) {
        if (!picker) return;
        restorePreview();
        picker.group = null;
        const valid = el && safe(el) && selectorFor(el);
        picker.selected = valid ? el : null;
        picker.invalid = !valid;
        if (!keepParents) picker.parents = [];
        draw(); notify();
      }
      function hit(event) {
        if (!picker) return;
        event.preventDefault(); event.stopImmediatePropagation();
        if (!event.isTrusted) return;
        // Accessibility activation can target the underlying link directly and
        // carry no useful coordinates. Treat it as a selection, never navigation.
        if (event.target instanceof Element && event.target !== picker.surface) {
          const r = event.target.getBoundingClientRect();
          pickAtPoint(r.left+r.width/2, r.top+r.height/2);
        }
        else pickAtPoint(event.clientX, event.clientY);
      }
      function pickAtPoint(x, y) {
        if (!picker || !allowed()) return null;
        picker.surface.style.setProperty('pointer-events', 'none', 'important');
        const hits = document.elementsFromPoint(x, y);
        const el = hits.find(e => e !== picker.surface && !picker.surface.contains(e));
        picker.surface.style.setProperty('pointer-events', 'auto', 'important');
        // Resolve the tiled image before rejecting an oversized transparent
        // hit layer. A full-screen click catcher must not make the visible
        // advertisement underneath impossible to mark.
        const imageGroup = window.__souloImageBanners.all().find(g => hits.some(hit => g.elements.some(e => e === hit || e.contains(hit))));
        const group = imageGroup ? window.__souloImageBanners.mark(imageGroup) : (el instanceof Element ? tiledBannerGroup(el, hits) : null);
        if (group) {
          select(group.elements.find(safe));
          if (picker.selected) { picker.group = group; draw(); notify(); }
        } else select(el);
        return describe();
      }
      function selectedSelector() { return picker.group?.selector || selectorFor(picker.selected); }
      function selectedElements() { return picker.group?.elements || [picker.selected]; }
      function tiledBannerGroup(overlay, hits) {
        const detected = window.__souloTiledBanners.find(overlay,hits);
        if (detected) {
          detected.elements.forEach(e => e.setAttribute('data-soulo-tiled-banner','bottom'));
          return {selector:tiledSelector, ...detected};
        }
        const style = getComputedStyle(overlay), r = overlay.getBoundingClientRect();
        if (style.position !== 'fixed' || style.backgroundImage !== 'none'
          || !['transparent', 'rgba(0, 0, 0, 0)'].includes(style.backgroundColor)
          || overlay.children.length || overlay.textContent.trim()) return null;
        const tile = hits.find(e => e !== overlay && e.parentElement === overlay.parentElement
          && e.style.backgroundPosition && getComputedStyle(e).position === 'fixed'
          && getComputedStyle(e).backgroundImage !== 'none');
        if (!tile) return null;
        const background = getComputedStyle(tile).backgroundImage;
        const tiles = Array.from(tile.parentElement.children).filter(e => e.localName === tile.localName
          && e.style.backgroundPosition && safe(e) && getComputedStyle(e).position === 'fixed'
          && getComputedStyle(e).backgroundImage === background);
        if (tiles.length < 4 || tiles.length > 80) return null;
        const rects = tiles.map(e => e.getBoundingClientRect());
        const bounds = { left: Math.min(...rects.map(r => r.left)), top: Math.min(...rects.map(r => r.top)),
          right: Math.max(...rects.map(r => r.right)), bottom: Math.max(...rects.map(r => r.bottom)) };
        if (Math.abs(bounds.left - r.left) > 8 || Math.abs(bounds.right - r.right) > 8
          || Math.abs(bounds.top - r.top) > 8 || Math.abs(bounds.bottom - r.bottom) > 8) return null;
        const parent = tile.parentElement === document.body ? 'body' : selectorFor(tile.parentElement);
        const cover = selectorFor(overlay);
        if (!parent || !cover) return null;
        const tileSelector = parent + ' > ' + CSS.escape(tile.localName) + '[style*="background-position"]';
        const matches = Array.from(document.querySelectorAll(tileSelector));
        if (matches.length !== tiles.length || matches.some(e => !tiles.includes(e))) return null;
        const selector = ':is(' + tileSelector + ',' + cover + ')';
        return selector.length <= 1024 ? { selector, elements: [...tiles, overlay] } : null;
      }
      function stop() {
        if (!picker) return;
        document.documentElement.removeAttribute('data-soulo-ad-picker-active');
        restorePreview(); picker.surface.remove(); picker.outline.remove();
        document.dispatchEvent(new Event('soulo-ad-picker-ended'));
        window.removeEventListener('scroll', scheduleDraw, true);
        window.removeEventListener('resize', scheduleDraw);
        window.visualViewport?.removeEventListener('resize', scheduleDraw);
        window.visualViewport?.removeEventListener('scroll', scheduleDraw);
        cancelAnimationFrame(frame); frame = 0; picker = null;
      }
      function begin(token) {
        stop();
        if (!allowed() || !document.body) return false;
        document.documentElement.setAttribute('data-soulo-ad-picker-active', 'true');
        document.dispatchEvent(new Event('soulo-ad-picker-started'));
        const surface = document.createElement('div'), outline = document.createElement('div');
        surface.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;background:transparent!important;touch-action:pan-y pinch-zoom!important;';
        outline.style.cssText = 'all:initial;position:fixed;box-sizing:border-box;z-index:2147483647;pointer-events:none;border:2px solid #007aff;background:rgba(0,122,255,.14);border-radius:4px;display:none;';
        surface.setAttribute('aria-hidden', 'true'); outline.setAttribute('aria-hidden', 'true');
        surface.addEventListener('contextmenu', e => e.preventDefault());
        surface.setAttribute('popover','manual');
        surface.style.setProperty('margin','0','important');
        surface.style.setProperty('padding','0','important');
        document.documentElement.append(surface);
        surface.append(outline);
        try { surface.showPopover(); } catch (_) {}
        picker = { token, surface, outline, selected: null, parents: [], preview: false, invalid: false };
        window.addEventListener('scroll', scheduleDraw, { passive: true, capture: true });
        window.addEventListener('resize', scheduleDraw, { passive: true });
        window.visualViewport?.addEventListener('resize', scheduleDraw, { passive: true });
        window.visualViewport?.addEventListener('scroll', scheduleDraw, { passive: true });
        return true;
      }
      function command(action) {
        if (!picker || !allowed()) { stop(); return null; }
        if (action === 'cancel') { stop(); return null; }
        if (action === 'larger' && picker.selected && !picker.group && safe(picker.selected.parentElement)) {
          picker.parents.push(picker.selected); select(picker.selected.parentElement, true);
        } else if (action === 'smaller' && picker.parents.length) select(picker.parents.pop(), true);
        else if (action === 'preview' && picker.selected) {
          if (picker.preview) restorePreview();
          else {
            if (!safe(picker.selected)) { select(null); return describe(); }
            const selector = selectedSelector();
            if (!selector) { select(null); return describe(); }
            const style = makeStyle();
            style.sheet.insertRule(selector + ' { display:none !important; }');
            picker.previewOriginals = new Map();
            selectedElements().forEach(el => {
              if (el.style.getPropertyPriority('display') === 'important' && el.style.getPropertyValue('display') !== 'none') {
                picker.previewOriginals.set(el, { value: el.style.getPropertyValue('display'), priority: 'important' });
                el.style.setProperty('display', 'none', 'important');
              }
            });
            picker.previewSheet = style; picker.preview = true;
          }
          draw(); notify();
        }
        return describe();
      }
      window.__souloManualAds = {
        configure(value) { config = value; apply(); }, begin, command, pickAtPoint,
        selection() {
          if (!picker || !allowed()) return null;
          restorePreview();
          if (!refreshTiledSelection() || !selectedElements().every(safe)) { select(null); return null; }
          const result = describe(); draw(); return result;
        }
      };
      window.addEventListener('click', hit, true);
      ['pointerdown','pointerup','touchstart','touchend'].forEach(type => window.addEventListener(type, event => {
        if (picker) event.stopImmediatePropagation();
      }, {capture:true, passive:true}));
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', apply, {once:true});
      window.addEventListener('popstate', () => { stop(); apply(); });
      window.addEventListener('hashchange', () => { stop(); apply(); });
    })();
    """#
}
