#!/usr/bin/env node
// Run with Playwright available through SOULO_PLAYWRIGHT_MODULE, or installed locally.
// Raw screenshots remain untouched. HTML/CSS compose the marketing artwork.
// Historical 2026-10-06 layout. Future artwork must follow the user's references
// in /Users/shunfei.z/Desktop/Screenshot/Soulo and
// docs/design/app-store-screenshot-style.md; update this template before reuse.
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require(process.env.SOULO_PLAYWRIGHT_MODULE || 'playwright');
const root = path.resolve(process.argv[2]);
const sourceRoot = path.resolve(process.argv[3] || process.cwd());
const icon = `data:image/png;base64,${(await fs.readFile(path.join(sourceRoot, 'Soulo/Assets.xcassets/AppIcon.appiconset/AppIcon.png'))).toString('base64')}`;
const escape = s => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
const imageURL = async file => `data:image/png;base64,${(await fs.readFile(file)).toString('base64')}`;
const copy = {
  'zh-Hans': {
    dir: '中文', title: '把搜索，<br>变成探索。', search: '一处搜索，<br>更多发现。',
    tagline: '多平台搜索 · 清爽浏览 · 随身阅读',
    features: [
      ['从一个搜索框，<br>开启更多发现', '搜索、网址和常用平台，触手可及'],
      ['常用平台，<br>一处直达', '管理搜索平台，建立自己的搜索入口'],
      ['下载与文件，<br>随手整理', '导入、分类、预览和 Wi-Fi 传输'],
      ['把好内容，<br>留给阅读', '连续阅读 · 字体与主题 · 阅读进度'],
      ['清爽浏览，<br>隐私由你掌控', '隐私模式 · HTTPS · 移除跟踪参数']
    ],
    category: ['搜索与浏览', '搜索平台', '文件管理', '随身阅读', '隐私设置'],
    preview: 'Duo 布局预览 · 待真实设备替换'
  },
  'en-US': {
    dir: 'English', title: 'Follow your<br>curiosity.', search: 'One search.<br>More to discover.',
    tagline: 'Multi-platform search. Browsing. Reading.',
    features: [
      ['One search.<br>More to discover.', 'Search, URLs and favorite platforms, together.'],
      ['Your favorites.<br>All in one place.', 'Build a search experience that feels like yours.'],
      ['Keep your files.<br>Close at hand.', 'Import, organize, preview and transfer over Wi-Fi.'],
      ['Make room<br>for a good read.', 'Continuous reading. Fonts, themes and progress.'],
      ['Browse with<br>more control.', 'Private browsing. HTTPS. Fewer tracking parameters.']
    ],
    category: ['SEARCH & BROWSE', 'SEARCH PLATFORMS', 'YOUR FILES', 'READING', 'PRIVACY'],
    preview: 'Duo layout preview · Replace with device capture'
  }
};
const browser = await chromium.launch({executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true});
const manifest = [];
const style = `
*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}body{color:#29271f;background:#f8f6ef;font-family:Georgia,'Times New Roman','Songti SC',serif;-webkit-font-smoothing:antialiased}
.canvas{position:relative;width:100%;height:100%;overflow:hidden;background:radial-gradient(ellipse at 85% 75%,#ead9ad70 0,transparent 55%),#f8f6ef}
.ring{position:absolute;border:1px solid #cdb87955;border-radius:50%;pointer-events:none}.brand{display:flex;align-items:center;gap:26px;font-size:68px;letter-spacing:-2px}.brand img{width:112px;height:112px;border-radius:26px;border:1px solid #ece4d2}.brand span{font-weight:400}
.sans{font-family:'Avenir Next','PingFang SC',sans-serif}.kicker{color:#9a7c3b;font-family:'Avenir Next','PingFang SC',sans-serif;font-weight:600;letter-spacing:4px;font-size:32px}.headline{font-weight:500;letter-spacing:-4px;line-height:1.16;margin:0}.zh .headline{font-family:'PingFang SC',sans-serif;font-weight:600;letter-spacing:-3px}.sub{font-family:'Avenir Next','PingFang SC',sans-serif;color:#777264;line-height:1.45}
.screen{position:absolute;border:9px solid #2f302d;border-radius:66px;background:#2f302d;overflow:hidden;box-shadow:0 28px 60px #4a3f2525}.screen img{display:block;width:100%;height:auto}.tablet{border-radius:40px;border-width:14px}.line{width:100px;height:4px;background:#baa56b}.footer{position:absolute;font-family:'Avenir Next','PingFang SC',sans-serif;font-size:26px;color:#a2987e;letter-spacing:2px}
`;
const rings = (x, y, size) => [0, 1, 2].map(i=>`<div class="ring" style="left:${x-i*90}px;top:${y-i*90}px;width:${size+i*180}px;height:${size+i*180}px"></div>`).join('');
const screen = (src, x, y, w, tablet=false, rotation=0) => `<div class="screen ${tablet?'tablet':''}" style="left:${x}px;top:${y}px;width:${w}px;transform:rotate(${rotation}deg)"><img src="${src}"></div>`;
async function render(relative, width, height, body, language, type, sourceFiles=[]) {
  const destination = path.join(root, relative);
  await fs.mkdir(path.dirname(destination), {recursive:true});
  const page = await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
  await page.setContent(`<html lang="${language}"><meta charset="utf-8"><style>${style}</style><body class="${language==='zh-Hans'?'zh':''}"><div class="canvas">${body}</div></body></html>`);
  await page.evaluate(async()=>{await document.fonts.ready; await Promise.all([...document.images].map(i=>i.decode()));});
  await page.screenshot({path:destination,omitBackground:false});
  await page.close();
  manifest.push({file:relative,width,height,language,type,sourceFiles:sourceFiles.map(file=>path.relative(root,file)),status:'ready'});
}
for (const [language, c] of Object.entries(copy)) {
  const raw = path.join(root,'源文件','原始截屏',language);
  const phonePaths = ['01-home','02-platforms','03-files','04-reader','05-privacy'].map(n=>path.join(raw,'iPhone',`${n}.png`));
  const phone = await Promise.all(phonePaths.map(imageURL));
  const ipadPaths = ['01-home','02-platforms','03-files','04-reader'].map(n=>path.join(raw,'iPad',`${n}.png`));
  const ipad = await Promise.all(ipadPaths.map(imageURL));
  const titleBody = `${rings(2030,30,1550)}
    <div style="position:absolute;left:220px;top:180px" class="brand"><img src="${icon}"><span>Soulo</span></div>
    <div style="position:absolute;left:230px;top:510px;width:1480px"><div class="kicker">${language==='zh-Hans'?'你的多平台搜索浏览器':'YOUR MULTI-PLATFORM BROWSER'}</div><h1 class="headline" style="font-size:${language==='zh-Hans'?182:190}px;margin-top:50px">${c.title}</h1><div class="line" style="margin-top:65px"></div><div class="sub" style="font-size:47px;margin-top:42px">${c.tagline}</div></div>
    ${screen(phone[2],1930,315,525,false,-6)}${screen(phone[3],3020,350,525,false,7)}${screen(phone[0],2440,145,615)}
    <div class="footer" style="left:230px;bottom:115px">SEARCH. EXPLORE. SOULO.</div>`;
  await render(`${c.dir}/01-标题素材/标题-3840x1646.png`,3840,1646,titleBody,language,'title',[phonePaths[2],phonePaths[3],phonePaths[0]]);
  const searchBody = `${rings(980,240,950)}<div class="brand" style="position:absolute;left:115px;top:95px;font-size:56px"><img src="${icon}" style="width:88px;height:88px;border-radius:20px"><span>Soulo</span></div>
    <div style="position:absolute;left:125px;top:380px;width:850px"><div class="kicker" style="font-size:23px">${language==='zh-Hans'?'搜索 · 浏览 · 阅读':'SEARCH · BROWSE · READ'}</div><h1 class="headline" style="font-size:${language==='zh-Hans'?108:105}px;margin-top:40px">${c.search}</h1><div class="line" style="margin-top:56px"></div><div class="sub" style="font-size:28px;max-width:700px;margin-top:33px">${c.tagline}</div></div>
    ${screen(phone[2],1430,330,390,false,5)}${screen(phone[0],1000,160,470,false,-4)}
    <div class="footer" style="left:125px;bottom:90px;font-size:19px">SEARCH. EXPLORE. SOULO.</div>`;
  await render(`${c.dir}/02-搜索结果素材/搜索-1920x1280.png`,1920,1280,searchBody,language,'search_result',[phonePaths[0],phonePaths[2]]);
  for(let i=0;i<5;i++) {
    const [headline, sub] = c.features[i];
    const body = `${rings(650,970,1400)}<div class="kicker" style="position:absolute;left:95px;top:82px;font-size:28px">SOULO / ${c.category[i]}</div>
      <h1 class="headline" style="position:absolute;left:95px;top:152px;width:1050px;font-size:${language==='zh-Hans'?87:88}px">${headline}</h1>
      <div class="sub" style="position:absolute;left:95px;top:382px;width:1040px;font-size:${language==='zh-Hans'?30:29}px">${escape(sub)}</div>
      ${screen(phone[i],125,508,956)}<div class="footer" style="right:65px;bottom:30px;font-size:18px">SOULO</div>`;
    await render(`${c.dir}/03-iPhone-6.3英寸/${String(i+1).padStart(2,'0')}-${['首页','平台','文件','阅读','隐私'][i]}-1206x2622.png`,1206,2622,body,language,'iphone', [phonePaths[i]]);
  }
  for(let i=0;i<4;i++) {
    const [headline, sub] = c.features[i];
    const body = `${rings(1100,850,1900)}<div class="kicker" style="position:absolute;left:155px;top:82px;font-size:28px">SOULO / ${c.category[i]}</div>
      <h1 class="headline" style="position:absolute;left:155px;top:147px;width:1770px;font-size:${language==='zh-Hans'?97:108}px">${headline.replace('<br>',' ')}</h1>
      <div class="sub" style="position:absolute;left:155px;top:308px;width:1770px;font-size:36px">${escape(sub)}</div>
      ${screen(ipad[i],207,441,1650,true)}<div class="footer" style="right:95px;bottom:45px;font-size:21px">SOULO</div>`;
    await render(`${c.dir}/05-iPad-13英寸/${String(i+1).padStart(2,'0')}-${['首页','平台','文件','阅读'][i]}-2064x2752.png`,2064,2752,body,language,'ipad', [ipadPaths[i]]);
  }
  const previews = [
    ['01-outer-home',1398,2034,language==='zh-Hans'?'首页，随心探索':'A home for your curiosity',language==='zh-Hans'?'外屏 · 首页预览':'COVER DISPLAY / HOME PREVIEW',194,330,1010],
    ['02-inner-platforms',2007,2853,language==='zh-Hans'?'更多空间，更多选择':'More space. More possibilities.',language==='zh-Hans'?'内屏 · 搜索平台预览':'INNER DISPLAY / PLATFORM PREVIEW',205,390,1597],
    ['03-inner-reader',2853,2007,language==='zh-Hans'?'展开一段阅读时光':'Open up a moment to read.',language==='zh-Hans'?'内屏横向 · 阅读预览':'INNER DISPLAY / READING PREVIEW',265,260,2323]
  ];
  for (const [name,w,h,title,category,x,y,imageWidth] of previews) {
    const file = path.join(raw,'Duo布局预览',`${name}.png`);
    const src = await imageURL(file);
    const fontSize = w === 1398 ? (language==='zh-Hans'?77:66) : w === 2007 ? 96 : 86;
    const body = `${rings(w*0.7,h*0.55,w)}
      <div class="kicker" style="position:absolute;left:${w*.068}px;top:62px;font-size:${w===1398?28:32}px">SOULO / ${category}</div>
      <h1 class="headline" style="position:absolute;left:${w*.068}px;top:${w===2853?125:132}px;width:${w*.87}px;font-size:${fontSize}px">${escape(title)}</h1>
      ${screen(src,x,y,imageWidth)}
      <div class="sans" style="position:absolute;left:${w*.055}px;bottom:35px;width:${w*.89}px;padding:23px 30px;background:#ede0bd;border:1px solid #c3a76b;border-radius:18px;color:#826027;text-align:center;font-size:${w===1398?30:35}px;font-weight:600">${c.preview}</div>`;
    await render(`${c.dir}/04-iPhone-Duo-预览-不可上传/${name}-${w}x${h}.png`,w,h,body,language,'duo_layout_preview',[file]);
    manifest[manifest.length-1].status = 'preview_needs_real_duo_capture';
  }
}
await browser.close();
await fs.mkdir(path.join(root,'源文件'),{recursive:true});
await fs.writeFile(path.join(root,'源文件','素材清单.json'),JSON.stringify(manifest,null,2));
console.log(`Rendered ${manifest.length} assets: 22 ready and 6 Duo layout previews in ${root}`);
