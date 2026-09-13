import './view.js'
import { EPUB } from './epub.js'
import { MOBI } from './mobi.js'
import { unzlibSync } from './vendor/fflate.js'
import { configure, ZipReader, BlobReader, TextWriter, BlobWriter } from './vendor/zip.js'
const post = (type, payload = {}) => window.webkit.messageHandlers.book.postMessage({ type, ...payload })
const view = document.createElement('foliate-view')
document.body.append(view)
let last = '', ready = false
const flatten = items => (items ?? []).flatMap(x => [{ label: x.label, href: x.href }, ...flatten(x.subitems)])
view.addEventListener('relocate', event => {
    last = event.detail.cfi
    post('location', { location: last, fraction: event.detail.fraction ?? 0 })
})
view.addEventListener('external-link', event => { event.preventDefault() })
const escape = text => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
const textSection = (text, index) => {
    let url
    const html = () => '<!doctype html><meta charset="utf-8"><article><p>' + escape(text).replaceAll('\n', '</p><p>') + '</p></article>'
    return {
        id: String(index), size: text.length,
        createDocument: async () => new DOMParser().parseFromString(html(), 'text/html'),
        load: async () => url ??= URL.createObjectURL(new Blob([html()], { type: 'text/html' })),
        unload: () => { if (url) URL.revokeObjectURL(url); url = null },
    }
}
window.soulo = {
    canToggleAt(x, y) {
        for (const { doc } of view.renderer?.getContents() || []) {
            if (!doc.getSelection()?.isCollapsed) return false
            const rect = doc.defaultView.frameElement.getBoundingClientRect()
            if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue
            const target = doc.elementFromPoint(x - rect.left, y - rect.top)
            if (target?.closest('a,button,input,select,textarea')) return false
        }
        return true
    },
    async open(format, location) {
        try {
            let book
            if (format === 'text' || format === 'palmDoc') {
                const chunks = await (await fetch('soulo-book://reader/text')).json()
                book = { metadata: {}, sections: chunks.map(textSection),
                    toc: chunks.map((text, index) => ({ label: text.trim().split('\n')[0].slice(0, 70) || String(index+1), href: String(index) })),
                    resolveHref: href => ({ index: Number(href) }), splitTOCHref: href => [href, ''], getTOCFragment: doc => doc.body }
            } else {
                const file = new File([await (await fetch('soulo-book://reader/book')).blob()], 'book')
                if (format === 'epub') {
                    configure({ useWebWorkers: false })
                    const reader = new ZipReader(new BlobReader(file))
                    const entries = await reader.getEntries()
                    if (entries.length > 10000 || entries.reduce((n, e) => n + e.uncompressedSize, 0) > 134217728) throw Error('Book exceeds the 128 MB reading limit')
                    const map = new Map(entries.map(e => [e.filename, e]))
                    if (!map.has('META-INF/container.xml')) throw Error('Invalid EPUB container')
                    book = await new EPUB({ entries, loadText: name => map.get(name)?.getData(new TextWriter()),
                        loadBlob: (name, type) => map.get(name)?.getData(new BlobWriter(type)), getSize: name => map.get(name)?.uncompressedSize ?? 0 }).init()
                } else { book = await new MOBI({ unzlib: unzlibSync }).open(file) }
            }
            if (book.souloPDF) {
                let binary = ''; const bytes = book.souloPDF
                for (let i = 0; i < bytes.length; i += 32768) binary += String.fromCharCode(...bytes.subarray(i, i + 32768))
                post('pdf', { data: btoa(binary) }); return
            }
            book.souloContinuous = true
            await view.open(book)
            view.renderer.addEventListener('error', event => post('error', { message: String(event.detail?.message || event.detail) }))
            let scrolling = false, scrollTimer
            view.renderer.addEventListener('scroll', () => {
                if (!scrolling) { scrolling = true; post('scroll') }
                clearTimeout(scrollTimer); scrollTimer = setTimeout(() => scrolling = false, 250)
            })
            await view.init({ lastLocation: location || undefined })
            ready = true
            post('ready', { toc: flatten(book.toc), title: book.metadata?.title ?? '' })
            try {
                const cover = await book.getCover?.()
                if (cover && cover.size <= 4194304) {
                    const image = await createImageBitmap(cover)
                    const canvas = document.createElement('canvas'); canvas.width = 180; canvas.height = Math.min(320, 180 * image.height / image.width)
                    canvas.getContext('2d').drawImage(image, 0, 0, canvas.width, canvas.height)
                    post('cover', { data: canvas.toDataURL('image/jpeg', 0.8).split(',')[1] }); image.close()
                }
            } catch (_) {}

        } catch (e) { post('error', { message: String(e.message || e) }) }
    },
    async next() { if (ready) await view.next() },
    async prev() { if (ready) await view.prev() },
    async fraction(value) { if (ready) await view.goToFraction(Math.max(0, Math.min(1, value))) },
    async go(location) { if (ready) await view.goTo(location) },
    style(size, line, theme, font = "serif") {
        const family = { serif: "Georgia, 'Songti SC', 'Songti TC', serif", sans: "-apple-system, 'PingFang SC', 'PingFang TC', sans-serif", mono: "ui-monospace, 'SFMono-Regular', Menlo, monospace" }[font] || "Georgia, serif"
        const colors = { paper: ['#f6f1e7', '#29251f'], light: ['#fff', '#202124'], dark: ['#171918', '#d8ddd9'] }
        const [bg, fg] = colors[theme] || colors.paper
        document.body.style.background = bg; document.body.style.color = fg
        view.renderer?.setStyles(`:root { color-scheme: ${theme === 'dark' ? 'dark' : 'light'} } body { background: ${bg} !important; color: ${fg} !important; font-family: ${family} !important; font-size: ${size}px !important; line-height: ${line} !important; padding: 12px 0 !important; } :root body :is(p, div, span, li, blockquote, td, h1, h2, h3, h4, h5, h6) { font-family: ${family} !important; line-height: ${line} !important; } :root body :is(p, div, li, blockquote, td) { font-size: inherit !important; } img { max-width:100%; height:auto } p { overflow-wrap:anywhere; text-align:justify }`)
    },
    async search(query) {
        try {
            view.clearSearch()
            if (!query.trim()) { post('search', { results: [] }); return }
            const results = []
            for await (const result of view.search({ query })) {
                for (const match of result.subitems || (result.cfi ? [result] : [])) {
                    if (results.length < 100) results.push({ label: typeof match.excerpt === 'string' ? match.excerpt : [match.excerpt?.pre, match.excerpt?.match, match.excerpt?.post].filter(Boolean).join(''), href: match.cfi })
                }
                if (results.length >= 100) break
            }
            post('search', { results })
        } catch (e) { post('error', { message: String(e.message || e) }) }
    }
}
post('boot')
