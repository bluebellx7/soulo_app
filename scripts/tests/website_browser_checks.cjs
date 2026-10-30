/* Run against a local website server. See website/README.md. */
const assert = require('node:assert/strict');
const {chromium} = require(process.env.SOULO_PLAYWRIGHT_MODULE || 'playwright');
const base = process.env.SOULO_WEBSITE_URL || 'http://127.0.0.1:8765';
const errors = [];

async function main() {
  const options = {headless: true};
  if (process.env.SOULO_CHROME_PATH) options.executablePath = process.env.SOULO_CHROME_PATH;
  const browser = await chromium.launch(options);
  try {
    const context = await browser.newContext({viewport: {width: 1440, height: 1000}, locale: 'zh-CN', colorScheme: 'light', permissions: ['clipboard-read','clipboard-write']});
    // Local QA must not send production analytics pageviews.
    await context.route('https://hm.baidu.com/**', route => route.abort());
    context.on('page', page => page.on('pageerror', error => errors.push(error.message)));
    const page = await context.newPage();
    await page.goto(base+'/movies.html');
    const total = await page.locator('.movie-card').count();
    assert.equal(total, 58);
    const visible = () => page.locator('.movie-card:visible').count();
    await page.locator('#movie-search').fill('PBKAN.COM');
    assert.equal(await visible(), 1);
    assert.match(await page.locator('.movie-card:visible h3').innerText(), /片吧影视/);
    await page.locator('#movie-search').fill('电影 下载');
    assert.ok(await visible() > 0);
    await page.locator('#movie-search').fill('this-site-does-not-exist');
    assert.equal(await visible(), 0);
    assert.ok(await page.locator('#movie-empty').isVisible());
    await page.locator('#reset-filters').click();
    assert.equal(await visible(), total);
    await page.locator('[data-category="anime"]').click();
    assert.equal(await visible(), 7);
    assert.equal(await page.locator('[data-section]:visible').count(), 1);
    await page.locator('[data-category="all"]').click();
    await page.locator('[data-favorite="pbpbw"]').click();
    await page.locator('#show-favorites').click();
    assert.equal(await visible(), 1);
    await page.reload();
    assert.equal(await page.locator('[data-favorite="pbpbw"]').getAttribute('aria-pressed'), 'true');
    await page.locator('#show-favorites').click();
    assert.equal(await visible(), 1);
    await page.locator('[data-favorite="pbpbw"]').click();
    assert.equal(await visible(), 0);
    assert.match(await page.locator('#empty-title').innerText(), /喜欢的入口/);
    await page.locator('#reset-filters').click();
    await page.keyboard.press('/');
    assert.equal(await page.locator('#movie-search').evaluate(e => e === document.activeElement), true);
    await page.keyboard.type('字幕');
    await page.keyboard.press('Escape');
    assert.equal(await visible(), total);
    await page.locator('#theme-toggle').click();
    assert.equal(await page.locator('html').getAttribute('data-resolved-theme'), 'dark');
    await page.reload();
    assert.equal(await page.locator('html').getAttribute('data-resolved-theme'), 'dark');
    const cardBackground = await page.locator('.movie-card').first().evaluate(e => getComputedStyle(e).backgroundColor);
    assert.equal(cardBackground, 'rgb(27, 28, 36)');
    await page.goto(base+'/');
    assert.equal(await page.locator('.nav-links a[href="#features"]').count(), 0);
    assert.equal(await page.locator('.nav-links a[href="movies.html"]').count(), 1);
    await page.locator('#language-toggle').click();
    assert.equal(await page.locator('html').getAttribute('lang'), 'en');
    assert.equal(await page.locator('.nav-links a[href="movies.html"]').innerText(), 'Movies');
    await page.goto(base+'/sources.html');
    const sourceCount = await page.locator('.source-card').count();
    assert.ok(sourceCount > 50);
    await page.locator('#filterInput').fill('GitHub');
    assert.equal(await page.locator('.source-card:visible').count(), 1);
    await page.locator('#copyVisibleButton').click();
    const copied = JSON.parse(await page.evaluate(() => navigator.clipboard.readText()));
    assert.equal(copied.length, 1);
    assert.equal(copied[0].name, 'GitHub');
    assert.ok(copied[0].url.includes('%@'));
    for (const width of [320, 360, 390, 768, 1280]) {
      await page.setViewportSize({width, height: 900});
      for (const file of ['', 'movies.html', 'sources.html', 'privacy.html']) {
        await page.goto(base+'/'+file);
        const dimensions = await page.evaluate(() => ({viewport:innerWidth, content:document.documentElement.scrollWidth}));
        assert.ok(dimensions.content <= dimensions.viewport, `${file || 'index.html'} overflows at ${width}px: ${dimensions.content}`);
      }
    }
    const nojs = await browser.newContext({javaScriptEnabled: false, viewport: {width: 1280, height: 900}});
    const plain = await nojs.newPage();
    await plain.goto(base+'/movies.html');
    assert.equal(await plain.locator('.movie-card:visible').count(), total);
    assert.equal(await plain.locator('.movie-category:visible').count(), 10);
    assert.equal(await plain.locator('.favorite-button:visible').count(), 0);
    await plain.goto(base+'/sources.html');
    assert.equal(await plain.locator('.source-card:visible').count(), sourceCount);
    // Corrupt or unavailable local storage must not prevent browsing.
    const restricted = await browser.newContext();
    await restricted.route('https://hm.baidu.com/**', route => route.abort());
    await restricted.addInitScript(() => {
      Storage.prototype.getItem = () => { throw new DOMException('Blocked', 'SecurityError'); };
      Storage.prototype.setItem = () => { throw new DOMException('Blocked', 'SecurityError'); };
    });
    const privatePage = await restricted.newPage();
    privatePage.on('pageerror', error => errors.push(error.message));
    await privatePage.goto(base+'/movies.html');
    await privatePage.locator('[data-favorite="pbpbw"]').click();
    assert.match(await privatePage.locator('#movie-toast').innerText(), /仅在本页有效/);
    await privatePage.locator('#show-favorites').click();
    assert.equal(await privatePage.locator('.movie-card:visible').count(), 1);
    assert.deepEqual(errors, []);
    console.log(`PASS: ${total} movie sites; search, categories, favorites, themes, language, clipboard, 5 viewport widths, no-JS and blocked storage.`);
  } finally {
    await browser.close();
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
