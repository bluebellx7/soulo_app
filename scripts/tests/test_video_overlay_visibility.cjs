// Exercise large result lists, dynamic players and open shadow roots.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const swift=fs.readFileSync(path.join(root,'Soulo/Source/Services/ReadingTools/WebMediaPlaybackBridge.swift'),'utf8');
const source=swift.match(/static let source = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const overlay=fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts/overlay-controls.js'),'utf8');
(async()=>{const browser=await chromium.launch({headless:true});try{
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
