// Evaluated as a factory in the page world only for explicitly granted scripts.
(function bindWebRequest(token, scriptID, includes, excludes) {
    'use strict';

    const key = '__souloBindWebRequest';
    if (!(key in window)) {
        Object.defineProperty(window, key, {value: createRegistry(token)});
    }
    return window[key](token, scriptID, includes, excludes);

    function createRegistry(bridgeToken) {
        const registrations = new Map();
        const openedRequests = new WeakMap();
        const NativeURL = window.URL;
        const NativeRequest = window.Request;
        const urlHref = Object.getOwnPropertyDescriptor(NativeURL.prototype, 'href').get;
        const requestURL = Object.getOwnPropertyDescriptor(NativeRequest.prototype, 'url').get;
        const requestBody = Object.getOwnPropertyDescriptor(NativeRequest.prototype, 'body').get;
        let installed = false;
        let suspended = false;

        function urlInput(value) {
            if (typeof value === 'string') return value;
            if (value instanceof NativeURL) return urlHref.call(value);
            return null;
        }

        function httpURL(value, base) {
            if (value === null) return null;
            const url = new NativeURL(value, base);
            return (url.protocol === 'https:' || url.protocol === 'http:') && !url.username && !url.password ? url : null;
        }

        function glob(value) {
            return value.split('*').map(part => part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('.*');
        }

        function selectorPatterns(value, kind) {
            if (value === undefined) return [];
            if (!Array.isArray(value)) value = [value];
            return value.map(pattern => {
                if (typeof pattern !== 'string' || pattern.length === 0) {
                    throw new TypeError('GM_webRequest selectors must be nonempty strings');
                }
                if (kind !== 'match') {
                    const regex = /^\/(.+)\/([a-z]*)$/.exec(pattern);
                    if (regex) return new RegExp(regex[1], regex[2]);
                    return new RegExp('^' + glob(pattern) + '$', 'i');
                }
                if (pattern === '<all_urls>') return /^https?:\/\//i;
                const match = /^(https?|\*):\/\/(\*|\*\.[^/*]+|[^/*]+)(\/.*)$/.exec(pattern);
                if (!match) throw new TypeError('Invalid GM_webRequest match pattern: ' + pattern);
                const scheme = match[1] === '*' ? 'https?' : match[1];
                let host = glob(match[2]);
                if (match[2] === '*') host = '[^/]+';
                if (match[2].startsWith('*.')) host = '(?:[^/]+\\.)?' + glob(match[2].slice(2));
                return new RegExp('^' + scheme + '://' + host + '(?::[0-9]+)?' + glob(match[3]) + '$', 'i');
            });
        }

        function matches(patterns, url) {
            return patterns.some(pattern => {
                pattern.lastIndex = 0;
                return pattern.test(url);
            });
        }

        function compile(rule) {
            const selector = rule?.selector;
            const action = rule?.action;
            const filters = typeof selector === 'string' ? {include: selector} : selector;
            if (!filters || typeof filters !== 'object') throw new TypeError('Invalid GM_webRequest selector');
            const positives = [...selectorPatterns(filters.include, 'include'), ...selectorPatterns(filters.match, 'match')];
            const negatives = selectorPatterns(filters.exclude, 'exclude');
            if (!positives.length && !negatives.length) throw new TypeError('GM_webRequest requires a URL selector');

            let target;
            let replacement;
            if (action !== 'cancel' && action?.cancel !== true) {
                target = action?.redirect;
                if (target && typeof target.from === 'string' && typeof target.to === 'string') {
                    replacement = new RegExp(target.from);
                    target = target.to;
                }
                if (typeof target !== 'string' || !target) throw new TypeError('Invalid GM_webRequest action');
            }
            return {rule, positives, negatives, target, replacement};
        }

        function findRule(url) {
            const page = window.location.href;
            for (const registration of registrations.values()) {
                if (!registration.allows(page)) continue;
                for (const rule of registration.rules) {
                    if (rule.positives.length && !matches(rule.positives, url.href)) continue;
                    if (matches(rule.negatives, url.href)) continue;
                    if (rule.replacement && !rule.replacement.test(url.href)) continue;
                    return {registration, rule, url};
                }
            }
            return null;
        }

        function redirectURL(hit) {
            const {rule, url, registration} = hit;
            const destination = rule.replacement ? url.href.replace(rule.replacement, rule.target) : rule.target;
            const target = httpURL(destination, url.href);
            if (!target || target.origin !== url.origin || !registration.allows(target.href)) {
                throw new TypeError('Redirect must be same-origin and inside the script’s allowed URLs');
            }
            return target.href;
        }

        function report(hit, error, destination) {
            const {registration, rule, url} = hit;
            if (!registration.listener) return;
            const details = {rule: rule.rule, url: url.href};
            if (destination) details.redirect_url = destination;
            if (error) details.description = String(error.message || error);
            queueMicrotask(() => {
                if (suspended || !registration.allows(window.location.href) ||
                    registrations.get(registration.id) !== registration) return;
                try { registration.listener(rule.target ? 'redirect' : 'cancel', error ? 'error' : 'ok', details); }
                catch (error) { console.error('Soulo GM_webRequest listener:', error); }
            });
        }

        function interceptFetch(original, receiver, args) {
            if (!registrations.size || suspended) return Reflect.apply(original, receiver, args);
            let inputIsRequest;
            let hit;
            try {
                inputIsRequest = args[0] instanceof NativeRequest;
                const url = httpURL(inputIsRequest ? requestURL.call(args[0]) : urlInput(args[0]), document.baseURI);
                if (url) hit = findRule(url);
            } catch (_) { /* Let Fetch handle input conversion and validation. */ }
            if (!hit) return Reflect.apply(original, receiver, args);
            if (!hit.rule.target) {
                try {
                    const request = new NativeRequest(args[0], args[1]);
                    if (request.signal.aborted) return Promise.reject(request.signal.reason);
                } catch (error) {
                    return Promise.reject(error);
                }
                report(hit);
                return Promise.reject(new TypeError('Load failed'));
            }

            let target;
            let input;
            try {
                target = redirectURL(hit);
                if (inputIsRequest && requestBody.call(args[0]) !== null) {
                    throw new TypeError('Redirecting a Fetch Request with a body is unsupported');
                }
                input = inputIsRequest ? new NativeRequest(target, args[0]) : target;
            } catch (error) {
                report(hit, error);
                return Reflect.apply(original, receiver, args);
            }
            const result = Reflect.apply(original, receiver, [input, ...args.slice(1)]);
            report(hit, null, target);
            return result;
        }

        function interceptOpen(original, xhr, args) {
            const previous = openedRequests.get(xhr);
            let request;
            if (!suspended && registrations.size && typeof args[0] === 'string') {
                try {
                    const url = httpURL(urlInput(args[1]), document.baseURI);
                    if (url) request = {url, args, headers: [], replayable: args.slice(3, 5).every(value => value == null)};
                } catch (_) { /* Let XMLHttpRequest validate the URL. */ }
            }
            // A page can call send() synchronously from the OPENED event.
            if (request) openedRequests.set(xhr, request);
            else openedRequests.delete(xhr);
            try { return Reflect.apply(original, xhr, args); }
            catch (error) {
                if (openedRequests.get(xhr) === request) {
                    if (previous) openedRequests.set(xhr, previous);
                    else openedRequests.delete(xhr);
                }
                throw error;
            }
        }

        function interceptHeader(original, xhr, args) {
            const result = Reflect.apply(original, xhr, args);
            const request = openedRequests.get(xhr);
            if (request?.replayable) {
                if (typeof args[0] === 'string' && typeof args[1] === 'string') request.headers.push(args);
                else request.replayable = false;
            }
            return result;
        }

        function interceptSend(original, xhr, args, open, setHeader) {
            const request = openedRequests.get(xhr);
            openedRequests.delete(xhr);
            const hit = !suspended && registrations.size && request && xhr.readyState === 1
                ? findRule(request.url) : null;
            if (!hit) return Reflect.apply(original, xhr, args);

            let destination;
            try {
                if (hit.rule.target) {
                    if (!request.replayable) throw new TypeError('XHR redirect requires string headers and no explicit username or password');
                    destination = redirectURL(hit);
                }
            } catch (error) {
                report(hit, error);
                return Reflect.apply(original, xhr, args);
            }

            // Reopening an OPENED XHR does not dispatch a second OPENED event.
            // Keep the same XHR, body and options. An invalid data payload gives
            // canceled requests the native network-error events without HTTP I/O.
            const [method, , ...options] = request.args;
            Reflect.apply(open, xhr, destination
                ? [method, destination, ...options]
                : [method, 'data:application/octet-stream;base64,%%%', ...options.slice(0, 1)]);
            if (destination) {
                for (const header of request.headers) Reflect.apply(setHeader, xhr, header);
            }
            try {
                const result = Reflect.apply(original, xhr, args);
                report(hit, null, destination);
                return result;
            } catch (error) {
                if (!destination && error.name === 'NetworkError') report(hit);
                else report(hit, error);
                throw error;
            }
        }

        function install() {
            if (installed) return;
            const xhr = window.XMLHttpRequest.prototype;
            const open = xhr.open;
            const setHeader = xhr.setRequestHeader;
            const hooks = [
                [window, 'fetch', interceptFetch],
                [xhr, 'open', interceptOpen],
                [xhr, 'setRequestHeader', interceptHeader],
                [xhr, 'send', (fn, self, args) => interceptSend(fn, self, args, open, setHeader)]
            ];
            const undo = [];
            try {
                for (const [owner, name, apply] of hooks) {
                    const descriptor = Object.getOwnPropertyDescriptor(owner, name);
                    Object.defineProperty(owner, name, {...descriptor, value: new Proxy(owner[name], {apply})});
                    undo.push(() => Object.defineProperty(owner, name, descriptor));
                }
            } catch (error) {
                undo.reverse().forEach(restore => restore());
                throw error;
            }
            window.addEventListener('pagehide', () => { suspended = true; });
            window.addEventListener('pageshow', () => { suspended = false; });
            installed = true;
        }

        return (providedToken, id, includes, excludes) => {
            if (providedToken !== bridgeToken) return undefined;
            const positives = includes.map(source => new RegExp(source, 'i'));
            const negatives = excludes.map(source => new RegExp(source, 'i'));
            const allows = url => matches(positives, url) && !matches(negatives, url);
            return (rules, listener) => {
                if (!Array.isArray(rules)) throw new TypeError('GM_webRequest requires an array of rules');
                if (listener != null && typeof listener !== 'function') throw new TypeError('Invalid GM_webRequest listener');
                if (!rules.length) { registrations.delete(id); return; }
                const compiled = Array.from(rules, compile);
                install();
                registrations.set(id, {id, allows, rules: compiled, listener});
            };
        };
    }
})
