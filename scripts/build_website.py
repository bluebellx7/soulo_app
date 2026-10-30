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
}


def icon(name):
    return f'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICONS[name]}</svg>'


def esc(value):
    return html.escape(str(value), quote=True)


def jsonld(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c')


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
              <a class="movie-card-link" href="{esc(site['url'])}" target="_blank" rel="noopener noreferrer" aria-label="打开{esc(site['name'])}（新标签页）"><div class="movie-card-heading"><span class="site-mark" aria-hidden="true">{esc(site['mark'])}</span><div><h3>{esc(site['name'])}</h3><span class="site-domain">{esc(domain)}</span></div>{icon('external')}</div><p>{esc(site['description'])}</p><div class="site-tags">{tags}</div></a>
              <button class="favorite-button" type="button" data-favorite="{site['id']}" aria-label="收藏{esc(site['name'])}" aria-pressed="false" title="收藏{esc(site['name'])}">{icon('heart')}</button>
            </article>''')
        sections.append(f'''<section class="movie-category category-{cid}" id="{cid}" data-section="{cid}" aria-labelledby="heading-{cid}"><div class="movie-section-heading"><div>{icon(category['icon'])}<h2 id="heading-{cid}">{esc(name)}</h2><span class="section-count">{len(items)}</span></div><p>{esc(category['description'])}</p></div><div class="movie-grid">{''.join(cards)}</div></section>''')
    featured = ''.join(f'<a class="quick-pick" href="{esc(s["url"])}" target="_blank" rel="noopener noreferrer"><span class="quick-mark" aria-hidden="true">{esc(s["mark"])}</span><span><strong>{esc(s["name"])}</strong><span>{esc(s["tags"][0])}入口</span></span>{icon("external")}</a>' for s in sites if s.get('featured'))
    graph = {
        '@context': 'https://schema.org', '@graph': [
            {'@type': 'WebSite', '@id': BASE+'#website', 'name': 'Soulo', 'url': BASE},
            {'@type': 'CollectionPage', '@id': BASE+'movies.html#webpage', 'url': BASE+'movies.html', 'name': 'Soulo 影视导航', 'description': f'按 10 个分类整理的 {len(sites)} 个影视网站入口，涵盖电影、剧集、动漫、字幕与影评。', 'inLanguage': 'zh-CN', 'dateModified': data['updated'], 'isPartOf': {'@id': BASE+'#website'}, 'breadcrumb': {'@id': BASE+'movies.html#breadcrumb'}, 'mainEntity': {'@id': BASE+'movies.html#directory'}, 'citation': data['sources'], 'about': [{'@type':'Thing', 'name':c['name']} for c in categories]},
            {'@type': 'BreadcrumbList', '@id': BASE+'movies.html#breadcrumb', 'itemListElement': [{'@type':'ListItem','position':1,'name':'Soulo','item':BASE},{'@type':'ListItem','position':2,'name':'影视导航','item':BASE+'movies.html'}]},
            {'@type': 'ItemList', '@id': BASE+'movies.html#directory', 'name':'影视网站目录', 'numberOfItems': len(sites), 'itemListOrder':'https://schema.org/ItemListUnordered', 'itemListElement':[{'@type':'ListItem','position':i+1,'item':{'@type':'WebSite','name':s['name'],'url':s['url'],'description':s['description']}} for i,s in enumerate(sites)]},
        ]}
    tokens = {'site_count':str(len(sites)), 'category_count':str(len(categories)), 'updated':data['updated'], 'structured_data':jsonld(graph), 'featured_sites':featured, 'category_links':''.join(links), 'catalog':'\n'.join(sections)}
    tokens.update({f'{key}_icon': icon(key) for key in ICONS})
    tokens['arrow'] = icon('arrow')
    template = (ROOT/'scripts/templates/movies.html').read_text()
    for key, value in tokens.items():
        template = template.replace('{{'+key+'}}', value)
    assert not re.search(r'\{\{\w+\}\}', template), 'Unresolved template token'
    return template


def build_sources():
    source = (SITE/'sources.html').read_text()
    entries = re.findall(r"\{ c: '([^']+)', n: '([^']+)', u: '([^']+)' \}", source)
    categories = re.findall(r"(\w+): \{ title: '([^']+)', icon: '([^']+)', desc: '([^']+)' \}", source)
    assert len(entries) > 50 and len(categories) == 9
    stats = f'<div class="stat-row" id="statRow" aria-live="polite"><span class="stat"><strong>{len(entries)}</strong> 个搜索源</span><span class="stat"><strong>{len(categories)}</strong> 个分类</span><span class="stat"><strong>100%</strong> 含 %@</span></div>'
    source = re.sub(r'<div class="stat-row" id="statRow" aria-live="polite">.*?</div>', lambda _:stats, source, count=1, flags=re.S)
    sections = []
    for cid, name, ico, description in categories:
        items = [(i,n,u) for i,(c,n,u) in enumerate(entries) if c == cid]
        cards = []
        for index,n,u in items:
            domain = urlparse(u).netloc.removeprefix('www.')
            local_icon = next((f'favicons/{domain}.{ext}' for ext in ['png','ico'] if (SITE/f'favicons/{domain}.{ext}').exists()), 'favicons/default-site.svg')
            cards.append(f'<a class="source-card" href="{esc(u.replace("%@",quote("Soulo")))}" target="_blank" rel="noopener noreferrer" data-index="{index}" data-search="{esc(f"{n} {domain} {name}".lower())}" aria-label="{esc(n)}，使用示例关键词打开搜索"><img class="favicon" src="{local_icon}" width="32" height="32" alt="" loading="lazy" /><span class="source-info"><span class="source-name">{esc(n)}</span><code class="source-template">{esc(u)}</code></span><i class="fa-solid fa-arrow-up-right-from-square external" aria-hidden="true"></i></a>')
        sections.append(f'<section class="category" id="category-{cid}" data-category="{cid}"><div class="category-head"><div><h2 class="category-title"><i class="fa-solid {ico}" aria-hidden="true"></i>{esc(name)}</h2><p class="category-desc">{esc(description)}</p></div><div class="category-actions"><span class="category-count">{len(items)}</span><button class="category-copy" type="button"><i class="fa-solid fa-copy" aria-hidden="true"></i>复制本分类</button></div></div><div class="source-grid">{"".join(cards)}</div></section>')
    catalog = '<div id="catalog">\n<!-- sources:start -->\n'+'\n'.join(sections)+'\n<!-- sources:end -->\n      </div>'
    source = re.sub(r'<div id="catalog">.*?<!-- sources:end -->\s*</div>|<div id="catalog"></div>', lambda _:catalog, source, count=1, flags=re.S)
    graph = {'@context':'https://schema.org','@graph':[
        {'@type':'CollectionPage','@id':BASE+'sources.html#webpage','url':BASE+'sources.html','name':'Soulo 搜索源目录','inLanguage':'zh-CN','isPartOf':{'@id':BASE+'#website'},'mainEntity':{'@id':BASE+'sources.html#catalog'},'breadcrumb':{'@id':BASE+'sources.html#breadcrumb'}},
        {'@type':'BreadcrumbList','@id':BASE+'sources.html#breadcrumb','itemListElement':[{'@type':'ListItem','position':1,'name':'Soulo','item':BASE},{'@type':'ListItem','position':2,'name':'搜索源','item':BASE+'sources.html'}]},
        {'@type':'ItemList','@id':BASE+'sources.html#catalog','name':'可导入的搜索源','numberOfItems':len(entries),'itemListElement':[{'@type':'ListItem','position':i+1,'name':n,'url':u.replace('%@','Soulo')} for i,(_,n,u) in enumerate(entries)]}
    ]}
    block = '<!-- sources-schema:start -->\n    <script type="application/ld+json">'+jsonld(graph)+'</script>\n    <!-- sources-schema:end -->'
    if '<!-- sources-schema:start -->' in source:
        source = re.sub(r'<!-- sources-schema:start -->.*?<!-- sources-schema:end -->', lambda _:block, source, flags=re.S)
    else:
        source = source.replace('  </head>', '    '+block+'\n  </head>')
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    changed = []
    for file, content in [('movies.html', build_movies()), ('sources.html', build_sources())]:
        target = SITE/file
        if not target.exists() or target.read_text() != content:
            changed.append(file)
            if not args.check:
                target.write_text(content)
    if args.check and changed:
        parser.exit(1, 'Out of date: '+', '.join(changed)+'. Run python3 scripts/build_website.py\n')
    print('Website directories are up to date.' if args.check else 'Built movies.html and crawlable sources.html.')


if __name__ == '__main__':
    main()
