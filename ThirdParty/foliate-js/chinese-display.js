// Convert only displayed text nodes; never rewrite EPUB markup or source blobs.
// Original strings are kept per live document, so switching back is lossless.
export class ChineseDisplay {
    #mode = 'original'
    #states = new WeakMap()
    #documents
    #convert
    constructor(documents, convert) { this.#documents = documents; this.#convert = convert }
    setMode(mode) {
        if (!['original', 'simplified', 'traditional'].includes(mode) || mode === this.#mode) return
        this.#mode = mode
        for (const doc of this.#documents()) this.apply(doc)
    }
    async apply(doc) {
        let state = this.#states.get(doc)
        if (!state && this.#mode === 'original') return
        if (!state) { state = { originals: new WeakMap(), revision: 0 }; this.#states.set(doc, state) }
        const revision = ++state.revision, mode = this.#mode
        const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
            acceptNode: node => node.parentElement?.closest('script,style,code,pre,textarea,input,svg,math')
                ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        })
        let batch = [], size = 0
        const flush = async () => {
            if (!batch.length) return true
            const current = batch; batch = []; size = 0
            const result = mode === 'original' ? current.map(x => x.original)
                : await this.#convert(current.map(x => x.original), mode)
            if (state.revision !== revision || !doc.defaultView?.frameElement?.isConnected) return false
            if (!Array.isArray(result) || result.length !== current.length) return false
            current.forEach((entry, index) => { entry.node.data = result[index] })
            // Yield between bounded batches instead of blocking scrolling.
            await new Promise(resolve => setTimeout(resolve, 0))
            return true
        }
        try {
            let node
            while ((node = walker.nextNode())) {
                if (state.revision !== revision) return
                const original = state.originals.get(node) ?? node.data
                if (!/[\u3400-\u9fff\uf900-\ufaff]/u.test(original)) continue
                state.originals.set(node, original)
                // A single pathological node is split only in the bridge payload, not in the DOM.
                if (original.length > 16000) {
                    if (!await flush()) return
                    let converted = ''
                    for (let offset = 0; offset < original.length;) {
                        let end = Math.min(offset + 16000, original.length)
                        if (end < original.length && /[\uD800-\uDBFF]/.test(original[end - 1])) end--
                        const part = original.slice(offset, end)
                        converted += mode === 'original' ? part : (await this.#convert([part], mode))[0]
                        if (state.revision !== revision || !doc.defaultView?.frameElement?.isConnected) return
                        offset = end
                    }
                    node.data = converted
                } else {
                    if (size + original.length > 16000 || batch.length >= 64) { if (!await flush()) return }
                    batch.push({ node, original }); size += original.length
                }
            }
            await flush()
        } catch (_) { /* A closed chapter/reader invalidates pending bridge replies. */ }
    }
}
