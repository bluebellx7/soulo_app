import Foundation

enum WebEpisodeSiteData {
    // Read public page state and real episode links. Platform adapters only
    // construct canonical watch URLs from IDs supplied by the current page.
    static let script = #"""
    (() => {
      const sources=[],used=new Set(),host=location.hostname.toLowerCase();
      const bili=/(^|\.)bilibili\.com$/.test(host),youku=/(^|\.)youku\.com$/.test(host);
      const text=value=>String(value || '').replace(/\s+/g,' ').trim().slice(0,160);
      function safe(value){
        if(typeof value!=='string'||!value.trim())return null;
        try{const u=new URL(value,location.href);u.hash='';
          const sameSite=u.hostname===location.hostname || bili&&/(^|\.)bilibili\.com$/.test(u.hostname) || youku&&/(^|\.)youku\.com$/.test(u.hostname);
          return /^https?:$/.test(u.protocol)&&sameSite?u.href:null
        }catch{return null}
      }
      function add(title,values){
        if(sources.length>=20)return;
        const episodes=[],seen=new Set();
        for(const item of values.slice(0,Math.max(0,5000-used.size))){
          const url=safe(item.url),name=text(item.title);
          if(!url||!name||seen.has(url)||used.has(url))continue;
          seen.add(url);episodes.push({title:name,url});
        }
        if(episodes.length<2)return;
        episodes.forEach(item=>used.add(item.url));sources.push({title:text(title),episodes});
      }
      function currentState(value){
        if(!bili)return true;
        const current=location.pathname.match(/\/video\/(BV\w+|av\d+)/i)?.[1];
        if(!current)return true;
        const video=value.videoData || value.videoInfo || value.video || {};
        return /^BV/.test(current)?!video.bvid || String(video.bvid)===current
          :!video.aid || 'av'+video.aid===current.toLowerCase();
      }
      let state={};
      for(const name of ['__INITIAL_STATE__','__INITIAL_DATA__']){
        try{const value=window[name];if(value&&typeof value==='object'&&currentState(value)){state=value;break}}catch{}
      }
      if(bili){
        const video=state.videoData || state.videoInfo || state.video || {};
        if(Array.isArray(video.pages)&&/\/video\/(?:BV[\w]+|av\d+)/i.test(location.pathname)){
          add(video.title,video.pages.map((part,index)=>{
            const page=Number(part.page || index+1),url=new URL(location.href);
            if(!Number.isSafeInteger(page)||page<1)return {};
            url.searchParams.set('p',String(page));return {title:'P'+page+' '+text(part.part || part.title || page),url:url.href};
          }));
        }
        const season=video.ugc_season || state.ugc_season;
        for(const section of season?.sections || []){
          add(section.title || season.title,(section.episodes || []).map(episode=>{
            const bvid=episode.bvid || episode.arc?.bvid;
            const url=/^BV\w+$/.test(bvid || '')?new URL('/video/'+bvid+'/',location.origin).href:episode.link;
            return {title:episode.title || episode.arc?.title,url};
          }));
        }
        const episodes=state.epList || state.mediaInfo?.episodes || state.episodes;
        if(Array.isArray(episodes))add(state.mediaInfo?.title,episodes.map(episode=>({
          title:text(episode.titleFormat || episode.title || episode.long_title || episode.longTitle),
          url:episode.link || episode.share_url || (/^\d+$/.test(String(episode.id || ''))?'/bangumi/play/ep'+episode.id:null)
        })));
      }
      if(bili||youku){
        const selector=bili?'.video-pod,.video-sections-content-list,#multi_page,.multi-page,.video-episode-card'
          :'.anthology,.anthology-list,.anthology-content,#anthology,.episode-list,.show-episode,.player-episode,[data-component*="episode"]';
        for(const group of document.querySelectorAll(selector)){
          add(group.getAttribute('aria-label') || '',[...group.querySelectorAll('a[href]')].map(link=>({
            title:link.getAttribute('title') || link.getAttribute('aria-label') || link.textContent,
            url:link.href
          })).filter(item=>bili?/\/(?:video|bangumi\/play)\//.test(item.url):/\/v_show\/id_/.test(item.url)));
        }
      }
      const roots=[];
      for(const name of ['__INITIAL_STATE__','__INITIAL_DATA__','__PRELOADED_STATE__','__NEXT_DATA__','pageConfig','detailData','initialData']){
        try{if(window[name]&&typeof window[name]==='object'&&currentState(window[name]))roots.push(window[name])}catch{}
      }
      for(const node of document.querySelectorAll('script[type="application/ld+json"],script#__NEXT_DATA__,script#RENDER_DATA')){
        try{roots.push(JSON.parse(node.id==='RENDER_DATA'?decodeURIComponent(node.textContent):node.textContent))}catch{}
      }
      function entry(node,index){
        node=node?.item || node?.data || node;
        if(!node||typeof node!=='object')return {};
        const id=node.videoId || node.video_id || node.vid;
        const explicit=node.url || node.link || node.href || node.playUrl || node.action?.value || node.action?.url;
        const url=typeof explicit==='string'?explicit:youku&&/^X[\w=+-]+$/.test(id || '')?'/v_show/id_'+id+'.html':null;
        return {title:node.title || node.name || node.displayName || node.text || node.shortTitle || String(node.position || index+1),url};
      }
      const visited=new Set();let count=0;
      function walk(node,depth=0,context=''){
        if(!node||typeof node!=='object'||depth>10||count++>12000||visited.has(node))return;
        visited.add(node);
        if(Array.isArray(node)){for(const item of node.slice(0,1000))walk(item,depth+1,context);return}
        const type=text(node.componentType || node.moduleType || node.type || node['@type']);
        const episodeContext=/episode|anthology|TVSeason|TVSeries|选集|選集/i.test(type);
        for(const key of Object.keys(node).slice(0,100)){
          if(/recommend|related|advert|feed|suggest/i.test(key))continue;
          const value=node[key];
          if(Array.isArray(value)&&(/^(?:episodes?|episodeList|playList|playlist|seriesList|anthology)$/i.test(key)
            || youku&&episodeContext&&/^(?:children|nodes|items|list|videos)$/i.test(key))){
            add(node.title || node.name || context,value.map(entry));
          }
          if(typeof value==='object')walk(value,depth+1,node.title || context);
        }
      }
      roots.forEach(root=>walk(root));
      return {pageURL:location.href,sources};
    })();
    """#
}
