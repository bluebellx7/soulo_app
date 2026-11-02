// Exercise large result lists, dynamic players and open shadow roots.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const swift=fs.readFileSync(path.join(root,'Soulo/Source/Services/ReadingTools/WebMediaPlaybackBridge.swift'),'utf8');
const source=swift.match(/static let source = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const overlay=fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts/overlay-controls.js'),'utf8');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const empty=await browser.newPage();
 await empty.setContent('<main>'+Array.from({length:80},(_,i)=>`<p id="text${i}">Text</p>`).join('')+'</main>');
 await empty.evaluate(()=>{
  window.work={timers:0,frames:0,scans:0};
  const timeout=setTimeout,raf=requestAnimationFrame,query=Element.prototype.querySelectorAll;
  window.setTimeout=(callback,delay,...args)=>{if(delay===150)work.timers++;return timeout(callback,delay,...args)};
  window.requestAnimationFrame=callback=>{work.frames++;return raf(callback)};
  Element.prototype.querySelectorAll=function(selector){if(selector==='*')work.scans++;return query.call(this,selector)};
 });
 await empty.evaluate(overlay+'\n'+source);await empty.waitForTimeout(300);
 await empty.evaluate(()=>Object.keys(work).forEach(key=>work[key]=0));
 for(let i=0;i<20;i++){
  await empty.evaluate(i=>document.getElementById('text'+i).style.opacity='.9',i);
  await empty.waitForTimeout(20);
 }
 await empty.waitForTimeout(250);
 assert.deepEqual(await empty.evaluate(()=>work),{timers:0,frames:0,scans:0},'Text-only animation must not wake video tools');
 await empty.evaluate(()=>{
  const parent=document.createElement('article');document.body.append(parent);
  for(let i=0;i<400;i++){const child=document.createElement('div');parent.append(child);child.textContent='New text'}
 });
 await empty.waitForTimeout(300);
 assert.equal(await empty.evaluate(()=>work.scans),1,'A batch must scan each new subtree once');
 await empty.evaluate(()=>{
  window.scaleReports=[];
  window.webkit={messageHandlers:{souloVideoOrientation:{postMessage(body){if(body.action==='viewport')scaleReports.push(body)}}}};
  window.__souloVideoOrientation.setContentZoom(1);
  for(let i=0;i<50;i++)dispatchEvent(new Event('resize'));
 });
 assert.equal(await empty.evaluate(()=>scaleReports.length),1,'Unchanged viewport geometry must not repeatedly cross the native bridge');
 await empty.evaluate(()=>window.__souloVideoOrientation.setPageScale(9,1));
 assert.equal(await empty.evaluate(()=>window.__souloOverlayControls.metrics().scale),1,'The owning document must use its actual CSS scale, not a stale native estimate');
 await empty.evaluate(()=>window.__souloVideoOrientation.setContentZoom(0.5));
 assert.equal(await empty.evaluate(()=>scaleReports.at(-1).scale),0.5);
 assert.equal(await empty.evaluate(()=>scaleReports.at(-1).zoom),0.5);
 await empty.close();
 const page=await browser.newPage({viewport:{width:390,height:844}});
 await page.setContent('<style>article{height:600px}video{width:320px;height:180px}</style>'+Array.from({length:100},(_,i)=>`<article><video id="v${i}" playsinline></video></article>`).join(''));
 await page.evaluate(()=>{
  window.geometryReads=0;const rect=HTMLVideoElement.prototype.getBoundingClientRect;
  HTMLVideoElement.prototype.getBoundingClientRect=function(){geometryReads++;return rect.call(this)};
  window.webkit={messageHandlers:{souloVideoOrientation:{postMessage(){}}}};
 });
 await page.evaluate(overlay+'\n'+source);
 await page.waitForSelector('[data-video-toggle]',{state:'visible'});
 assert.ok(await page.locator('[data-soulo-video-rotate]').count()<5,'Offscreen videos must not eagerly build a toolbar');
 await page.evaluate(()=>geometryReads=0);
 await page.mouse.wheel(0,200);await page.waitForTimeout(150);
 assert.ok(await page.evaluate(()=>geometryReads)<20,'Scrolling should measure nearby videos, not the whole result list');
 await page.evaluate(()=>{scrollTo(0,0);document.getElementById('v0').parentElement.style.visibility='hidden'});
 await page.waitForFunction(()=>[...document.querySelectorAll('[data-soulo-video-rotate]')].filter(n=>getComputedStyle(n).display!=='none').length===1);
 await page.evaluate(()=>document.getElementById('v0').parentElement.style.visibility='visible');
 await page.locator('#v80').scrollIntoViewIfNeeded();
 await page.waitForFunction(()=>document.getElementById('v80').hasAttribute('data-soulo-media-id'));
 const id=await page.locator('#v80').getAttribute('data-soulo-media-id');
 await page.waitForFunction(id=>getComputedStyle([...document.querySelectorAll('[data-soulo-video-rotate]')].find(n=>n.dataset.souloMediaID===id)).display==='flex',id);
 await page.evaluate(()=>document.getElementById('v80').remove());
 await page.waitForFunction(id=>![...document.querySelectorAll('[data-soulo-video-rotate]')].find(n=>n.dataset.souloMediaID===id),id);
 await page.evaluate(()=>{
  scrollTo(0,0);const host=document.createElement('div');host.id='shadow-host';document.body.prepend(host);
  host.attachShadow({mode:'open'}).innerHTML='<video playsinline style="width:320px;height:180px"></video>';
 });
 await page.waitForFunction(()=>document.getElementById('shadow-host').shadowRoot.querySelector('video').hasAttribute('data-soulo-media-id'));
 console.log('Video overlays: lazy controls, bounded scroll reads, hidden ancestors, later results, removal and shadow players passed');
}finally{await browser.close()}})().catch(error=>{console.error(error);process.exitCode=1});
