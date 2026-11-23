const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.SOULO_PLAYWRIGHT_MODULE || 'playwright');

const extension = path.resolve(__dirname, '../../extensions/search-platform-capture');
const origin = 'https://soulo-search.test';

async function checkPlacement(browser, anchoredAt) {
    const page = await browser.newPage({ viewport: { width: 390, height: 520 }, locale: 'zh-CN' });
    try {
        await page.addInitScript({ path: path.join(extension, 'capture.js') });
        await page.route(`${origin}/**`, route => route.fulfill({
            contentType: 'text/html; charset=utf-8',
            body: `<!doctype html><meta name="viewport" content="width=device-width, initial-scale=1">
                <style>form{position:fixed;${anchoredAt}:10px;left:10px;right:10px;display:flex}
                input{box-sizing:border-box;min-width:0;flex:1;height:48px;font:16px system-ui}</style>
                <form action="/results"><input type="search" name="q" aria-label="网页搜索"><button>搜索</button></form>`,
        }));
        await page.goto(origin);
        const field = page.getByRole('searchbox');
        await field.focus();
        await page.keyboard.type('%s');
        await page.getByRole('button', { name: '搜索' }).click();
        await page.waitForURL(`${origin}/results?q=%25s`);

        const banner = page.locator('[data-soulo-search-platform]');
        for (const width of [390, 320]) {
            await page.setViewportSize({ width, height: 520 });
            await banner.waitFor({ state: 'visible' });
            await page.waitForFunction(() => {
                const banner = document.querySelector('[data-soulo-search-platform]').getBoundingClientRect();
                const field = document.querySelector('input').getBoundingClientRect();
                return banner.right <= innerWidth && (banner.top >= field.bottom || banner.bottom <= field.top);
            });
            const frame = await banner.boundingBox();
            const input = await field.boundingBox();
            assert.ok(frame.y >= 0 && frame.y + frame.height <= 520);
            if (anchoredAt === 'top') assert.ok(frame.y > input.y + input.height);
            else assert.ok(frame.y + frame.height < input.y);
            await field.click();
            assert.equal(await field.evaluate(input => document.activeElement === input), true);
        }
    } finally {
        await page.close();
    }
}

async function checkInstructions(browser, locale, heading) {
    const page = await browser.newPage({ viewport: { width: 320, height: 440 }, locale });
    try {
        await page.route(`${origin}/**`, route => {
            const name = new URL(route.request().url()).pathname.slice(1);
            return route.fulfill({
                contentType: name.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8',
                body: fs.readFileSync(path.join(extension, name), 'utf8'),
            });
        });
        const manifest = JSON.parse(fs.readFileSync(path.join(extension, 'manifest.json'), 'utf8'));
        await page.goto(`${origin}/${manifest.action.default_popup}`);
        await page.getByRole('heading', { name: heading }).waitFor();
        assert.equal(await page.locator('main:visible code').innerText(), '%s');
        assert.equal(await page.locator('main:visible li').count(), 3);
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 320);
    } finally {
        await page.close();
    }
}

(async () => {
    const browser = await chromium.launch({ executablePath: process.env.SOULO_CHROME_PATH });
    try {
        await checkPlacement(browser, 'top');
        await checkPlacement(browser, 'bottom');
        await checkInstructions(browser, 'zh-CN', '怎样添加搜索平台');
        await checkInstructions(browser, 'en-US', 'How to add a search platform');
        console.log('Search platform banner placement and packaged instructions passed.');
    } finally {
        await browser.close();
    }
})().catch(error => {
    console.error(error);
    process.exitCode = 1;
});
