#if canImport(UIKit)
import SwiftUI

struct LocalAILinkResultsView: View {
    let result: LocalAILinkResult
    @State private var expanded = false
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(result.links.prefix(expanded ? 100 : 5).enumerated()), id: \.element.id) { index, link in
                HStack(alignment: .center, spacing: 8) {
                    Link(destination: link.url) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(index + 1). " + link.title).font(.subheadline.weight(.medium)).foregroundStyle(Color.primary).lineLimit(3)
                            Text(link.url.host ?? "").font(.caption).foregroundStyle(Color.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("localAI.link.\(index + 1)")
                    Button {
                        UIPasteboard.general.string = link.url.absoluteString; copied = link.id
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: copied == link.id ? "checkmark" : "doc.on.doc").frame(width: 44, height: 44)
                    }.foregroundStyle(copied == link.id ? Color.green : LocalAIStyle.accent)
                        .accessibilityLabel(AIL10n.text(copied == link.id ? "copied" : "copy"))
                        .accessibilityIdentifier("localAI.link.copy.\(index + 1)")
                }.padding(12).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            if !expanded, result.links.count > 5 {
                Button(String(format: AIL10n.text("links_more"), result.links.count - 5)) { expanded = true }
                    .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("localAI.links.expand")
            }
            if result.limited { Text(AIL10n.text("links_limited")).font(.footnote).foregroundStyle(.secondary) }
        }
    }
}

/// Small native Markdown renderer; links still use the host's restricted OpenURLAction.
struct LocalAIMessageContentView: View, Equatable {
    let text: String
    private struct Block: Identifiable {
        let id: Int
        let text: String
        let style: Int // paragraph, heading, list, quote, code
    }
    private var blocks: [Block] {
        var result: [Block] = [], paragraph: [String] = [], code: [String] = []
        var inCode = false
        func append(_ text: String, _ style: Int) { if !text.isEmpty { result.append(Block(id: result.count, text: text, style: style)) } }
        func flush() { append(paragraph.joined(separator: "\n"), 0); paragraph = [] }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                if inCode { append(code.joined(separator: "\n"), 4); code = [] }
                inCode.toggle(); continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed.range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil {
                flush(); append(trimmed.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression), 1)
            } else if trimmed.range(of: #"^([-*+]\s|\d+[.)]\s)"#, options: .regularExpression) != nil {
                flush(); append(trimmed, 2)
            } else if trimmed.hasPrefix("> ") {
                flush(); append(String(trimmed.dropFirst(2)), 3)
            } else { paragraph.append(line) }
        }
        flush(); if !code.isEmpty { append(code.joined(separator: "\n"), 4) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(blocks) { block in
                switch block.style {
                case 1: inline(block.text).font(.headline).padding(.top, block.id == 0 ? 0 : 6)
                case 2:
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(block.text.first?.isNumber == true ? String(block.text.prefix { $0.isNumber || $0 == "." || $0 == ")" }) : "•").foregroundStyle(.secondary)
                        inline(block.text.replacingOccurrences(of: #"^([-*+]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression))
                    }
                case 3:
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2).fill(LocalAIStyle.accent.opacity(0.6)).frame(width: 3)
                        inline(block.text).foregroundStyle(.secondary)
                    }.fixedSize(horizontal: false, vertical: true)
                case 4:
                    ScrollView(.horizontal) { Text(block.text).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).padding(14) }
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                default: inline(block.text)
                }
            }
        }.font(.body).lineSpacing(5).foregroundStyle(.primary).textSelection(.enabled)
    }
    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
    }
}
#endif
