import Foundation
import WebKit

struct AIPlatformInteractionService {

    /// Detect login status by checking URL and page content
    static func loginDetectionScript(for platformName: String) -> String {
        let kimiLogin = ["Kimi", "platform_kimi"].contains(platformName) ? """
            var kimiLoginButtons = document.querySelectorAll('.login-button, .next-sidebar-history-list__login');
            for (var k = 0; k < kimiLoginButtons.length; k++) {
                var bounds = kimiLoginButtons[k].getBoundingClientRect();
                if (bounds.width > 0 && bounds.height > 0) return 'needs_login';
            }
        """ : ""
        return """
        (function() {
            var url = window.location.href.toLowerCase();
            \(kimiLogin)
            // URL-based detection
            if (url.includes('/login') || url.includes('/signin') || url.includes('/auth') || url.includes('/passport')) {
                return 'needs_login';
            }
            // Page has a visible password field
            var pwdFields = document.querySelectorAll('input[type="password"]');
            for (var i = 0; i < pwdFields.length; i++) {
                var rect = pwdFields[i].getBoundingClientRect();
                if (rect.width > 0 && rect.height > 0) return 'needs_login';
            }
            // Has a textarea/chat input or search input = likely logged in
            var hasInput = document.querySelector('textarea') ||
                           document.querySelector('[contenteditable="true"]') ||
                           document.querySelector('#chat-input') ||
                           document.querySelector('input[type="search"]') ||
                           document.querySelector('input[placeholder*="搜索"]') ||
                           document.querySelector('input[placeholder*="search" i]');
            if (hasInput) return 'logged_in';
            // No clear signal — assume needs login if page has login-related buttons
            var loginBtn = document.querySelector('button[class*="login" i]') ||
                           document.querySelector('a[href*="login"]') ||
                           document.querySelector('[class*="sign-in" i]');
            if (loginBtn) return 'needs_login';
            return 'logged_in';
        })();
        """
    }

    /// Cancel delayed work when the user leaves or replaces the interaction.
    private static let interactionLifecycle = """
    if (window.__souloCancelAIInteraction) window.__souloCancelAIInteraction();
    var cancelled = false, timers = new Set(), initialURL = location.href;
    function cancelInteraction() {
        cancelled = true;
        timers.forEach(clearTimeout); timers.clear();
        window.removeEventListener('pagehide', cancelInteraction);
        document.removeEventListener('visibilitychange', visibilityChanged);
    }
    function visibilityChanged() { if (document.hidden) cancelInteraction(); }
    function scheduleInteraction(action, delay) {
        var timer = setTimeout(function() {
            timers.delete(timer);
            if (cancelled || document.hidden || location.href !== initialURL) {
                cancelInteraction(); return;
            }
            action();
        }, delay);
        timers.add(timer);
    }
    window.__souloCancelAIInteraction = cancelInteraction;
    window.addEventListener('pagehide', cancelInteraction);
    document.addEventListener('visibilitychange', visibilityChanged);
    """

    @MainActor
    static func cancelInteraction(in webView: WKWebView?) {
        webView?.evaluateJavaScript("window.__souloCancelAIInteraction && window.__souloCancelAIInteraction();", completionHandler: nil)
    }

