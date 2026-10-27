import SwiftUI
import UIKit

/// UIKit owns the marked text and caret. SwiftUI only replaces text for an
/// explicit clear/fill command, never as an echo of the keyboard's last edit.
struct SearchInputField: UIViewRepresentable {
    @ObservedObject var input: SearchInputState
    let placeholder: String
    let fontSize: CGFloat
    let textColor: UIColor
    let placeholderColor: UIColor
    var focusRequest = 0
    var wantsFocus = true
    var onFocusChanged: (Bool) -> Void = { _ in }
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> Field {
        let field = Field()
        field.text = input.text
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = textColor
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor])
        field.keyboardType = .default
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.compositionChanged = { [weak coordinator = context.coordinator] field in coordinator?.changed(field) }
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        let shouldFocus = coordinator.parent.focusRequest != focusRequest
        coordinator.parent = self
        if coordinator.replacement != input.edit.replacement {
            coordinator.isReplacing = true
            field.unmarkText()
            field.text = input.text
            coordinator.replacement = input.edit.replacement
            coordinator.isReplacing = false
        }
        // Updating keyboard traits or attributedText during composition can
        // terminate the input method's session. Appearance changes stay separate.
        if field.textColor != textColor { field.textColor = textColor }
        if field.font?.pointSize != fontSize { field.font = .systemFont(ofSize: fontSize) }
        if field.placeholder != placeholder || coordinator.placeholderColor != placeholderColor {
            field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: placeholderColor])
            coordinator.placeholderColor = placeholderColor
        }
        if shouldFocus {
            DispatchQueue.main.async { [weak field] in
                guard let field, field.window != nil else { return }
                if wantsFocus {
                    if !field.isFirstResponder { field.becomeFirstResponder() }
                } else if field.isFirstResponder { field.resignFirstResponder() }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: Field, context: Context) -> CGSize? {
        let width = proposal.width ?? max(1, uiView.intrinsicContentSize.width)
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: fitted.height)
    }

    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        field.compositionChanged = nil
        field.delegate = nil
        coordinator.parent.input.setEditing(false)
    }

    final class Field: UITextField {
        var compositionChanged: ((Field) -> Void)?
        override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
            super.setMarkedText(markedText, selectedRange: selectedRange)
            compositionChanged?(self)
        }
        override func unmarkText() {
            super.unmarkText()
            compositionChanged?(self)
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchInputField
        var replacement: Int
        var placeholderColor: UIColor
        var isReplacing = false

        init(parent: SearchInputField) {
            self.parent = parent
            replacement = parent.input.edit.replacement
            placeholderColor = parent.placeholderColor
        }

        @objc func changed(_ field: UITextField) {
            guard !isReplacing else { return }
            parent.input.receiveEdit(field.text ?? "", isComposing: field.markedTextRange != nil)
        }
        func textFieldDidChangeSelection(_ textField: UITextField) { changed(textField) }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.input.setEditing(true)
            parent.onFocusChanged(true)
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            changed(textField)
            parent.input.setEditing(false)
            parent.onFocusChanged(false)
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            // The input method may use Return to accept a candidate first.
            guard textField.markedTextRange == nil else { return false }
            changed(textField)
            textField.resignFirstResponder()
            parent.onSubmit()
            return true
        }
    }
}
