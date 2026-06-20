import Foundation

enum WebViewScripts {
    static let loginOverlayRemoval = """
    (function() {
        var skipDomains = ['deepseek.com', 'qianwen.com', 'chatgpt.com', 'claude.ai', 'xiaohongshu.com', 'taobao.com', 'jd.com', 'yuanbao.tencent.com', 'doubao.com', 'metaso.cn'];
        var host = window.location.hostname;
        for (var i = 0; i < skipDomains.length; i++) {
            if (host.includes(skipDomains[i])) return;
        }

        const OVERLAY_SELECTORS = [
            '.login-modal', '.signup-dialog', '.login-popup', '.signup-popup', '.auth-modal',
            '[class*="login-guide"]', '[class*="loginGuide"]', '[class*="login-panel"]',
            '[class*="login-mask"]', '[class*="dy-account"]', '[class*="passport-sdk"]',
            '[class*="loginLayer"]', '[class*="login-layer"]',
            '[class*="mask-login"]', '[class*="guide-login"]'
        ];

        function shouldRemove(el) {
            try {
                const style = window.getComputedStyle(el);
                const zIndex = parseInt(style.zIndex, 10);
                const position = style.position;
                return (position === 'fixed' || position === 'absolute') && zIndex > 999;
            } catch (_) {}
            return false;
        }

        function removeOverlays() {
            OVERLAY_SELECTORS.forEach(function(selector) {
                try {
                    document.querySelectorAll(selector).forEach(function(el) {
                        if (shouldRemove(el)) el.remove();
                    });
                } catch (_) {}
            });

            try {
                document.querySelectorAll('div').forEach(function(el) {
                    var s = window.getComputedStyle(el);
                    if ((s.position === 'fixed' || s.position === 'absolute') &&
                        parseInt(s.zIndex) > 999 &&
                        el.offsetWidth > 100 && el.offsetHeight > 100) {
                        var text = (el.textContent || '').toLowerCase();
                        if (text.includes('登录') || text.includes('login') ||
                            text.includes('注册') || text.includes('sign') ||
                            text.includes('验证码') || text.includes('手机号')) {
                            el.remove();
                        }
                    }
                });
            } catch(_) {}

            try {
                document.body.style.overflow = '';
                document.documentElement.style.overflow = '';
            } catch (_) {}
        }

        removeOverlays();

        const observer = new MutationObserver(function(mutations) {
            let shouldCheck = false;
            mutations.forEach(function(m) {
                if (m.addedNodes.length > 0) shouldCheck = true;
            });
            if (shouldCheck) removeOverlays();
        });

        observer.observe(document.body || document.documentElement, {
            childList: true,
            subtree: true
        });
    })();
    """

    static func initialElementBlockStyle(css: String) -> String {
        """
        (function() {
            var style = document.createElement('style');
            style.id = 'soulo-element-block-style';
            style.textContent = '\(css.escapedForJS)';
            (document.head || document.documentElement).appendChild(style);
        })();
        """
    }

