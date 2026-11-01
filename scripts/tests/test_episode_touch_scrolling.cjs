/* Real touch gestures against the production episode dock runtime.
 * SOULO_PLAYWRIGHT_MODULE=/path/to/playwright node scripts/tests/test_episode_touch_scrolling.cjs
 */
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const source=fs.readFileSync(process.env.SOULO_EPISODE_SOURCE_PATH||path.join(root,'Soulo/Resources/UserScripts/episode-detector.js'),'utf8');
const overlay=fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts/overlay-controls.js'),'utf8');
const html=`<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;height:100%;overflow:hidden;font:16px system-ui}#page{height:100%;overflow:auto;background:#fff}article{padding:16px;height:100px;border-bottom:1px solid #eee}h1{font-size:24px;padding:16px}</style>
<main id="page"><h1>盐焗 · 搜索结果</h1><ul class="episode-list"><li><a href="/watch/1">第1集</a></li><li><a href="/watch/2">第2集</a></li></ul>${Array.from({length:45},(_,i)=>`<article><h2>盐焗资料 ${i}</h2><p>烹饪方法与相关内容</p></article>`).join('')}</main>`;
async function drag(cdp,x,y,dx,dy){
 await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x,y,id:1}]});
 for(let i=1;i<=12;i++)await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:x+dx*i/12,y:y+dy*i/12,id:1}]});
 await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
}
(async()=>{const browser=await chromium.launch({headless:true});try{
 const context=await browser.newContext({viewport:{width:390,height:844},hasTouch:true,isMobile:true});
 await context.route('**/*',r=>r.fulfill({contentType:'text/html;charset=utf-8',body:html}));
 await context.addInitScript(()=>{
  window.registrations=[];window.messages=[];
  const add=EventTarget.prototype.addEventListener;
  EventTarget.prototype.addEventListener=function(type,handler,options){
   if(this===window||this===document||this===document.documentElement||this===document.body)
    registrations.push({type,passive:typeof options==='object'?options.passive:undefined});
   return add.call(this,type,handler,options);
  };
  window.webkit={messageHandlers:{souloEpisodes:{postMessage(body){messages.push(body)}}}};
 });
 const page=await context.newPage();await page.goto('https://fixture.test/s?word=盐焗');
 await page.evaluate(code=>{registrations=[];(0,eval)(code);window.episodeRegistrations=[...registrations]},overlay+'\n'+source);
 await page.waitForSelector('#soulo-episode-dock');
 const blocking=await page.evaluate(()=>episodeRegistrations.filter(e=>['touchstart','touchmove','wheel'].includes(e.type)&&e.passive===false));
 console.log('Root scroll-blocking listeners:',JSON.stringify(blocking));
 assert.deepEqual(blocking,[],'An inactive or visible dock must never impose a blocking touch handler on the whole page');
 const cdp=await context.newCDPSession(page);
 await drag(cdp,90,650,0,-330);await page.waitForTimeout(220);
 assert.ok(await page.locator('#page').evaluate(e=>e.scrollTop)>100,'A finger must scroll the nested Baidu-style results container');
 await page.evaluate(()=>new Promise(resolve=>{let last=-1,stable=0,checks=0;const timer=setInterval(()=>{const now=document.getElementById('page').scrollTop;stable=now===last?stable+1:0;last=now;if(stable>=6||++checks>=180){clearInterval(timer);resolve()}},16)}));
 const before=await page.locator('#page').evaluate(e=>e.scrollTop),box=await page.locator('#soulo-episode-dock').boundingBox();
 await drag(cdp,box.x+box.width/2,box.y+box.height/2,-box.x+30,-70);await page.waitForTimeout(120);
 assert.ok(await page.evaluate(()=>messages.some(m=>m.action==='position'&&m.edge==='left')),'The dock must still drag and persist its position');
 assert.ok(Math.abs(await page.locator('#page').evaluate(e=>e.scrollTop)-before)<2,'Dragging the dock must not scroll the page');
 const opens=await page.evaluate(()=>messages.filter(m=>m.action==='open').length);
 await page.locator('#soulo-episode-dock').tap();
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='open').length),opens+1,'A tap must open the picker exactly once');
 await page.evaluate(()=>__souloEpisodes.configure({enabled:false}));
 await page.waitForSelector('#soulo-episode-dock',{state:'detached'});
 const noDockBefore=await page.locator('#page').evaluate(e=>e.scrollTop);
 await drag(cdp,90,650,0,-250);await page.waitForTimeout(150);
 assert.ok(await page.locator('#page').evaluate(e=>e.scrollTop)>noDockBefore+100,'Scrolling must remain available without a dock');
 console.log('Episode touch scrolling: nested scrolling, passive root handlers, dock drag/tap and disabled state passed');
 await context.close();
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
