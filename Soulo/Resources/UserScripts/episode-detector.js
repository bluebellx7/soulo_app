(() => {
  if (window.__souloEpisodes) return;
  const overlay = window.__souloOverlayControls;
  let timer = 0, previous = '', enabled = true, dockEnabled = true, watchChanges = true, observer = null, dockFrame = 0, stateTimer = 0, lastStateRefresh = 0;
  let pageSources = [], pageSignature = '', pageURL=location.href;
  const resourceListSelector = '.dy-collect-list,.vodplayinfo ul,.vodplayinfo ol';
  const listSelector = '.stui-content__playlist,.stui-play__list,.myui-content__list,.module-play-list,.module-play-list-content,.anthology-list-play,.playlist,.play-list,.episode-list,.episodes,[data-episode-list],' + resourceListSelector;
  const linkSelector = 'a[href],button[data-url],button[data-href],[role="link"][data-url]';
  const resourceTextSelector = 'textarea,[data-playlist]';
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
  function resourcePlaybackURL(url) {
    return /\.(?:m3u8|mp4|m4v|mov|webm)$/i.test(url.pathname)
      || /\/(?:play(?:er)?|vodplay|watch|episodes?|v[_-]?play|share)(?:[/.\-_]|$)/i.test(url.pathname);
  }
  function safeURL(raw) {
    if (typeof raw !== 'string' || !raw.trim() || raw.length > 8192) return null;
    if (/^https?:/i.test(raw.trim()) && !/^https?:\/\//i.test(raw.trim())) return null;
    try {
      const url = new URL(raw,document.baseURI);
      if (!/^https?:$/.test(url.protocol) || !url.hostname || url.username || url.password) return null;
      url.hash = ''; return url;
    } catch (_) { return null; }
  }
  function destination(link, resource = false) {
    const raw = link.getAttribute('href') || link.getAttribute('data-url') || link.getAttribute('data-href');
    const url = safeURL(raw);
    return url && (url.host === location.host || resource && resourcePlaybackURL(url)) ? url : null;
  }
  function delimitedResourceEntry(text, link = null) {
    text = (text || '').trim();
    if (text.length > 5000) return null;
    const parts = text.match(/^(.{1,160}?)\$\s*(https?:\/\/\S+)\s*$/i);
    if (!parts) return null;
    const url = safeURL(parts[2]), title = clean(parts[1]);
    if (!url || !title || !resourcePlaybackURL(url)) return null;
    if (link) {
      const wrapper = safeURL(link.getAttribute('href') || link.getAttribute('data-url') || link.getAttribute('data-href'));
      if (!wrapper) return null;
      // A visible copy URL is authoritative for signed query parameters. Only
      // unwrap when the real href names that file; never run player scripts.
      const targets = [wrapper, ...['url','src','file','playurl'].map(key => safeURL(wrapper.searchParams.get(key)))];
      if (!targets.some(target => target && target.origin === url.origin && target.pathname === url.pathname)) return null;
    }
    return {title,url};
  }
  function resourceLabel(title) {
    return episodeLabel(title) || /^(?:HD|BD|正片|全集|高清|预告|特别篇|特別篇|番外|剧场版|劇場版|OVA|OAD|SP)(?:\b|[\d中字国粤英日语語版集篇上下：:\s]|$)/i.test(labelText(title));
  }
  function auxiliaryLink(link) {
    return /^(?:我要报错|报错|報錯|举报|舉報|反馈|反饋|复制.*|複製.*|下载.*|下載.*|上一集|下一集|copy(?:\s.*)?|report(?:\s.*)?|download(?:\s.*)?|previous|next)$/i.test(clean(link.textContent))
      || /(?:^|[-_\s])(?:report|copy|download)(?:[-_\s]|$)/i.test(link.className || '');
  }
  function resourceGroup(row) {
    return row.closest('ul,ol,tbody,[role="list"]')
      || (row.querySelectorAll(linkSelector).length > 1 ? row : row.parentElement);
  }
  function resourceRow(link) {
    const row = link.closest('li,tr,[role="listitem"]');
    if (row) return row;
    const parent = link.parentElement;
    return parent?.matches('span,b,strong,em') ? parent.parentElement : parent;
  }
  function resourceLinkEntry(link, labels) {
    if (auxiliaryLink(link)) return null;
    const text = (link.textContent || '').trim();
    // A malformed or mismatched copy link must not fall back to its caption.
    if (text.includes('$')) return delimitedResourceEntry(text,link);
    const url = safeURL(link.getAttribute('href') || link.getAttribute('data-url') || link.getAttribute('data-href'));
    if (!url || !resourcePlaybackURL(url)) return null;
    const row = resourceRow(link);
    if (!row || row === document.body || row === document.documentElement) return null;
    const trusted = !!link.closest(resourceListSelector);
    const direct = /\.(?:m3u8|mp4|m4v|mov|webm)$/i.test(url.pathname);
    const caption = clean(link.getAttribute('title') || link.getAttribute('aria-label') || text);
    if (resourceLabel(caption) && (direct || trusted)) return {title:caption,url};
    const first = [...row.querySelectorAll(linkSelector)].find(candidate => !auxiliaryLink(candidate));
    if (first !== link) return null;
    if (!labels.has(row)) {
      const explicit = row.querySelector('.c-name,[data-episode-title],[data-episode-name]');
      const clone = row.cloneNode(true);
      clone.querySelectorAll('a,button,input,select,textarea,script,style,[role="button"]').forEach(node => node.remove());
      labels.set(row,clean(explicit?.getAttribute('data-episode-title') || explicit?.getAttribute('data-episode-name') || explicit?.textContent || clone.textContent).replace(/\s*[$：:]\s*$/,''));
    }
    const title = labels.get(row);
    const displayed = safeURL(text);
    const copied = [...row.querySelectorAll('input[type="checkbox"]')].some(input => safeURL(input.value)?.href === url.href);
    const paired = displayed?.href === url.href || copied;
    // Repeated copy rows also retain named specials beside a real URL.
    // Ordinary cross-site links labelled EP1 alone remain excluded.
    if (!title || !(resourceLabel(title) || trusted && row.querySelector('.c-name') || paired && !/https?:\/\/|\$/.test(title))) return null;
    if (!direct && !trusted && !paired) return null;
    return {title,url};
  }
  function discoverResourceGroups() {
    const records = new Map(), labels = new WeakMap();
    function add(group,entry) {
      if (!group || group === document.body || group === document.documentElement || excludedGroup(group)) return;
      if (!records.has(group)) {
        if (records.size >= 60) return;
        records.set(group,new Map());
      }
      const items = records.get(group);
      if (items.size < 5000 && !items.has(entry.url.href)) items.set(entry.url.href,entry);
    }
    let count = 0;
    for (const link of document.querySelectorAll(linkSelector)) {
      if (++count > 6000) break;
      const row = resourceRow(link);
      if (!row || excludedGroup(row)) continue;
      const entry = resourceLinkEntry(link,labels);
      if (entry) add(resourceGroup(row),entry);
    }
    // Copy-only rows need no clickable anchor. Do not reparse rows containing
    // links: doing so would accept unsafe or mismatched hrefs rejected above.
    count = 0;
    for (const row of document.querySelectorAll('li,tr,[role="listitem"]')) {
      if (++count > 6000) break;
      if (!row.textContent.includes('$') || row.querySelector(linkSelector) || excludedGroup(row)) continue;
      const clone = row.cloneNode(true);
      clone.querySelectorAll('button,input,script,style').forEach(node => node.remove());
      const entry = delimitedResourceEntry(clone.textContent);
      if (entry) add(resourceGroup(row),entry);
    }
    const groups = new Map();
    for (const [group,items] of records) {
      const entries = [...items.values()];
      const numbered = new Set(entries.filter(entry => episodeLabel(entry.title)).map(entry => entry.title));
      const explicit = group.matches(resourceListSelector) || semanticGroup(group);
      if (entries.length && (explicit || numbered.size >= 2)) groups.set(group,[{entries,title:headingText(group)}]);
    }
    count = 0;
    let textBudget = 2000000;
    for (const node of document.querySelectorAll(resourceTextSelector)) {
      if (++count > 60) break;
      if (excludedGroup(node) || node.matches(linkSelector) || node.querySelector(linkSelector)) continue;
      const value = node instanceof HTMLTextAreaElement ? node.value : node.textContent;
      if (!value || value.length > textBudget) continue;
      textBudget -= value.length;
      const lines = value.split('$$$').slice(0,20), sources = [];
      let remaining = 5000;
      for (const [index,line] of lines.entries()) {
        const entries = line.split(/\r?\n|#(?=[^#$\r\n]{1,160}\$\s*https?:\/\/)/).slice(0,remaining).map(part => delimitedResourceEntry(part)).filter(Boolean);
        const unique = [...new Map(entries.map(entry => [entry.url.href,entry])).values()];
        const explicit = semanticGroup(node);
        if (unique.length && (explicit || unique.filter(entry => episodeLabel(entry.title)).length >= 2)) {
          const heading = headingText(node);
          sources.push({entries:unique,title:lines.length > 1 && heading ? heading+' '+(index+1) : heading});
          remaining -= unique.length;
        }
        if (!remaining) break;
      }
      if (sources.length) groups.set(node,sources);
    }
    return groups;
  }
  function looksPlayable(url) {
    if ([...url.searchParams.keys()].some(key => /^(?:page|pageindex|page_no)$/i.test(key))) return false;
    return /\/(?:play(?:er)?|vodplay|watch|episodes?|v[_-]?play)(?:[\/.\-_]|$)/i.test(url.pathname)
      || [...url.searchParams.keys()].some(key => /^(?:ep|episode|episodeid|eid|nid|play)$/i.test(key))
      || (/\/video\//i.test(url.pathname) && url.pathname === location.pathname && /^\d+$/.test(url.searchParams.get('p') || ''));
  }
  function opaquePlayFamily(url) {
    const route = url?.pathname.match(/^(.*\/v[_-]?play)\/[^/]+\/?$/i);
    return route ? url.origin + route[1].toLowerCase() + '/' : null;
  }
  function headingText(group) {
    const heading = group.previousElementSibling;
    const shortLabel = heading?.querySelector('p,strong,b,legend')?.textContent;
    const title = clean(group.getAttribute('data-title') || group.getAttribute('aria-label')
      || (group.matches(resourceListSelector) ? group.closest('.dy-collect-video')?.querySelector('.dy-collect-video-name')?.textContent : '')
      || group.closest('table')?.querySelector('caption')?.textContent
      || heading?.querySelector('h2,h3,h4')?.textContent
      || (heading?.matches('h2,h3,h4,legend') ? heading.textContent : '')
      || (shortLabel && shortLabel.trim().length <= 40 && !/[。！？]/.test(shortLabel) ? shortLabel : ''));
    return title.replace(/^(?:来源|來源|播放类型|播放類型|播放线路|播放線路|source)\s*[:：]\s*/i, '');
  }
  function semanticGroup(group) {
    return group.matches('[data-playlist],[data-episode-list]') || /episode|season|playlist|play[-_ ]?list|anthology|m3u8|选集|選集|剧集|劇集|播放|集数|集數|分集|合集|エピソード/i.test(
      [group.id,typeof group.className === 'string' ? group.className : '',headingText(group)].join(' '));
  }
  function excludedGroup(group) {
    return !!group.closest('nav,[role="navigation"],.pagination,.pager,.stui-page__item,.related,.recommend,.recommendations,[data-recommendations],.ad,.ads,.advertisement,[data-ad]')
      || /(?:^|[-_\s])(?:pagination|recommend|related)(?:[-_\s]|$)/i.test(group.className || '');
  }
  let actionKey='',actionScope='',buttonIDs=new WeakMap();
  const buttonActions=new Map();
  function uuid(){
    if(typeof crypto.randomUUID==='function')return crypto.randomUUID();
    const bytes=crypto.getRandomValues(new Uint8Array(16));bytes[6]=(bytes[6]&15)|64;bytes[8]=(bytes[8]&63)|128;
    const hex=[...bytes].map(v=>v.toString(16).padStart(2,'0')).join('');
    return hex.slice(0,8)+'-'+hex.slice(8,12)+'-'+hex.slice(12,16)+'-'+hex.slice(16,20)+'-'+hex.slice(20);
  }
  function catalogKey(){
    const url=new URL(location.href);url.hash='';
    for(const key of [...url.searchParams.keys()])if(/^(?:episode|episodeid|episode_id|ep|eid|part|p|line|lineid|line_id)$/i.test(key))url.searchParams.delete(key);
    return url.href+'|'+clean(document.querySelector('h1')?.textContent);
  }
  function ensureActions(){
    const key=catalogKey();if(key!==actionKey){actionKey=key;actionScope=uuid();buttonIDs=new WeakMap();buttonActions.clear();}
    for(const [token,value]of buttonActions)if(!value.node.isConnected)buttonActions.delete(token);
  }
  function buttonTitle(node){return clean(node.getAttribute('title')||node.getAttribute('aria-label')||node.textContent);}
  function usableButton(node){
    const title=buttonTitle(node);
    if(!(typeof node.click==='function'&&!node.matches(linkSelector)&&!node.closest('form,[disabled],[aria-disabled="true"],[aria-hidden="true"],[hidden]')
      &&episodeLabel(title)&&(episodeNumber(title)??0)>0&&!excludedGroup(node)
      &&(!plainNumber.test(labelText(title))||!node.querySelector('svg,img,input'))))return false;
    const rect=node.getBoundingClientRect(),style=getComputedStyle(node);
    return rect.width>0&&rect.height>0&&style.display!=='none'&&style.visibility!=='hidden';
  }
  function selectedButton(node){
    const current=node.getAttribute('aria-current');
    return !!current&&current!=='false'||node.getAttribute('aria-selected')==='true'||node.getAttribute('aria-pressed')==='true'
      ||/(?:^|\s)[\w-]*(?:active|selected|current|primary)(?:\s|$)/i.test(node.getAttribute('class')||'');
  }
  function buttonSources(){
    ensureActions();const groups=new Map();let scanned=0;
    for(const node of document.querySelectorAll('button,[role="button"]')){
      if(++scanned>3000)break;if(!usableButton(node))continue;
      for(let group=node.parentElement,depth=0;group&&group!==document.body&&depth<6;group=group.parentElement,depth++){
        if(excludedGroup(group))break;
        if(!semanticGroup(group))continue;
        if(!groups.has(group)&&groups.size<60){
          const buttons=[...group.querySelectorAll('button,[role="button"]')].slice(0,1000).filter(usableButton);
          if(new Set(buttons.map(n=>episodeNumber(buttonTitle(n)))).size>=2)groups.set(group,buttons);
        }
        if(groups.has(group))break;
      }
    }
    const sources=[];let total=0;
    for(const [group,buttons]of groups){
      if(sources.length>=20||total>=5000)break;
      if([...groups.keys()].some(other=>other!==group&&group.contains(other)))continue;
      const episodes=[];const hasCurrent=buttons.some(selectedButton);
      for(const [index,node]of buttons.entries()){
        if(total++>=5000)break;
        const title=buttonTitle(node);let token=buttonIDs.get(node);
        if(!token){if(buttonActions.size>=5000)continue;token=uuid();buttonIDs.set(node,token);}
        buttonActions.set(token,{node,group,title,scope:actionScope});
        episodes.push({title,url:location.href,action:{token,scope:actionScope,isCurrent:hasCurrent&&selectedButton(node)}});
      }
      if(episodes.length)sources.push({title:headingText(group),episodes});
    }
    return sources;
  }
  function activateButton(token,scope){
    if(!enabled||typeof token!=='string'||typeof scope!=='string')return false;
    ensureActions();const entry=buttonActions.get(token);
    if(!entry||scope!==actionScope||entry.scope!==scope||!entry.node.isConnected||!entry.group.contains(entry.node)
      ||!semanticGroup(entry.group)||!usableButton(entry.node)||buttonTitle(entry.node)!==entry.title)return false;
    const rect=entry.node.getBoundingClientRect(),style=getComputedStyle(entry.node);
    if(rect.width<=0||rect.height<=0||style.display==='none'||style.visibility==='hidden')return false;
    entry.node.click();setTimeout(()=>refresh(true),50);return true;
  }
  function extract() {
    if (pageSources.length) return {pageURL:location.href,sources:pageSources};
    const resourceGroups = discoverResourceGroups();
    const groups = new Set([...document.querySelectorAll(listSelector),...resourceGroups.keys()]);
    const currentQuery = location.search.match(/^\?(\d+)-(\d+)-(\d+)\.html$/i);
    const current = location.pathname.match(playPath), videoPage = !!document.querySelector('video,iframe[src*="player"],iframe[src*="play/"]');
    const currentURL = safeURL(location.href), currentOpaqueFamily = opaquePlayFamily(currentURL);
    const opaqueGroups = new Map(), selectedRows = new WeakMap();
    function opaqueGroup(group,family) {
      let cached = opaqueGroups.get(group);
      if (!cached) { cached = new Map(); opaqueGroups.set(group,cached); }
      if (cached.has(family)) return cached.get(family);
      const numbers = new Set(), urls = new Set(), numericParents = new Set();
      let anchored = false, currentTitle = '', count = 0;
      if (!currentURL || currentOpaqueFamily && family !== currentOpaqueFamily) {
        const result = {valid:false,family,currentTitle,numericParents}; cached.set(family,result); return result;
      }
      for (const link of group.querySelectorAll(linkSelector)) {
        if (++count > 5000) break;
        if (excludedGroup(link) || auxiliaryLink(link) || link.hasAttribute('download')
            || link.querySelector('img,picture,video,form,input')) continue;
        const url = destination(link), title = clean(link.textContent) || buttonTitle(link), number = episodeNumber(title);
        if (!url || !looksPlayable(url) || url.origin !== currentURL.origin || opaquePlayFamily(url) !== family
            || !episodeLabel(title) || number === undefined || urls.has(url.href)) continue;
        urls.add(url.href); numbers.add(number); numericParents.add(link.parentElement);
        const row = link.closest('li,[role="listitem"]') || link.parentElement;
        let selectedRow = false;
        if (row && row !== group && selectedButton(row)) {
          if (!selectedRows.has(row)) selectedRows.set(row,row.querySelectorAll(linkSelector).length === 1);
          selectedRow = selectedRows.get(row);
        }
        if (url.href === currentURL.href || selectedButton(link) || selectedRow) anchored = true;
      }
      // Some templates render the current episode as a selected span, not a
      // link. Accept a leaf episode marker, never an active whole list/tab.
      count = 0;
      for (const marker of group.querySelectorAll('[aria-current],[aria-selected="true"],.active,.selected,.current')) {
        if (++count > 1000) break;
        if (!selectedButton(marker) || excludedGroup(marker) || marker.matches(linkSelector)
            || marker.querySelector(linkSelector + ',button,[role="button"]')) continue;
        const title = clean(marker.textContent) || buttonTitle(marker), number = episodeNumber(title);
        if (!episodeLabel(title) || number === undefined) continue;
        numbers.add(number); anchored = true;
        if (!currentTitle && currentOpaqueFamily === family) currentTitle = title;
      }
      const result = {valid:anchored && urls.size > 0 && numbers.size >= 2,family,currentTitle,numericParents};
      cached.set(family,result); return result;
    }
    function namedOpaquePeer(link,title,url,opaque) {
      if (!title || title.length > 48 || !opaque.numericParents.has(link.parentElement)
          || excludedGroup(link) || auxiliaryLink(link) || link.hasAttribute('download')
          || link.querySelector('img,picture,video,form,input')
          || /^\s*#/.test(link.getAttribute('href') || '')
          || /#(?:respond|reply|comments?)(?:\b|[-_])/i.test(link.getAttribute('href') || '')
          || [...url.searchParams.keys()].some(key => /^(?:reply|replyto|reply_to|comment|commentid|comment_id|post|action)$/i.test(key))) return false;
      return !/^(?:回复|回復|回覆|评论|評論|留言|reply|comments?)(?:\s*(?:[（(]?\d+[)）]?|[:：].*|作者|楼主|樓主|TA|to\b.*))?$/i.test(title)
        && !/(?:取消\s*(?:回复|回復|回覆|评论|評論)|cancel\s+(?:reply|comment))/i.test(title)
        && !/(?:^|[-_\s])(?:reply|comment|cancel|report|copy|download)(?:[-_\s]|$)/i.test(link.className || '')
        && !/^https?:\/\//i.test(title);
    }
    // Fall back to repeated, labelled links instead of any site's class names.
    // Require playback context so numeric pagination and catalog cards stay out.
    let scannedLinks = 0;
    for (const link of document.querySelectorAll(linkSelector)) {
      if (++scannedLinks > 6000) break;
      if (groups.size >= 60 || link.closest(listSelector)) continue;
      const title = clean(link.textContent || link.getAttribute('title') || link.getAttribute('aria-label'));
      const url = destination(link);
      if (!url || !episodeLabel(title)) continue;
      let group = link.closest('ul,ol,[role="list"]') || link.parentElement;
      for (let depth = 0; group && depth < 4; depth++, group = group.parentElement) {
        if (group === document.body || group === document.documentElement || excludedGroup(group)) break;
        const semantic = semanticGroup(group);
        if (!(semantic || looksPlayable(url) || (videoPage && !plainNumber.test(labelText(title))))) continue;
        const family = opaquePlayFamily(url);
        if (family) {
          if (opaqueGroup(group,family).valid) { groups.add(group); break; }
          // Do not merge independent lists above a rejected recommendation or
          // pagination block merely to find the current URL in a sibling list.
          if (group.matches('ul,ol,[role="list"]')) break;
          continue;
        }
        let count = 0;
        for (const candidate of group.querySelectorAll(linkSelector)) {
          if (destination(candidate) && episodeLabel(clean(candidate.textContent || candidate.getAttribute('title') || candidate.getAttribute('aria-label'))) && ++count >= 2) break;
        }
        if (count >= 2) { groups.add(group); break; }
      }
    }
    const sources = [], used = new Set();
    let total = 0;
    function appendSource(title,episodes) {
      if (!episodes.length) return;
      if (episodes.every(item => episodeNumber(item.title) !== undefined)) episodes.sort((a,b) => episodeNumber(a.title)-episodeNumber(b.title));
      episodes.forEach(item => used.add(item.url));
      sources.push({title:clean(title),episodes});
    }
    for (const group of groups) {
      if (sources.length >= 20 || total >= 5000) break;
      if (excludedGroup(group) || [...groups].some(other => other !== group && group.contains(other)
          && (resourceGroups.has(other) || !resourceGroups.has(group)))) continue;
      const episodes = [], seen = new Set(), known = group.matches(listSelector);
      const resources = resourceGroups.get(group);
      if (resources) {
        for (const line of resources) {
          if (sources.length >= 20 || total >= 5000) break;
          const entries = [];
          for (const entry of line.entries) {
            if (total >= 5000) break;
            if (used.has(entry.url.href)) continue;
            entries.push({title:entry.title,url:entry.url.href,resourcePageURL:location.href}); total++;
          }
          appendSource(line.title,entries);
        }
        continue;
      }
      if (group.matches(resourceListSelector)) continue;
      let opaque = null, opaqueFamily = null;
      for (const link of group.querySelectorAll(linkSelector)) {
        const family = opaquePlayFamily(destination(link));
        if (!family) continue;
        if (!opaqueFamily) opaqueFamily = family;
        if (family === currentOpaqueFamily) { opaqueFamily = family; break; }
      }
      if (opaqueFamily) opaque = opaqueGroup(group,opaqueFamily);
      if (opaque && !opaque.valid) continue;
      for (const link of group.querySelectorAll(linkSelector)) {
        if (total >= 5000) break;
        if (link.closest('.pagination,.pager,.related,.recommend,.recommendations,[data-recommendations]')) continue;
        const url = destination(link);
        if (!url) continue;
        if (opaque && (!looksPlayable(url) || url.origin !== currentURL.origin || opaquePlayFamily(url) !== opaque.family
            || excludedGroup(link) || auxiliaryLink(link) || link.hasAttribute('download')
            || link.querySelector('img,picture,video,form,input'))) continue;
        if (currentQuery) {
          const query = url.search.match(/^\?(\d+)-(\d+)-(\d+)\.html$/i);
          if (url.pathname !== location.pathname || !query || query[1] !== currentQuery[1]) continue;
        }
        const title = clean(link.textContent || link.getAttribute('title') || link.getAttribute('aria-label'));
        const match = url.pathname.match(playPath);
        if (!title || !(match || episodeLabel(title) || (opaque ? namedOpaquePeer(link,title,url,opaque)
            : known && /^(?:HD|BD|正片|全集)/i.test(title)))) continue;
        if (current && match && match[1] !== current[1]) continue;
        if (seen.has(url.href) || used.has(url.href)) continue;
        seen.add(url.href); episodes.push({title,url:url.href}); total++;
      }
      if (opaque?.currentTitle && !seen.has(currentURL.href) && !used.has(currentURL.href) && total < 5000) {
        episodes.push({title:opaque.currentTitle,url:currentURL.href}); total++;
      }
      if (!episodes.length) continue;
      const playItem = group.closest('.play-item');
      const lineIndex = playItem ? [...playItem.parentElement.children].indexOf(playItem) : -1;
      const lineTitle = lineIndex >= 0 ? group.closest('.tab-content')?.querySelectorAll('.play-tab a')[lineIndex]?.textContent : '';
      appendSource(lineTitle || headingText(group),episodes);
    }
    if(!sources.length&&videoPage)sources.push(...buttonSources());
    return {pageURL:location.href,sources};
  }
  let dock=null,drag=null,available=false,label='Episodes',edge='right',fraction=.62,lastUp=0;
  function send(action,details={}){try{window.webkit.messageHandlers.souloEpisodes.postMessage({action,pageURL:location.href,...details})}catch{}}
  function visibleVideoTools(){
    // The media runtime also finds videos inside open shadow roots. Its visible
    // controls are a shared DOM signal even though this world cannot query those
    // videos through document.querySelectorAll().
    if([...document.querySelectorAll('[data-soulo-video-rotate]')].some(node=>{
      const r=node.getBoundingClientRect(),s=getComputedStyle(node);
      return r.width>1&&r.height>1&&r.right>0&&r.left<innerWidth&&r.bottom>0&&r.top<innerHeight&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0;
    }))return true;
    // A video or iframe alone does not guarantee that Soulo's episode menu is
    // present (disabled tools, cross-origin players and replacement players).
    return false;
  }
  function bounds(){const v=overlay.metrics();return {...v,top:v.top+12*v.unit,height:Math.max(0,v.height-144*v.unit)}}
  function positionDock(x,y){dock.style.setProperty('left',x+'px','important');dock.style.setProperty('top',y+'px','important')}
  function layoutDock(){
    if(!dock||drag)return;const b=bounds();
    overlay.apply(dock,b);
    positionDock(b.left+(edge==='left'?0:Math.max(0,b.width-b.size)),b.top+b.height*fraction);
    dock.setAttribute('data-edge',edge);
  }
  function updateDock(){
    if(!dockEnabled||!available||!enabled||visibleVideoTools()){drag=null;dock?.remove();return}
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
      const x=event.clientX-drag.x,y=event.clientY-drag.y,b=bounds();if(!drag.moved&&Math.hypot(x,y)<8*b.unit)return;drag.moved=true;
      positionDock(Math.max(b.left,Math.min(b.left+b.width-b.size,drag.left+x)),Math.max(b.top,Math.min(b.top+b.height,drag.top+y)));
    }else if((event.type==='pointerup'||event.type==='pointercancel')&&drag?.id===event.pointerId){
      const old=drag;drag=null;lastUp=performance.now();try{dock.releasePointerCapture(event.pointerId)}catch{}
      if(old.moved&&event.type==='pointerup'){const b=bounds(),r=dock.getBoundingClientRect();edge=r.left+r.width/2<b.left+b.width/2?'left':'right';fraction=b.height>0?Math.max(0,Math.min(1,(r.top-b.top)/b.height)):.5;send('position',{edge,fraction})}
      layoutDock();if(!old.moved&&event.type==='pointerup')send('open');
    }else if(event.type==='click'&&performance.now()-lastUp>400)send('open');
    else if(event.type==='keydown'&&['Enter',' '].includes(event.key))send('open');
  }
  for(const name of ['pointerdown','pointermove','pointerup','pointercancel','click','keydown','contextmenu'])window.addEventListener(name,ownEvent,{capture:true});
  // A non-passive root touch listener makes every page's scrolling wait for JS,
  // even when there is no episode dock. Pointer capture and the dock's own
  // touch-action:none handle dragging; touch events only isolate this control.
  for(const name of ['touchstart','touchmove','touchend','touchcancel'])window.addEventListener(name,event=>{
    if(dock?.isConnected&&(event.composedPath?.()||[]).includes(dock))event.stopImmediatePropagation();
  },{capture:true,passive:true});
  function scheduleDock(){if(!dockEnabled)return;if(!dockFrame)dockFrame=requestAnimationFrame(()=>{dockFrame=0;updateDock()})}
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
  function schedule() { if (watchChanges && !timer) timer = setTimeout(()=>refresh(true),300); }
  window.__souloEpisodes = {extract,activate:activateButton,refresh() {
    // Native state is reset when navigation starts, even when WebKit restores
    // this document and its unchanged DOM from the back-forward cache.
    previous='';return refresh(true);
  },setContentZoom(value) {
    overlay.setContentZoom(value);scheduleDock();
  },configure(value) {
    enabled = value.enabled !== false;
    dockEnabled = value.dockEnabled !== false;
    watchChanges = value.watchChanges !== false;
    observer?.disconnect();
    if(watchChanges && document.documentElement)observer?.observe(document.documentElement,observationOptions);
    if(!dockEnabled){if(dockFrame)cancelAnimationFrame(dockFrame);dockFrame=0;drag=null;dock?.remove();}
    if(!watchChanges){clearTimeout(timer);timer=0;clearTimeout(stateTimer);stateTimer=0;}
    if(typeof value.label==='string')label=value.label;
    if(['left','right'].includes(value.edge))edge=value.edge;
    if(Number.isFinite(value.fraction))fraction=Math.max(0,Math.min(1,value.fraction));
    previous = ''; refresh();
  },setPageSources(value) {
    const signature=JSON.stringify(value);
    if(signature===pageSignature)return;
    pageSignature=signature;pageSources=value;refresh();
  }};
  const observationOptions={childList:true,subtree:true,attributes:true,attributeFilter:['href','data-url','data-href','aria-current','aria-selected','aria-pressed','title','disabled','class','style','hidden']};
  function observe() {
    observer = new MutationObserver(records => {
      if (records.some(record => {
        const target=record.target instanceof Element?record.target:record.target.parentElement;
        if(target?.hasAttribute('data-soulo-video-rotate')&&record.attributeName==='style')scheduleDock();
        if([...record.addedNodes,...record.removedNodes].some(node=>node instanceof Element&&node.hasAttribute('data-soulo-video-rotate')))scheduleDock();
        if(target?.closest('[data-soulo-video-rotate],#soulo-episode-dock'))return false;
        if(record.type==='attributes'&&record.attributeName==='class'&&buttonIDs.has(target))return true;
        if(record.type==='attributes'&&['class','style','hidden'].includes(record.attributeName)){
          if(target?.matches(playerSelector)||target?.querySelector(playerSelector))scheduleDock();
          return false;
        }
        return record.type === 'attributes'
          || target?.closest(linkSelector + ',' + listSelector + ',' + resourceTextSelector + ',' + stateSelector + ',button,[role="button"],li,tr,[role="listitem"],h1,h2,h3,title')
          || [...record.addedNodes,...record.removedNodes].some(node => node instanceof Element
            && (node.matches(linkSelector + ',' + listSelector + ',' + resourceTextSelector + ',' + stateSelector + ',button,[role="button"],li,tr,video,iframe') || node.querySelector(linkSelector + ',' + resourceTextSelector + ',' + stateSelector + ',li,tr,video,iframe')));
      })) schedule();
    });
    if(watchChanges)observer.observe(document.documentElement,observationOptions);
    refresh();
  }
  if(document.documentElement)observe();else document.addEventListener('DOMContentLoaded',observe,{once:true});
  document.addEventListener('DOMContentLoaded',schedule,{once:true});
  document.addEventListener('input',event => {if(event.target instanceof HTMLTextAreaElement)schedule()},true);
  for(const event of ['popstate','hashchange','pageshow'])window.addEventListener(event,() => {previous='';pageSources=[];pageSignature='';if(watchChanges)schedule();else refresh()});
})();
