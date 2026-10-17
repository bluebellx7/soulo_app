import Foundation

enum WebVideoHoldSpeedRuntime {
    static let source = #"""
    (() => {
      if (window.__souloVideoHoldSpeed) return;
      let pending = null, active = null, released = null;
      const nativeRate = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'playbackRate');
      const rate = video => nativeRate.get.call(video);
      const setRate = (video, value) => { try { nativeRate.set.call(video, value); } catch (_) {} };
      function end() {
        if (pending) clearTimeout(pending.timer);
        pending = null;
        if (!active) return;
        const old = active; active = null;
        setRate(old.video, old.rate);
        old.badge.remove();
        released = {video:old.video,target:old.target,until:performance.now()+450};
      }
      function videoAt(event, point) {
        const path = event.composedPath?.() || [];
        if (path.some(node => node instanceof Element && node.matches(
          'button,a,input,select,textarea,[role="button"],[role="slider"],[data-soulo-video-rotate]'))) return null;
        const candidates = [...document.querySelectorAll('video')];
        for (const node of path) if (node instanceof HTMLVideoElement && !candidates.includes(node)) candidates.push(node);
        return candidates.filter(video => {
          const r = video.getBoundingClientRect(), style = getComputedStyle(video);
          return !video.paused && !video.ended && r.width >= 100 && r.height >= 70
            && style.visibility !== 'hidden' && style.display !== 'none'
            && point.clientX >= r.left && point.clientX <= r.right
            && point.clientY >= r.top && point.clientY <= r.bottom - 48;
        }).sort((a,b) => {
          const x=a.getBoundingClientRect(), y=b.getBoundingClientRect();
          return x.width*x.height-y.width*y.height;
        })[0] || null;
      }
      function begin(event) {
        if (!event.isTrusted || (event.button !== undefined && event.button !== 0)) return;
        if(event.isPrimary===false){end();return;}
        if (event.touches && event.touches.length !== 1) { end(); return; }
        if (pending || active) return;
        const point = event.touches?.[0] || event, video = videoAt(event, point);
        if (!video || rate(video) >= 2) return;
        const press = {video, target:event.composedPath?.()[0] || event.target, x:point.clientX, y:point.clientY, pointer:event.pointerId};
        pending = press;
        press.timer = setTimeout(() => {
          if (pending !== press || !video.isConnected || video.paused || video.ended) { end(); return; }
          const oldRate = rate(video);
          if (oldRate >= 2) { end(); return; }
          const badge = document.createElement('div'), r = video.getBoundingClientRect();
          badge.setAttribute('data-soulo-hold-speed', ''); badge.textContent = '2×';
          badge.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483647;color:white;background:rgba(28,28,30,.8);font:600 15px system-ui;padding:6px 14px;border-radius:14px;';
          badge.style.left = Math.max(8,r.left+r.width/2-25)+'px'; badge.style.top = Math.max(8,r.top+14)+'px';
          (document.fullscreenElement || document.documentElement).append(badge);
          active = {video, target:press.target, rate:oldRate, badge};
          setRate(video, 2);
        }, 450);
      }
      function move(event) {
        if (!pending) return;
        const point=event.touches?.[0] || event;
        if (event.touches?.length > 1 || Math.hypot(point.clientX-pending.x,point.clientY-pending.y) > 12) end();
      }
      const events = window.PointerEvent
        ? ['pointerdown','pointermove','pointerup','pointercancel']
        : ['touchstart','touchmove','touchend','touchcancel'];
      window.addEventListener(events[0],begin,{capture:true,passive:true});
      window.addEventListener(events[1],move,{capture:true,passive:true});
      for (const name of events.slice(2)) window.addEventListener(name,end,{capture:true,passive:true});
      window.addEventListener('contextmenu',event => {
        if (!active) return;
        event.preventDefault(); event.stopImmediatePropagation();
      },true);
      window.addEventListener('click',event => {
        if (!released || performance.now()>released.until) {released=null;return;}
        const path=event.composedPath?.() || [];
        if(!path.includes(released.video)&&(path[0]||event.target)!==released.target)return;
        released=null;
        event.preventDefault(); event.stopImmediatePropagation();
      },true);
      for (const name of ['blur','pagehide']) window.addEventListener(name,end);
      document.addEventListener('visibilitychange',() => { if (document.hidden) end(); });
      for (const name of ['pause','ended','emptied','webkitbeginfullscreen','webkitendfullscreen']) {
        document.addEventListener(name,event => { if (event.target === active?.video || event.target === pending?.video) end(); },true);
      }
      document.addEventListener('fullscreenchange',end);
      new MutationObserver(() => { if (active && !active.video.isConnected) end(); })
        .observe(document.documentElement,{childList:true,subtree:true});
      window.__souloVideoHoldSpeed = {end};
    })();
    """#
}
