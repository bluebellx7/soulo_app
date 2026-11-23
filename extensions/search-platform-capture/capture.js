(() => {
    const pendingKey = "soulo-search-platform-pending";
    const marker = "%s";
    const placeholder = "%@";
    const lifetime = 120_000;
    const sensitiveParameter = /^(?:password|passwd|pwd|auth|authorization|api[_-]?key|session(?:[_-]?id)?|(?:access[_-]?|refresh[_-]?)?token|csrf(?:[_-]?token)?|authenticity_token|signature|sig)$/i;
    const editableFields = 'input:not([type]), input[type="text" i], input[type="search" i], textarea, [contenteditable]:not([contenteditable="false" i])';
    let pendingUntil = 0;
    let input;
    let timer;
    let dismissBanner;
    try { pendingUntil = Number(sessionStorage.getItem(pendingKey)) || 0; } catch (_) {}

    function decode(value, formEncoded = false) {
        try { return decodeURIComponent(formEncoded ? value.replace(/\+/g, " ") : value); }
        catch (_) { return value; }
    }

    function searchTemplate(address) {
        const url = new URL(address);
        if (!["http:", "https:"].includes(url.protocol) || url.username || url.password) return null;

        let occurrences = 0;
        const path = url.pathname.split("/").map(part => {
            if (decode(part) !== marker) return part;
            occurrences++;
            return placeholder;
        }).join("/");
        const params = [];
        for (const field of url.search.slice(1).split("&")) {
            if (!field) continue;
            const split = field.indexOf("=");
            const key = split < 0 ? field : field.slice(0, split);
            const value = split < 0 ? "" : field.slice(split + 1);
            if (sensitiveParameter.test(decode(key, true))) return null;
            if (decode(value, true) === marker) {
                occurrences++;
                params.push(key + "=" + placeholder);
            } else {
                params.push(field);
            }
        }
        const template = url.origin + path + (params.length ? "?" + params.join("&") : "");
        if (occurrences !== 1 || new TextEncoder().encode(template).length > 4096) return null;
        return template;
    }

    function clearPending() {
        pendingUntil = 0;
        input = undefined;
        clearTimeout(timer);
        try { sessionStorage.removeItem(pendingKey); } catch (_) {}
    }

    function offerPlatform(template, searchField) {
        dismissBanner?.();
        const banner = document.createElement("div");
        banner.setAttribute("data-soulo-search-platform", "");
        const root = banner.attachShadow({ mode: "closed" });
        const chinese = /^zh\b/i.test(navigator.language || "");
        const style = document.createElement("style");
        style.textContent = `
            :host { all: initial; position: fixed !important; z-index: 2147483647 !important;
                left: var(--soulo-left) !important; top: var(--soulo-top) !important;
                width: var(--soulo-width) !important; visibility: var(--soulo-visibility, hidden) !important; }
            aside { display: flex; align-items: center; flex-wrap: wrap; gap: 8px 12px;
                padding: 12px; border: 1px solid #aeb6c5; border-radius: 14px; background: #fff;
                box-shadow: 0 4px 20px #0003; color: #20232b; font: 15px system-ui, sans-serif; }
            p { flex: 1 1 145px; margin: 0; }
            a, button { box-sizing: border-box; display: inline-grid; place-content: center;
                min-height: 44px; padding: 0 12px; border: 0; border-radius: 8px; font: inherit; cursor: pointer; }
            a { background: #2459c4; color: white; text-decoration: none; }
            button { background: #e9ebf0; color: #20232b; }
            @media (prefers-color-scheme: dark) {
                aside { background: #222630; color: #f5f7fb; border-color: #535b6d; }
                button { background: #393f4e; color: #fff; }
            }
        `;
        const prompt = document.createElement("aside");
        prompt.setAttribute("aria-label", chinese ? "搜索平台建议" : "Search platform suggestion");
        const message = document.createElement("p");
        message.textContent = chinese ? "把这个网站添加为搜索平台？" : "Add this site as a search platform?";
        const add = document.createElement("a");
        add.href = "soulo://add-search-platform?template=" + encodeURIComponent(template);
        add.textContent = chinese ? "添加平台" : "Add platform";
        add.addEventListener("click", event => {
            if (!event.isTrusted) event.preventDefault();
            else setTimeout(close, 250);
        });
        const dismiss = document.createElement("button");
        dismiss.type = "button";
        dismiss.textContent = chinese ? "关闭" : "Dismiss";
        dismiss.addEventListener("click", close);
        prompt.append(message, add, dismiss);
        root.append(style, prompt);
        document.documentElement.append(banner);

        const listeners = new AbortController();
        const options = { passive: true, signal: listeners.signal };
        const viewport = window.visualViewport;
        const observer = new ResizeObserver(schedulePosition);
        let frame;
        let focusedField;
        dismissBanner = close;
        function close() {
            listeners.abort();
            observer.disconnect();
            cancelAnimationFrame(frame);
            banner.remove();
            if (dismissBanner === close) dismissBanner = undefined;
        }

        function position() {
            const margin = 12;
            const viewportWidth = viewport?.width ?? document.documentElement.clientWidth;
            const width = Math.max(0, Math.min(440, viewportWidth - 2 * margin));
            const left = (viewport?.offsetLeft ?? 0) + (viewportWidth - width) / 2;
            const viewportTop = viewport?.offsetTop ?? 0;
            const viewportBottom = viewportTop + (viewport?.height ?? window.innerHeight);
            banner.style.setProperty("--soulo-width", `${width}px`);
            banner.style.setProperty("--soulo-left", `${left}px`);
            const height = prompt.getBoundingClientRect().height;
            let top = viewportTop + margin;

            const fields = new Set(document.querySelectorAll(editableFields));
            if (searchField?.isConnected) fields.add(searchField);
            if (focusedField?.isConnected) fields.add(focusedField);
            // Keep the prompt near the search controls and away from browser chrome.
            const occupied = Array.from(fields, field => field.getBoundingClientRect())
                .filter(rect => rect.width && rect.height && rect.left < left + width && rect.right > left &&
                    rect.top < viewportBottom && rect.bottom > viewportTop)
                .sort((a, b) => a.top - b.top);
            for (const rect of occupied) {
                if (rect.bottom + margin > top && rect.top - margin < top + height) {
                    top = rect.bottom + margin;
                }
            }
            banner.style.setProperty("--soulo-top", `${top}px`);
            banner.style.setProperty("--soulo-visibility", width && top + height <= viewportBottom - margin ? "visible" : "hidden");
        }

        function schedulePosition() {
            cancelAnimationFrame(frame);
            frame = requestAnimationFrame(position);
        }

        window.addEventListener("resize", schedulePosition, options);
        window.addEventListener("scroll", schedulePosition, { ...options, capture: true });
        viewport?.addEventListener("resize", schedulePosition, options);
        viewport?.addEventListener("scroll", schedulePosition, options);
        document.addEventListener("focusin", event => {
            focusedField = event.composedPath().find(element => element instanceof Element && element.matches(editableFields));
            schedulePosition();
        }, options);
        document.addEventListener("DOMContentLoaded", schedulePosition, { ...options, once: true });
        observer.observe(prompt);
        if (document.body) observer.observe(document.body);
        schedulePosition();
    }

    function inspectAddress() {
        clearTimeout(timer);
        const now = Date.now();
        if (pendingUntil <= now || pendingUntil > now + lifetime) {
            clearPending();
            return;
        }
        const template = searchTemplate(location.href);
        if (template && document.documentElement) {
            const searchField = input;
            clearPending();
            offerPlatform(template, searchField);
        } else {
            timer = setTimeout(inspectAddress, 350);
        }
    }

    document.addEventListener("input", event => {
        const field = event.composedPath()[0];
        if (!event.isTrusted || !(field instanceof HTMLInputElement) || !["search", "text"].includes(field.type)) return;
        if (field.value.trim() !== marker) {
            if (field === input) clearPending();
            return;
        }
        input = field;
        pendingUntil = Date.now() + lifetime;
        try { sessionStorage.setItem(pendingKey, String(pendingUntil)); } catch (_) {}
        inspectAddress();
    }, true);
    addEventListener("pageshow", inspectAddress);
    addEventListener("pagehide", () => clearTimeout(timer));
    if (pendingUntil) inspectAddress();
})();
