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
<div class="c-result" id="main" tpl="www_index" data-log='{"mu":"https://bishun.1qi.cn/5929.html"}'><h3><a id="main-title" href="/link?url=opaque" target="_blank">天的笔顺 — 一笔一画，认识汉字</a></h3><div class="c-abstract">天，汉语常用字。共 4 画，笔顺为横、横、撇、捺。查看书写示范和相关释义。</div><a id="sitelink" href="https://example.com/meaning">字词释义</a><a id="expand" href="#full">展开</a></div>
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
  (0,eval)(source);window.__souloSiteOptimization.configure({...rule,enabled:true,navigationEnabled:true});
 },{source,rule});
 const page=await context.newPage();await page.goto(url);
 await page.waitForSelector('#soulo-baidu-search-style',{state:'attached'});return {context,page};
}
(async()=>{
 const browser=await chromium.launch({headless:true,channel:process.env.SOULO_CHROME_CHANNEL});let checks=0;
 try {
  for (const url of ['https://m.baidu.com/s?word=test','https://m.baidu.com/from=home/s?word=test','https://www.baidu.com/s?wd=test','https://baidu.com/s?wd=test']) {
   const {context,page}=await setup(browser,url);
   assert.equal(await page.locator('#main-title').getAttribute('href'),'/link?url=opaque');
   assert.equal(await page.locator('#main-title').getAttribute('target'),'_blank');
   assert.equal(await page.locator('#desktop-title').getAttribute('href'),'/link?url=desktopopaque');
   assert.equal(await page.locator('#app-promo').isVisible(),false);
   assert.equal(await page.locator('#site-tools').isVisible(),true);
   assert.equal(await page.locator('#related .c-invoke-willshow-class').isVisible(),false);
   assert.equal(await page.evaluate(()=>getComputedStyle(document.body).backgroundColor),'rgb(241, 243, 245)');
   await page.locator('#related-query').click();
   assert.equal(await page.evaluate(()=>new URL(nativeMessages.filter(m=>m.url).at(-1).url).searchParams.get('word')),'焗和蒸的区别');
   await page.locator('#app-web-link').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://example.org/article');
   await page.locator('#desktop-title').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://desktop.example/article');
   await page.locator('#main-title').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://bishun.1qi.cn/5929.html');
   assert.equal(await page.evaluate(()=>baiduPrompts),0,'Trusted activation avoids the site app/interstitial handler');
   assert.equal(await page.locator('.soulo-baidu-status,[aria-busy=true]').count(),0);
   await page.mouse.wheel(0,450);await page.waitForTimeout(100);
   assert.ok(await page.evaluate(()=>scrollY)>100);
   await page.locator('#play').click();assert.equal(await page.evaluate(()=>playClicks),1);
   await page.locator('#mobile h3').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://hanyu.baidu.com/view/%E5%A4%A9');
   await page.evaluate(()=>document.getElementById('main').dataset.log=JSON.stringify({mu:'https://new.example/changed'}));
   assert.equal(await page.locator('#main-title').getAttribute('href'),'/link?url=opaque');
   await page.locator('#main-title').focus();await page.keyboard.press('Enter');
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://new.example/changed','Only the activated result reads current metadata');
   const count=await page.evaluate(()=>nativeMessages.filter(m=>m.url).length);
   await page.evaluate(()=>document.getElementById('main-title').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})));
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).length),count);
   await page.locator('#main-title').click({modifiers:['Control']});
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).length),count);
   await page.evaluate(()=>{
    window.ruleMutations=[];new MutationObserver(records=>ruleMutations.push(...records)).observe(document.documentElement,{subtree:true,attributes:true,childList:true});
    const next=document.getElementById('main').cloneNode(true);next.id='dynamic';next.querySelector('a').id='dynamic-title';next.dataset.log=JSON.stringify({mu:'https://dynamic.example/'});document.getElementById('results').append(next);
   });
   await page.evaluate(()=>getSelection()?.removeAllRanges());await page.bringToFront();await page.locator('#dynamic-title').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).at(-1).url),'https://dynamic.example/');
   await page.evaluate(()=>ruleMutations=[]);
   for(let i=0;i<4;i++)await page.mouse.wheel(0,300);
   await page.waitForTimeout(350);
   assert.equal(await page.evaluate(()=>ruleMutations.length),0,'Scrolling and idle time must not mutate results or overlays');
   const beforeExpand=await page.evaluate(()=>nativeMessages.filter(m=>m.url).length);
   await page.locator('#main #expand').click();
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).length),beforeExpand,'In-page controls must not become native page loads');
   await page.evaluate(()=>__souloSiteOptimization.configure({enabled:false}));
   assert.equal(await page.locator('[data-soulo-baidu-search],#soulo-baidu-search-style').count(),0);
   assert.equal(await page.locator('#app-promo').isVisible(),true);
   assert.equal(await page.locator('#main-title').getAttribute('href'),'/link?url=opaque');
   assert.equal(await page.locator('#main-title').getAttribute('target'),'_blank');
   assert.equal(await page.locator('#draft').inputValue(),'kept');
   checks++;await context.close();
  }
  for (const [selector,expected] of [['#opaque h3 a','https://m.baidu.com/link?url=unknown'],['#sitelink','https://example.com/meaning']]) {
   const {context,page}=await setup(browser,'https://m.baidu.com/s?word=test');
   const request=page.waitForRequest(r=>r.isNavigationRequest()&&r.url()===expected);
   await page.locator(selector).click(); await request;
   // The new document's init script starts with no native navigation messages.
   await page.waitForLoadState('domcontentloaded');
   assert.equal(await page.evaluate(()=>nativeMessages.filter(m=>m.url).length),0,'Ordinary HTTP activation must stay in the browser engine');
   await context.close();checks++;
  }
  for (const [name,width,colorScheme] of [['mobile-light',390,'light'],['mobile-dark',390,'dark'],['desktop',1440,'light']]) {
   const {context,page}=await setup(browser,'https://www.baidu.com/s?wd=test',{viewport:{width,height:920},colorScheme});
   if(colorScheme==='dark')await page.evaluate(()=>{document.documentElement.classList.add('soulo-force-dark');document.head.insertAdjacentHTML('beforeend','<style>body{background:#111;color:#e8eaed}.c-result,header,nav{background:#1c1c1f;color:#e8eaed}</style>')});
   await page.screenshot({path:path.join(output,name+'.png')});await context.close();checks++;
  }
  console.log(`Baidu: ${checks} host, trusted-click, dynamic-content, scroll, restore and visual checks passed`);
 }finally{await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
