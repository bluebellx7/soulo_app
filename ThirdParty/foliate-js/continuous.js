// Soulo's vertical reader keeps only nearby chapter documents alive. Empty slots
// retain measured heights, so unloading a chapter never changes the scroll position.
import { View } from './paginator.js'
const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
export class ContinuousReader extends HTMLElement {
    #root = this.attachShadow({ mode: 'closed' })
    #container
    #slots = []
    #styles = ''
    #current = 0
    #navigating = false
    #navigation = 0
    #programmaticTop = null
    #destroyed = false
    #raf = 0
    #timer = 0
    #resize = new ResizeObserver(() => this.#resizeViews())
    constructor() {
        super()
        this.#root.innerHTML = `<style>
        :host{display:block;height:100%;width:100%;overflow:hidden}
        #scroll{position:relative;height:100%;overflow-y:auto;overflow-x:hidden;overflow-anchor:none;overscroll-behavior-y:contain;-webkit-overflow-scrolling:touch}
        .section{position:relative;width:100%;overflow:hidden;box-sizing:border-box}
        </style><div id="scroll"></div>`
        this.#container = this.#root.querySelector('#scroll')
        this.#container.addEventListener('scroll', () => {
            if (this.#destroyed || this.#navigating) return
            if (this.#programmaticTop != null && Math.abs(this.#container.scrollTop - this.#programmaticTop) < 1) return
            this.#programmaticTop = null
            this.dispatchEvent(new Event('scroll'))
            if (!this.#raf) this.#raf = requestAnimationFrame(() => {
                this.#raf = 0
                const index = this.#indexAt(this.#container.scrollTop + 2)
                if (index !== this.#current) {
                    this.#current = index
                    this.#maintain()
                }
            })
            clearTimeout(this.#timer)
            this.#timer = setTimeout(() => this.#relocate('scroll'), 220)
        }, { passive: true })
        this.#resize.observe(this)
    }
    open(book) {
        this.sections = book.sections
        this.setAttribute('flow', 'scrolled')
        for (let index = 0; index < this.sections.length; index++) {
            const element = document.createElement('div')
            element.className = 'section'
            const height = this.sections[index].linear === 'no' ? 0 : Math.max(600, Math.min(12000, (this.sections[index].size || 1500) * 0.16))
            element.style.height = `${height}px`
            this.#container.append(element)
            this.#slots.push({ index, element, height, view: null, loading: null })
        }
    }
    #layout() {
        const width = this.clientWidth || innerWidth, height = this.clientHeight || innerHeight
        return { flow: 'scrolled', width, height, margin: 14, gap: 20, columnWidth: Math.min(720, width - 40) }
    }
    #indexAt(y) {
        let low = 0, high = this.#slots.length - 1
        while (low < high) {
            const mid = Math.floor((low + high) / 2)
            const slot = this.#slots[mid]
            if (slot.element.offsetTop + slot.height <= y) low = mid + 1
            else high = mid
        }
        return low
    }
    #measure(slot) {
        if (!slot.view || this.#destroyed) return
        const height = Math.max(1, slot.view.element.getBoundingClientRect().height)
        const delta = height - slot.height
        if (Math.abs(delta) < 0.5) return
        const previousTop = this.#container.scrollTop
        const above = slot.element.offsetTop + slot.height <= previousTop + 1
        slot.height = height
        slot.element.style.height = `${height}px`
        if (above && !this.#navigating) {
            // Assign from the pre-layout offset: WebKit may already compensate
            // for resized iframe content, so += would move the reader twice.
            this.#container.scrollTop = previousTop + delta
            if (this.#programmaticTop != null) this.#programmaticTop = this.#container.scrollTop
        }
    }
    async #load(index) {
        const slot = this.#slots[index]
        if (!slot || this.#destroyed) return
        if (slot.loading) return slot.loading
        if (slot.view) return slot
        slot.loading = (async () => {
            const src = await this.sections[index].load()
            if (this.#destroyed || !this.#neighbors().has(index)) { this.sections[index].unload?.(); return }
            const view = new View({ container: this, onExpand: () => this.#measure(slot) })
            slot.view = view
            slot.element.append(view.element)
            await view.load(src, doc => {
                const style = doc.createElement('style')
                style.dataset.souloStyle = ''
                style.textContent = this.#styles
                doc.head.append(style)
                this.dispatchEvent(new CustomEvent('load', { detail: { doc, index } }))
            }, () => this.#layout())
            if (this.#destroyed) { view.destroy(); return }
            this.dispatchEvent(new CustomEvent('create-overlayer', { detail: {
                doc: view.document, index, attach: overlayer => view.overlayer = overlayer,
            } }))
            this.#measure(slot)
            return slot
        })()
        try { return await slot.loading }
        finally { slot.loading = null }
    }
    #neighbors() {
        const keep = new Set([this.#current])
        for (const direction of [-1, 1]) {
            let count = 0
            for (let i = this.#current + direction; i >= 0 && i < this.sections.length && count < 2; i += direction) {
                if (this.sections[i].linear === 'no') continue
                keep.add(i); count++
            }
        }
        return keep
    }
    #maintain() {
        if (this.#destroyed) return
        const keep = this.#neighbors()
        for (const index of keep) this.#load(index).then(() => this.#trim()).catch(error => {
            if (index === this.#current) this.dispatchEvent(new CustomEvent('error', { detail: error }))
        })
        this.#trim()
    }
    #trim() {
        const keep = this.#neighbors()
        for (const slot of this.#slots) {
            if (!slot.view || slot.loading || keep.has(slot.index)) continue
            slot.view.destroy()
            slot.view.element.remove()
            slot.view = null
            this.sections[slot.index].unload?.()
        }
    }
    async goTo(target) {
        const navigation = ++this.#navigation
        const resolved = await target
        const index = resolved?.index
        if (navigation !== this.#navigation) return
        if (!Number.isInteger(index) || !this.#slots[index] || this.#destroyed) { this.#navigating = false; return }
        this.#navigating = true
        try {
            this.#current = index
            const slot = await this.#load(index)
            if (!slot || this.#destroyed || navigation !== this.#navigation) return
            await frame()
            if (navigation !== this.#navigation) return
            const anchor = typeof resolved.anchor === 'function' ? resolved.anchor(slot.view.document) : resolved.anchor
            this.#scrollToAnchor(slot, anchor ?? 0, resolved.select)
            this.#relocate('navigation')
        } finally {
            if (navigation === this.#navigation) {
                this.#navigating = false
                this.#maintain()
            }
        }
    }
    #scrollToAnchor(slot, anchor, select) {
        let offset = 0
        if (typeof anchor === 'number') offset = anchor * Math.max(0, slot.height - this.clientHeight)
        else if (anchor?.getBoundingClientRect) {
            const iframe = slot.view.element.querySelector('iframe')
            offset = iframe.offsetTop + anchor.getBoundingClientRect().top
            if (select && anchor.startContainer) {
                const selection = slot.view.document.getSelection()
                selection.removeAllRanges(); selection.addRange(anchor)
            }
        }
        this.#container.scrollTop = slot.element.offsetTop + Math.max(0, offset)
        this.#programmaticTop = this.#container.scrollTop
    }
    async scrollToAnchor(anchor, select) {
        const slot = this.#slots[this.#current]
        if (!slot?.view) return
        this.#scrollToAnchor(slot, anchor, select)
        this.#relocate('navigation')
    }
    #visibleRange(slot) {
        const doc = slot.view.document
        const iframe = slot.view.element.querySelector('iframe')
        const y = Math.max(0, this.#container.scrollTop - slot.element.offsetTop - iframe.offsetTop)
        // DOM coordinates are local to the chapter, including when its top is offscreen.
        const range = doc.caretRangeFromPoint?.(Math.min(40, this.clientWidth / 2), y + 12)
        if (range && doc.body.contains(range.startContainer)) return range
        const fallback = doc.createRange()
        const text = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT).nextNode()
        if (text) { fallback.setStart(text, 0); fallback.collapse(true) }
        else { fallback.selectNodeContents(doc.body); fallback.collapse(true) }
        return fallback
    }
    #relocate(reason) {
        const index = reason === 'navigation' ? this.#current : this.#indexAt(this.#container.scrollTop + 2)
        const slot = this.#slots[index]
        if (!slot?.view || slot.loading || this.#destroyed) return
        this.#current = index
        const fraction = Math.min(1, Math.max(0, (this.#container.scrollTop - slot.element.offsetTop) / Math.max(1, slot.height)))
        this.dispatchEvent(new CustomEvent('relocate', { detail: {
            reason, index, range: this.#visibleRange(slot), fraction,
            size: Math.min(1, this.clientHeight / Math.max(1, slot.height)),
        } }))
    }
    setStyles(styles) {
        this.#styles = Array.isArray(styles) ? styles.join('\n') : styles || ''
        const current = this.#slots[this.#current]
        const anchor = current?.view ? this.#visibleRange(current) : null
        for (const slot of this.#slots) {
            if (!slot.view) continue
            const style = slot.view.document?.querySelector('style[data-soulo-style]')
            if (style) style.textContent = this.#styles
            slot.view.render(this.#layout())
        }
        if (anchor && current?.view) requestAnimationFrame(() => {
            if (!this.#destroyed && current.view) this.#scrollToAnchor(current, anchor)
        })
    }
    #resizeViews() {
        if (this.#destroyed) return
        for (const slot of this.#slots) slot.view?.render(this.#layout())
    }
    getContents() {
        return this.#slots.filter(x => x.view && !x.loading)
            .sort((a, b) => (a.index === this.#current ? -1 : b.index === this.#current ? 1 : a.index - b.index))
            .map(x => ({ index: x.index, doc: x.view.document, overlayer: x.view.overlayer }))
    }
    async next(distance) {
        if (!this.getContents().length) return this.goTo({ index: this.sections.findIndex(s => s.linear !== 'no') })
        this.#container.scrollTo({ top: this.#container.scrollTop + (distance ?? this.clientHeight * 0.85), behavior: 'smooth' })
    }
    async prev(distance) { this.#container.scrollTo({ top: this.#container.scrollTop - (distance ?? this.clientHeight * 0.85), behavior: 'smooth' }) }
    scrollBy(x, y) { this.#container.scrollTop = this.#container.scrollTop + y }
    focusView() { this.#slots[this.#current]?.view?.document.defaultView.focus() }
    destroy() {
        this.#destroyed = true
        clearTimeout(this.#timer); cancelAnimationFrame(this.#raf); this.#resize.disconnect()
        for (const slot of this.#slots) { slot.view?.destroy(); this.sections[slot.index].unload?.() }
        this.#container.replaceChildren()
    }
}
customElements.define('soulo-continuous', ContinuousReader)
