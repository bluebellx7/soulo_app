// Verify batched dynamic-media discovery without changing playback or navigation.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const swift=fs.readFileSync(path.join(root,'Soulo/Source/Services/ReadingTools/WebMediaPlaybackBridge.swift'),'utf8');
const sources=[...swift.matchAll(/static let source = #"""\n([\s\S]*?)\n\s*"""#/g)].map(match=>match[1]);
const source=sources.find(value=>value.includes('window.__souloMediaCheckpoint'));
assert.ok(source);
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
  const page=await browser.newPage();
  await page.setContent('<main id="content"></main>');
  await page.evaluate(()=>{
   window.work={scans:0,pauses:0};window.messages=[];
   const query=Element.prototype.querySelectorAll,pause=HTMLMediaElement.prototype.pause;
   Element.prototype.querySelectorAll=function(selector){if(selector==='video,audio')work.scans++;return query.call(this,selector)};
   HTMLMediaElement.prototype.pause=function(){work.pauses++;return pause.call(this)};
   window.webkit={messageHandlers:{souloMediaSession:{postMessage(body){messages.push(body)}}}};
  });
  await page.evaluate(source);
  await page.evaluate(()=>window.__souloMediaRestore([]));
  await page.evaluate(()=>{
   const parent=document.createElement('article');parent.id='batch';content.append(parent);
   for(let i=0;i<400;i++){const child=document.createElement('section');parent.append(child);child.append(document.createTextNode('Result '+i))}
   const video=document.createElement('video');video.id='v';video.src='https://example.test/clip.mp4';parent.children[250].append(video);
   const audio=document.createElement('audio');audio.id='a';audio.src='https://example.test/clip.mp3';parent.children[399].append(audio);
  });
  await page.waitForFunction(()=>window.__souloMediaCheckpoint().length===2);
  const work=await page.evaluate(()=>window.work);
  console.log('Media session batch workload:',JSON.stringify(work));
  assert.equal(work.scans,1,'One mutation batch must scan a new parent subtree only once');
  assert.deepEqual(await page.evaluate(()=>window.__souloMediaCheckpoint().map(m=>m.src)),['https://example.test/clip.mp4','https://example.test/clip.mp3']);
  await page.evaluate(()=>{work.scans=0;work.pauses=0;v.remove();a.remove()});
  await page.waitForFunction(()=>window.__souloMediaCheckpoint().length===0);
  assert.equal(await page.evaluate(()=>work.pauses),2,'Removal-only mutations must still pause and release detached media');
  await page.evaluate(()=>{
   work.scans=0;work.pauses=0;
   const transient=document.createElement('article');content.append(transient);
   const video=document.createElement('video');transient.append(video);transient.remove();
  });
  await page.waitForTimeout(30);
  assert.deepEqual(await page.evaluate(()=>work),{scans:0,pauses:0},'Already detached new subtrees need no discovery or playback work');
  await page.evaluate(()=>{
   const a=document.createElement('article'),b=document.createElement('article');content.append(a,b);
   a.innerHTML='<video id="reused"></video>';b.innerHTML='<audio></audio>';
  });
  await page.waitForFunction(()=>window.__souloMediaCheckpoint().length===2);
  const before=await page.evaluate(()=>messages.length);
  await page.evaluate(()=>document.getElementById('reused').dispatchEvent(new Event('play')));
  assert.equal(await page.evaluate(()=>messages.length),before+1,'Discovery must register each media listener once');
  await page.evaluate(()=>{const video=document.getElementById('reused');video.remove();content.append(video)});
  await page.waitForTimeout(30);
  const moved=await page.evaluate(()=>messages.length);
  await page.evaluate(()=>document.getElementById('reused').dispatchEvent(new Event('play')));
  assert.equal(await page.evaluate(()=>messages.length),moved+1,'Moving a connected video must not duplicate its listeners');
  console.log('Media session: bounded batch scanning, all media discovery, removal cleanup and moved media passed');
 }finally{await browser.close()}
})().catch(error=>{console.error(error);process.exitCode=1});