    static let elementPicker = """
    (function() {
        if (window.__souloElementPickerInstalled) return;
        window.__souloElementPickerInstalled = true;
        var active = false;
        var highlighted = null;
        var menu = null;
        var box = null;
        var shield = null;
        var lastPoint = null;

        function selectorCandidates(el) {
            if (!el || el.nodeType !== 1) return '';
            var candidates = [];
            if (el.id && !/\\s/.test(el.id)) candidates.push('#' + CSS.escape(el.id));
            ['data-testid', 'data-test', 'data-cy', 'data-ad-slot', 'data-ad', 'aria-label', 'role'].forEach(function(attr) {
                var value = el.getAttribute && el.getAttribute(attr);
                if (value && value.length < 80) candidates.push(el.localName.toLowerCase() + '[' + attr + '="' + cssAttributeValue(value) + '"]');
            });
            var parts = [];
            var node = el;
            while (el && el.nodeType === 1 && el !== document.body) {
                var part = el.localName.toLowerCase();
                if (el.classList && el.classList.length) {
                    var classes = Array.prototype.slice.call(el.classList).filter(function(c) {
                        return c && !/^soulo-/.test(c) && c.length < 40;
                    }).slice(0, 3);
                    if (classes.length) part += '.' + classes.map(function(c) { return CSS.escape(c); }).join('.');
                }
                var parent = el.parentElement;
                if (parent) {
                    var same = Array.prototype.filter.call(parent.children, function(child) {
                        return child.localName === el.localName;
                    });
                    if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
                }
                parts.unshift(part);
                if (parts.length >= 5) break;
                el = parent;
            }
            if (parts.length) candidates.push(parts.join(' > '));
            if (node.classList && node.classList.length) {
                var stable = Array.prototype.slice.call(node.classList).filter(function(c) {
                    return c && !/^soulo-/.test(c) && !/^[a-z0-9_-]{1,3}$/i.test(c) && c.length < 40;
                }).slice(0, 3);
                if (stable.length) candidates.push(node.localName.toLowerCase() + '.' + stable.map(function(c) { return CSS.escape(c); }).join('.'));
            }
            return dedupe(candidates.filter(Boolean)).filter(isUsableSelector).slice(0, 5).join(',');
        }

        function cssAttributeValue(value) {
            return String(value).replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"').replace(/\\n/g, '\\\\A ');
        }

        function dedupe(items) {
            var seen = {};
            return items.filter(function(item) {
                if (!item || seen[item]) return false;
                seen[item] = true;
                return true;
            });
        }

        function isUsableSelector(selector) {
            try {
                document.querySelector(selector);
                return true;
            } catch (_) {
                return false;
            }
        }

        function xpathFor(el) {
            if (!el || el.nodeType !== 1) return '';
            if (el.id && !/\\s/.test(el.id)) {
                return '//*[@id="' + el.id.replace(/"/g, '\\\\"') + '"]';
            }
            var parts = [];
            var node = el;
            while (node && node.nodeType === 1 && node !== document.documentElement) {
                var index = 1;
                var sibling = node.previousElementSibling;
                while (sibling) {
                    if (sibling.localName === node.localName) index++;
                    sibling = sibling.previousElementSibling;
                }
                parts.unshift(node.localName.toLowerCase() + '[' + index + ']');
                node = node.parentElement;
                if (parts.length >= 8) break;
            }
            return parts.length ? '/html/' + parts.join('/') : '';
        }

        function labelFor(el) {
            var text = (el.innerText || el.getAttribute('aria-label') || el.getAttribute('title') || el.localName || '').trim();
            text = text.replace(/\\s+/g, ' ');
            return text.length > 48 ? text.slice(0, 48) + '...' : text;
        }

        function ensureBox() {
            if (box) return box;
            box = document.createElement('div');
            box.style.cssText = 'position:fixed;z-index:2147483646;border:2px solid #ff3b30;background:rgba(255,59,48,.14);pointer-events:none;display:none;';
            document.documentElement.appendChild(box);
            return box;
        }

        function ensureShield() {
            if (shield) return shield;
            shield = document.createElement('div');
            shield.id = 'soulo-element-picker-shield';
            shield.style.cssText = 'position:fixed;inset:0;z-index:2147483645;background:rgba(0,0,0,0.001);cursor:crosshair;touch-action:none;user-select:none;-webkit-user-select:none;';
            document.documentElement.appendChild(shield);
            return shield;
        }

        function underlyingElementAt(x, y) {
            var oldPointer = shield ? shield.style.pointerEvents : '';
            var oldBoxDisplay = box ? box.style.display : '';
            if (shield) shield.style.pointerEvents = 'none';
            if (box) box.style.display = 'none';
            var el = document.elementFromPoint(x, y);
            if (box) box.style.display = oldBoxDisplay;
            if (shield) shield.style.pointerEvents = oldPointer;
            if (!el || el === document.documentElement || el === document.body) return el;
            if (el.closest && el.closest('#soulo-element-picker-shield')) return null;
            return el;
        }

        function showHighlight(el) {
            if (!el || el === document.documentElement || el === document.body) return;
            highlighted = el;
            var r = el.getBoundingClientRect();
            var b = ensureBox();
            b.style.left = r.left + 'px';
            b.style.top = r.top + 'px';
            b.style.width = r.width + 'px';
            b.style.height = r.height + 'px';
            b.style.display = 'block';
        }

        function removeMenu() {
            if (menu) menu.remove();
            menu = null;
        }

        function showMenu(el, x, y) {
            if (!el || el === document.documentElement || el === document.body) return;
            removeMenu();
            menu = document.createElement('div');
            menu.style.cssText = 'position:fixed;z-index:2147483647;left:' + Math.min(x, window.innerWidth - 190) + 'px;top:' + Math.min(y, window.innerHeight - 96) + 'px;background:rgba(20,20,22,.96);color:white;border-radius:12px;box-shadow:0 8px 28px rgba(0,0,0,.35);font:14px -apple-system,BlinkMacSystemFont,sans-serif;overflow:hidden;min-width:176px;';
            var title = document.createElement('div');
            title.textContent = labelFor(el) || 'Element';
            title.style.cssText = 'padding:10px 12px;color:rgba(255,255,255,.7);font-size:12px;max-width:220px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;';
            var block = document.createElement('button');
            block.textContent = '排除该元素';
            block.style.cssText = 'display:block;width:100%;padding:12px;border:0;background:#ff3b30;color:#fff;font:600 14px -apple-system;text-align:left;';
            block.onclick = function(ev) {
                cancelEvent(ev);
                var selector = selectorCandidates(el);
                var xpath = xpathFor(el);
                if ((selector || xpath) && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.souloElementBlocker) {
                    window.webkit.messageHandlers.souloElementBlocker.postMessage({
                        host: location.hostname,
                        selector: selector,
                        xpath: xpath,
                        label: labelFor(el)
                    });
                }
                el.style.setProperty('display', 'none', 'important');
                window.souloElementPickerStop();
            };
            var parent = document.createElement('button');
            parent.textContent = '选择父级';
            parent.style.cssText = 'display:block;width:100%;padding:12px;border:0;background:rgba(255,255,255,.08);color:#fff;font:600 14px -apple-system;text-align:left;';
            parent.onclick = function(ev) {
                cancelEvent(ev);
                if (el.parentElement && el.parentElement !== document.body && el.parentElement !== document.documentElement) {
                    showHighlight(el.parentElement);
                    showMenu(el.parentElement, x, y);
                }
            };
            menu.appendChild(title);
            menu.appendChild(block);
            if (el.parentElement && el.parentElement !== document.body && el.parentElement !== document.documentElement) {
                menu.appendChild(parent);
            }
            document.documentElement.appendChild(menu);
        }

        function cancelEvent(e) {
            if (!e) return;
            if (e.preventDefault) e.preventDefault();
            if (e.stopPropagation) e.stopPropagation();
            if (e.stopImmediatePropagation) e.stopImmediatePropagation();
        }

        function onMove(e) {
            if (!active) return;
            cancelEvent(e);
            if (menu && menu.contains(e.target)) return;
            lastPoint = { x: e.clientX, y: e.clientY };
            var el = underlyingElementAt(e.clientX, e.clientY);
            showHighlight(el);
        }

        function onPreClick(e) {
            if (!active) return;
            if (menu && menu.contains(e.target)) return;
            cancelEvent(e);
            var point = pointFromEvent(e);
            if (point) {
                lastPoint = point;
                var el = underlyingElementAt(point.x, point.y);
                if (el) showHighlight(el);
            }
        }

        function onClick(e) {
            if (!active) return;
            if (menu && menu.contains(e.target)) return;
            cancelEvent(e);
            var point = pointFromEvent(e) || lastPoint;
            var el = (point ? underlyingElementAt(point.x, point.y) : null) || highlighted;
            if (el && point) showMenu(el, point.x, point.y);
        }

        function pointFromEvent(e) {
            if (!e) return null;
            if (typeof e.clientX === 'number' && typeof e.clientY === 'number') return { x: e.clientX, y: e.clientY };
            if (e.touches && e.touches[0]) return { x: e.touches[0].clientX, y: e.touches[0].clientY };
            if (e.changedTouches && e.changedTouches[0]) return { x: e.changedTouches[0].clientX, y: e.changedTouches[0].clientY };
            return null;
        }

        function onTouchMove(e) {
            if (!active || !e.touches || !e.touches[0]) return;
            cancelEvent(e);
            var t = e.touches[0];
            lastPoint = { x: t.clientX, y: t.clientY };
            var el = underlyingElementAt(t.clientX, t.clientY);
            if (el) showHighlight(el);
        }

        function onTouchEnd(e) {
            if (!active || !e.changedTouches || !e.changedTouches[0]) return;
            if (menu && menu.contains(e.target)) return;
            cancelEvent(e);
            var t = e.changedTouches[0];
            lastPoint = { x: t.clientX, y: t.clientY };
            var el = underlyingElementAt(t.clientX, t.clientY) || highlighted;
            if (el) showMenu(el, t.clientX, t.clientY);
        }

        window.souloElementPickerStart = function() {
            active = true;
            var eventOptions = { capture: true, passive: false };
            var s = ensureShield();
            s.addEventListener('pointerdown', onPreClick, eventOptions);
            s.addEventListener('pointerup', onClick, eventOptions);
            s.addEventListener('pointermove', onMove, eventOptions);
            s.addEventListener('mousedown', onPreClick, eventOptions);
            s.addEventListener('mouseup', onClick, eventOptions);
            s.addEventListener('mousemove', onMove, eventOptions);
            s.addEventListener('touchstart', onPreClick, eventOptions);
            s.addEventListener('touchmove', onTouchMove, eventOptions);
            s.addEventListener('touchend', onTouchEnd, eventOptions);
            s.addEventListener('click', onClick, eventOptions);
            document.addEventListener('pointerdown', onPreClick, eventOptions);
            document.addEventListener('pointerup', onPreClick, eventOptions);
            document.addEventListener('mousedown', onPreClick, eventOptions);
            document.addEventListener('mouseup', onPreClick, eventOptions);
            document.addEventListener('mousemove', onMove, eventOptions);
            document.addEventListener('touchstart', onPreClick, eventOptions);
            document.addEventListener('touchmove', onTouchMove, eventOptions);
            document.addEventListener('click', onClick, eventOptions);
            document.addEventListener('touchend', onTouchEnd, eventOptions);
            document.addEventListener('auxclick', onPreClick, eventOptions);
            document.addEventListener('dblclick', onPreClick, eventOptions);
            document.addEventListener('contextmenu', onPreClick, eventOptions);
            document.documentElement.style.cursor = 'crosshair';
        };

        window.souloElementPickerStop = function() {
            active = false;
            var eventOptions = { capture: true, passive: false };
            if (shield) {
                shield.removeEventListener('pointerdown', onPreClick, eventOptions);
                shield.removeEventListener('pointerup', onClick, eventOptions);
                shield.removeEventListener('pointermove', onMove, eventOptions);
                shield.removeEventListener('mousedown', onPreClick, eventOptions);
                shield.removeEventListener('mouseup', onClick, eventOptions);
                shield.removeEventListener('mousemove', onMove, eventOptions);
                shield.removeEventListener('touchstart', onPreClick, eventOptions);
                shield.removeEventListener('touchmove', onTouchMove, eventOptions);
                shield.removeEventListener('touchend', onTouchEnd, eventOptions);
                shield.removeEventListener('click', onClick, eventOptions);
                shield.remove();
                shield = null;
            }
            document.removeEventListener('pointerdown', onPreClick, eventOptions);
            document.removeEventListener('pointerup', onPreClick, eventOptions);
            document.removeEventListener('mousedown', onPreClick, eventOptions);
            document.removeEventListener('mouseup', onPreClick, eventOptions);
            document.removeEventListener('mousemove', onMove, eventOptions);
            document.removeEventListener('touchstart', onPreClick, eventOptions);
            document.removeEventListener('touchmove', onTouchMove, eventOptions);
            document.removeEventListener('click', onClick, eventOptions);
            document.removeEventListener('touchend', onTouchEnd, eventOptions);
            document.removeEventListener('auxclick', onPreClick, eventOptions);
            document.removeEventListener('dblclick', onPreClick, eventOptions);
            document.removeEventListener('contextmenu', onPreClick, eventOptions);
            if (box) box.style.display = 'none';
            removeMenu();
            lastPoint = null;
            document.documentElement.style.cursor = '';
        };
    })();
    """
}