    /// AI chat interaction script
    static func aiChatScript(query: String) -> String {
        let escaped = query.escapedForJS
        return """
        (function() {
            \(interactionLifecycle)
            var query = '\(escaped)';
            var attempts = 0;

            function tryInteract() {
                attempts++;
                if (attempts > 30) { cancelInteraction(); return; }

                var textarea = document.querySelector('textarea') ||
                               document.querySelector('[contenteditable="true"][role="textbox"]') ||
                               document.querySelector('[contenteditable="true"]') ||
                               document.querySelector('#chat-input');

                if (!textarea) {
                    scheduleInteraction(tryInteract, 500);
                    return;
                }

                // Focus and clear
                textarea.focus();
                textarea.click();

                // Use execCommand for reliable React integration
                // First select all existing content
                if (textarea.tagName === 'TEXTAREA' || textarea.tagName === 'INPUT') {
                    textarea.select();
                } else {
                    var range = document.createRange();
                    range.selectNodeContents(textarea);
                    var sel = window.getSelection();
                    sel.removeAllRanges();
                    sel.addRange(range);
                }

                // Delete selection then insert new text
                document.execCommand('delete', false);
                document.execCommand('insertText', false, query);

                // Verify and fallback
                scheduleInteraction(function() {
                    var val = textarea.value || textarea.innerText || '';
                    if (val.trim().length === 0) {
                        // Fallback: native setter
                        if (textarea.tagName === 'TEXTAREA') {
                            var s = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
                            if (s && s.set) s.set.call(textarea, query);
                        }
                        textarea.dispatchEvent(new Event('input', { bubbles: true }));
                    }
                    // Wait then send
                    waitAndSend(textarea, 0);
                }, 500);
            }

            function waitAndSend(textarea, attempt) {
                if (attempt > 15 || !textarea.isConnected) { cancelInteraction(); return; }

                // Find any non-disabled button that could be "send"
                var sendBtn = findSendButton(textarea);

                if (sendBtn && !sendBtn.disabled) {
                    cancelInteraction();
                    sendBtn.click();
                    return;
                }

                // If button exists but disabled, try to enable it
                if (sendBtn && sendBtn.disabled) {
                    // Trigger more events to make React update
                    textarea.dispatchEvent(new Event('input', { bubbles: true }));
                    textarea.dispatchEvent(new Event('change', { bubbles: true }));
                    textarea.dispatchEvent(new KeyboardEvent('keyup', { key: 'a', bubbles: true }));

                    // Let the site enable its own control after processing
                    // input. A disabled button may also mean rate limiting.
                    scheduleInteraction(function() { waitAndSend(textarea, attempt + 1); }, 500);
                    return;
                }

                // No button found yet, try Enter key
                if (attempt > 3) {
                    textarea.focus();
                    var enterEvent = new KeyboardEvent('keydown', {
                        key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                        bubbles: true, cancelable: true
                    });
                    cancelInteraction();
                    textarea.dispatchEvent(enterEvent);
                    return;
                }

                // Retry
                scheduleInteraction(function() { waitAndSend(textarea, attempt + 1); }, 500);
            }

            function isJunkButton(btn) {
                var text = ((btn.textContent || '') + ' ' + (btn.getAttribute('aria-label') || '')).toLowerCase();
                var junk = ['download', '下载', 'app store', 'install', '安装', 'get app', '获取', 'stop generating', '停止生成', '停止回答'];
                for (var j = 0; j < junk.length; j++) {
                    if (text.includes(junk[j])) return true;
                }
                var href = btn.getAttribute('href') || '';
                if (href.includes('apps.apple') || href.includes('play.google')) return true;
                // Links disguised as buttons
                if (btn.closest('a[href*="apps.apple"]') || btn.closest('a[href*="play.google"]')) return true;
                return false;
            }

            function findSendButton(textarea) {
                // Direct selectors
                var btn = document.querySelector('[data-testid="send-button"]') ||
                          document.querySelector('[aria-label="Send"]') ||
                          document.querySelector('[aria-label="send"]') ||
                          document.querySelector('[aria-label="发送"]') ||
                          document.querySelector('button[class*="send" i]');
                if (btn && !isJunkButton(btn)) return btn;

                // Walk up from textarea ONLY (max 3 levels to stay near the input area)
                var parent = textarea.parentElement;
                for (var l = 0; l < 3 && parent; l++) {
                    var buttons = parent.querySelectorAll('button');
                    for (var i = buttons.length - 1; i >= 0; i--) {
                        var b = buttons[i];
                        if (b.disabled || isJunkButton(b)) continue;
                        if (b.querySelector('svg')) {
                            return b;
                        }
                    }
                    parent = parent.parentElement;
                }
                return null;
            }

            scheduleInteraction(tryInteract, 800);
            return 'injecting';
        })();
        """
    }

