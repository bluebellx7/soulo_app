const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const swift=fs.readFileSync(path.join(root,'Soulo/Source/Services/ReadingTools/WebMediaPlaybackBridge.swift'),'utf8');
const source=swift.match(/static let source = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const overlay=fs.readFileSync(path.join(root,'Soulo/Resources/UserScripts/overlay-controls.js'),'utf8');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const page=await browser.newPage({viewport:{width:390,height:844}});
 await page.setContent('<meta name="viewport" content="width=device-width,initial-scale=1"><video id="v" playsinline style="width:340px;height:200px"></video>');
 await page.evaluate(()=>{
  window.messages=[];window.nativeCalls=0;window.documentCalls=0;
  window.mediaReady=4;
  window.webkit={messageHandlers:{souloVideoOrientation:{postMessage(body){messages.push(body)}}}};
  const v=document.getElementById('v');
  Object.defineProperties(v,{readyState:{get:()=>mediaReady},videoWidth:{get:()=>640},videoHeight:{get:()=>360},paused:{get:()=>false,configurable:true}});
  v.webkitEnterFullscreen=()=>{nativeCalls++;v.dispatchEvent(new Event('webkitbeginfullscreen'))};
  v.requestFullscreen=()=>{documentCalls++;return Promise.resolve()};
 });
 await page.evaluate(overlay+'\n'+source);await page.waitForSelector('[data-video-toggle]',{state:'visible'});
 await page.evaluate(()=>document.querySelector('[data-video-toggle]').click());
 assert.equal(await page.evaluate(()=>nativeCalls),0);
 await page.locator('[data-video-toggle]').click();
 await page.getByRole('button',{name:'Fullscreen',exact:true}).click();
 assert.equal(await page.evaluate(()=>nativeCalls),1);
 assert.equal(await page.locator('#v').evaluate(v=>v.style.cssText),'width: 340px; height: 200px;','Native fullscreen must not resize the site video or trigger its player rebuild');
 assert.equal(await page.evaluate(()=>documentCalls),0,'Prefer native AVKit over the page fullscreen API on iOS');
 assert.deepEqual(await page.evaluate(()=>messages.filter(m=>['prepare','begin','end','failed'].includes(m.action)).map(m=>m.action)),['prepare','begin']);
 await page.evaluate(()=>{document.dispatchEvent(new Event('fullscreenchange'));document.getElementById('v').dispatchEvent(new Event('webkitpresentationmodechanged'))});
 await page.waitForTimeout(200);
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='end').length),0,'Page fullscreen changes must not restore portrait during a native video transition');
 await page.evaluate(()=>document.getElementById('v').dispatchEvent(new Event('webkitendfullscreen')));
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='end').length),1);
 assert.equal(await page.locator('#v').evaluate(v=>v.style.width),'340px');
 // Later playlist/feed entries may still be loading when the user taps.
 await page.evaluate(()=>{
  mediaReady=0;window.playCalls=0;window.entryAttempts=0;
  const v=document.getElementById('v');
  Object.defineProperty(v,'paused',{get:()=>true,configurable:true});
  v.play=()=>{playCalls++;return new Promise(resolve=>window.finishPlay=resolve)};
  v.webkitEnterFullscreen=()=>{entryAttempts++;if(mediaReady<2)throw new Error('Video is not ready');nativeCalls++;v.dispatchEvent(new Event('webkitbeginfullscreen'))};
 });
 await page.locator('[data-video-toggle]').click();
 await page.getByRole('button',{name:'Fullscreen',exact:true}).click();
 assert.equal(await page.evaluate(()=>playCalls),1);
 assert.equal(await page.evaluate(()=>entryAttempts),0,'Never transfer an unloaded later video to AVKit');
 await page.evaluate(()=>{mediaReady=4;document.getElementById('v').dispatchEvent(new Event('loadeddata'));finishPlay()});
 await page.waitForFunction(()=>nativeCalls===2);
 assert.equal(await page.evaluate(()=>entryAttempts),1);
 await page.evaluate(()=>document.getElementById('v').dispatchEvent(new Event('webkitendfullscreen')));
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='failed').length),0);
 // When AVKit rejects entry, try the supported document API in the same action.
 await page.evaluate(()=>{
  const v=document.getElementById('v');Object.defineProperty(v,'paused',{get:()=>false,configurable:true});
  v.webkitEnterFullscreen=()=>{throw new Error('Native entry unavailable')};
  Object.defineProperty(document,'fullscreenEnabled',{value:true,configurable:true});
  v.requestFullscreen=()=>{documentCalls++;Object.defineProperty(document,'fullscreenElement',{value:v,configurable:true});document.dispatchEvent(new Event('fullscreenchange'));return Promise.resolve()};
 });
 await page.locator('[data-video-toggle]').click();
 await page.getByRole('button',{name:'Fullscreen',exact:true}).click();
 assert.equal(await page.evaluate(()=>documentCalls),1,'Native rejection must not prevent a supported fullscreen fallback');
 await page.evaluate(()=>{Object.defineProperty(document,'fullscreenElement',{value:null,configurable:true});document.dispatchEvent(new Event('fullscreenchange'))});
 // Leaving while a late video loads must cancel its deferred fullscreen entry.
 await page.evaluate(()=>{
  mediaReady=0;const v=document.getElementById('v');Object.defineProperty(v,'paused',{get:()=>true,configurable:true});
  v.play=()=>new Promise(resolve=>window.finishPlay=resolve);
 });
 await page.locator('[data-video-toggle]').click();
 await page.getByRole('button',{name:'Fullscreen',exact:true}).click();
 const before=await page.evaluate(()=>messages.filter(m=>m.action==='prepare').length);
 await page.evaluate(()=>{dispatchEvent(new Event('pagehide'));mediaReady=4;document.getElementById('v').dispatchEvent(new Event('loadeddata'));finishPlay()});
 await page.waitForTimeout(50);
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='prepare').length),before,'A completed old load must not reopen fullscreen after navigation');
 assert.equal(await page.evaluate(()=>messages.filter(m=>m.action==='failed').length),0);
 console.log('Web video fullscreen: unchanged player geometry, lazy media, native fallback, exit events and cancelled navigation passed');
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});
