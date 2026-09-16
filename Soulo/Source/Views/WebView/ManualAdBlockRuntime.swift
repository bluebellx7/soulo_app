import WebKit

enum ManualAdBlockRuntime {
    static let world = WKContentWorld.world(name: "SouloManualAdBlock")
    static let handler = "souloManualAdPicker"
    static let prefix = "/* SouloManualAdBlock v1 */"

    @MainActor
    static func configuredScript(enabled: Bool, allowlistedHosts: [String], rules: [ManualAdRule]) -> String {
        let payload: [String: Any] = [
            "enabled": enabled,
            "allowlist": WebCompatibilityService.protectionBypassHosts(adding: allowlistedHosts),
            "rules": rules.map { ["host": $0.host, "path": $0.path as Any? ?? NSNull(), "selector": $0.selector] }
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return prefix + "\n" + source + "\nwindow.__souloManualAds.configure(\(json));"
    }

    // This runs in a separate WebKit content world. Page scripts cannot send a
    // trusted selection or invoke the native save action. DOM changes remain visible.
    static let source = #"""
    (() => {
      if (window.__souloManualAds) return;
      let config = {}, sheet = null, picker = null, frame = 0;
      let selectors = [], pendingRoots = new Set(), inlineOriginals = new Map(), fallbackTimer = 0;
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
        for (const record of records) {
          if (record.type === 'attributes') {
            // Attribute-only changes need no descendant query.
            const el = record.target;
            if (selectors.some(s => { try { return el.matches(s); } catch (_) { return false; } })) forceInlineIfNeeded(el);
          } else record.addedNodes.forEach(node => { if (node instanceof Element) pendingRoots.add(node); });
        }
        if (!fallbackTimer) fallbackTimer = setTimeout(flushFallbacks, 100);
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
        sheet = makeStyle();
        selectors.forEach(s => {
          try {
            if (s.length > 1024 || /[{},;\n\r]/.test(s)) return;
            // insertRule parses each selector independently: one stale/bad rule
            // cannot break all rules. CSS automatically handles newly added ads.
            sheet.sheet.insertRule(':is(' + s + '):not(:is(' + protectedSelector + ',form *,[contenteditable="true"] *)) { display: none !important; }');
            document.querySelectorAll(s).forEach(forceInlineIfNeeded);
          } catch (_) {}
        });
        fallbackObserver.observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class', 'id'] });
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
          selected: !!el, selector: el ? selectorFor(el) : null,
          larger: !!el && safe(el.parentElement), smaller: picker.parents.length > 0,
          preview: picker.preview, invalid: picker.invalid };
      }
      function notify() {
        try { window.webkit.messageHandlers.souloManualAdPicker.postMessage(describe()); } catch (_) {}
      }
      function draw() {
        frame = 0;
        if (!picker) return;
        const el = picker.selected;
        if (el && !el.isConnected) { select(null); return; }
        picker.outline.style.display = el && !picker.preview ? 'block' : 'none';
        if (el && !picker.preview) {
          const r = el.getBoundingClientRect();
          Object.assign(picker.outline.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
        }
      }
      function scheduleDraw() { if (!frame) frame = requestAnimationFrame(draw); }
      function restorePreview() {
        if (picker?.previewSheet) picker.previewSheet.remove();
        if (picker?.previewOriginal && picker.selected) restoreInline(picker.selected, picker.previewOriginal);
        if (picker) { picker.previewSheet = null; picker.previewOriginal = null; picker.preview = false; }
      }
      function select(el, keepParents = false) {
        if (!picker) return;
        restorePreview();
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
        if (event.target instanceof Element && event.target !== picker.surface) select(event.target);
        else pickAtPoint(event.clientX, event.clientY);
      }
      function pickAtPoint(x, y) {
        if (!picker || !allowed()) return null;
        picker.surface.style.setProperty('pointer-events', 'none', 'important');
        const el = document.elementFromPoint(x, y);
        picker.surface.style.setProperty('pointer-events', 'auto', 'important');
        select(el);
        return describe();
      }
      function stop() {
        if (!picker) return;
        restorePreview(); picker.surface.remove(); picker.outline.remove();
        window.removeEventListener('click', hit, true);
        window.removeEventListener('scroll', scheduleDraw, true);
        window.removeEventListener('resize', scheduleDraw);
        window.visualViewport?.removeEventListener('resize', scheduleDraw);
        window.visualViewport?.removeEventListener('scroll', scheduleDraw);
        cancelAnimationFrame(frame); frame = 0; picker = null;
      }
      function begin(token) {
        stop();
        if (!allowed() || !document.body) return false;
        const surface = document.createElement('div'), outline = document.createElement('div');
        surface.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;z-index:2147483647!important;background:transparent!important;touch-action:pan-y pinch-zoom!important;';
        outline.style.cssText = 'all:initial;position:fixed;box-sizing:border-box;z-index:2147483647;pointer-events:none;border:2px solid #007aff;background:rgba(0,122,255,.14);border-radius:4px;display:none;';
        surface.setAttribute('aria-hidden', 'true'); outline.setAttribute('aria-hidden', 'true');
        window.addEventListener('click', hit, true);
        surface.addEventListener('contextmenu', e => e.preventDefault());
        document.documentElement.append(surface, outline);
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
        if (action === 'larger' && picker.selected && safe(picker.selected.parentElement)) {
          picker.parents.push(picker.selected); select(picker.selected.parentElement, true);
        } else if (action === 'smaller' && picker.parents.length) select(picker.parents.pop(), true);
        else if (action === 'preview' && picker.selected) {
          if (picker.preview) restorePreview();
          else {
            if (!safe(picker.selected)) { select(null); return describe(); }
            const selector = selectorFor(picker.selected);
            if (!selector) { select(null); return describe(); }
            const style = makeStyle();
            style.sheet.insertRule(selector + ' { display:none !important; }');
            const el = picker.selected;
            if (el.style.getPropertyPriority('display') === 'important' && el.style.getPropertyValue('display') !== 'none') {
              picker.previewOriginal = { value: el.style.getPropertyValue('display'), priority: 'important' };
              el.style.setProperty('display', 'none', 'important');
            }
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
          if (!safe(picker.selected)) { select(null); return null; }
          const result = describe(); draw(); return result;
        }
      };
      window.addEventListener('popstate', () => { stop(); apply(); });
      window.addEventListener('hashchange', () => { stop(); apply(); });
    })();
    """#
}
