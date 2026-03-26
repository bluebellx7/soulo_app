import SwiftUI

struct SummarySheetView: View {
    let summary: String
    let pageTitle: String
    let isLoading: Bool
    var onDismiss: () -> Void

    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 20) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 12)

            // Icon + title
            VStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                Text(LanguageManager.shared.localizedString("link_copied"))
                    .font(.system(size: 17, weight: .semibold))

                if !pageTitle.isEmpty {
                    Text(pageTitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }

            // Link text
            Text(summary)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.blue)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 20)

            // Copy button
            Button {
                UIPasteboard.general.string = summary
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 14))
                    Text(didCopy ? LanguageManager.shared.localizedString("copied") : LanguageManager.shared.localizedString("copy_link"))
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(didCopy ? .green : .blue)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    (didCopy ? Color.green : Color.blue).opacity(0.1),
                    in: Capsule()
                )
            }

            Spacer()

            // Done
            Button {
                onDismiss()
            } label: {
                Text(LanguageManager.shared.localizedString("done"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}
