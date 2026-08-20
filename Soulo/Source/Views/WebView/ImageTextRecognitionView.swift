import SwiftUI

struct ImageTextRecognitionView: View {
    let result: ImageTextRecognitionResult
    var onSearch: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(uiImage: result.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    Text(result.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = result.text
                            copied = true
                        } label: {
                            Label(
                                LanguageManager.shared.localizedString(copied ? "copied" : "copy_all"),
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onSearch(result.text)
                            dismiss()
                        } label: {
                            Label(LanguageManager.shared.localizedString("search"), systemImage: "magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle(LanguageManager.shared.localizedString("image_extract_text"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
    }
}

struct ImageTextRecognitionPresentationModifier: ViewModifier {
    let webViewModel: WebViewModel
    let isActiveTab: Bool
    @Binding var result: ImageTextRecognitionResult?
    @Binding var errorMessage: String?
    let onSearch: (String) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(item: $result) { value in
                ImageTextRecognitionView(result: value, onSearch: onSearch)
                    .presentationDetents([.medium, .large])
            }
            .alert(
                LanguageManager.shared.localizedString("image_extract_text"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onReceive(NotificationCenter.default.publisher(for: .imageTextRecognitionCompleted)) { notification in
                guard isActiveTab,
                      notification.object as AnyObject? === webViewModel,
                      let value = notification.userInfo?["result"] as? ImageTextRecognitionResult else { return }
                result = value
            }
            .onReceive(NotificationCenter.default.publisher(for: .imageTextRecognitionFailed)) { notification in
                guard isActiveTab, notification.object as AnyObject? === webViewModel else { return }
                errorMessage = (notification.userInfo?["error"] as? Error)?.localizedDescription
                    ?? LanguageManager.shared.localizedString("image_text_unavailable")
            }
    }
}