    /// Metaso: fill search input and submit
    static func metasoSearchScript(query: String) -> String {
        let escaped = query.escapedForJS
        return """
        (function() {
            \(interactionLifecycle)
            var query = '\(escaped)';
            var attempts = 0;
            function trySearch() {
                attempts++;
                if (attempts > 20) { cancelInteraction(); return; }
                var input = document.querySelector('input[type="search"]') ||
                            document.querySelector('input[placeholder*="搜索"]') ||
                            document.querySelector('input[placeholder*="search" i]') ||
                            document.querySelector('textarea');
                if (!input) { scheduleInteraction(trySearch, 500); return; }
                input.focus();
                if (input.tagName === 'INPUT' || input.tagName === 'TEXTAREA') {
                    var prototype = input.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                    var s = Object.getOwnPropertyDescriptor(prototype, 'value');
                    if (s && s.set) s.set.call(input, query);
                }
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                scheduleInteraction(function() {
                    if (!input.isConnected) { cancelInteraction(); return; }
                    var btn = document.querySelector('button[type="submit"]') ||
                              document.querySelector('[class*="search-btn" i]') ||
                              document.querySelector('[aria-label*="搜索"]');
                    cancelInteraction();
                    if (btn) {
                        if (!btn.disabled) btn.click();
                    } else {
                        input.dispatchEvent(new KeyboardEvent('keydown', {
                            key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
                        }));
                    }
                }, 300);
            }
            scheduleInteraction(trySearch, 800);
            return 'injecting';
        })();
        """
    }

    /// Kimi uses a Lexical editor and a div-based send control, not DeepSeek's button.
    static func kimiChatScript(query: String) -> String {
        let escaped = query.escapedForJS
        return """
        (function() {
            \(interactionLifecycle)
            var query = '\(escaped)', attempts = 0;
            function visible(el) {
                return el && el.isConnected && el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().height > 0;
            }
            function disabled(el) {
                return !el || el.disabled || el.getAttribute('aria-disabled') === 'true' ||
                    /(^|[\\s_-])disabled($|[\\s_-])/.test(el.className || '');
            }
            function send(editor, attempt) {
                if (cancelled || !editor.isConnected || (editor.value || editor.innerText || '').trim() !== query.trim()) {
                    cancelInteraction(); return;
                }
                var container = document.querySelector('.send-button-container');
                var icon = container && container.querySelector('.send-icon, [name="Send"]');
                var button = icon && (icon.closest('button, [role="button"], .send-button') || container);
                if (visible(button) && !disabled(button) && !disabled(container)) {
                    cancelInteraction(); button.click(); return;
                }
                if (attempt >= 20) { cancelInteraction(); return; }
                scheduleInteraction(function() { send(editor, attempt + 1); }, 250);
            }
            function fill() {
                if (++attempts > 30) { cancelInteraction(); return; }
                var editor = document.querySelector('.chat-input-editor[contenteditable="true"], [data-lexical-editor="true"][contenteditable="true"]');
                if (!visible(editor)) { scheduleInteraction(fill, 500); return; }
                editor.focus();
                var range = document.createRange(); range.selectNodeContents(editor);
                var selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
                document.execCommand('insertText', false, query);
                // Lexical applies insertText asynchronously. Mutating textContent here
                // races its state update and can duplicate the user's query.
                scheduleInteraction(function() { send(editor, 0); }, 300);
            }
            scheduleInteraction(fill, 500);
            return 'injecting';
        })();
        """
    }

    @MainActor
    static func interact(webView: WKWebView?, platform: SearchPlatform, keyword: String) {
        guard let webView else { return }
        if platform.name == "platform_xiaohongshu" {
            if let url = platform.searchURL(for: keyword) { webView.load(URLRequest(url: url)) }
        } else if ["Kimi", "platform_kimi"].contains(platform.name) {
            guard ["www.kimi.com", "kimi.com"].contains(webView.url?.host?.lowercased() ?? "") else { return }
            webView.evaluateJavaScript(kimiChatScript(query: keyword)) { _, _ in }
        } else if platform.name == "platform_metaso" {
            webView.evaluateJavaScript(metasoSearchScript(query: keyword)) { _, _ in }
        } else {
            webView.evaluateJavaScript(aiChatScript(query: keyword)) { _, _ in }
        }
    }
}
