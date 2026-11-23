#!/usr/bin/env python3
"""Build crawlable directory HTML from local data; use --check in validation."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
from urllib.parse import quote, urljoin, urlparse

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'website'
BASE = 'https://soulo.dkluge.com/'
ICONS = {
    'puzzle': '<path d="M9 3h6v4a3 3 0 1 1 4 4h2v10H3V11h4a3 3 0 1 0 2-4V3Z"/>',
    'play': '<path d="m9 5 11 7-11 7V5Z"/>',
    'film': '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M7 4v16M17 4v16M3 9h4m10 0h4M3 15h4m10 0h4"/>',
    'tv': '<rect x="3" y="7" width="18" height="14" rx="3"/><path d="m8 3 4 4 4-4"/>',
    'spark': '<path d="m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3Z"/>',
    'search': '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    'cloud': '<path d="M7 18a5 5 0 0 1-1-10 7 7 0 0 1 13 1 4.5 4.5 0 0 1-1 9H7Z"/>',
    'caption': '<rect x="2" y="5" width="20" height="14" rx="3"/><path d="M10 9a3 3 0 1 0 0 6m9-6a3 3 0 1 0 0 6"/>',
    'heart': '<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0l-1 1-1-1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"/>',
    'globe': '<circle cx="12" cy="12" r="9"/><ellipse cx="12" cy="12" rx="4" ry="9"/><path d="M3 12h18"/>',
    'tool': '<path d="m14 6 4 4M4 20l4-1L20 7l-3-3L5 16l-1 4Z"/>',
    'wrench': '<path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94L14.7 6.3Z"/>',
    'grid': '<rect x="3" y="3" width="7" height="7" rx="2"/><rect x="14" y="3" width="7" height="7" rx="2"/><rect x="3" y="14" width="7" height="7" rx="2"/><rect x="14" y="14" width="7" height="7" rx="2"/>',
    'arrow': '<path d="M5 12h14m-6-6 6 6-6 6"/>',
    'external': '<path d="M8 5h11v11M19 5 5 19"/>',
    'copy': '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M15 8V4a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h4"/>',
    'code': '<path d="m8 6-6 6 6 6m8-12 6 6-6 6m-3-14-2 16"/>',
    'academic': '<path d="m2 9 10-5 10 5-10 5L2 9Zm4 2v6c4 3 8 3 12 0v-6m4-2v7"/>',
    'social': '<path d="M4 4h16v12H9l-5 4V4Z"/><path d="M8 8h8M8 12h5"/>',
    'shopping': '<path d="M5 7h14l2 14H3L5 7Z"/><path d="M8 8V6a4 4 0 0 1 8 0v2"/>',
    'image': '<rect x="3" y="3" width="18" height="18" rx="3"/><circle cx="8" cy="8" r="1"/><path d="m3 17 6-6 4 4 3-3 5 5"/>',
    'book': '<path d="M12 5c-3-2-6-2-10-1v15c4-1 7-1 10 1 3-2 6-2 10-1V4c-4-1-7-1-10 1Zm0 0v15"/>',
    'chevron': '<path d="m6 9 6 6 6-6"/>',
    'magnet': '<path d="M3 4h4v8a5 5 0 0 0 10 0V4h4v8a9 9 0 0 1-18 0V4Z"/><path d="M3 8h4m10 0h4"/>',
    'chart': '<path d="M3 3v18h18M6 15l5-5 4 3 6-7"/>',
    'headphones': '<path d="M3 14v-3a9 9 0 0 1 18 0v3"/><rect x="3" y="12" width="5" height="9" rx="2"/><rect x="16" y="12" width="5" height="9" rx="2"/>',
    'mic': '<rect x="9" y="2" width="6" height="13" rx="3"/><path d="M5 10v2a7 7 0 0 0 14 0v-2m-7 9v3m-4 0h8"/>',
    'radio': '<rect x="3" y="8" width="18" height="13" rx="3"/><path d="m5 8 14-5M7 12h4M7 16h2"/><circle cx="16" cy="15" r="2"/>',
}
SOURCE_ICONS = {
    'search.yahoo.com': 'favicons/yahoo.co.jp.png',
    'search.yahoo.co.jp': 'favicons/yahoo.co.jp.png',
    'google.co.jp': 'favicons/google.com.png',
    'zh.wikipedia.org': 'favicons/wikipedia.org.png',
    'en.wikipedia.org': 'favicons/wikipedia.org.png',
    'xueshu.baidu.com': 'favicons/baidu.com.png',
    'x.com': 'favicons/twitter.com.png',
    'search.bilibili.com': 'favicons/bilibili.com.png',
    'manga.bilibili.com': 'favicons/bilibili.com.png',
    's.weibo.com': 'favicons/weibo.com.png',
    's.m.taobao.com': 'favicons/taobao.com.png',
    'so.m.jd.com': 'favicons/jd.com.png',
    'zh.z-library.sk': 'favicons/z-library.sk.png',
    'm.iqiyi.com': 'images/movie-icons/site-iqiyi-com.png',
    'v.qq.com': 'images/movie-icons/site-v-qq-com.png',
    'so.mgtv.com': 'images/movie-icons/site-mgtv-com.png',
}


def icon(name):
    return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>'


def esc(value):
    return html.escape(str(value), quote=True)


def jsonld(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')


def navigation(page):
    template = (ROOT/'scripts/templates/navigation.html').read_text().strip()
    for key, file in [('home', 'index.html'), ('sources', 'sources.html'), ('movies', 'movies.html'), ('resources', 'resources.html'), ('reading', 'reading.html'), ('music', 'music.html'), ('stocks', 'stocks.html'), ('extensions', 'extensions.html')]:
        template = template.replace('{{'+key+'_current}}', ' aria-current="page"' if page == file else '')
    for name in ['search', 'play', 'grid', 'book', 'headphones', 'chart', 'wrench', 'puzzle']:
        template = template.replace('{{nav_'+name+'}}', icon(name))
    return template


def movie_mark(site, css_class):
    style = ''
    if path := site.get('icon'):
        assert re.fullmatch(r'images/(?:movie|reading|music|stock)-icons/[a-z0-9-]+\.png', path), path
        assert (SITE/path).is_file(), f'Missing site icon: {path}'
        content = f'<img src="{esc(path)}" width="32" height="32" alt="" loading="lazy" decoding="async" />'
        css_class += ' has-icon'
        style = f' style="--site-logo:url(\'{esc(path)}\')"'
    else:
        content = esc(site['mark'])
    return f'<span class="{css_class}" aria-hidden="true"{style}>{content}</span>'


def version_assets(html_text):
    def repl(match):
        attr, name = match.group(1), match.group(2)
        path = SITE / name
        if not path.is_file():
            return match.group(0)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()[:8]
        return f'{attr}="{name}?v={digest}"'
    return re.sub(r'\b(href|src|data-src-(?:zh|en))="([A-Za-z0-9_.-]+\.(?:css|js)|images/web/[A-Za-z0-9_.-]+\.webp)(?:\?v=[^"]*)?"', repl, html_text)


def finish_page(html_text, page):
    footer = []
    for key, name, href in [('sources', '搜索源', 'sources.html'), ('movies', '影视导航', 'movies.html'), ('resources', '资源搜索', 'resources.html'), ('reading', '阅读导航', 'reading.html'), ('music', '音乐资源', 'music.html'), ('stocks', '股票导航', 'stocks.html'), ('tools', '在线工具', 'https://www.dkluge.com/zh/bag'), ('privacy', '隐私政策', 'privacy.html'), ('support', '技术支持', 'https://www.dkluge.com/contact-us')]:
        current = ' aria-current="page"' if href == page else ''
        external = ' target="_blank" rel="noopener noreferrer"' if key == 'tools' else ''
        footer.append(f'<a href="{href}" data-i18n="{key}"{current}{external}>{name}</a>')
    html_text = re.sub(r'(<div class="footer-links">).*?(</div>)', lambda m: m[1]+''.join(footer)+m[2], html_text, flags=re.S)
    return version_assets(html_text)


def bilingual(zh, en):
    return f' data-text-zh="{esc(zh)}" data-text-en="{esc(en)}"' if en else ''


def build_existing_page(file):
    source = (SITE/file).read_text()
    replacement = navigation(file)
    if '<!-- site-nav:start -->' in source:
        source = re.sub(r'<!-- site-nav:start -->.*?<!-- site-nav:end -->', lambda _:replacement, source, count=1, flags=re.S)
    elif file == 'index.html':
        source = re.sub(r'<header class="site-header">.*?</header>', lambda _:replacement, source, count=1, flags=re.S)
    else:
        source = re.sub(r'<div class="privacy-topbar">.*?</div>\s*<nav class="privacy-directory-links".*?</nav>', lambda _:replacement, source, count=1, flags=re.S)
    if 'href="navigation.css?' not in source:
        source = source.replace('</head>', '    <link rel="stylesheet" href="navigation.css?v=20261030b" />\n</head>')
    return finish_page(source, file)


def build_directory(data, template_file, page_file, page_title, breadcrumb_name, list_name, summary_suffix, extra_tokens=None):
    sites, categories = data['sites'], data['categories']
    ids, urls = set(), set()
    for site in sites:
        assert site['id'] not in ids, f"Duplicate ID: {site['id']}"
        assert site['url'] not in urls, f"Duplicate URL: {site['url']}"
        assert site['category'] in {c['id'] for c in categories}
        assert urlparse(site['url']).scheme == 'https', site['url']
        ids.add(site['id']); urls.add(site['url'])
    links, sections = [], []
    for category in categories:
        items = [s for s in sites if s['category'] == category['id']]
        cid, name = category['id'], category['name']
        group_attr = f' data-group="{esc(category["group"])}"' if 'group' in category else ''
        links.append(f'<a class="category-link" href="#{cid}" data-category="{cid}"{group_attr}>{icon(category["icon"])}<span>{esc(name)}</span><span class="nav-count">{len(items)}</span></a>')
        cards = []
        for site in items:
            domain = urlparse(site['url']).netloc.removeprefix('www.')
            search = ' '.join([site['name'], site.get('name_en',''), domain, cid, name, category.get('name_en',''), site['description'], site.get('description_en',''), *site['tags'], *site.get('tags_en',[])]).lower()
            tags = ''.join(f'<span{bilingual(tag, site.get("tags_en",[])[i] if i < len(site.get("tags_en",[])) else None)}>{esc(tag)}</span>' for i, tag in enumerate(site['tags']))
            label = f' data-label-zh="打开{esc(site["name"])}（新标签页）" data-label-en="Open {esc(site["name_en"])} in a new tab"' if site.get('name_en') else ''
            cards.append(f'''<article class="movie-card" data-site="{site['id']}" data-search="{esc(search)}">
              <a class="movie-card-link" href="{esc(site['url'])}" target="_blank" rel="noopener noreferrer" aria-label="打开{esc(site['name'])}（新标签页）"{label}><div class="movie-card-heading">{movie_mark(site, 'site-mark')}<div><h3{bilingual(site['name'], site.get('name_en'))}>{esc(site['name'])}</h3><span class="site-domain">{esc(domain)}</span></div>{icon('external')}</div><p title="{esc(site['description'])}"{bilingual(site['description'], site.get('description_en'))}>{esc(site['description'])}</p><div class="site-tags">{tags}</div></a>
              <button class="favorite-button" type="button" data-favorite="{site['id']}" aria-label="收藏{esc(site['name'])}" aria-pressed="false" title="收藏{esc(site['name'])}">{icon('heart')}</button>
            </article>''')
        sections.append(f'''<section class="movie-category category-{cid}" id="{cid}" data-section="{cid}"{group_attr} aria-labelledby="heading-{cid}"><div class="movie-section-heading"><div>{icon(category['icon'])}<h2 id="heading-{cid}">{esc(name)}</h2><span class="section-count">{len(items)}</span></div><p>{esc(category['description'])}</p></div><div class="movie-grid">{''.join(cards)}</div></section>''')
    graph = {
        '@context': 'https://schema.org', '@graph': [
            {'@type': 'WebSite', '@id': BASE+'#website', 'name': 'Soulo', 'url': BASE},
            {'@type': 'CollectionPage', '@id': BASE+page_file+'#webpage', 'url': BASE+page_file, 'name': page_title, 'description': f'按 {len(categories)} 个分类整理的 {len(sites)} 个{summary_suffix}。', 'inLanguage': 'zh-CN', 'dateModified': data['updated'], 'isPartOf': {'@id': BASE+'#website'}, 'breadcrumb': {'@id': BASE+page_file+'#breadcrumb'}, 'mainEntity': {'@id': BASE+page_file+'#directory'}, 'about': [{'@type':'Thing', 'name':c['name']} for c in categories]},
            {'@type': 'BreadcrumbList', '@id': BASE+page_file+'#breadcrumb', 'itemListElement': [{'@type':'ListItem','position':1,'name':'Soulo','item':BASE},{'@type':'ListItem','position':2,'name':breadcrumb_name,'item':BASE+page_file}]},
            {'@type': 'ItemList', '@id': BASE+page_file+'#directory', 'name':list_name, 'numberOfItems': len(sites), 'itemListOrder':'https://schema.org/ItemListUnordered', 'itemListElement':[{'@type':'ListItem','position':i+1,'item':{'@type':'WebSite','name':s['name'],'url':s['url'],'description':s['description']}} for i,s in enumerate(sites)]},
        ]}
    tokens = {'site_count':str(len(sites)), 'category_count':str(len(categories)), 'updated':data['updated'], 'structured_data':jsonld(graph), 'category_links':''.join(links), 'catalog':'\n'.join(sections), 'navigation':navigation(page_file)}
    tokens.update({f'{key}_icon': icon(key) for key in ICONS})
    tokens['arrow'] = icon('arrow')
    tokens.update(extra_tokens or {})
    template = (ROOT/'scripts/templates'/template_file).read_text()
    for key, value in tokens.items():
        template = template.replace('{{'+key+'}}', value)
    assert not re.search(r'\{\{\w+\}\}', template), 'Unresolved template token'
    return finish_page(template, page_file)


def build_movies():
    data = json.loads((SITE/'movies.json').read_text())
    return build_directory(data, 'movies.html', 'movies.html', 'Soulo 影视导航', '影视导航', '影视网站目录', '影视网站入口，涵盖电影、剧集、动漫、字幕与影评')


def build_extensions():
    data = json.loads((SITE/'extensions.json').read_text())
    chrome = '<svg class="store-logo" viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="11" fill="#db4437"/><path d="M12 12H23a11 11 0 0 1-16.5 9.5Z" fill="#0f9d58"/><path d="m12 12-5.5 9.5A11 11 0 0 1 2.5 6.5Z" fill="#f4b400"/><circle cx="12" cy="12" r="5" fill="#4285f4" stroke="white" stroke-width="1.5"/></svg>'
    edge = '<svg class="store-logo" viewBox="0 0 24 24" aria-hidden="true"><path d="M22 15c-1 6-8 9-14 6-5-2-7-7-5-12 0 6 9 6 13 5 4-1 7-3 6 1Z" fill="#159c8b"/><path d="M3 15C-1 7 5 1 12 1c7 0 11 5 11 10 0 4-4 7-8 6 6-4 2-9-3-8-4 0-6 3-6 5 0 2 1 3 3 4-3 0-5-1-6-3Z" fill="#168bd2"/><path d="M11 9c6-1 9 4 4 8-3 1-7 0-8-2-2-3 0-6 4-6Z" fill="#0864b4"/></svg>'
    cards = []
    for item in data['extensions']:
        is_download = item['store'] == 'soulo'
        if is_download:
            assert item['url'].startswith('downloads/') and item['url'].endswith('.zip')
            assert (SITE/item['url']).is_file()
        else:
            assert item['store'] in ('chrome', 'edge') and urlparse(item['url']).scheme == 'https'
        assert (SITE/item['icon']).is_file()
        name, en = item['name'], item.get('name_en', item['name'])
        soulo_version = item.get('souloVersion', data['souloVersion'])
        logos = {'chrome': chrome, 'edge': edge, 'soulo': ''}
        store_label = {'chrome': 'Chrome', 'edge': 'Edge', 'soulo': 'Soulo'}[item['store']]
        deep_link = 'soulo://install-extension?url=' + quote(urljoin(BASE, item['url']), safe='')
        install = f'<a class="catalog-button primary" href="{esc(deep_link)}" data-install-extension="{esc(item["id"])}"{bilingual("在 Soulo 中安装", "Install in Soulo")}>在 Soulo 中安装</a>'
        if is_download:
            secondary = f'<a class="catalog-button" href="{esc(item["url"])}" download{bilingual("下载 ZIP", "Download ZIP")}>下载 ZIP</a>'
        else:
            secondary = f'<a class="catalog-button" href="{esc(item["url"])}" target="_blank" rel="noopener noreferrer"{bilingual("官方商店", "Official store")}>官方商店</a>'
        checks = ''.join(f'<li{bilingual(zh, en)}>{esc(zh)}</li>' for zh, en in zip(item['tested'], item['tested_en']))
        cards.append(f'''<article class="extension-card" id="{esc(item['id'])}">
          <div class="extension-identity"><img class="extension-logo" src="{esc(item['icon'])}" width="44" height="44" alt="" /><div><div class="extension-heading"><h2{bilingual(name, en)}>{esc(name)}</h2><span class="extension-source" title="{esc(item['storeName'])}" aria-label="{esc(item['storeName'])}">{logos[item['store']]}<span>{store_label}</span></span></div><p class="extension-subtitle"{bilingual(item['subtitle'], item['subtitle_en'])}>{esc(item['subtitle'])}</p></div></div>
          <p class="extension-description"{bilingual(item['description'], item['description_en'])}>{esc(item['description'])}</p>
          <ul class="extension-tested" aria-label="已验证功能"{label_language('已验证功能', 'Tested features')}>{checks}</ul>
          <p class="extension-version"{bilingual('验证版本：'+item['version']+' ／ Soulo '+soulo_version, 'Tested: '+item['version']+' / Soulo '+soulo_version)}>验证版本：{esc(item['version'])} ／ Soulo {esc(soulo_version)}</p>
          <div class="extension-actions">{install}{secondary}</div>
          <p class="extension-note"{bilingual(item['note'], item['note_en'])}>{esc(item['note'])}</p>
        </article>''')
    description = '查看在 Soulo 实测的浏览器扩展、验证版本和功能范围，以及对应的商店或下载入口。'
    graph = {'@context': 'https://schema.org', '@graph': [
        {'@type': 'CollectionPage', '@id': BASE+'extensions.html#webpage', 'url': BASE+'extensions.html', 'name': 'Soulo 扩展', 'description': description, 'inLanguage': ['zh-CN', 'en'], 'dateModified': data['updated']},
        {'@type': 'ItemList', 'name': '已验证的 Soulo 扩展', 'numberOfItems': len(data['extensions']), 'itemListElement': [
            {'@type': 'ListItem', 'position': i+1, 'item': {'@type': 'SoftwareApplication', 'name': item['name'], 'url': urljoin(BASE,item['url']), 'softwareVersion': item['version'], 'applicationCategory': 'BrowserApplication'}}
            for i, item in enumerate(data['extensions'])]}
    ]}
    tokens = {'kind':'extensions', 'page_title':'Soulo 扩展 - 已验证的手机浏览器扩展', 'page_description':description,
              'structured_data':jsonld(graph), 'page_locales':jsonld({'zh':{'page.title':'Soulo 扩展 - 已验证的手机浏览器扩展','page.description':description}, 'en':{'page.title':'Soulo Extensions - Tested mobile browser extensions','page.description':'Find extensions tested in Soulo, see which features were verified, and find their store or download links.'}, 'categories':{}}),
              'navigation':navigation('extensions.html'), 'catalog':'\n'.join(cards)}
    template = (ROOT/'scripts/templates/extensions.html').read_text()
    for key, value in tokens.items(): template = template.replace('{{'+key+'}}', value)
    assert not re.search(r'\{\{\w+\}\}', template), 'Unresolved extension template token'
    return finish_page(template, 'extensions.html')


def build_resources():
    magnets, pans = (json.loads((SITE/file).read_text()) for file in ('magnets.json', 'pans.json'))
    categories = [
        {**category, 'group': group, 'id': 'cloud-engine' if group == 'cloud' and category['id'] == 'engine' else category['id']}
        for group, directory in [('cloud', pans), ('magnet', magnets)]
        for category in directory['categories']
    ]
    sites = {site['url']: site for site in magnets['sites']}
    aliases = {}
    for site in pans['sites']:
        if existing := sites.get(site['url']):
            aliases[site['id']] = existing['id']
            existing['description'] += site['description']
            existing['tags'] = list(dict.fromkeys([*existing['tags'], *site['tags']]))
            continue
        if site['category'] == 'engine':
            site['category'] = 'cloud-engine'
        sites[site['url']] = site
    filters = [('all', '全部', 'All', 'grid'), ('cloud', '网盘', 'Cloud', 'cloud'), ('magnet', '磁力', 'Magnets', 'magnet')]
    buttons = ''.join(f'<button type="button" data-resource-group="{key}" aria-pressed="{str(key == "all").lower()}">{icon(mark)}<span{bilingual(zh, en)}>{zh}</span></button>' for key, zh, en, mark in filters)
    category_order = {category['id']: i for i, category in enumerate(categories)}
    data = {'updated': max(magnets['updated'], pans['updated']), 'categories': categories,
            'sites': sorted(sites.values(), key=lambda site: category_order[site['category']])}
    return build_search_directory(
        data, 'resources', '资源搜索', 'Resource Search',
        '网盘、磁力与 BT 种子搜索', 'Cloud Drives, Magnets & Torrents',
        '查找影视网盘、学习资料、磁力搜索引擎和 BT 种子站入口，支持分类筛选与收藏。',
        'Browse cloud drive directories, magnet search engines, and torrent sites.',
        '试试网站名称、域名，或“DHT”“夸克”等关键词。',
        'Try a site name, domain, or a keyword such as DHT or Quark.',
        groups=f'<div class="directory-tabs resource-types" role="group" aria-label="资源类型"{label_language("资源类型", "Resource type")}>{buttons}</div>',
        favorites=f' data-legacy-favorites="soulo-magnet-favorites soulo-pan-favorites" data-favorite-aliases="{esc(jsonld(aliases))}"',
    )


def label_language(zh, en):
    return f' data-label-zh="{esc(zh)}" data-label-en="{esc(en)}"'


def build_search_directory(data, kind, name, name_en, subtitle, subtitle_en, description, description_en,
                           empty, empty_en, groups='', favorites=''):
    zh = {
        'page.title': f'{name} - {subtitle} | Soulo', 'page.description': description,
        'directory.name': name, 'directory.total': '共 {count} 个网站',
        'directory.search': '搜索网站、域名或关键词',
        'directory.emptyDescription': empty, 'directory.emptyFavorites': '点击卡片上的爱心，收藏常用网站。',
    }
    en = {
        'page.title': f'{name_en} - {subtitle_en} | Soulo', 'page.description': description_en,
        'directory.name': name_en, 'directory.total': '{count} websites',
        'directory.search': 'Search sites, domains, or keywords',
        'directory.emptyDescription': empty_en, 'directory.emptyFavoritesTitle': 'Save your go-to sites here',
        'directory.emptyFavorites': 'Use the heart button on a card to save a website.',
    }
    locales = {'zh': zh, 'en': en, 'categories': {
        c['id']: {'zh': [c['name'], c['description']], 'en': [c['name_en'], c['description_en']]}
        for c in data['categories']
    }}
    tokens = {
        'kind': kind, 'page_title': esc(zh['page.title']), 'page_description': esc(description),
        'description_en': esc(description_en), 'directory_name': name, 'page_locales': jsonld(locales),
        'resource_groups': groups, 'legacy_favorites': favorites,
        'all_sites_button': '' if groups else f'<button id="show-all" type="button" aria-pressed="true"><span{bilingual("全部网站", "All sites")}>全部网站</span></button>',
    }
    return build_directory(data, 'search-directory.html', kind+'.html', 'Soulo '+name, name, name+'目录', subtitle+'网站入口', tokens)


def build_stocks():
    data = json.loads((SITE/'stocks.json').read_text())
    return build_search_directory(
        data, 'stocks', '股票导航', 'Stocks',
        '行情、复盘与公共数据', 'Market Quotes, Reviews & Public Data',
        '从牛盘盘开始，查 A 股与全球市场行情、复盘资料和公共统计数据。',
        'Start with 牛盘盘 for A-share market reviews, then explore global quotes and public statistics.',
        '试试网站名称、域名，或“A 股”“宏观数据”等关键词。',
        'Try a site name, domain, or a keyword such as US stocks or economic data.',
    )


def build_directory_redirect(group, fallback):
    template = (ROOT/'scripts/templates/directory-redirect.html').read_text()
    return template.replace('{{group}}', group).replace('{{fallback}}', fallback)


def build_content_directory(kind):
    data = json.loads((SITE/(kind+'.json')).read_text())
    reading = kind == 'reading'
    name = '阅读导航' if reading else '音乐资源'
    name_en = 'Reading' if reading else 'Music'
    description = f'Soulo 阅读导航整理 {len(data["sites"])} 个找书与电子书资源入口，包括 iBooks、SoBooks、苦瓜书盘，以及古籍、公开书库和阅读工具，支持分类、搜索和本地收藏。' if reading else f'Soulo 音乐资源整理 {len(data["sites"])} 个音乐搜索、无损资源、数字专辑与配乐音效入口，包括歌曲宝、HiFiBa 和 Bandcamp，支持分类、搜索和本地收藏。'
    en_description = 'Find eBooks with iBooks, SoBooks, book search engines, open libraries, and reading tools.' if reading else 'Find songs, lossless editions, downloadable albums, and background music.'
    zh = {
        'page.title': f'{name} - '+('找书搜索与电子书资源' if reading else '音乐搜索、无损下载与配乐')+' | Soulo',
        'page.description': description,
        'directory.name': name, 'directory.skip': '跳到'+name+'目录',
        'directory.heroTitle': '想读的书，<br />从这里找。' if reading else '想听的歌，<br />在这里找。',
        'directory.heroDesc': '电子书库、找书搜索与阅读工具。<br />从 iBooks、SoBooks 开始，找到想读的书。' if reading else '找歌、无损音乐、专辑与配乐。<br />把常用的音乐检索和下载入口收在一起。',
        'directory.browse': '浏览目录', 'directory.search': '搜索网站、域名或资源类型',
        'directory.all': '全部网站', 'directory.favorites': '我的收藏', 'directory.categories': '全部分类',
        'directory.reset': '查看全部',
        'directory.total': '共 {count} 个阅读网站' if reading else '共 {count} 个音乐网站',
        'directory.emptyFavorites': '点击网站卡片上的爱心，建立自己的阅读收藏夹。' if reading else '点击网站卡片上的爱心，建立自己的音乐收藏夹。',
        'directory.emptyDescription': '试试网站名称、域名，或“电子书”“EPUB”“古籍”等关键词。' if reading else '试试网站名称、域名，或“无损”“MP3”“配乐”等关键词。',
        'directory.toolsPrompt': '还有文件需要处理？', 'directory.toolsLink': '打开在线工具',
        'directory.aboutTitle': '把常用的找书入口，收在一起。' if reading else '把找歌和下载入口，放在顺手的地方。',
        'directory.about': '从电子书库、找书搜索到阅读工具，按用途浏览并前往对应网站。点击爱心保存常用入口，收藏保存在当前浏览器。' if reading else '从音乐检索、无损资源到专辑和配乐，按用途浏览并前往对应网站。点击爱心保存常用入口，收藏保存在当前浏览器。',
        'directory.faqTitle': '如何保存常用入口？',
        'directory.faq': '点击卡片上的爱心即可收藏，在“我的收藏”中查看。收藏只保存在当前浏览器，清除网站数据后会丢失。',
    }
    en = {
        'page.title': ('Reading Directory - Book Search & eBook Resources' if reading else 'Music Resources - Search, Lossless Downloads & Soundtracks')+' | Soulo',
        'page.description': en_description,
        'directory.name': name_en, 'directory.skip': 'Skip to the '+name_en.lower()+' directory',
        'directory.heroTitle': 'Find the book<br />you want to read.' if reading else 'Find the music<br />you want to hear.',
        'directory.heroDesc': 'eBook collections, book search, and reading tools.<br />Start with iBooks, SoBooks, and more.' if reading else 'Song search, lossless music, albums, and soundtracks.<br />Keep your favorite music resources together.',
        'directory.browse': 'Browse directory', 'directory.search': 'Search websites, domains, or resource types',
        'directory.all': 'All websites', 'directory.favorites': 'My favorites', 'directory.categories': 'All categories',
        'directory.reset': 'View all',
        'directory.total': '{count} reading websites' if reading else '{count} music & audio websites',
        'directory.emptyFavoritesTitle': 'Save your go-to reading sites here' if reading else 'Save your go-to music sites here',
        'directory.emptyFavorites': 'Use the heart icon on a card to build your reading list.' if reading else 'Use the heart icon on a card to build your listening list.',
        'directory.emptyDescription': 'Try a website name, domain, or keywords like eBooks, EPUB, or Classics.' if reading else 'Try a website name, domain, or keywords like Lossless, MP3, or Soundtracks.',
        'directory.toolsPrompt': 'Need to work with files?', 'directory.toolsLink': 'Open online tools',
        'directory.aboutTitle': 'Keep your favorite book resources together.' if reading else 'Keep music search and downloads close.',
        'directory.about': 'Browse eBook collections, book search engines, and reading tools by purpose. Use the heart to save your favorite resources in this browser.' if reading else 'Browse song search, lossless collections, albums, and soundtracks by purpose. Use the heart to save your favorite resources in this browser.',
        'directory.faqTitle': 'How do I save a website?',
        'directory.faq': 'Use the heart button on a card, then open My favorites. Favorites are stored in this browser and are removed when website data is cleared.',
    }
    locales = {'zh':zh, 'en':en, 'categories':{c['id']:{'zh':[c['name'], c['description']], 'en':[c['name_en'], c['description_en']]} for c in data['categories']}}
    artwork = '<svg viewBox="0 0 400 280" fill="none"><circle cx="204" cy="140" r="108" fill="currentColor" opacity=".1"/><path d="M115 152v-28a89 89 0 0 1 178 0v28" stroke="currentColor" stroke-width="14" stroke-linecap="round"/><rect x="102" y="140" width="43" height="77" rx="18" fill="var(--surface)" stroke="currentColor" stroke-width="3"/><rect x="263" y="140" width="43" height="77" rx="18" fill="var(--surface)" stroke="currentColor" stroke-width="3"/><path d="M174 130v29m20-48v65m20-56v47m20-30v17" stroke="currentColor" stroke-width="6" stroke-linecap="round"/></svg>'
    if reading:
        artwork = '<img class="app-illustration" src="images/web/illustration-reading.webp" width="720" height="480" loading="lazy" decoding="async" alt="" />'
    extra = {'kind':kind, 'page_title':esc(zh['page.title']), 'page_description':esc(description), 'directory_name':name, 'hero_title':zh['directory.heroTitle'], 'hero_description':zh['directory.heroDesc'], 'artwork':artwork, 'page_locales':jsonld(locales), 'favorites_key':f'soulo-{kind}-favorites', 'about_title':zh['directory.aboutTitle'], 'about_description':zh['directory.about'], 'faq_title':zh['directory.faqTitle'], 'faq_description':zh['directory.faq']}
    summary = '找书与电子书资源入口，涵盖 iBooks、SoBooks、古籍与阅读工具' if reading else '音乐资源入口，涵盖歌曲检索、无损资源、数字专辑与配乐音效'
    return build_directory(data, 'content-directory.html', kind+'.html', 'Soulo '+name, name, name+'目录', summary, extra)


def build_sources():
    data = json.loads((SITE/'sources.json').read_text())
    entries, categories = data['sources'], data['categories']
    category_ids = {c['id'] for c in categories}
    assert len(entries) == len({s['url'] for s in entries}), 'Duplicate source URL'
    assert all(s['category'] in category_ids and '%@' in s['url'] for s in entries)
    sections, links = [], []
    for category in categories:
        cid, name = category['id'], category['name']
        items = [(i, source) for i, source in enumerate(entries) if source['category'] == cid]
        links.append(f'<a class="source-category-link" href="#category-{cid}" data-source-category="{cid}">{icon(category["icon"])}<span>{esc(name)}</span><span class="source-nav-count">{len(items)}</span></a>')
        cards = []
        for index, source in items:
            n, u = source['name'], source['url']
            domain = urlparse(u).netloc.removeprefix('www.')
            icon_candidates = [f'images/source-icons/{domain}.png', *(f'favicons/{domain}.{ext}' for ext in ['png', 'ico'])]
            local_icon = next((path for path in icon_candidates if (SITE/path).is_file()), SOURCE_ICONS.get(domain))
            # This site's cached ICO is a solid white placeholder. Prefer a
            # readable label until a page-specific or PNG favicon is supplied.
            if local_icon == 'favicons/pianbs.com.ico':
                local_icon = None
            words = re.findall(r'[A-Za-z]+', n)
            mark = ''.join(word[0] for word in words[:2]).upper() if words else n[0]
            if local_icon:
                assert (SITE/local_icon).is_file(), f'Missing source icon: {local_icon}'
                avatar_tag = f'<span class="source-avatar has-icon" aria-hidden="true" style="--site-logo:url(\'{esc(local_icon)}\')"><span class="source-fallback">{esc(mark)}</span><img src="{esc(local_icon)}" width="18" height="18" alt="" loading="lazy" decoding="async" /></span>'
            else:
                avatar_tag = f'<span class="source-avatar" aria-hidden="true">{esc(mark)}</span>'
            cards.append(f'''<article class="source-card" data-index="{index}" data-search="{esc(f'{n} {domain} {cid} {name}'.lower())}"><a class="source-card-link" href="{esc(u.replace('%@',quote('Soulo')))}" target="_blank" rel="noopener noreferrer" aria-label="预览{esc(n)}的搜索（新标签页）" title="{esc(n)} · {esc(domain)}">{avatar_tag}<div class="source-info"><h3 class="source-name">{esc(n)}</h3><span class="source-domain">{esc(domain)}</span></div></a><button class="source-copy" type="button" aria-label="复制{esc(n)}的配置" title="复制{esc(n)}">{icon('copy')}</button></article>''')
        sections.append(f'''<section class="source-category" id="category-{cid}" data-category="{cid}" aria-labelledby="heading-{cid}"><div class="category-head"><div><h2 id="heading-{cid}">{icon(category['icon'])}<em class="category-title-text">{esc(name)}</em><span class="category-count">{len(items)}</span></h2><p class="category-desc">{esc(category['description'])}</p></div><button class="category-copy" type="button" aria-label="复制{esc(name)}分类的可见搜索源">{icon('copy')}<em class="category-copy-text">复制</em></button></div><div class="source-grid">{''.join(cards)}</div></section>''')
    graph = {'@context':'https://schema.org','@graph':[
        {'@type':'CollectionPage','@id':BASE+'sources.html#webpage','url':BASE+'sources.html','name':'Soulo 搜索源目录','inLanguage':'zh-CN','isPartOf':{'@id':BASE+'#website'},'mainEntity':{'@id':BASE+'sources.html#catalog'},'breadcrumb':{'@id':BASE+'sources.html#breadcrumb'}},
        {'@type':'BreadcrumbList','@id':BASE+'sources.html#breadcrumb','itemListElement':[{'@type':'ListItem','position':1,'name':'Soulo','item':BASE},{'@type':'ListItem','position':2,'name':'搜索源','item':BASE+'sources.html'}]},
        {'@type':'ItemList','@id':BASE+'sources.html#catalog','name':'可导入的搜索源','numberOfItems':len(entries),'itemListElement':[{'@type':'ListItem','position':i+1,'name':s['name'],'url':s['url'].replace('%@','Soulo')} for i,s in enumerate(entries)]}
    ]}
    tokens = {'source_count':str(len(entries)), 'category_count':str(len(categories)), 'structured_data':jsonld(graph), 'source_data':jsonld(data), 'category_links':''.join(links), 'catalog':'\n'.join(sections), 'navigation':navigation('sources.html')}
    tokens.update({f'{key}_icon':icon(key) for key in ICONS})
    template = (ROOT/'scripts/templates/sources.html').read_text()
    for key, value in tokens.items():
        template = template.replace('{{'+key+'}}', value)
    assert not re.search(r'\{\{\w+\}\}', template), 'Unresolved source template token'
    return finish_page(template, 'sources.html')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    changed = []
    for file, content in [('movies.html', build_movies()), ('extensions.html', build_extensions()), ('resources.html', build_resources()), ('stocks.html', build_stocks()), ('magnets.html', build_directory_redirect('magnet', 'engine')), ('pans.html', build_directory_redirect('cloud', 'cloud-engine')), ('reading.html', build_content_directory('reading')), ('music.html', build_content_directory('music')), ('sources.html', build_sources()), ('index.html', build_existing_page('index.html')), ('privacy.html', build_existing_page('privacy.html'))]:
        target = SITE/file
        if not target.exists() or target.read_text() != content:
            changed.append(file)
            if not args.check:
                target.write_text(content)
    if args.check and changed:
        parser.exit(1, 'Out of date: '+', '.join(changed)+'. Run python3 scripts/build_website.py\n')
    print('Website directories are up to date.' if args.check else 'Built crawlable directories, redirects, and shared navigation.')


if __name__ == '__main__':
    main()
