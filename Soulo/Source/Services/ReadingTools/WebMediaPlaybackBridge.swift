import WebKit

enum WebVideoOrientationRuntime {
    static let world = WKContentWorld.world(name: "SouloVideoOrientation")
    static let handler = "souloVideoOrientation"

    @MainActor static func script() -> String {
        let label = (try? JSONSerialization.data(withJSONObject: [ToolText.text("media_landscape"), ToolText.text("web_media_speed"), LanguageManager.shared.localizedString("download"), ToolText.text("video_tools")]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"Fullscreen\"]"
        return source + "\nwindow.__souloVideoOrientation.setLabels(\(label));"
    }

    // Inject into every frame in an isolated world, so cross-origin embedded
    // players have the same control without exposing the native bridge to pages.
    static let source = #"""
    (() => {
      if (window.__souloVideoOrientation) return;
      const controls = new Map(), roots = new Set(), pending = new Set();
      let labels = ['Fullscreen', 'Speed', 'Download', 'Video tools'], frame = 0, scanTimer = 0, active = null, expandedGroup = null;
      function send(action, token) {
        try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action, token}); } catch (_) {}
      }
      function isFullscreen(video) {
        return video.webkitDisplayingFullscreen || video.webkitPresentationMode === 'fullscreen'
          || document.fullscreenElement === video;
      }
      function finish(action = 'end') {
        if (!active) return;
        clearTimeout(active.timeout);
        if (active.sizing) {
          const {video, sizing} = active;
          for (const [property, old] of sizing) {
            if (video.style.getPropertyValue(property) !== old.applied) continue;
            if (old.value) video.style.setProperty(property, old.value, old.priority);
            else video.style.removeProperty(property);
          }
        }
        send(action, active.token); active = null; schedule();
      }
      function fullscreenChanged() {
        if (!active) return;
        if (isFullscreen(active.video)) {
          if (!active.began) {
            active.began = true; clearTimeout(active.timeout); send('begin', active.token); schedule();
          }
        } else if (active.began) finish();
      }
      function enterFullscreen(video) {
        if (active) return;
        const token = globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + Math.random().toString(36);
        active = {video, token, began:false, timeout:setTimeout(() => { if (active?.token === token) finish('failed'); }, 5000)};
        send('prepare', token);
        try {
          // Keep this call synchronous within the real click's user activation.
          // The video stays in its original player: no URL extraction or reload.
          // WebKit can retain the inline render-box size when transferring
          // the video layer to AVKit, including through requestFullscreen().
          // Prepare the landscape fit size before transfer and restore only
          // our own overrides on exit. The media element and source stay intact.
          const w = Math.max(screen.width, screen.height), h = Math.min(screen.width, screen.height);
          const ratio = video.videoWidth > 0 && video.videoHeight > 0 ? video.videoWidth / video.videoHeight : 16 / 9;
          const values = {width:Math.min(w, h * ratio) + 'px', height:Math.min(h, w / ratio) + 'px',
            'max-width':'none', 'max-height':'none', 'min-width':'0px', 'min-height':'0px', 'object-fit':'contain'};
          active.sizing = new Map();
          for (const [property, value] of Object.entries(values)) {
            const old = {value:video.style.getPropertyValue(property), priority:video.style.getPropertyPriority(property)};
            video.style.setProperty(property, value, 'important');
            old.applied = video.style.getPropertyValue(property); active.sizing.set(property, old);
          }
          video.getBoundingClientRect();
          video.play()?.catch(() => {});
          if (document.fullscreenEnabled && video.requestFullscreen) {
            video.requestFullscreen().catch(() => { if (active?.token === token) finish('failed'); });
          } else if (typeof video.webkitEnterFullscreen === 'function') video.webkitEnterFullscreen();
          else finish('failed');
        } catch (_) { finish('failed'); }
      }
      function prune() {
        for (const [video, button] of controls) {
          if (!video.isConnected) { if (expandedGroup === button) collapse(); if (active?.video === video) finish(); button.remove(); resize.unobserve(video); controls.delete(video); }
        }
        let removedRoot = false;
        for (const root of roots) if (root.host && !root.host.isConnected) { roots.delete(root); removedRoot = true; }
        if (removedRoot) {
          observer.disconnect();
          roots.forEach(root => observer.observe(root, {childList:true,subtree:true}));
        }
      }
      function layout() {
        frame = 0;
        prune();
        for (const [video, button] of controls) {
          const r = video.getBoundingClientRect(), style = getComputedStyle(video);
          const visible = !active?.began && r.width >= 100 && r.height >= 70 && r.right > 44 && r.bottom > 44
            && r.left < innerWidth - 44 && r.top < innerHeight - 44
            && style.visibility !== 'hidden' && style.display !== 'none' && style.opacity !== '0';
          button.style.setProperty('display', visible ? 'flex' : 'none', 'important');
          if (!visible) continue;
          const width = button === expandedGroup ? 144 : 36;
          button.style.setProperty('right', Math.max(4, Math.min(innerWidth - width - 4, innerWidth - r.right + 8)) + 'px', 'important');
          button.style.setProperty('top', Math.max(4, r.top + 8) + 'px', 'important');
        }
      }
      function schedule() { if (!frame) frame = requestAnimationFrame(layout); }
      function collapse() {
        if (!expandedGroup) return;
        const group = expandedGroup; expandedGroup = null;
        group.style.setProperty('width', '36px', 'important');
        group.querySelectorAll('[data-video-action]').forEach(el => showAction(el, false));
        const toggle = group.querySelector('[data-video-toggle]');
        toggle.setAttribute('aria-expanded', 'false'); toggle.innerHTML = toolsIcon;
        schedule();
      }
      const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
      function configureMotion(group) {
        group.style.setProperty('transition', reducedMotion.matches ? 'none' : 'width 220ms cubic-bezier(.2,.8,.2,1)', 'important');
        group.querySelectorAll('[data-video-action]').forEach(action => {
          action.style.setProperty('transition', reducedMotion.matches ? 'none' : 'opacity 140ms ease,transform 220ms cubic-bezier(.2,.8,.2,1)', 'important');
        });
      }
      function showAction(action, visible) {
        action.style.setProperty('opacity', visible ? '1' : '0', 'important');
        action.style.setProperty('transform', visible ? 'translateX(0)' : 'translateX(6px)', 'important');
        action.style.setProperty('pointer-events', visible ? 'auto' : 'none', 'important');
        action.setAttribute('aria-hidden', visible ? 'false' : 'true');
        action.tabIndex = visible ? 0 : -1;
      }
      reducedMotion.addEventListener('change', () => controls.forEach(configureMotion));
      const svg = content => '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + content + '</svg>';
      const toolsIcon = svg('<path d="M10 19H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v6"/><path d="m8 7 5 3-5 3Z" fill="currentColor" stroke="none"/><path d="M14 16h2m3 0h3m-8 5h5"/><circle cx="17.5" cy="16" r="1.5"/><circle cx="20.5" cy="21" r="1.5"/>');
      const resize = new ResizeObserver(schedule);
      function add(video) {
        if (controls.has(video)) return;
        const button = document.createElement('div');
        button.setAttribute('data-soulo-video-rotate', '');
        button.setAttribute('role', 'group');
        button.dataset.souloMediaID = globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + Math.random().toString(36);
        button.style.cssText = 'all:initial!important;position:fixed!important;z-index:2147483646!important;display:none!important;width:36px!important;height:36px!important;align-items:center!important;justify-content:flex-end!important;border-radius:18px!important;background:rgba(24,25,29,.7)!important;backdrop-filter:blur(16px) saturate(1.2)!important;-webkit-backdrop-filter:blur(16px) saturate(1.2)!important;box-shadow:inset 0 0 0 1px rgba(255,255,255,.16),0 2px 8px rgba(0,0,0,.16)!important;color:rgba(255,255,255,.94)!important;pointer-events:auto!important;touch-action:manipulation!important;isolation:isolate!important;overflow:hidden!important;user-select:none!important;-webkit-user-select:none!important;-webkit-touch-callout:none!important;';
        const controlStyle = 'all:initial!important;box-sizing:border-box!important;width:36px!important;min-width:36px!important;height:36px!important;display:flex!important;flex-direction:column!important;align-items:center!important;justify-content:center!important;border-radius:18px!important;color:rgba(255,255,255,.94)!important;cursor:pointer!important;user-select:none!important;-webkit-user-select:none!important;-webkit-touch-callout:none!important;font:600 14px -apple-system,sans-serif!important;';
        const fullscreen = document.createElement('button'); fullscreen.type = 'button'; fullscreen.style.cssText = controlStyle;
        fullscreen.setAttribute('aria-label', labels[0]); fullscreen.title = labels[0];
        fullscreen.innerHTML = svg('<rect x="3" y="3" width="10" height="18" rx="2.5"/><path d="M6.5 6h3M16 12h2.5a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-2.5 2.5H16M16 3a7 7 0 0 1 5 6m-3-1 3 1 .5-3"/><circle cx="8" cy="17.5" r=".9"/>');
        fullscreen.addEventListener('click', event => {
          event.preventDefault(); event.stopImmediatePropagation();
          if (!event.isTrusted || !video.isConnected) return;
          collapse(); enterFullscreen(video);
        });
        for (const event of ['webkitbeginfullscreen', 'webkitendfullscreen', 'webkitpresentationmodechanged']) {
          video.addEventListener(event, fullscreenChanged);
        }
        const download = document.createElement('button'); download.type = 'button'; download.style.cssText = controlStyle;
        download.setAttribute('aria-label', labels[2]); download.title = labels[2];
        download.innerHTML = svg('<path d="M12 3v12m-4-4 4 4 4-4M5 17v2a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-2"/>');
        download.addEventListener('click', event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          collapse();
          try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action:'download',token:'download',url:video.currentSrc || video.src || ''}); } catch (_) {}
        });
        const speed = document.createElement('button'); speed.type = 'button'; speed.style.cssText = controlStyle;
        speed.setAttribute('aria-label', labels[1]); speed.title = labels[1];
        speed.innerHTML = svg('<circle cx="12" cy="12" r="8.5"/><path d="M12 5v1M5 12h1m12 0h1M7 7l.7.7m4.3 4.3 4-4"/><circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/>');
        const updateRate = () => { speed.setAttribute('aria-valuetext', video.playbackRate + '×'); };
        video.addEventListener('ratechange', updateRate); updateRate();
        speed.addEventListener('click', event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          collapse();
          try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action:'speed',token:button.dataset.souloMediaID,rate:video.playbackRate}); } catch (_) {}
        });
        for (const action of [download, speed, fullscreen]) {
          action.setAttribute('data-video-action', ''); showAction(action, false);
          action.addEventListener('pointerdown', () => action.style.setProperty('background','rgba(255,255,255,.14)','important'));
          for (const event of ['pointerup','pointercancel','pointerleave']) action.addEventListener(event, () => action.style.setProperty('background','transparent','important'));
        }
        const toggle = document.createElement('button'); toggle.type = 'button'; toggle.style.cssText = controlStyle;
        toggle.setAttribute('data-video-toggle',''); toggle.setAttribute('aria-label', labels[3]);
        toggle.title = labels[3]; toggle.setAttribute('aria-expanded','false'); toggle.innerHTML = toolsIcon;
        toggle.addEventListener('pointerdown', () => toggle.style.setProperty('background','rgba(255,255,255,.14)','important'));
        for (const event of ['pointerup','pointercancel','pointerleave']) toggle.addEventListener(event, () => toggle.style.setProperty('background','transparent','important'));

        toggle.addEventListener('click', event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          const wasExpanded = expandedGroup === button; collapse(); if (wasExpanded) return;
          expandedGroup = button; button.style.setProperty('width','144px','important');
          for (const action of [download, speed, fullscreen]) showAction(action, true);
          toggle.setAttribute('aria-expanded','true'); toggle.innerHTML = svg('<path d="m10 7 5 5-5 5"/>'); schedule();
        });
        button.append(download, speed, fullscreen, toggle);
        configureMotion(button);
        document.documentElement.append(button);
        controls.set(video, button); resize.observe(video);
      }
      function scan(root = document) {
        if ((root === document || root instanceof ShadowRoot) && !roots.has(root)) {
          roots.add(root); observer.observe(root, {childList:true,subtree:true});
        }
        if (root instanceof Element && root.matches('video')) add(root);
        if (root instanceof Element && root.shadowRoot) scan(root.shadowRoot);
        root.querySelectorAll('video').forEach(add);
        root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) scan(el.shadowRoot); });
        schedule();
      }
      const observer = new MutationObserver(records => {
        if (records.every(r => [...r.addedNodes, ...r.removedNodes].every(n =>
          (r.target instanceof Element && r.target.closest('[data-soulo-video-rotate]')) || (n instanceof Element && n.hasAttribute('data-soulo-video-rotate'))))) return;
        for (const record of records) for (const node of record.addedNodes) {
          if (node instanceof Element && !node.hasAttribute('data-soulo-video-rotate')) pending.add(node);
        }
        if (!scanTimer) scanTimer = setTimeout(() => {
          scanTimer = 0;
          pending.forEach(node => { if (node.isConnected) scan(node); }); pending.clear();
          // Hidden tabs may suspend animation frames. Release detached videos
          // and controls even while layout is paused.
          prune();
          schedule();
        }, 150);
      });
      window.__souloVideoOrientation = {setLabels(value) {
        labels = value;
        controls.forEach(group => {
          const buttons = group.querySelectorAll(':scope > button');
          [2,1,0,3].forEach((index, i) => { buttons[i].setAttribute('aria-label', labels[index]); buttons[i].title = labels[index]; });
        });
      }, async setRate(token, rate) {
        for (const [video, group] of controls) if (group.dataset.souloMediaID === token && video.isConnected) {
          if (![0.5,1,1.5,2,4,8,16].includes(rate)) return false;
          try {
            video.defaultPlaybackRate = rate; video.playbackRate = rate;
            await new Promise(resolve => setTimeout(resolve, 250));
            return Math.abs(video.playbackRate - rate) < 0.01;
          } catch (_) { return false; }
        }
        return false;
      }};
      document.addEventListener('fullscreenchange', fullscreenChanged);
      window.addEventListener('pagehide', () => { collapse(); finish(); });
      const collapseOutside = event => {
        if (expandedGroup && !event.composedPath().includes(expandedGroup)) collapse();
      };
      // iOS may omit pointer events on non-interactive text; touchstart also
      // dismisses the palette when the user taps or begins scrolling the page.
      for (const event of ['pointerdown', 'touchstart']) {
        window.addEventListener(event, collapseOutside, {capture:true, passive:true});
      }
      window.addEventListener('scroll', schedule, {capture:true,passive:true});
      window.addEventListener('resize', schedule, {passive:true});
      window.visualViewport?.addEventListener('resize', schedule, {passive:true});
      document.addEventListener('loadedmetadata', schedule, true);
      document.addEventListener('play', schedule, true);
      scan();
    })();
    """#
}

struct WebMediaPlaybackState: Equatable {
    var count = 0
    var rate = 1.0
}

@MainActor enum WebMediaPlaybackBridge {
    /// A small scan for visible browser controls; no article extraction or network requests.
    static func inspect(_ webView: WKWebView) async -> WebMediaPlaybackState {
        let script = #"""
        const items = [], seen = new Set();
        const visit = doc => {
            if (!doc || seen.has(doc) || seen.size >= 12) return;
            seen.add(doc);
            doc.querySelectorAll('video,audio').forEach(m => {
                if (m.currentSrc || m.getAttribute('src') || m.srcObject || m.querySelector('source[src]')) items.push(m);
            });
            doc.querySelectorAll('iframe').forEach(f => { try { visit(f.contentDocument); } catch {} });
        };
        visit(document);
        const area = m => {
            const r = m.getBoundingClientRect(), w = m.ownerDocument.defaultView;
            return Math.max(0, Math.min(r.right,w.innerWidth)-Math.max(r.left,0)) *
                Math.max(0,Math.min(r.bottom,w.innerHeight)-Math.max(r.top,0));
        };
        items.sort((a,b) => Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || area(b) - area(a));
        const active = items[0];
        return {count: items.length, rate: active ? active.playbackRate : 1};
        """#
        guard let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else { return .init() }
        return .init(count: result["count"] as? Int ?? 0, rate: result["rate"] as? Double ?? 1)
    }

    static func setRate(_ rate: Double, on webView: WKWebView) async throws -> [Double] {
        guard MediaSession.validRate(Float(rate)) else { throw ReadingToolError.invalid }
        // The page world may wrap playbackRate. Use WebKit's isolated DOM bindings and
        // verify the native value after the player's initial ratechange handlers run.
        let result = try await webView.callAsyncJavaScript(rateControllerScript,
            arguments: ["requestedRate": rate], in: nil, contentWorld: .defaultClient)
        guard let rates = result as? [Double], let actual = rates.first,
              abs(actual - rate) < 0.001 else { throw ReadingToolError.unsupported }
        return rates
    }

    private static let rateControllerScript = #"""
    const key = '__souloMediaRateController_v1';
    const collect = () => {
        const documents = [], items = [], seen = new Set();
        const visit = doc => {
            if (!doc || seen.has(doc) || seen.size >= 12) return;
            seen.add(doc); documents.push(doc);
            doc.querySelectorAll('video,audio').forEach(m => items.push(m));
            doc.querySelectorAll('iframe').forEach(f => { try { visit(f.contentDocument); } catch {} });
        };
        visit(document);
        return {documents, items};
    };
    const readRate = m => {
        try {
            const proto = m.ownerDocument.defaultView.HTMLMediaElement.prototype;
            return Object.getOwnPropertyDescriptor(proto, 'playbackRate').get.call(m);
        } catch { return m.playbackRate; }
    };
    const writeRate = (m, value) => {
        try {
            const proto = m.ownerDocument.defaultView.HTMLMediaElement.prototype;
            for (const name of ['defaultPlaybackRate', 'playbackRate']) {
                const property = Object.getOwnPropertyDescriptor(proto, name);
                if (Math.abs(property.get.call(m) - value) > .001) property.set.call(m, value);
            }
        } catch {}
    };
    const ordered = items => {
        const visibleArea = m => {
            const r = m.getBoundingClientRect(), w = m.ownerDocument.defaultView;
            return Math.max(0, Math.min(r.right, w.innerWidth) - Math.max(r.left, 0)) *
                Math.max(0, Math.min(r.bottom, w.innerHeight) - Math.max(r.top, 0));
        };
        return [...items].sort((a,b) =>
            Number(!b.paused && !b.ended) - Number(!a.paused && !a.ended) || visibleArea(b) - visibleArea(a));
    };
    let controller = globalThis[key];
    if (!controller && collect().items.length === 0) return [];
    if (requestedRate === 1) {
        if (controller) controller.dispose();
        const items = ordered(collect().items);
        items.forEach(m => writeRate(m, 1));
        await new Promise(resolve => setTimeout(resolve, 160));
        return items.filter(m => m.isConnected).map(readRate);
    }
    if (!controller) {
        const records = new Map(), documents = new Map();
        let refreshTimer = null, disposed = false;
        controller = {
            desired: requestedRate,
            refresh,
            reset() {
                records.forEach((record, media) => { arm(record); writeRate(media, controller.desired); });
            },
            dispose() {
                disposed = true;
                clearTimeout(refreshTimer);
                records.forEach(record => record.remove()); records.clear();
                documents.forEach(record => record.remove()); documents.clear();
                window.removeEventListener('pagehide', controller.dispose);
                if (globalThis[key] === controller) delete globalThis[key];
            }
        };
        function arm(record) { record.retries = 0; record.until = performance.now() + 2000; }
        function schedule() {
            if (!disposed && refreshTimer === null) refreshTimer = setTimeout(() => {
                refreshTimer = null; refresh();
            }, 60);
        }
        function refresh() {
            if (disposed) return;
            const current = collect(), present = new Set(current.items);
            records.forEach((record, media) => {
                if (!present.has(media)) { record.remove(); records.delete(media); }
            });
            documents.forEach((record, doc) => {
                if (!current.documents.includes(doc)) { record.remove(); documents.delete(doc); }
            });
            current.documents.forEach(doc => {
                if (documents.has(doc)) return;
                const relevant = node => node.nodeType === 1 &&
                    (node.matches('video,audio,source,iframe') || node.querySelector('video,audio,source,iframe'));
                const observer = new MutationObserver(changes => {
                    if (changes.some(change => change.type === 'attributes'
                        ? change.target.matches('video,audio,source,iframe')
                        : [...change.addedNodes, ...change.removedNodes].some(relevant))) schedule();
                });
                observer.observe(doc, {subtree: true, childList: true, attributes: true, attributeFilter: ['src']});
                doc.addEventListener('load', schedule, true);
                documents.set(doc, {remove() { observer.disconnect(); doc.removeEventListener('load', schedule, true); }});
            });
            current.items.forEach(media => {
                const source = media.currentSrc || media.getAttribute('src') || media.querySelector('source[src]')?.src || '';
                let record = records.get(media);
                if (record) {
                    if (record.source !== source) {
                        record.source = source; arm(record); writeRate(media, controller.desired);
                    }
                    return;
                }
                record = {source, retries: 0, until: 0};
                const restart = () => {
                    if (performance.now() > record.until) arm(record);
                    if (record.retries < 4 && Math.abs(readRate(media) - controller.desired) > .001) {
                        record.retries++; writeRate(media, controller.desired);
                    }
                };
                const changed = () => {
                    if (disposed || Math.abs(readRate(media) - controller.desired) < .001) return;
                    // Repair startup resets only. Never create an endless ratechange fight,
                    // and allow the site's own speed controls once startup has settled.
                    if (performance.now() <= record.until && record.retries < 4) {
                        record.retries++; writeRate(media, controller.desired);
                    }
                };
                media.addEventListener('loadedmetadata', restart);
                media.addEventListener('play', restart);
                media.addEventListener('ratechange', changed);
                record.remove = () => {
                    media.removeEventListener('loadedmetadata', restart);
                    media.removeEventListener('play', restart);
                    media.removeEventListener('ratechange', changed);
                };
                records.set(media, record); restart();
            });
        }
        globalThis[key] = controller;
        window.addEventListener('pagehide', controller.dispose, {once: true});
    }
    controller.desired = requestedRate;
    controller.refresh();
    controller.reset();
    await new Promise(resolve => setTimeout(resolve, 160));
    return ordered(collect().items).map(readRate);
    """#
}

/// Lives with a tab, not its SwiftUI wrapper. Keeps bounded, in-memory checkpoints
/// for frames (including cross-origin players); private tabs never write these to disk.
@MainActor final class WebMediaSession: NSObject, WKScriptMessageHandler {
    static let handler = "souloMediaSession"
    static let world = WKContentWorld.world(name: "SouloMediaSession")
    weak var webView: WKWebView?
    private(set) var isActive = true
    private var frames: [String: WKFrameInfo] = [:]
    private weak var installedController: WKUserContentController?
    private var pendingRestoration: [String: [[String: Any]]] = [:]
    private var mainDocumentKey: String?
    private var generation = 0
    private(set) var checkpoints: [String: [[String: Any]]] = [:]

    func install(on controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handler, contentWorld: Self.world)
        controller.add(self, contentWorld: Self.world, name: Self.handler)
        // Restore once per newly created runtime. Embedding checkpoints in a
        // user script would replay stale positions on every later navigation.
        if installedController !== controller {
            pendingRestoration = checkpoints
            installedController = controller
        }
        controller.addUserScript(WKUserScript(source: Self.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Self.world))
    }

    func reset() {
        generation += 1
        checkpoints.removeAll(); pendingRestoration.removeAll(); frames.removeAll()
        mainDocumentKey = nil
    }
    func detach() {
        generation += 1
        frames.removeAll(); webView = nil; mainDocumentKey = nil
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        webView?.setAllMediaPlaybackSuspended(!active, completionHandler: nil)
    }

    func capture() async {
        guard let webView else { return }
        let capturedGeneration = generation
        for (key, frame) in frames {
            guard let items = try? await webView.callAsyncJavaScript("return window.__souloMediaCheckpoint?.();",
                arguments: [:], in: frame, contentWorld: Self.world) as? [[String: Any]] else { continue }
            guard generation == capturedGeneration, self.webView === webView else { return }
            save(items, for: key)
        }
    }

    private func save(_ items: [[String: Any]], for key: String) {
        guard items.count <= 32, key.count < 8192, checkpoints.count < 24 || checkpoints[key] != nil else { return }
        var items = items
        if !isActive, let old = checkpoints[key] {
            for i in items.indices {
                if let previous = old.first(where: { ($0["index"] as? Int) == (items[i]["index"] as? Int) && ($0["src"] as? String) == (items[i]["src"] as? String) }) {
                    items[i]["playing"] = previous["playing"]
                }
            }
        }
        if !items.isEmpty { checkpoints[key] = items }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.world.name == Self.world.name,
              let body = message.body as? [String: Any], let key = body["url"] as? String,
              let items = body["items"] as? [[String: Any]] else { return }
        if message.frameInfo.isMainFrame {
            if let mainDocumentKey, mainDocumentKey != key {
                generation += 1
                frames.removeAll(); checkpoints.removeAll(); pendingRestoration.removeAll()
            }
            mainDocumentKey = key
        }
        if frames.count < 24 || frames[key] != nil { frames[key] = message.frameInfo }
        if body["ready"] as? Bool == true, let webView = message.webView {
            let saved = pendingRestoration.removeValue(forKey: key) ?? []
            webView.callAsyncJavaScript("window.__souloMediaRestore?.(items);", arguments: ["items": saved],
                in: message.frameInfo, in: Self.world, completionHandler: nil)
        }
        save(items, for: key)
    }

    static let source = #"""
    (() => {
        if (window.__souloMediaCheckpoint) return;
        const restored = new WeakSet(), registered = new WeakSet(), tracked = new Set();
        const frameKey = (() => {
            const path = []; let frame = window;
            try {
                for (let depth = 0; frame !== frame.parent && depth < 12; depth++) {
                    const parent = frame.parent;
                    for (let i = 0; i < Math.min(parent.length, 128); i++) if (parent[i] === frame) { path.unshift(i); break; }
                    frame = parent;
                }
            } catch (_) {}
            return location.href + '#soulo-frame=' + path.join('.');
        })();
        let saved = [], restorationResolved = false;
        let lastSent = 0;
        function snapshot() {
            return [...tracked].filter(m => m.isConnected).slice(0,32).map((m,index) => ({
                index, src:m.currentSrc || m.src || '', time:Number.isFinite(m.currentTime) ? m.currentTime : 0,
                rate:m.playbackRate, playing:!m.paused && !m.ended,
                duration:Number.isFinite(m.duration) ? m.duration : 0
            }));
        }
        window.__souloMediaCheckpoint = snapshot;
        function send(ready = false) {
            lastSent = Date.now();
            try { window.webkit.messageHandlers.souloMediaSession.postMessage({url:frameKey,items:snapshot(),ready:ready === true}); } catch (_) {}
        }
        window.__souloMediaRestore = items => {
            if (restorationResolved) return;
            saved = items; restorationResolved = true;
            tracked.forEach(restore); send();
        };
        function restore(m) {
            if (!restorationResolved || restored.has(m) || m.readyState < 1) return;
            const index = [...tracked].filter(x => x.isConnected).indexOf(m), src = m.currentSrc || m.src || '';
            const old = saved.find(s => s.index === index && (s.src === src || (s.src.startsWith('blob:') && src.startsWith('blob:'))));
            if (!old) { restored.add(m); return; }
            // A changed playlist/video must not inherit an unrelated seek position.
            if (old.duration > 0 && Number.isFinite(m.duration) && Math.abs(old.duration - m.duration) > 3) { restored.add(m); return; }
            if (old.time > 0 && Number.isFinite(m.duration)) {
                try { m.currentTime = Math.min(old.time, Math.max(0,m.duration - 0.1)); } catch (_) { return; }
            }
            if (old.rate >= 0.25 && old.rate <= 16) m.playbackRate = old.rate;
            restored.add(m);
            if (old.playing) m.play()?.catch(() => {});
        }
        function add(m) {
            if (tracked.has(m)) return;
            tracked.add(m);
            if (!registered.has(m)) {
                registered.add(m);
                for (const event of ['loadedmetadata','canplay']) m.addEventListener(event, () => restore(m));
                for (const event of ['play','pause','seeked','ratechange','ended']) m.addEventListener(event, send);
                m.addEventListener('timeupdate', () => { if (Date.now() - lastSent >= 5000) send(); });
            }
            restore(m);
        }
        function scan(root) {
            if (root.matches?.('video,audio')) add(root);
            root.querySelectorAll?.('video,audio').forEach(add);
            for (const m of tracked) if (!m.isConnected) tracked.delete(m);
        }
        const observer = new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) if (node instanceof Element) scan(node);
            // Removal-only mutations must also release detached media buffers.
            for (const media of tracked) if (!media.isConnected) tracked.delete(media);
        });
        observer.observe(document, {childList:true,subtree:true});
        scan(document); send(true);
        window.addEventListener('pagehide', send);
    })();
    """#
}
