import Combine
import Foundation

/// Keystrokes and suggestions belong to the search controls, not the browser's
/// navigation model. Native edits never request a programmatic text replacement.
@MainActor
final class SearchInputState: ObservableObject {
    struct Edit: Equatable {
        var text = ""
        var isComposing = false
        var replacement = 0
    }

    @Published private(set) var edit = Edit()
    @Published private(set) var isEditing = false
    @Published var suggestions: [String] = []
    @Published var isLoadingSuggestions = false

    var text: String {
        get { edit.text }
        set {
            // Clear/fill/voice/paste-from-another-screen are explicit replacements,
            // including replacing a marked syllable with the same visible text.
            guard edit.text != newValue || edit.isComposing else { return }
            edit = Edit(text: newValue, replacement: edit.replacement &+ 1)
        }
    }

    func receiveEdit(_ text: String, isComposing: Bool) {
        let next = Edit(text: text, isComposing: isComposing, replacement: edit.replacement)
        if edit != next { edit = next }
    }

    func setEditing(_ value: Bool) {
        if isEditing != value { isEditing = value }
    }
}
