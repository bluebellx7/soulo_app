const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.SOULO_PLAYWRIGHT_MODULE||'playwright');
const root=path.resolve(__dirname,'../..');
const swift=fs.readFileSync(path.join(root,'Soulo/Source/Views/WebView/WebViewScripts.swift'),'utf8');
const source=swift.match(/static let accessibilityEnhancements = """\n([\s\S]*?)\n\s*"""/)[1].replace(/\\\\/g,'\\');
(async()=>{const browser=await chromium.launch({headless:true});try{
 const page=await browser.newPage();
 await page.setContent(Array.from({length:100},(_,i)=>`<article class="search-result"><h3>Result ${i}</h3><a href="/article">Read article</a></article>`).join('')+'<div id="dynamic"></div>');
 await page.evaluate(()=>{
  window.reads=0;window.wrote=false;window.readsAfterWrite=0;
  const rect=Element.prototype.getBoundingClientRect,set=Element.prototype.setAttribute;
  Element.prototype.getBoundingClientRect=function(){reads++;if(wrote)readsAfterWrite++;return rect.call(this)};
  Element.prototype.setAttribute=function(...args){wrote=true;return set.apply(this,args)};
 });
 await page.evaluate(source);
 assert.equal(await page.locator('[data-soulo-accessible-result]').count(),100);
 assert.equal(await page.evaluate(()=>readsAfterWrite),0,'Accessibility metadata must be written after all geometry reads');
 await page.evaluate(()=>{reads=0;wrote=false;__souloAccessibilityScan()});
 assert.equal(await page.evaluate(()=>reads),0,'An unchanged, labelled page must not repeat layout reads');
 await page.evaluate(()=>{reads=0;wrote=false;document.getElementById('dynamic').innerHTML='<div class="search-result"><h3>New result</h3><a href="/new">New link</a></div><div onclick="void 0">Open details</div>'});
 await page.waitForSelector('[data-soulo-accessible-result][aria-label="New result"]');
 assert.ok(await page.evaluate(()=>reads)<8,'A small addition must not rescan every result');
 assert.equal(await page.getByRole('button',{name:'Open details'}).count(),1);
 assert.equal(await page.locator('a[href="/new"]').getAttribute('href'),'/new');
 console.log('Accessibility: batch writes, no repeated layout on labelled content, dynamic regions and clickable semantics passed');
}finally{await browser.close()}})().catch(error=>{console.error(error);process.exitCode=1});
