import SwiftUI
import UIKit

/// Selects the initial query once after this field joins the presented window.
/// Subsequent taps and edits retain the user's own caret/selection.
struct PresentationSearchField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = text
        field.placeholder = placeholder
        field.accessibilityLabel = placeholder
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = .label
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        if field.text != text { field.text = text }
    }

    final class Field: UITextField {
        private var didSelectInitialText = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !didSelectInitialText else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, !self.didSelectInitialText else { return }
                if self.becomeFirstResponder() { self.selectInitialText() }
            }
        }

        func selectInitialText() {
            guard !didSelectInitialText, isFirstResponder else { return }
            didSelectInitialText = true
            selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: PresentationSearchField
        init(parent: PresentationSearchField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onFocusChanged(true)
            DispatchQueue.main.async { (textField as? Field)?.selectInitialText() }
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onFocusChanged(false)
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return true
        }
    }
}
