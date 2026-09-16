import Foundation

/// Display-only conversion. Source documents and their offsets remain unchanged.
enum ChineseTextDisplay {
    static func convert(_ text: String, mode: String) -> String {
        let transform: StringTransform
        switch mode {
        case "simplified": transform = StringTransform("Hant-Hans")
        case "traditional": transform = StringTransform("Hans-Hant")
        default: return text
        }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}
