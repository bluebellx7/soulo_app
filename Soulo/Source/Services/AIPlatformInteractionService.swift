import Foundation
import WebKit

struct AIPlatformInteractionService {

    /// Detect login status by checking URL and page content
    static func loginDetectionScript(for platformName: String) -> String {
        """
        (function() {
            var url = window.location.href.toLowerCase();
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

    /// AI chat interaction script
    static func aiChatScript(query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
        return """
        (function() {
            var query = '\(escaped)';
            var attempts = 0;

            function tryInteract() {
                attempts++;
                if (attempts > 30) return;

                var textarea = document.querySelector('textarea') ||
                               document.querySelector('[contenteditable="true"][role="textbox"]') ||
                               document.querySelector('[contenteditable="true"]') ||
                               document.querySelector('#chat-input');

                if (!textarea) {
                    setTimeout(tryInteract, 500);
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
                setTimeout(function() {
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
                if (attempt > 15) return;

                // Find any non-disabled button that could be "send"
                var sendBtn = findSendButton(textarea);

                if (sendBtn && !sendBtn.disabled) {
                    sendBtn.click();
                    setTimeout(function() { sendBtn.click(); }, 100);
                    return;
                }

                // If button exists but disabled, try to enable it
                if (sendBtn && sendBtn.disabled) {
                    // Trigger more events to make React update
                    textarea.dispatchEvent(new Event('input', { bubbles: true }));
                    textarea.dispatchEvent(new Event('change', { bubbles: true }));
                    textarea.dispatchEvent(new KeyboardEvent('keyup', { key: 'a', bubbles: true }));

                    // Force enable and click
                    setTimeout(function() {
                        if (sendBtn.disabled) {
                            sendBtn.removeAttribute('disabled');
                            sendBtn.disabled = false;
                        }
                        sendBtn.click();
                    }, 300);
                    return;
                }

                // No button found yet, try Enter key
                if (attempt > 3) {
                    textarea.focus();
                    var enterEvent = new KeyboardEvent('keydown', {
                        key: 'Enter', code: 'Enter', keyCode: 13, which: 13,
                        bubbles: true, cancelable: true
                    });
                    textarea.dispatchEvent(enterEvent);
                }

                // Retry
                setTimeout(function() { waitAndSend(textarea, attempt + 1); }, 500);
            }

            function isJunkButton(btn) {
                var text = (btn.textContent || '').toLowerCase();
                var junk = ['download', '下载', 'app store', 'install', '安装', 'get app', '获取'];
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

            setTimeout(tryInteract, 800);
            return 'injecting';
        })();
        """
    }

    /// Xiaohongshu: navigate to search results page directly via JS
    static func xiaohongshuSearchScript(query: String) -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return """
        (function() {
            window.location.href = 'https://www.xiaohongshu.com/search_result?keyword=\(encoded)&source=web_explore_feed&type=51';
        })();
        """
    }

    /// Metaso: fill search input and submit
    static func metasoSearchScript(query: String) -> String {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
            var query = '\(escaped)';
            var attempts = 0;
            function trySearch() {
                attempts++;
                if (attempts > 20) return;
                var input = document.querySelector('input[type="search"]') ||
                            document.querySelector('input[placeholder*="搜索"]') ||
                            document.querySelector('input[placeholder*="search" i]') ||
                            document.querySelector('textarea');
                if (!input) { setTimeout(trySearch, 500); return; }
                input.focus();
                if (input.tagName === 'INPUT' || input.tagName === 'TEXTAREA') {
                    var s = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value') ||
                            Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
                    if (s && s.set) s.set.call(input, query);
                }
                input.dispatchEvent(new Event('input', { bubbles: true }));
                input.dispatchEvent(new Event('change', { bubbles: true }));
                setTimeout(function() {
                    // Try submit via Enter key
                    input.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true
                    }));
                    // Also try clicking search button
                    var btn = document.querySelector('button[type="submit"]') ||
                              document.querySelector('[class*="search-btn" i]') ||
                              document.querySelector('[aria-label*="搜索"]');
                    if (btn) btn.click();
                }, 300);
            }
            setTimeout(trySearch, 800);
            return 'injecting';
        })();
        """
    }

    @MainActor
    static func interact(webView: WKWebView?, platform: SearchPlatform, keyword: String) {
        guard let webView else { return }
        if platform.name == "platform_xiaohongshu" {
            webView.evaluateJavaScript(xiaohongshuSearchScript(query: keyword)) { _, _ in }
        } else if platform.name == "platform_metaso" {
            webView.evaluateJavaScript(metasoSearchScript(query: keyword)) { _, _ in }
        } else {
            webView.evaluateJavaScript(aiChatScript(query: keyword)) { _, _ in }
        }
    }
}
