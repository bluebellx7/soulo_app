#!/usr/bin/env python3
"""Build crawlable directory HTML from local data; use --check in validation."""
import argparse
import html
import json
from pathlib import Path
import re
from urllib.parse import quote, urlparse

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'website'
BASE = 'https://soulo.dkluge.com/'
ICONS = {
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
}


def icon(name):
    return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>'


def esc(value):
    return html.escape(str(value), quote=True)


def jsonld(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')


def navigation(page):
    template = (ROOT/'scripts/templates/navigation.html').read_text().strip()
    for key, file in [('home', 'index.html'), ('sources', 'sources.html'), ('movies', 'movies.html')]:
        template = template.replace('{{'+key+'_current}}', ' aria-current="page"' if page == file else '')
    return template


def movie_mark(site, css_class):
    style = ''
    if path := site.get('icon'):
        assert re.fullmatch(r'images/movie-icons/[a-z0-9-]+\.png', path), path
        assert (SITE/path).is_file(), f'Missing movie icon: {path}'
        content = f'<img src="{esc(path)}" width="32" height="32" alt="" loading="lazy" decoding="async" />'
        css_class += ' has-icon'
        style = f' style="--site-logo:url(\'{esc(path)}\')"'
    else:
        content = esc(site['mark'])
    return f'<span class="{css_class}" aria-hidden="true"{style}>{content}</span>'


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
    source = source.replace('site-ui.js?v=20261030', 'site-ui.js?v=20261030b') if 'site-ui.js?v=20261030b' not in source else source
    return source


def build_movies():
    data = json.loads((SITE / 'movies.json').read_text())
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
        links.append(f'<a class="category-link" href="#{cid}" data-category="{cid}">{icon(category["icon"])}<span>{esc(name)}</span><span class="nav-count">{len(items)}</span></a>')
        cards = []
        for site in items:
            domain = urlparse(site['url']).netloc.removeprefix('www.')
            search = ' '.join([site['name'], domain, name, site['description'], *site['tags']]).lower()
            tags = ''.join(f'<span>{esc(tag)}</span>' for tag in site['tags'])
            cards.append(f'''<article class="movie-card" data-site="{site['id']}" data-search="{esc(search)}">
              <a class="movie-card-link" href="{esc(site['url'])}" target="_blank" rel="noopener noreferrer" aria-label="打开{esc(site['name'])}（新标签页）"><div class="movie-card-heading">{movie_mark(site, 'site-mark')}<div><h3>{esc(site['name'])}</h3><span class="site-domain">{esc(domain)}</span></div>{icon('external')}</div><p title="{esc(site['description'])}">{esc(site['description'])}</p><div class="site-tags">{tags}</div></a>
              <button class="favorite-button" type="button" data-favorite="{site['id']}" aria-label="收藏{esc(site['name'])}" aria-pressed="false" title="收藏{esc(site['name'])}">{icon('heart')}</button>
            </article>''')
        sections.append(f'''<section class="movie-category category-{cid}" id="{cid}" data-section="{cid}" aria-labelledby="heading-{cid}"><div class="movie-section-heading"><div>{icon(category['icon'])}<h2 id="heading-{cid}">{esc(name)}</h2><span class="section-count">{len(items)}</span></div><p>{esc(category['description'])}</p></div><div class="movie-grid">{''.join(cards)}</div></section>''')
    featured = ''.join(f'<a class="quick-pick" href="{esc(s["url"])}" target="_blank" rel="noopener noreferrer">{movie_mark(s, "quick-mark")}<span><strong>{esc(s["name"])}</strong><span>{esc(s["tags"][0])}入口</span></span>{icon("external")}</a>' for s in sites if s.get('featured'))
    source_names = {'https://i8k.tv/': 'i8K 影视导航', 'https://www.weidus.com/favorites/mfys': '微度导航', 'https://tv.baozangdh.com/': '影视宝藏导航', 'https://ailongmiao.com/movie/': '龙喵影视导航', 'https://cn1.xgcartoon.com/': '西瓜卡通'}
    source_links = '、'.join(f'<a href="{esc(url)}" target="_blank" rel="noopener noreferrer">{esc(source_names.get(url, urlparse(url).netloc))}</a>' for url in data['sources'])
    graph = {
        '@context': 'https://schema.org', '@graph': [
            {'@type': 'WebSite', '@id': BASE+'#website', 'name': 'Soulo', 'url': BASE},
            {'@type': 'CollectionPage', '@id': BASE+'movies.html#webpage', 'url': BASE+'movies.html', 'name': 'Soulo 影视导航', 'description': f'按 {len(categories)} 个分类整理的 {len(sites)} 个影视网站入口，涵盖电影、剧集、动漫、字幕与影评。', 'inLanguage': 'zh-CN', 'dateModified': data['updated'], 'isPartOf': {'@id': BASE+'#website'}, 'breadcrumb': {'@id': BASE+'movies.html#breadcrumb'}, 'mainEntity': {'@id': BASE+'movies.html#directory'}, 'citation': data['sources'], 'about': [{'@type':'Thing', 'name':c['name']} for c in categories]},
            {'@type': 'BreadcrumbList', '@id': BASE+'movies.html#breadcrumb', 'itemListElement': [{'@type':'ListItem','position':1,'name':'Soulo','item':BASE},{'@type':'ListItem','position':2,'name':'影视导航','item':BASE+'movies.html'}]},
            {'@type': 'ItemList', '@id': BASE+'movies.html#directory', 'name':'影视网站目录', 'numberOfItems': len(sites), 'itemListOrder':'https://schema.org/ItemListUnordered', 'itemListElement':[{'@type':'ListItem','position':i+1,'item':{'@type':'WebSite','name':s['name'],'url':s['url'],'description':s['description']}} for i,s in enumerate(sites)]},
        ]}
    tokens = {'site_count':str(len(sites)), 'category_count':str(len(categories)), 'updated':data['updated'], 'structured_data':jsonld(graph), 'featured_sites':featured, 'source_links':source_links, 'category_links':''.join(links), 'catalog':'\n'.join(sections), 'navigation':navigation('movies.html')}
    tokens.update({f'{key}_icon': icon(key) for key in ICONS})
    tokens['arrow'] = icon('arrow')
    template = (ROOT/'scripts/templates/movies.html').read_text()
    for key, value in tokens.items():
        template = template.replace('{{'+key+'}}', value)
    assert not re.search(r'\{\{\w+\}\}', template), 'Unresolved template token'
    return template


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
            local_icon = next((f'favicons/{domain}.{ext}' for ext in ['png','ico'] if (SITE/f'favicons/{domain}.{ext}').exists()), None)
            words = re.findall(r'[A-Za-z]+', n)
            mark = ''.join(word[0] for word in words[:2]).upper() if words else n[0]
            avatar = f'<img src="{local_icon}" width="25" height="25" alt="" loading="lazy" />' if local_icon else esc(mark)
            cards.append(f'''<article class="source-card" data-index="{index}" data-search="{esc(f'{n} {domain} {name}'.lower())}"><a class="source-card-link" href="{esc(u.replace('%@',quote('Soulo')))}" target="_blank" rel="noopener noreferrer" aria-label="预览{esc(n)}的搜索（新标签页）"><span class="source-avatar" aria-hidden="true">{avatar}</span><div class="source-info"><h3 class="source-name">{esc(n)}</h3><span class="source-domain">{esc(domain)}</span></div>{icon('external')}</a><button class="source-copy" type="button" aria-label="复制{esc(n)}的配置" title="复制{esc(n)}">{icon('copy')}</button></article>''')
        sections.append(f'''<section class="source-category" id="category-{cid}" data-category="{cid}" aria-labelledby="heading-{cid}"><div class="category-head"><div><h2 id="heading-{cid}">{icon(category['icon'])}{esc(name)}<span class="category-count">{len(items)}</span></h2><p class="category-desc">{esc(category['description'])}</p></div><button class="category-copy" type="button" aria-label="复制{esc(name)}分类的可见搜索源">{icon('copy')}复制</button></div><div class="source-grid">{''.join(cards)}</div></section>''')
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
    return template


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    changed = []
    for file, content in [('movies.html', build_movies()), ('sources.html', build_sources()), ('index.html', build_existing_page('index.html')), ('privacy.html', build_existing_page('privacy.html'))]:
        target = SITE/file
        if not target.exists() or target.read_text() != content:
            changed.append(file)
            if not args.check:
                target.write_text(content)
    if args.check and changed:
        parser.exit(1, 'Out of date: '+', '.join(changed)+'. Run python3 scripts/build_website.py\n')
    print('Website directories are up to date.' if args.check else 'Built crawlable directories and shared navigation on all four pages.')


if __name__ == '__main__':
    main()
