import UIKit
import WebKit
import PDFKit

extension Notification.Name {
    static let searchSelectionInSoulo = Notification.Name("soulo.searchSelection")
}

/// Replace only the system web-search command, preserving Look Up and Translate.
@MainActor enum SelectionWebSearch {
    static func replace(in builder: UIMenuBuilder, search: @escaping () -> Void) {
        guard let lookup = builder.menu(for: .lookup) else { return }
        // UIKit augments its lookup group with a Data Detectors web-search item
        // after buildMenu returns. Use our own group to prevent that Safari action.
        builder.remove(menu: .lookup)
        let action = UIAction(title: ToolText.text("search_web"), image: UIImage(systemName: "magnifyingglass")) { _ in search() }
        let group = UIMenu(title: "", identifier: UIMenu.Identifier("soulo.selectionSearch"), options: .displayInline, children: lookup.children + [action])
        builder.insertSibling(group, afterMenu: .standardEdit)
    }

    static func open(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        NotificationCenter.default.post(name: .searchSelectionInSoulo, object: text)
    }

    static func search(in webView: WKWebView) {
        webView.evaluateJavaScript("""
        (() => {
            const reader = document.querySelector('foliate-view');
            for (const {doc} of reader?.renderer?.getContents() || []) {
                const text = doc.getSelection()?.toString();
                if (text) return text;
            }
            const active = document.activeElement;
            if (active && ['TEXTAREA','INPUT'].includes(active.tagName)) {
                return active.value.substring(active.selectionStart || 0, active.selectionEnd || 0);
            }
            return window.getSelection()?.toString() || '';
        })()
        """) { value, _ in open(value as? String) }
    }
}

final class SelectionSearchWebView: WKWebView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionWebSearch.replace(in: builder) { [weak self] in
            if let self { SelectionWebSearch.search(in: self) }
        }
    }
}

final class SelectionSearchPDFView: PDFView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionWebSearch.replace(in: builder) { [weak self] in SelectionWebSearch.open(self?.currentSelection?.string) }
    }
}

final class SelectionSearchTextView: UITextView {
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        SelectionWebSearch.replace(in: builder) { [weak self] in
            guard let self, let range = self.selectedTextRange else { return }
            SelectionWebSearch.open(self.text(in: range))
        }
    }
}
