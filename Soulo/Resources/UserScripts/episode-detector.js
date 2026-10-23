(() => {
  if (window.__souloEpisodes) return;
  let timer = 0, previous = '', enabled = true, dockFrame = 0, stateTimer = 0, lastStateRefresh = 0;
  let pageSources = [], pageSignature = '', pageURL=location.href;
  const listSelector = '.stui-content__playlist,.stui-play__list,.myui-content__list,.module-play-list,.module-play-list-content,.anthology-list-play,.playlist,.play-list,.episode-list,.episodes,[data-episode-list]';
  const linkSelector = 'a[href],button[data-url],button[data-href],[role="link"][data-url]';
  const stateSelector = 'script[type="application/ld+json"],script#__NEXT_DATA__,script#RENDER_DATA';
  const playerSelector = 'video,iframe[allowfullscreen],iframe[src*="player"],iframe[src*="play/"]';
  const clean = value => (value || '').replace(/\s+/g, ' ').trim().slice(0, 160);
  const playPath = /\/(?:player|play|vodplay)\/(\d+)[-_](\d+)[-_](\d+)(?:\.html)?\/?$/i;
  const plainNumber = /^#?\d{1,5}$/;
  function labelText(value) {
    return clean(value).normalize('NFKC').replace(/[\u0660-\u0669\u06f0-\u06f9]/g,c => String(c.charCodeAt(0) & 15));
  }
  function episodeNumber(title) {
    const text = labelText(title);
    const match = text.match(/^S\d+\s*E(\d+)/i)
      || text.match(/^(?:第\s*|ep(?:isode)?\.?\s*|e\s*|epis[oó]dio\s*|épisode\s*|folge\s*|bölüm\s*|серия\s*|(?:الحلقة|حلقة)\s*|ตอนที่\s*|#\s*)?(\d+)(?:\s*(?:[集期话話回화]|ตอน|bölüm|серия)|\b|$)/i);
    if (match) return Number(match[1]);
    const chinese = text.match(/^第([〇零一二三四五六七八九十百千两兩]+)[集期话話回]/)?.[1];
    if (!chinese) return undefined;
    const digits = {'〇':0,'零':0,'一':1,'二':2,'两':2,'兩':2,'三':3,'四':4,'五':5,'六':6,'七':7,'八':8,'九':9};
    if (!/[十百千]/.test(chinese)) return Number([...chinese].map(c => digits[c]).join(''));
    let value = 0, digit = 0;
    for (const c of chinese) {
      const unit = {'十':10,'百':100,'千':1000}[c];
      if (unit) { value += (digit || 1)*unit; digit = 0; } else digit = digits[c];
    }
    return value+digit;
  }
  function episodeLabel(title) {
    const text = labelText(title);
    return plainNumber.test(text)
      || /^第\s*[\d〇零一二三四五六七八九十百千两兩]+\s*[集期话話回]/.test(text)
      || /^(?:S\d+\s*E\d+|ep(?:isode)?\.?\s*\d+|e\s*\d+|epis[oó]dio\s*\d+|épisode\s*\d+|folge\s*\d+|bölüm\s*\d+|серия\s*\d+|(?:الحلقة|حلقة)\s*\d+|ตอนที่\s*\d+|\d+\s*(?:[集期话話回화]|bölüm|серия))/i.test(text);
  }
  function destination(link) {
    const raw = link.getAttribute('href') || link.getAttribute('data-url') || link.getAttribute('data-href');
    if (!raw) return null;
    try {
      const url = new URL(raw,document.baseURI);
      if (!/^https?:$/.test(url.protocol) || url.host !== location.host) return null;
      url.hash = ''; return url;
    } catch (_) { return null; }
  }
  function looksPlayable(url) {
    if ([...url.searchParams.keys()].some(key => /^(?:page|pageindex|page_no)$/i.test(key))) return false;
    return /\/(?:play(?:er)?|vodplay|watch|episodes?|vplay)(?:[\/.\-_]|$)/i.test(url.pathname)
      || [...url.searchParams.keys()].some(key => /^(?:ep|episode|episodeid|eid|nid|play)$/i.test(key))
      || (/\/video\//i.test(url.pathname) && url.pathname === location.pathname && /^\d+$/.test(url.searchParams.get('p') || ''));
  }
  function headingText(group) {
    const heading = group.previousElementSibling;
    return clean(group.getAttribute('data-title') || group.getAttribute('aria-label')
      || heading?.querySelector('h2,h3,h4')?.textContent
      || (heading?.matches('h2,h3,h4') ? heading.textContent : ''));
  }
  function semanticGroup(group) {
    return /episode|season|playlist|play[-_ ]?list|anthology|选集|選集|剧集|劇集|播放|集数|集數|分集|合集|エピソード/i.test(
      [group.id,typeof group.className === 'string' ? group.className : '',headingText(group)].join(' '));
  }
  function excludedGroup(group) {
    return !!group.closest('nav,[role="navigation"],.pagination,.pager,.stui-page__item,.related,.recommend,.recommendations,[data-recommendations]')
      || /(?:^|[-_\s])(?:pagination|recommend|related)(?:[-_\s]|$)/i.test(group.className || '');
  }
  function extract() {
    if (pageSources.length) return {pageURL:location.href,sources:pageSources};
    const groups = new Set(document.querySelectorAll(listSelector));
    const current = location.pathname.match(playPath), videoPage = !!document.querySelector('video,iframe[src*="player"],iframe[src*="play/"]');
    // Fall back to repeated, labelled links instead of any site's class names.
    // Require playback context so numeric pagination and catalog cards stay out.
    for (const link of document.querySelectorAll(linkSelector)) {
      if (groups.size >= 60 || link.closest(listSelector)) continue;
      const title = clean(link.textContent || link.getAttribute('title') || link.getAttribute('aria-label'));
      const url = destination(link);
      if (!url || !episodeLabel(title)) continue;
      let group = link.closest('ul,ol,[role="list"]') || link.parentElement;
      for (let depth = 0; group && depth < 4; depth++, group = group.parentElement) {
        if (group === document.body || group === document.documentElement || excludedGroup(group)) break;
        const semantic = semanticGroup(group);
        if (!(semantic || looksPlayable(url) || (videoPage && !plainNumber.test(labelText(title))))) break;
        let count = 0;
        for (const candidate of group.querySelectorAll(linkSelector)) {
          if (destination(candidate) && episodeLabel(clean(candidate.textContent || candidate.getAttribute('title') || candidate.getAttribute('aria-label'))) && ++count >= 2) break;
        }
        if (count >= 2) { groups.add(group); break; }
      }
    }
    const sources = [], used = new Set();
    let total = 0;
    for (const group of groups) {
      if (sources.length >= 20 || total >= 5000) break;
      if (excludedGroup(group) || [...groups].some(other => other !== group && group.contains(other))) continue;
      const episodes = [], seen = new Set(), known = group.matches(listSelector);
      for (const link of group.querySelectorAll(linkSelector)) {
        if (total >= 5000) break;
        if (link.closest('.pagination,.pager,.related,.recommend,.recommendations,[data-recommendations]')) continue;
        const url = destination(link);
        if (!url) continue;
        const title = clean(link.textContent || link.getAttribute('title') || link.getAttribute('aria-label'));
        const match = url.pathname.match(playPath);
        if (!title || !(match || episodeLabel(title) || (known && /^(?:HD|BD|正片|全集)/i.test(title)))) continue;
        if (current && match && match[1] !== current[1]) continue;
        if (seen.has(url.href) || used.has(url.href)) continue;
        seen.add(url.href); episodes.push({title,url:url.href}); total++;
      }
      if (!episodes.length) continue;
      if (episodes.every(item => episodeNumber(item.title) !== undefined)) episodes.sort((a,b) => episodeNumber(a.title)-episodeNumber(b.title));
      episodes.forEach(item => used.add(item.url));
      const playItem = group.closest('.play-item');
      const lineIndex = playItem ? [...playItem.parentElement.children].indexOf(playItem) : -1;
      const lineTitle = lineIndex >= 0 ? group.closest('.tab-content')?.querySelectorAll('.play-tab a')[lineIndex]?.textContent : '';
      sources.push({title:clean(lineTitle || headingText(group)),episodes});
    }
    return {pageURL:location.href,sources};
  }
  let dock=null,drag=null,available=false,label='Episodes',edge='right',fraction=.62,lastUp=0;
  function send(action,details={}){try{window.webkit.messageHandlers.souloEpisodes.postMessage({action,pageURL:location.href,...details})}catch{}}
  function visiblePlayer(){
    // The media runtime also finds videos inside open shadow roots. Its visible
    // controls are a shared DOM signal even though this world cannot query those
    // videos through document.querySelectorAll().
    if([...document.querySelectorAll('[data-soulo-video-rotate]')].some(node=>{
      const r=node.getBoundingClientRect();return r.width>1&&r.height>1&&getComputedStyle(node).display!=='none';
    }))return true;
    return [...document.querySelectorAll(playerSelector)].some(node=>{
    const r=node.getBoundingClientRect();
    if(r.width<100||r.height<70||r.right<=0||r.left>=innerWidth||r.bottom<=0||r.top>=innerHeight)return false;
    for(let parent=node;parent;parent=parent.parentElement){
      const s=getComputedStyle(parent);
      if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||Number(s.opacity)===0)return false;
    }
    return true;
  })}
  function bounds(){const v=visualViewport;return {left:v?.offsetLeft||0,top:(v?.offsetTop||0)+12,width:v?.width||innerWidth,height:Math.max(0,(v?.height||innerHeight)-144)}}
  function positionDock(x,y){dock.style.setProperty('left',x+'px','important');dock.style.setProperty('top',y+'px','important')}
  function layoutDock(){
    if(!dock||drag)return;const b=bounds();
    positionDock(b.left+(edge==='left'?0:Math.max(0,b.width-48)),b.top+b.height*fraction);
    dock.setAttribute('data-edge',edge);
  }
  function updateDock(){
    if(!available||!enabled||visiblePlayer()){drag=null;dock?.remove();return}
    if(!dock){
      dock=document.createElement('div');dock.id='soulo-episode-dock';
      dock.style.cssText='all:initial!important;position:fixed!important;z-index:2147483646!important;width:48px!important;height:48px!important;touch-action:none!important;user-select:none!important;-webkit-user-select:none!important;';
      const root=dock.attachShadow({mode:'closed'}),style=document.createElement('style'),button=document.createElement('button');
      style.textContent='button{all:initial;display:flex;align-items:center;justify-content:center;width:48px;height:48px;cursor:pointer;touch-action:none;color:white;background:rgba(28,28,30,.82);border-radius:14px 0 0 14px;box-shadow:0 2px 9px #0003;backdrop-filter:blur(16px);-webkit-user-select:none} :host([data-edge=left]) button{border-radius:0 14px 14px 0}svg{width:23px;height:23px;pointer-events:none}button:focus-visible{outline:3px solid #0a84ff}';
      button.type='button';button.setAttribute('aria-label',label);button.title=label;
      button.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M10 6h10M10 12h10M10 18h10"/><path d="M4 5h1v3M3.5 11c1.8-1.4 3.1.4 1.4 1.5L3.5 14H6M3.5 17.2c2.4-.8 3.4 1.2.8 1.5 2.6.1 1.7 2.3-.8 1.5" stroke="#60a5ff" stroke-width="1.5"/></svg>';
      root.append(style,button);
    }
    if(!dock.isConnected)document.documentElement.append(dock);layoutDock();
  }
  function ownEvent(event){
    if(!dock?.isConnected||!(event.composedPath?.()||[]).includes(dock))return;
    event.stopImmediatePropagation();if(event.type==='keydown'&&event.key==='Tab')return;
    if(event.cancelable)event.preventDefault();if(!event.isTrusted)return;
    if(event.type==='pointerdown'&&event.button===0&&!drag){const r=dock.getBoundingClientRect();drag={id:event.pointerId,x:event.clientX,y:event.clientY,left:r.left,top:r.top,moved:false};try{dock.setPointerCapture(event.pointerId)}catch{}}
    else if(event.type==='pointermove'&&drag?.id===event.pointerId){
      const x=event.clientX-drag.x,y=event.clientY-drag.y;if(!drag.moved&&Math.hypot(x,y)<8)return;drag.moved=true;
      const b=bounds();positionDock(Math.max(b.left,Math.min(b.left+b.width-48,drag.left+x)),Math.max(b.top,Math.min(b.top+b.height,drag.top+y)));
    }else if((event.type==='pointerup'||event.type==='pointercancel')&&drag?.id===event.pointerId){
      const old=drag;drag=null;lastUp=performance.now();try{dock.releasePointerCapture(event.pointerId)}catch{}
      if(old.moved&&event.type==='pointerup'){const b=bounds(),r=dock.getBoundingClientRect();edge=r.left+r.width/2<b.left+b.width/2?'left':'right';fraction=b.height>0?Math.max(0,Math.min(1,(r.top-b.top)/b.height)):.5;send('position',{edge,fraction})}
      layoutDock();if(!old.moved&&event.type==='pointerup')send('open');
    }else if(event.type==='click'&&performance.now()-lastUp>400)send('open');
    else if(event.type==='keydown'&&['Enter',' '].includes(event.key))send('open');
  }
  for(const name of ['pointerdown','pointermove','pointerup','pointercancel','click','keydown','contextmenu','touchstart','touchmove','touchend','touchcancel'])window.addEventListener(name,ownEvent,{capture:true,passive:false});
  function scheduleDock(){if(!dockFrame)dockFrame=requestAnimationFrame(()=>{dockFrame=0;updateDock()})}
  for(const name of ['scroll','resize'])window.addEventListener(name,scheduleDock,{passive:true});
  visualViewport?.addEventListener('resize',scheduleDock);visualViewport?.addEventListener('scroll',scheduleDock);
  for(const name of ['loadedmetadata','play','emptied','fullscreenchange'])document.addEventListener(name,updateDock,true);
  function refresh(checkPageState = false) {
    timer = 0;
    if(pageURL!==location.href){pageURL=location.href;pageSources=[];pageSignature='';}
    const result = enabled ? extract() : {pageURL:location.href,sources:[]};
    available=result.sources.length>0;updateDock();
    const signature = JSON.stringify(result);
    if (signature === previous) { if(checkPageState&&enabled)refreshPageState();return result; }
    previous = signature;
    lastStateRefresh=performance.now();
    try { window.webkit.messageHandlers.souloEpisodes.postMessage(result); } catch (_) {}
    return result;
  }
  function refreshPageState(){
    if(stateTimer)return;
    const wait=Math.max(0,1000-(performance.now()-lastStateRefresh));
    stateTimer=setTimeout(()=>{stateTimer=0;lastStateRefresh=performance.now();send('refresh')},wait);
  }
  function schedule() { if (!timer) timer = setTimeout(()=>refresh(true),300); }
  window.__souloEpisodes = {extract,refresh() {
    // Native state is reset when navigation starts, even when WebKit restores
    // this document and its unchanged DOM from the back-forward cache.
    previous='';return refresh(true);
  },configure(value) {
    enabled = value.enabled !== false;
    if(typeof value.label==='string')label=value.label;
    if(['left','right'].includes(value.edge))edge=value.edge;
    if(Number.isFinite(value.fraction))fraction=Math.max(0,Math.min(1,value.fraction));
    previous = ''; refresh();
  },setPageSources(value) {
    const signature=JSON.stringify(value);
    if(signature===pageSignature)return;
    pageSignature=signature;pageSources=value;refresh();
  }};
  function observe() {
    new MutationObserver(records => {
      if (records.some(record => {
        const target=record.target instanceof Element?record.target:record.target.parentElement;
        if(target?.hasAttribute('data-soulo-video-rotate')&&record.attributeName==='style')scheduleDock();
        if([...record.addedNodes,...record.removedNodes].some(node=>node instanceof Element&&node.hasAttribute('data-soulo-video-rotate')))scheduleDock();
        if(target?.closest('[data-soulo-video-rotate],#soulo-episode-dock'))return false;
        if(record.type==='attributes'&&['class','style','hidden'].includes(record.attributeName)){
          if(target?.matches(playerSelector)||target?.querySelector(playerSelector))scheduleDock();
          return false;
        }
        return record.type === 'attributes'
          || target?.closest(linkSelector + ',' + listSelector + ',' + stateSelector + ',h1,h2,h3,title')
          || [...record.addedNodes,...record.removedNodes].some(node => node instanceof Element
            && (node.matches(linkSelector + ',' + listSelector + ',' + stateSelector + ',video,iframe') || node.querySelector(linkSelector + ',' + stateSelector + ',video,iframe')));
      })) schedule();
    }).observe(document.documentElement,{childList:true,subtree:true,attributes:true,attributeFilter:['href','data-url','data-href','aria-current','class','style','hidden']});
    refresh();
  }
  if(document.documentElement)observe();else document.addEventListener('DOMContentLoaded',observe,{once:true});
  document.addEventListener('DOMContentLoaded',schedule,{once:true});
  for(const event of ['popstate','hashchange','pageshow'])window.addEventListener(event,() => {previous='';pageSources=[];pageSignature='';schedule()});
})();
