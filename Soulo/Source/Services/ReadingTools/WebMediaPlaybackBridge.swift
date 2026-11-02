import WebKit

enum WebVideoOrientationRuntime {
    static let world = WKContentWorld.world(name: "SouloVideoOrientation")
    static let handler = "souloVideoOrientation"

    @MainActor static func script() -> String {
        let label = (try? JSONSerialization.data(withJSONObject: [ToolText.text("video_fullscreen"), ToolText.text("video_speed"), LanguageManager.shared.localizedString("download"), ToolText.text("video_tools"), ToolText.text("episodes"), ToolText.text("video_tools_collapse")]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"Fullscreen\"]"
        return WebOverlayControlsRuntime.source + "\n" + source + WebVideoHoldSpeedRuntime.source + "\nwindow.__souloVideoOrientation.setLabels(\(label));"
    }

    // Inject into every frame in an isolated world, so cross-origin embedded
    // players have the same control without exposing the native bridge to pages.
    static let source = #"""
    (() => {
      if (window.__souloVideoOrientation) return;
      const controls = new Map(), roots = new Set(), pending = new Set(), videos = new Set(), visibleVideos = new Set();
      const overlay = window.__souloOverlayControls;
      let labels = ['Fullscreen', 'Speed', 'Download', 'Video tools', 'Episodes', 'Close'], frame = 0, scanTimer = 0, active = null, expandedGroup = null;
      let bottomControls = {needed:false}, episodesAvailable = false;
      let reportedViewportScale = null;
      const expandedWidth = () => (episodesAvailable ? 5 : 4) * overlay.size;
      const observationOptions = {childList:true,subtree:true,attributes:true,attributeFilter:['class','style','hidden']};
      function send(action, token, details = {}) {
        try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action, token, ...details}); } catch (_) {}
      }
      function isFullscreen(video) {
        return video.webkitDisplayingFullscreen || video.webkitPresentationMode === 'fullscreen'
          || document.fullscreenElement === video || video.getRootNode()?.fullscreenElement === video;
      }
      function computed(node, styles) {
        if (!styles.has(node)) styles.set(node, getComputedStyle(node));
        return styles.get(node);
      }
      function isVisible(video, styles) {
        for (let node=video;node;node=node.parentElement || node.getRootNode()?.host) {
          const style=computed(node, styles);
          if(style.display==='none'||style.visibility==='hidden'||style.visibility==='collapse'||Number(style.opacity)===0)return false;
        }
        return true;
      }
      function needsBottomClearance(video, rect, styles) {
        if (window !== window.top || isFullscreen(video)) return false;
        if (rect.width < 100 || rect.height < 70 || rect.bottom <= 0 || rect.top >= innerHeight
            || rect.right <= 0 || rect.left >= innerWidth) return false;
        let anchored = false;
        for (let node = video; node && node !== document.documentElement;
             node = node.parentElement || node.getRootNode()?.host) {
          const style = computed(node, styles);
          if (style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0) return false;
          if (node === document.body || !['fixed','absolute','sticky'].includes(style.position)) continue;
          const r = node.getBoundingClientRect();
          if (r.width >= innerWidth * 0.5 && r.height >= innerHeight * 0.5
              && r.top <= innerHeight * 0.35 && r.right > innerWidth * 0.25 && r.left < innerWidth * 0.75
              && Math.abs(r.bottom - innerHeight) <= 96) anchored = true;
        }
        return anchored;
      }
      function reportBottomControls(needed) {
        if (window !== window.top || bottomControls.needed === needed) return;
        bottomControls.needed = needed;
        send('bottomControls', '', {needed});
      }
      function reportViewportScale(force = false) {
        if (window !== window.top) return;
        const {scale,zoom} = overlay.metrics();
        if (!force && reportedViewportScale?.scale === scale && reportedViewportScale?.zoom === zoom) return;
        reportedViewportScale = {scale,zoom};
        send('viewport','',{scale,zoom,url:location.href});
      }
      function finish(action = 'end') {
        if (!active) return;
        clearTimeout(active.timeout);
        active.cleanup?.();
        send(action, active.token); active = null; schedule();
      }
      function fullscreenChanged(event) {
        if (!active) return;
        if (active.mode === 'native') {
          // AVKit and document fullscreen have independent event streams.
          // Baidu can dispatch a document transition while AVKit is rotating;
          // only the active video's native end event should restore portrait.
          if (event?.target !== active.video) return;
          if (event.type === 'webkitendfullscreen') { finish(); return; }
          if (event.type !== 'webkitbeginfullscreen' && !isFullscreen(active.video)) return;
        }
        if (active.mode === 'native' || isFullscreen(active.video)) {
          if (!active.began) {
            active.began = true; clearTimeout(active.timeout); active.cleanup?.(); send('begin', active.token); schedule();
          }
        } else if (active.began) finish();
      }
      function enterFullscreen(video) {
        if (active) return;
        const token = globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + Math.random().toString(36);
        active = {video, token, began:false, timeout:setTimeout(() => { if (active?.token === token) finish('failed'); }, 5000)};
        let playbackReady = !video.paused;
        const failed = () => { if (active?.token === token && !active.began) finish('failed'); };
        const request = () => {
          if (active?.token !== token || active.began || active.requested) return;
          if (!video.isConnected) { failed(); return; }
          // Later feed/playlist videos can still be loading or switching source.
          // Transfer an actual decoded frame, never an empty AVKit surface.
          if (!playbackReady || video.readyState < 2 || !video.videoWidth || !video.videoHeight) return;
          active.requested = true;
          send('prepare', token, {landscape:video.videoWidth / video.videoHeight > 1.1});
          const documentFullscreen = () => {
            if (active?.token !== token) return;
            if (!document.fullscreenEnabled || typeof video.requestFullscreen !== 'function') { failed(); return; }
            active.mode = 'document';
            try { Promise.resolve(video.requestFullscreen()).catch(failed); } catch (_) { failed(); }
          };
          // Preserve the site's video geometry, source and player. Changing its
          // inline size before AVKit entry can rebuild a responsive player.
          if (typeof video.webkitEnterFullscreen === 'function' && video.webkitSupportsFullscreen !== false) {
            active.mode = 'native';
            try { video.webkitEnterFullscreen(); } catch (_) { documentFullscreen(); }
          } else documentFullscreen();
        };
        const readyEvents = ['loadeddata','canplay','playing'];
        readyEvents.forEach(event => video.addEventListener(event, request));
        active.cleanup = () => readyEvents.forEach(event => video.removeEventListener(event, request));
        if (video.paused) {
          // Start loading inside the real user gesture. WebKit grants media
          // playback here; completion only requests fullscreen for this session.
          try {
            Promise.resolve(video.play()).then(() => {
              if (active?.token !== token) return;
              playbackReady = true; request();
            }, failed);
          } catch (_) { failed(); }
        } else {
          // A playing, ready video keeps synchronous native fullscreen entry.
          request();
        }
      }
      function prune() {
        for (const video of videos) if (!video.isConnected) {
          intersection.unobserve(video); visibleVideos.delete(video); videos.delete(video);
        }
        for (const [video, button] of controls) {
          if (!video.isConnected) { if (expandedGroup === button) collapse(); if (active?.video === video) finish(); button.remove(); resize.unobserve(video); controls.delete(video); }
        }
        let removedRoot = false;
        for (const root of roots) if (root.host && !root.host.isConnected) { roots.delete(root); removedRoot = true; }
        if (removedRoot) {
          observer.disconnect();
          roots.forEach(root => observer.observe(root, observationOptions));
        }
      }
      function layout() {
        frame = 0;
        prune();
        const viewport = overlay.metrics(), styles = new Map(), updates = [];
        let needsClearance = false;
        // Read all geometry first. Interleaving a floating control's writes with
        // the next video's reads forces repeated layout on result-heavy pages.
        for (const video of visibleVideos) {
          const button = controls.get(video);
          if (!button) continue;
          const r = video.getBoundingClientRect();
          const visible = !active?.began && r.width >= 100 && r.height >= 70 && r.right > 44 && r.bottom > 44
            && r.left < innerWidth - 44 && r.top < innerHeight - 44 && isVisible(video, styles);
          if (visible) needsClearance ||= needsBottomClearance(video, r, styles);
          const width = (button === expandedGroup ? expandedWidth() : overlay.size) * viewport.unit;
          updates.push({button, visible,
            left:Math.max(viewport.left+viewport.gap,Math.min(r.right-viewport.gap,viewport.left+viewport.width-viewport.gap)-width),
            top:Math.max(viewport.top+viewport.gap,Math.min(r.top+viewport.gap,viewport.top+viewport.height-viewport.size-viewport.gap))});
        }
        reportBottomControls(needsClearance);
        for (const {button,visible,left,top} of updates) {
          if (!visible && expandedGroup === button) collapse();
          setStyleIfChanged(button,'display',visible ? 'flex' : 'none');
          if (!visible) continue;
          overlay.apply(button,viewport);
          setStyleIfChanged(button,'max-width',Math.max(overlay.size,viewport.width/viewport.unit-16)+'px');
          setStyleIfChanged(button,'left',left+'px');
          setStyleIfChanged(button,'top',top+'px');
        }
      }
      function setStyleIfChanged(element,property,value) {
        if(element.style.getPropertyValue(property)!==value)element.style.setProperty(property,value,'important');
      }
      function schedule() { if (!frame) frame = requestAnimationFrame(layout); }
      function collapse() {
        if (!expandedGroup) return;
        const group = expandedGroup; expandedGroup = null;
        group.style.setProperty('width', overlay.size+'px', 'important');
        group.style.setProperty('height', overlay.size+'px', 'important');
        group.querySelectorAll('[data-video-action]').forEach(el => showAction(el, false));
        const toggle = group.querySelector('[data-video-toggle]');
        setToggleState(toggle,false);
        schedule();
      }
      function setControlLabel(button,label) {
        if(!button)return;
        button.setAttribute('aria-label',label);button.title=label;
      }
      function setToggleState(toggle,expanded) {
        toggle.setAttribute('aria-expanded',expanded ? 'true' : 'false');
        toggle.firstElementChild.style.setProperty('display',expanded ? 'none' : 'block','important');
        toggle.lastElementChild.style.setProperty('display',expanded ? 'block' : 'none','important');
        setControlLabel(toggle,labels[expanded ? 5 : 3]);
      }
      window.addEventListener('click',event => {
        const button=(event.composedPath?.() || []).find(node => node instanceof Element && typeof node.__souloVideoAction === 'function');
        if(!button)return;
        event.preventDefault();event.stopImmediatePropagation();button.__souloVideoAction(event);
      },true);
      const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
      function configureMotion(group) {
        // Resize once; animating a blurred surface's width forces repaint on every frame.
        group.style.setProperty('transition', 'none', 'important');
        group.querySelectorAll('[data-video-action]').forEach(action => {
          action.style.setProperty('transition', reducedMotion.matches ? 'none' : 'opacity 100ms ease', 'important');
        });
      }
      function showAction(action, visible) {
        action.style.setProperty('display', visible ? 'flex' : 'none', 'important');
        action.style.setProperty('opacity', visible ? '1' : '0', 'important');
        action.style.setProperty('transform', visible ? 'translateX(0)' : 'translateX(6px)', 'important');
        action.style.setProperty('pointer-events', visible ? 'auto' : 'none', 'important');
        action.setAttribute('aria-hidden', visible ? 'false' : 'true');
        action.tabIndex = visible ? 0 : -1;
      }
      reducedMotion.addEventListener('change', () => controls.forEach(configureMotion));
      const svg = content => '<svg width="23" height="23" style="width:23px!important;height:23px!important;min-width:23px!important;flex:0 0 23px!important;display:block!important" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + content + '</svg>';
      const toolsIcon = svg('<path d="M10 19H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2v6"/><path d="m8 7 5 3-5 3Z" fill="currentColor" stroke="none"/><path d="M14 16h2m3 0h3m-8 5h5"/><circle cx="17.5" cy="16" r="1.5"/><circle cx="20.5" cy="21" r="1.5"/>');
      const resize = new ResizeObserver(schedule);
      const intersection = new IntersectionObserver(entries => {
        for (const entry of entries) {
          const video = entry.target;
          if (entry.isIntersecting) { visibleVideos.add(video); createControl(video); }
          else {
            visibleVideos.delete(video);
            const button = controls.get(video);
            if (expandedGroup === button) collapse();
            if (button) setStyleIfChanged(button,'display','none');
          }
        }
        schedule();
      }, {rootMargin:'64px'});
      function add(video) {
        if (videos.has(video)) return;
        videos.add(video); intersection.observe(video);
      }
      function createControl(video) {
        if (controls.has(video)) return;
        const button = document.createElement('div');
        button.setAttribute('data-soulo-video-rotate', '');
        button.setAttribute('role', 'group');
        button.dataset.souloMediaID = globalThis.crypto?.randomUUID?.() || Date.now().toString(36) + Math.random().toString(36);
        video.setAttribute('data-soulo-media-id', button.dataset.souloMediaID);
        button.style.cssText = 'all:initial!important;position:fixed!important;z-index:2147483646!important;display:none!important;width:48px!important;max-width:calc(100vw - 16px)!important;height:48px!important;flex-direction:row!important;align-items:center!important;justify-content:flex-end!important;border-radius:14px!important;background:rgba(24,25,29,.7)!important;backdrop-filter:blur(16px) saturate(1.2)!important;-webkit-backdrop-filter:blur(16px) saturate(1.2)!important;box-shadow:inset 0 0 0 1px rgba(255,255,255,.16),0 2px 8px rgba(0,0,0,.16)!important;color:rgba(255,255,255,.94)!important;pointer-events:auto!important;touch-action:manipulation!important;isolation:isolate!important;overflow:hidden!important;user-select:none!important;-webkit-user-select:none!important;-webkit-touch-callout:none!important;';
        const controlStyle = 'all:initial!important;box-sizing:border-box!important;width:48px!important;min-width:48px!important;min-height:48px!important;height:48px!important;display:flex!important;flex-direction:row!important;gap:0!important;padding:0!important;align-items:center!important;justify-content:center!important;border-radius:14px!important;color:rgba(255,255,255,.94)!important;cursor:pointer!important;user-select:none!important;-webkit-user-select:none!important;-webkit-touch-callout:none!important;font:600 14px -apple-system,sans-serif!important;';
        const fullscreen = document.createElement('button'); fullscreen.type = 'button'; fullscreen.style.cssText = controlStyle;
        fullscreen.setAttribute('aria-label', labels[0]); fullscreen.title = labels[0];
        fullscreen.innerHTML = svg('<rect x="3" y="3" width="10" height="18" rx="2.5"/><path d="M6.5 6h3M16 12h2.5a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-2.5 2.5H16M16 3a7 7 0 0 1 5 6m-3-1 3 1 .5-3"/><circle cx="8" cy="17.5" r=".9"/>');
        fullscreen.__souloVideoAction = event => {
          event.preventDefault(); event.stopImmediatePropagation();
          if (!event.isTrusted || !video.isConnected) return;
          collapse(); enterFullscreen(video);
        };
        for (const event of ['webkitbeginfullscreen', 'webkitendfullscreen', 'webkitpresentationmodechanged']) {
          video.addEventListener(event, fullscreenChanged);
        }
        const download = document.createElement('button'); download.type = 'button'; download.style.cssText = controlStyle;
        download.setAttribute('aria-label', labels[2]); download.title = labels[2];
        download.innerHTML = svg('<path d="M12 3v12m-4-4 4 4 4-4M5 17v2a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-2"/>');
        download.__souloVideoAction = event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          collapse();
          try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action:'download',token:button.dataset.souloMediaID,url:video.currentSrc || video.src || ''}); } catch (_) {}
        };
        const speed = document.createElement('button'); speed.type = 'button'; speed.style.cssText = controlStyle;
        speed.setAttribute('aria-label', labels[1]); speed.title = labels[1];
        speed.innerHTML = svg('<circle cx="12" cy="12" r="8.5"/><path d="M12 5v1M5 12h1m12 0h1M7 7l.7.7m4.3 4.3 4-4"/><circle cx="12" cy="12" r="1.3" fill="currentColor" stroke="none"/>');
        const updateRate = () => { speed.setAttribute('aria-valuetext', video.playbackRate + '×'); };
        video.addEventListener('ratechange', updateRate); updateRate();
        speed.__souloVideoAction = event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          collapse();
          try { window.webkit.messageHandlers.souloVideoOrientation.postMessage({action:'speed',token:button.dataset.souloMediaID,rate:video.playbackRate}); } catch (_) {}
        };
        const episodes = document.createElement('button'); episodes.type='button'; episodes.style.cssText=controlStyle;
        episodes.setAttribute('data-video-episodes','');
        episodes.innerHTML=svg('<path d="M9 6h12M9 12h12M9 18h12M3 5h2v3M3 11h2l-2 3h2M3 18h2"/>');
        episodes.__souloVideoAction = event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          if (!episodesAvailable) return;
          collapse(); send('episodes',button.dataset.souloMediaID);
        };
        [download,speed,fullscreen,episodes].forEach((action,index) => setControlLabel(action,labels[[2,1,0,4][index]]));
        for (const action of [download, speed, fullscreen, episodes]) {
          action.setAttribute('data-video-action', ''); showAction(action, false);
          action.addEventListener('pointerdown', () => action.style.setProperty('background','rgba(255,255,255,.14)','important'));
          for (const event of ['pointerup','pointercancel','pointerleave']) action.addEventListener(event, () => action.style.setProperty('background','transparent','important'));
        }
        const toggle = document.createElement('button'); toggle.type = 'button'; toggle.style.cssText = controlStyle;
        toggle.setAttribute('data-video-toggle',''); toggle.setAttribute('aria-label', labels[3]);
        toggle.title = labels[3]; toggle.innerHTML = toolsIcon + svg('<path d="m10 7 5 5-5 5"/>'); setToggleState(toggle,false);
        toggle.addEventListener('pointerdown', () => toggle.style.setProperty('background','rgba(255,255,255,.14)','important'));
        for (const event of ['pointerup','pointercancel','pointerleave']) toggle.addEventListener(event, () => toggle.style.setProperty('background','transparent','important'));

        toggle.__souloVideoAction = event => {
          event.preventDefault(); event.stopImmediatePropagation(); if (!event.isTrusted) return;
          const wasExpanded = expandedGroup === button; collapse(); if (wasExpanded) return;
          expandedGroup = button; button.style.setProperty('width',expandedWidth()+'px','important');
          for (const action of [download, speed, fullscreen, episodes]) showAction(action, action !== episodes || episodesAvailable);
          setToggleState(toggle,true); schedule();
        };
        button.append(download, speed, fullscreen, episodes, toggle);
        configureMotion(button);
        document.documentElement.append(button);
        controls.set(video, button); resize.observe(video);
      }
      function scan(root = document) {
        if ((root === document || root instanceof ShadowRoot) && !roots.has(root)) {
          roots.add(root); observer.observe(root, observationOptions);
        }
        if (root instanceof Element && root.matches('video')) add(root);
        if (root instanceof Element && root.shadowRoot) scan(root.shadowRoot);
        root.querySelectorAll('video').forEach(add);
        root.querySelectorAll('*').forEach(el => { if (el.shadowRoot) scan(el.shadowRoot); });
        schedule();
      }
      const observer = new MutationObserver(records => {
        // Text-only pages often animate classes/styles while scrolling. There
        // is no video geometry to update until a media element is discovered.
        if (!videos.size && records.every(record => record.type === 'attributes')) return;
        const ownUI='[data-soulo-video-rotate],[data-soulo-hold-speed],#soulo-episode-dock';
        if (records.every(r =>
          (r.target instanceof Element && r.target.closest(ownUI))
          || (r.type === 'childList' && [...r.addedNodes, ...r.removedNodes].every(n =>
            n instanceof Element && n.matches(ownUI))))) return;
        for (const record of records) for (const node of record.addedNodes) {
          if (node instanceof Element && !node.matches(ownUI)) pending.add(node);
        }
        if (!scanTimer) scanTimer = setTimeout(() => {
          scanTimer = 0;
          pending.forEach(node => {
            if (!node.isConnected) return;
            // Scanning an added parent already covers its added descendants.
            for (let parent = node.parentElement; parent; parent = parent.parentElement) {
              if (pending.has(parent)) return;
            }
            scan(node);
          }); pending.clear();
          // Hidden tabs may suspend animation frames. Release detached videos
          // and controls even while layout is paused.
          prune();
          schedule();
        }, 150);
      });
      window.__souloVideoOrientation = {setPageScale(value,zoom = 1) {
        const scaleChanged=overlay.setPageScale(value),zoomChanged=overlay.setContentZoom(zoom);
        if(scaleChanged||zoomChanged)schedule();
      },setContentZoom(zoom) {
        if (overlay.setContentZoom(zoom)) schedule();
        reportViewportScale(true);
      },setLabels(value) {
        labels = value;
        controls.forEach(group => {
          const buttons = group.querySelectorAll(':scope > button');
          [2,1,0,4,group === expandedGroup ? 5 : 3].forEach((index,i) => setControlLabel(buttons[i],labels[index]));
        });
      }, setEpisodesAvailable(value) {
        if (episodesAvailable === (value === true)) return;
        episodesAvailable = value === true;
        // Collapsed controls already hide every action. Keep background episode
        // detection from invalidating the hit-test region of a pending tap.
        if (!expandedGroup) return;
        showAction(expandedGroup.querySelector('[data-video-episodes]'),episodesAvailable);
        expandedGroup.style.setProperty('width',expandedWidth()+'px','important');
        schedule();
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
      window.addEventListener('pagehide', () => { reportBottomControls(false); collapse(); finish(); });
      window.addEventListener('pageshow', () => { schedule(); send('ready',''); });
      const collapseOutside = event => {
        if (expandedGroup && !event.composedPath().includes(expandedGroup)) collapse();
      };
      // iOS may omit pointer events on non-interactive text; touchstart also
      // dismisses the palette when the user taps or begins scrolling the page.
      for (const event of ['pointerdown', 'touchstart']) {
        window.addEventListener(event, collapseOutside, {capture:true, passive:true});
      }
      const scrollLayout = () => { if (visibleVideos.size) schedule(); };
      window.addEventListener('scroll', scrollLayout, {capture:true,passive:true});
      const viewportChanged = () => { schedule(); reportViewportScale(); };
      window.addEventListener('resize', viewportChanged, {passive:true});
      // Report only an actual scale change. Height-only changes and ordinary
      // scrolling keep their local layout without messages to native frames.
      window.visualViewport?.addEventListener('resize', viewportChanged, {passive:true});
      window.visualViewport?.addEventListener('scroll', scrollLayout, {passive:true});
      document.addEventListener('loadedmetadata', schedule, true);
      document.addEventListener('play', schedule, true);
      scan();
      send('ready','');
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

struct WebMediaPlaybackHandoff {
    let target: URL
    let time: Double
    let duration: Double
    let volume: Double
    let muted: Bool
    let playing: Bool

    init?(target: URL, values: [String: Any]) {
        guard let time = values["time"] as? Double, time.isFinite, (0...43_200).contains(time),
              let duration = values["duration"] as? Double, duration.isFinite, duration >= 0,
              let volume = values["volume"] as? Double, volume.isFinite, (0...1).contains(volume),
              let muted = values["muted"] as? Bool, let playing = values["playing"] as? Bool else { return nil }
        self.target = target; self.time = time; self.duration = duration
        self.volume = volume; self.muted = muted; self.playing = playing
    }

    func matches(_ document: URL) -> Bool {
        guard target.scheme == document.scheme, target.host == document.host,
              target.port == document.port, target.path == document.path else { return false }
        let expected = URLComponents(url: target, resolvingAgainstBaseURL: false)
        let actual = URLComponents(url: document, resolvingAgainstBaseURL: false)
        if let id = expected?.queryItems?.first(where: { $0.name == "nid" })?.value {
            return actual?.queryItems?.first(where: { $0.name == "nid" })?.value == id
        }
        return expected?.query == actual?.query
    }

    var scriptValues: [String: Any] {
        ["time": time, "duration": duration, "volume": volume, "muted": muted, "playing": playing]
    }
}

/// Lives with a tab, not its SwiftUI wrapper. Keeps bounded, in-memory checkpoints
/// for frames (including cross-origin players); private tabs never write these to disk.
@MainActor final class WebMediaSession: NSObject, WKScriptMessageHandler {
    static let handler = "souloMediaSession"
    static let world = WKContentWorld.world(name: "SouloMediaSession")
    weak var webView: WKWebView? {
        didSet {
            guard oldValue !== webView else { return }
            navigationPending = false
            navigationWasCancelled = false
            suspensionApplied = false
            updatePlaybackSuspension()
        }
    }
    private(set) var isActive = true
    private var navigationPending = false
    private(set) var navigationWasCancelled = false
    private var suspensionApplied = false
    private var frames: [String: WKFrameInfo] = [:]
    private weak var installedController: WKUserContentController?
    private var pendingRestoration: [String: [[String: Any]]] = [:]
    private var mainDocumentKey: String?
    private var generation = 0
    private(set) var checkpoints: [String: [[String: Any]]] = [:]
    private var playbackHandoff: WebMediaPlaybackHandoff?

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
        playbackHandoff = nil
    }

    func preparePlaybackHandoff(_ handoff: WebMediaPlaybackHandoff) {
        playbackHandoff = handoff
    }
    func detach() {
        generation += 1
        frames.removeAll(); webView = nil; mainDocumentKey = nil
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        updatePlaybackSuspension()
    }

    /// User navigation leaves media and page-cache lifecycle to WebKit.
    /// Only inactive tabs use web-view-wide playback suspension.
    func allowUserNavigation() { navigationWasCancelled = false }

    func beginNavigation(to destination: URL, navigationType: WKNavigationType = .other, startsNewRequest: Bool = false) {
        if startsNewRequest { navigationWasCancelled = false }
        guard !navigationWasCancelled else { return }
        finishNavigation()
    }

    func finishNavigation(restoreInterruptedMedia: Bool = false) {
        navigationPending = false
        updatePlaybackSuspension()
        if restoreInterruptedMedia {
            webView?.callAsyncJavaScript("window.__souloMediaResume?.();", arguments: [:],
                in: nil, in: Self.world, completionHandler: nil)
        }
    }

    func cancelNavigation() {
        navigationWasCancelled = true
        finishNavigation(restoreInterruptedMedia: true)
    }

    private func updatePlaybackSuspension() {
        let suspended = !isActive || navigationPending
        guard let webView, suspensionApplied != suspended else { return }
        // Suspend only inactive tabs. WebKit owns foreground page navigation.
        suspensionApplied = suspended
        BrowserStartupTrace.mark("media_suspension", detail: "suspended=\(suspended) active=\(isActive) navigation=\(navigationPending)")
        webView.setAllMediaPlaybackSuspended(suspended, completionHandler: nil)
    }

    static func replacesDocument(from source: URL?, to destination: URL, navigationType: WKNavigationType) -> Bool {
        guard ["http", "https", "file", "about", "blob", "data", "webkit-extension"].contains(destination.scheme?.lowercased() ?? "") else { return false }
        guard let source,
              var previous = URLComponents(url: source, resolvingAgainstBaseURL: true),
              var next = URLComponents(url: destination, resolvingAgainstBaseURL: true) else { return true }
        let oldFragment = previous.fragment, newFragment = next.fragment
        previous.fragment = nil; next.fragment = nil
        let explicitReload = [.reload, .formSubmitted, .formResubmitted].contains(navigationType)
        if !explicitReload, previous.url == next.url,
           newFragment != nil || (navigationType == .backForward && oldFragment != newFragment) { return false }
        return true
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
            if message.frameInfo.isMainFrame, let handoff = playbackHandoff,
               let suffix = key.range(of: "#soulo-frame=", options: .backwards),
               let document = URL(string: String(key[..<suffix.lowerBound])), handoff.matches(document) {
                playbackHandoff = nil
                webView.callAsyncJavaScript("window.__souloMediaRestorePlayback?.(intent);",
                    arguments: ["intent": handoff.scriptValues], in: message.frameInfo,
                    in: Self.world, completionHandler: nil)
            }
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
        let playbackIntent = null, playbackStart = null;
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
        window.__souloMediaRestorePlayback = intent => {
            playbackIntent = intent;
            tracked.forEach(schedulePlaybackIntent);
        };
        function schedulePlaybackIntent(media) {
            if (playbackIntent) setTimeout(() => applyPlaybackIntent(media), 0);
        }
        function applyPlaybackIntent(media) {
            if (!playbackIntent || media.tagName !== 'VIDEO' || !media.isConnected || media.readyState < 1) return;
            const customSound = location.hostname === 'm.baidu.com' && location.pathname === '/video/page' && !media.controls;
            const soundControl = customSound ? document.querySelector('[class*="voiceControlContainer"]') : null;
            // Baidu keeps a separate muted flag in its custom player. Changing
            // only HTMLMediaElement.muted leaves its icon and next click stale.
            // Wait for the control, then use its own action to update both.
            if (customSound && !soundControl) return;
            const videos = [...tracked].filter(m => m.tagName === 'VIDEO' && m.isConnected);
            const area = m => {const r=m.getBoundingClientRect();return Math.max(0,Math.min(innerWidth,r.right)-Math.max(0,r.left))*Math.max(0,Math.min(innerHeight,r.bottom)-Math.max(0,r.top));};
            videos.sort((a,b) => area(b)-area(a));
            if (videos[0] !== media) return;
            const intent = playbackIntent; playbackIntent = null;
            if (soundControl) {
                const off = soundControl.querySelector('[class*="voiceOffSvg"]');
                const iconMuted = !!off && getComputedStyle(off).display !== 'none';
                if (iconMuted !== intent.muted) soundControl.click();
            }
            media.muted = intent.muted; media.volume = intent.volume;
            if (intent.time > 0 && Number.isFinite(media.duration) && media.duration > 0
                && (!intent.duration || Math.abs(media.duration-intent.duration) < Math.max(3,intent.duration*0.03))) {
                try { media.currentTime = Math.min(intent.time,Math.max(0,media.duration-0.1)); } catch (_) {}
            }
            if (intent.playing) {
                // iOS can queue a pause while an autoplaying player becomes
                // audible or seeks during startup. Retry once after that pause;
                // a subsequent user gesture always cancels the handoff.
                const start = {media,expires:Date.now()+5000}; playbackStart = start;
                setTimeout(() => {if(playbackStart===start)playbackStart=null;},5000);
                play.call(media)?.catch(() => {});
            }
            send();
        }
        function resumePlaybackStart(media) {
            const start = playbackStart;
            if (!start || start.media !== media || Date.now()>start.expires || !media.paused) return;
            playbackStart = null;
            play.call(media)?.catch(() => {});
        }
        for (const event of ['pointerdown','keydown']) window.addEventListener(event,e => {
            if (e.isTrusted) {playbackIntent = null;playbackStart = null;}
        },true);
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
                for (const event of ['loadedmetadata','canplay']) m.addEventListener(event, () => {restore(m);schedulePlaybackIntent(m);resumePlaybackStart(m);});
                m.addEventListener('play', send);
                m.addEventListener('pause', () => {if(playbackStart?.media===m)setTimeout(()=>resumePlaybackStart(m),0);});
                for (const event of ['pause','seeked','ratechange','ended']) m.addEventListener(event, send);
                m.addEventListener('timeupdate', () => { if (Date.now() - lastSent >= 5000) send(); });
            }
            restore(m);
            schedulePlaybackIntent(m);
        }
        function scan(root) {
            if (root.matches?.('video,audio')) add(root);
            root.querySelectorAll?.('video,audio').forEach(add);
        }
        const pause = HTMLMediaElement.prototype.pause;
        const play = HTMLMediaElement.prototype.play;
        function prune() {
            for (const media of tracked) if (!media.isConnected) {
                try { pause.call(media); } catch (_) {}
                tracked.delete(media);
            }
        }
        const observer = new MutationObserver(records => {
            // A parent record already covers its newly inserted descendants.
            // Discover each live subtree once instead of rescanning it for
            // every result, thumbnail and control inserted in the same batch.
            const pending = new Set();
            for (const record of records) for (const node of record.addedNodes) {
                if (node instanceof Element && node.isConnected) pending.add(node);
            }
            for (const node of pending) {
                let covered = false;
                for (let parent = node.parentElement; parent; parent = parent.parentElement) {
                    if (pending.has(parent)) { covered = true; break; }
                }
                if (!covered) scan(node);
            }
            // Removal-only mutations must also release detached media buffers.
            prune();
            if(playbackIntent)tracked.forEach(schedulePlaybackIntent);
        });
        observer.observe(document, {childList:true,subtree:true});
        scan(document); send(true);
        window.__souloMediaResume = send;
        // WebKit owns BFCache restoration and media teardown. Do not clear
        // src/srcObject or call load() while a native navigation is in flight.
        window.addEventListener('pagehide', send);
        window.addEventListener('pageshow', send);
    })();
    """#
}
