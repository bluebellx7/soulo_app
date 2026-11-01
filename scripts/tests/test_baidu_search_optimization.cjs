/* Trusted browser interactions against the bundled rule, without remote requests.
 * SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_baidu_search_optimization.cjs
 */
const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { chromium } = require(process.env.SOULO_PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(__dirname, '../..');
const rule = JSON.parse(fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts/site-optimizations.json'),'utf8'))[0];
const source = fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts',rule.resourceFile),'utf8');
const output = process.env.SOULO_BAIDU_QA_OUTPUT || '/tmp/soulo-baidu-optimization-qa';
fs.mkdirSync(output,{recursive:true});
const fixture = `<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{margin:0;background:#f1f3f5;color:#222;font:16px Arial}header{padding:22px 16px;background:white;border-bottom:1px solid #eee}input{font:inherit;padding:12px;border:1px solid #ddd;border-radius:24px;width:65%}nav{padding:18px 16px;background:white;color:#666}#results{margin:0 auto}.c-result{background:white;padding:16px;margin:10px;border-radius:16px}h3{font-size:22px}a{color:#222}.c-abstract{line-height:1.6}button{padding:10px}</style></head><body>
<header><input aria-label="搜索" value="天字怎么写"><button id="search">搜索</button></header><nav>全部　图片　视频　资讯</nav>
<main id="results">
<div class="c-result" id="main" tpl="www_index" data-log='{"mu":"https://bishun.1qi.cn/5929.html"}'><h3><a id="main-title" href="/link?url=opaque" target="_blank">天的笔顺 — 一笔一画，认识汉字</a></h3><div class="c-abstract">天，汉语常用字。共 4 画，笔顺为横、横、撇、捺。查看书写示范和相关释义。</div><a id="sitelink" href="https://example.com/meaning">字词释义</a></div>
<div class="c-result" id="mobile" tpl="www_index" data-log='{"mu":"https://hanyu.baidu.com/view/天"}'><article rl-link-href="https://hanyu.baidu.com/view/天"><div data-module="title"><h3><span>天 - 汉字释义与词语用法</span></h3></div><div data-module="abstract">从字形到用法，了解「天」在常见词语中的意思。</div></article></div>
<div class="c-result" id="opaque" tpl="www_index"><h3><a href="/link?url=unknown">更多汉字书写资料</a></h3><div class="c-abstract">保留未提供目标网址的原始链接。</div></div>
<div class="c-result" id="video" tpl="vid_recommend" data-log='{"mu":"https://example.com/video"}'><h3>书写视频</h3><button id="play">播放</button><video controls style="width:100%;max-width:340px;height:120px"></video></div>
${Array.from({length:8},(_,i)=>`<div class="c-result" tpl="www_index" data-log='{"mu":"https://example.com/result-${i}"}'><h3>更多关于汉字的内容 ${i+1}</h3><div class="c-abstract">书写、释义与学习资源。</div></div>`).join('')}
<div class="c-result" id="related" tpl="recommend_list_san"><h3>大家还在搜</h3><a class="c-invoke-class" data-rgitem-type="search" data-url="https://m.baidu.com/from=home/s?word=焗和蒸的区别" href="baiduboxapp://search"><button id="related-query">焗和蒸的区别</button></a><div class="c-invoke-willshow-class">百度APP内打开</div></div>
<div class="c-result" id="app-result" tpl="note_lead"><a class="c-invoke-class" id="app-web-link" href="baiduboxapp://article" data-url="https://example.org/article">在浏览器中阅读</a></div>
</main><aside id="app-promo" style="position:fixed;bottom:0;width:100%;height:52px;background:white"><span>今日金价速看</span><span ref="open">去看看</span></aside><aside id="site-tools" style="position:fixed;bottom:80px;height:40px">帮助</aside><div id="content_left"><div class="result c-container" tpl="se_com_default" mu="https://desktop.example/article"><h3><a id="desktop-title" href="/link?url=desktopopaque">Desktop result</a></h3><div class="c-abstract">Desktop summary</div></div></div><a id="pagination" href="/s?wd=test&pn=10">下一页</a><input id="draft" value="kept">
<script>window.baiduPrompts=0;document.querySelectorAll('.c-result').forEach(card=>card.addEventListener('click',e=>{if(!e.target.closest('button,video')){window.baiduPrompts++;e.preventDefault()}}));window.playClicks=0;document.getElementById('play').onclick=()=>window.playClicks++;</script></body></html>`;
async function setup(browser,url,config={}) {
 const context=await browser.newContext({viewport:{width:390,height:844},...config});
 await context.route('**/*',route=>route.fulfill({contentType:'text/html',body:fixture}));
 await context.addInitScript(({source,rule})=>{
  window.nativeMessages=[];
  window.webkit={messageHandlers:{souloSiteOptimizationNavigate:{postMessage(body){window.nativeMessages.push(body);}}}};
  (0,eval)(source);
  window.__souloSiteOptimization.configure({...rule,enabled:true,navigationEnabled:true,loadingText:'正在打开'});
 },{source,rule});
 const page=await context.newPage();await page.goto(url);await page.waitForFunction(()=>document.getElementById('desktop-title').href==='https://desktop.example/article');return {context,page};
}
(async()=>{
 const browser=await chromium.launch({headless:true});let checks=0;
 try {
  for (const url of ['https://m.baidu.com/s?word=test','https://m.baidu.com/from=home/s?word=test','https://www.baidu.com/s?wd=test','https://baidu.com/s?wd=test']) {
   const {context,page}=await setup(browser,url);
   assert.equal(await page.locator('#main-title').getAttribute('href'),'https://bishun.1qi.cn/5929.html');
   assert.equal(await page.locator('#opaque h3 a').getAttribute('href'),'/link?url=unknown');
   assert.equal(await page.locator('#sitelink').getAttribute('href'),'https://example.com/meaning');
   assert.equal(await page.locator('#app-promo').isVisible(),false);
   assert.equal(await page.locator('#site-tools').isVisible(),true);
   assert.equal(await page.locator('#related .c-invoke-willshow-class').isVisible(),false);
   assert.equal(await page.evaluate(()=>getComputedStyle(document.body).backgroundColor),'rgb(241, 243, 245)','Do not repaint the entire website background');
   await page.locator('#related-query').click();
   assert.equal(await page.evaluate(()=>new URL(nativeMessages.filter(m=>m.url).at(-1).url).searchParams.get('word')),'焗和蒸的区别');
   assert.equal(await page.evaluate(()=>baiduPrompts),0);
   await page.locator('#app-web-link').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://example.org/article');
   assert.equal(await page.locator('#desktop-title').getAttribute('href'),'https://desktop.example/article');
   await page.locator('#desktop-title').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://desktop.example/article');
   await page.locator('#main-title').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://bishun.1qi.cn/5929.html');
   assert.equal(await page.evaluate(()=>baiduPrompts),0);
   await page.waitForSelector('.soulo-baidu-status');
   assert.equal(await page.locator('#main').getAttribute('aria-busy'),'true');
   await page.mouse.wheel(0,450);await page.waitForTimeout(100);
   assert.ok(await page.evaluate(()=>scrollY)>100,'Loading feedback must leave the page scrollable');
   await page.locator('#play').click();assert.equal(await page.evaluate(()=>playClicks),1);
   assert.equal(await page.locator('#video').getAttribute('data-soulo-baidu-card'),null);
   await page.evaluate(()=>__souloSiteOptimization.finishNavigation());
   assert.equal(await page.locator('.soulo-baidu-status').count(),0);
   await page.locator('#opaque h3 a').click();
   assert.match(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),/\/link\?url=unknown$/);
   assert.equal(await page.evaluate(()=>baiduPrompts),0,'Opaque links must bypass the site interstitial without guessing the destination');
   await page.locator('#mobile h3').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://hanyu.baidu.com/view/%E5%A4%A9');
   await page.evaluate(()=>{document.getElementById('main').dataset.log=JSON.stringify({mu:'https://new.example/changed'})});
   await page.waitForFunction(()=>document.getElementById('main-title').href==='https://new.example/changed');
   assert.equal(await page.locator('#main .soulo-baidu-source-name').textContent(),'new.example');
   await page.locator('#main-title').focus();await page.keyboard.press('Enter');
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://new.example/changed');
   const count=await page.evaluate(()=>nativeMessages.filter(m=>m.url).length);
   await page.evaluate(()=>document.getElementById('main-title').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})));
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).length),count,'Synthetic events cannot invoke native navigation');
   await page.evaluate(()=>{document.getElementById('main').setAttribute('data-log','{}')});
   await page.waitForFunction(()=>document.getElementById('main-title').getAttribute('href')==='/link?url=opaque');
   assert.equal(await page.locator('#main .soulo-baidu-source').count(),0);
   await page.evaluate(()=>__souloSiteOptimization.configure({enabled:false}));
   assert.equal(await page.locator('[data-soulo-baidu-search]').count(),0);
   assert.equal(await page.locator('.soulo-baidu-source').count(),0);
   assert.equal(await page.locator('#main-title').getAttribute('target'),'_blank');
   assert.equal(await page.locator('#app-promo').isVisible(),true);
   assert.equal(await page.locator('#related .c-invoke-willshow-class').isVisible(),true);
   assert.equal(await page.locator('#app-web-link').getAttribute('href'),'baiduboxapp://article');
   assert.equal(await page.locator('#main').getAttribute('aria-busy'),null);
   assert.equal(await page.locator('#pagination').getAttribute('href'),'/s?wd=test&pn=10');
   assert.equal(await page.locator('#draft').inputValue(),'kept');
   checks++;await context.close();
  }
  for (const [name,width,colorScheme] of [['mobile-light',390,'light'],['mobile-dark',390,'dark'],['desktop',1440,'light']]) {
   const {context,page}=await setup(browser,'https://www.baidu.com/s?wd=test',{viewport:{width,height:920},colorScheme});
   if(colorScheme==='dark') await page.evaluate(()=>document.documentElement.classList.add('soulo-force-dark'));
   await page.screenshot({path:path.join(output,name+'.png')});await context.close();checks++;
  }
  const perf = [];
  for (const enabled of [false,true]) {
   const context=await browser.newContext({viewport:{width:390,height:844}});
   const stress='<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><div id="results">'+Array.from({length:120},(_,i)=>`<div class="c-result" tpl="www_index" data-log='{"mu":"https://example.com/${i}"}'><h3>Result ${i}</h3><p>Useful search summary</p></div>`).join('')+'</div>';
   await context.route('**/*',route=>route.fulfill({contentType:'text/html; charset=utf-8',body:stress}));
   const page=await context.newPage(),cdp=await context.newCDPSession(page);
   await cdp.send('Emulation.setCPUThrottlingRate',{rate:4});
   await page.addInitScript(({source,rule,enabled})=>{(0,eval)(source);__souloSiteOptimization.configure({...rule,enabled})},{source,rule,enabled});
   await page.goto('https://m.baidu.com/s?word=performance');
   if(enabled) await page.waitForFunction(()=>document.querySelectorAll('.soulo-baidu-source').length===120);
   await page.waitForTimeout(200);
   const metrics=await page.evaluate(()=>new Promise(resolve=>{
    const deltas=[];let previous=0,frame=0,mutations=0;
    const observer=new MutationObserver(records=>{mutations+=records.filter(r=>r.type==='childList').length});
    observer.observe(document.getElementById('results'),{subtree:true,childList:true});
    function tick(now){
     if(previous)deltas.push(now-previous);previous=now;
     scrollTo(0,frame*20);
     if(frame%5===0)document.querySelectorAll('.c-result')[frame].setAttribute('data-log',JSON.stringify({mu:'https://changed.example/'+frame}));
     if(++frame<80)requestAnimationFrame(tick);else{observer.disconnect();deltas.sort((a,b)=>a-b);resolve({p95:deltas[Math.floor(deltas.length*.95)],max:deltas.at(-1),mutations})}
    }
    requestAnimationFrame(tick);
   }));
   perf.push({enabled,...metrics});
   if(enabled)assert.equal(metrics.mutations,0,'Do not change result layout while scrolling');
   await context.close();
  }
  assert.ok(perf[1].p95<=Math.max(45,perf[0].p95+15),'The rule must not add sustained scrolling frame stalls');
  fs.writeFileSync(path.join(output,'performance.json'),JSON.stringify(perf,null,2));
  console.log('4x CPU scrolling benchmark:',JSON.stringify(perf));
  console.log(`Baidu rule: ${checks} host/interaction/visual scenarios passed; screenshots: ${output}`);
 } finally {await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
