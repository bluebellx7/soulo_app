#!/usr/bin/env python3
"""Check static SEO, structured data, directory consistency and local links."""
from collections import Counter
from datetime import date
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT/'website'
BASE = 'https://soulo.dkluge.com/'
PAGES = ['index.html', 'sources.html', 'movies.html', 'privacy.html']


class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.tags = []
        self.schema = []
        self.current_schema = None
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if tag == 'script' and attrs.get('type') == 'application/ld+json':
            self.current_schema = ''

    def handle_data(self, data):
        if self.current_schema is not None:
            self.current_schema += data

    def handle_endtag(self, tag):
        if tag == 'script' and self.current_schema is not None:
            self.schema.append(json.loads(self.current_schema))
            self.current_schema = None


def check():
    subprocess.run([sys.executable, str(ROOT/'scripts/build_website.py'), '--check'], check=True)
    pages = {}
    for file in PAGES:
        text = (SITE/file).read_text()
        page = Page(text)
        pages[file] = page
        metas = {a.get('name', a.get('property')): a.get('content') for t,a in page.tags if t == 'meta'}
        links = {a.get('rel'):a.get('href') for t,a in page.tags if t == 'link'}
        expected = BASE + ('' if file == 'index.html' else file)
        assert links['canonical'] == expected, (file, 'canonical')
        assert metas['description'] and len(metas['description']) >= 30, (file, 'description')
        assert 'noindex' not in metas['robots'] and 'index' in metas['robots']
        for field in ['og:title','og:description','og:image','og:image:alt','og:locale','twitter:card','twitter:title','twitter:description','twitter:image','twitter:image:alt']:
            assert metas.get(field), (file, field)
        assert metas['og:url'] == expected
        assert sum(t == 'title' for t,a in page.tags) == 1
        assert sum(t == 'h1' for t,a in page.tags) == 1
        ids = [a['id'] for t,a in page.tags if a.get('id')]
        assert all(n == 1 for n in Counter(ids).values()), (file, 'duplicate IDs')
        assert page.schema, (file, 'JSON-LD')
        assert all(s.get('@context') == 'https://schema.org' for s in page.schema)
        assert text.count('https://hm.baidu.com/hm.js?bdc8ea6c501e6ff0d7b16dc13b09b991') == 1
        assert links['icon'].startswith('favicon.svg?')
        for tag, attrs in page.tags:
            if tag == 'img':
                assert 'alt' in attrs, (file, 'image alt')
            for attr in ['href','src']:
                value = attrs.get(attr)
                if not value or urlparse(value).scheme or value.startswith('//'):
                    continue
                url = urlparse(value)
                local = SITE/unquote(url.path.lstrip('/')) if url.path.startswith('/') else SITE/unquote(url.path)
                assert local.exists(), (file, value, 'missing local file')
                if not url.path and url.fragment:
                    assert unquote(url.fragment) in ids, (file, value, 'missing anchor')
        print(f'{file}: metadata, JSON-LD, links, headings and analytics OK')

    data = json.loads((SITE/'movies.json').read_text())
    movies = pages['movies.html']
    cards = [a for t,a in movies.tags if 'movie-card' in a.get('class','').split()]
    assert len(cards) == len(data['sites']) == len({s['url'] for s in data['sites']})
    assert {a['data-site'] for a in cards} == {s['id'] for s in data['sites']}
    links = {a.get('href') for t,a in movies.tags if t == 'a'}
    assert {s['url'] for s in data['sites']} <= links
    user_urls = {'https://i8k.tv/','https://y80s.tv/movie/search/','https://www.6vdyy.com/','https://hhzyapi.com/','https://www.pbpbw.com/','https://www.pbkan.com/'}
    assert user_urls <= links, 'Missing user-provided website'
    graph = movies.schema[0]['@graph']
    directory = next(n for n in graph if n['@type'] == 'ItemList')
    assert directory['numberOfItems'] == len(data['sites'])
    assert {x['item']['url'] for x in directory['itemListElement']} == {s['url'] for s in data['sites']}
    source_data = json.loads((SITE/'sources.json').read_text())
    source_cards = [a for t,a in pages['sources.html'].tags if 'source-card' in a.get('class','').split()]
    assert len(source_cards) == len(source_data['sources'])
    assert {int(card['data-index']) for card in source_cards} == set(range(len(source_data['sources'])))
    assert all('%@' in entry['url'] for entry in source_data['sources'])
    for file, page in pages.items():
        assert sum(t == 'header' and 'data-shared-nav' in a for t,a in page.tags) == 1, (file, 'shared navigation')
        assert sum(a.get('id') == 'language-toggle' for t,a in page.tags) == 1
        assert sum(a.get('id') == 'theme-toggle' for t,a in page.tags) == 1
        assert any(t == 'link' and a.get('href','').startswith('navigation.css?') for t,a in page.tags)
    assert not any(t == 'a' and a.get('href') == '#features' for t,a in pages['index.html'].tags)
    sitemap = ET.parse(SITE/'sitemap.xml')
    ns = {'s':'http://www.sitemaps.org/schemas/sitemap/0.9'}
    assert {n.text for n in sitemap.findall('s:url/s:loc',ns)} == {BASE + ('' if f == 'index.html' else f) for f in PAGES}
    for node in sitemap.findall('s:url/s:lastmod', ns):
        assert date.fromisoformat(node.text) <= date.today(), 'Future sitemap date'
    assert 'Sitemap: '+BASE+'sitemap.xml' in (SITE/'robots.txt').read_text()
    for file in ['llms.txt','llms-full.txt']:
        text = (SITE/file).read_text()
        assert all(BASE + ('' if p == 'index.html' else p) in text for p in PAGES)
    print(f'Directory: {len(cards)} sites, {len(data["categories"])} categories; sitemap and GEO summaries OK')


if __name__ == '__main__':
    check()
