import SwiftUI

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    private let lm = LanguageManager.shared

    @State private var feedbackType = "other"
    @State private var content = ""
    @State private var contactInfo = ""
    @State private var isSubmitting = false
    @State private var showSuccess = false
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var includeDiagnostics = true
    @State private var diagnostics: FeedbackDiagnostics?
    @State private var showDiagnostics = false
    @State private var checkScale: CGFloat = 0.3

    private let types = ["bug", "feature", "question", "other"]

    init(initialType: String = "other", initialContent: String = "") {
        _feedbackType = State(initialValue: initialType)
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(spacing: 20) {
                        // Type picker
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lm.localizedString("feedback_type"))
                                .font(.subheadline.bold())
                                .foregroundStyle(.secondary)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(types, id: \.self) { type in
                                        Button {
                                            feedbackType = type
                                            HapticsManager.selection()
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: typeIcon(type))
                                                    .font(.system(size: 12))
                                                Text(lm.localizedString("feedback_type_\(type)"))
                                                    .font(.system(size: 13, weight: .medium))
                                            }
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(feedbackType == type ? Color.themePrimary : Color(uiColor: .tertiarySystemFill))
                                            .foregroundStyle(feedbackType == type ? .white : .primary)
                                            .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        // Content
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(lm.localizedString("feedback_content"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(content.count)/2000")
                                    .font(.caption)
                                    .foregroundStyle(content.count > 2000 ? .red : .secondary)
                            }
                            TextEditor(text: $content)
                                .accessibilityIdentifier("feedback.content")
                                .frame(minHeight: 150)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    Group {
                                        if content.isEmpty {
                                            Text(lm.localizedString("feedback_placeholder"))
                                                .foregroundStyle(.tertiary)
                                                .padding(.leading, 16)
                                                .padding(.top, 20)
                                        }
                                    },
                                    alignment: .topLeading
                                )
                        }

                        // Contact
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(lm.localizedString("feedback_contact"))
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                Text("(\(lm.localizedString("feedback_optional")))")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            TextField(lm.localizedString("feedback_contact_hint"), text: $contactInfo)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("feedback.contact")
                                .padding(12)
                                .background(Color(uiColor: .tertiarySystemFill))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            Text(lm.localizedString("feedback_contact_reply_hint"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 4)
                        }



                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(ToolText.text("feedback_diag_include"), isOn: $includeDiagnostics)
                                .font(.subheadline.weight(.medium))
                                .accessibilityIdentifier("feedback.include-diagnostics")
                            Text(ToolText.text("feedback_diag_hint"))
                                .font(.caption).foregroundStyle(.secondary)
                            if includeDiagnostics, let diagnostics {
                                DisclosureGroup(isExpanded: $showDiagnostics) {
                                    VStack(spacing: 12) {
                                        ForEach(diagnostics.fields) { field in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(diagnosticTitle(field.titleKey)).font(.caption).foregroundStyle(.secondary)
                                                Text(diagnosticValue(field.value)).font(.subheadline).textSelection(.enabled)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }.padding(.top, 12)
                                } label: {
                                    Text(ToolText.text("feedback_diag_preview")).font(.subheadline)
                                }
                                .accessibilityIdentifier("feedback.diagnostics-preview")
                            }
                        }
                        .padding(14)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))

                        // App info
                        HStack(spacing: 6) {
                            Image(systemName: "app.fill").font(.system(size: 10))
                            Text("\(SouloFeedbackService.appName) v\(SouloFeedbackService.appVersion) (\(SouloFeedbackService.buildNumber))")
                                .font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(Capsule())

                        // Submit
                        Button { submitFeedback() } label: {
                            HStack(spacing: 8) {
                                if isSubmitting {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text(isSubmitting ? lm.localizedString("feedback_submitting") : lm.localizedString("feedback_submit"))
                                    .font(.headline)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(!canSubmit ? Color.gray : Color.themePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .disabled(!canSubmit || isSubmitting)
                        .accessibilityIdentifier("feedback.submit")

                        HStack(spacing: 12) {
                            Image(systemName: "envelope").foregroundStyle(Color.themePrimary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ToolText.text("feedback_support_email")).font(.caption).foregroundStyle(.secondary)
                                Link("contact@dkluge.com", destination: URL(string: "mailto:contact@dkluge.com")!)
                                    .font(.subheadline)
                            }
                            Spacer(minLength: 0)
                            Button { UIPasteboard.general.string = "contact@dkluge.com"; HapticsManager.light() } label: {
                                Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(ToolText.text("copy"))
                        }
                        .padding(12)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(20)
                    .disabled(isSubmitting)
                }
                .background(Color(uiColor: .systemGroupedBackground))

                // Success overlay
                if showSuccess {
                    successOverlay
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .task { if diagnostics == nil { diagnostics = FeedbackDiagnostics.capture() } }
            .interactiveDismissDisabled(isSubmitting)
            .navigationTitle(lm.localizedString("feedback_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(lm.localizedString("cancel")) { dismiss() }.disabled(isSubmitting)
                }
            }
            .alert(lm.localizedString("feedback_error"), isPresented: $showError) {
                Button(lm.localizedString("done")) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private var successOverlay: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                ZStack {
                    Circle().fill(Color.green.opacity(0.1)).frame(width: 120, height: 120)
                    Circle().fill(Color.green.opacity(0.06)).frame(width: 160, height: 160)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64)).foregroundStyle(.green)
                        .scaleEffect(checkScale)
                        .onAppear {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { checkScale = 1.0 }
                        }
                }
                VStack(spacing: 10) {
                    Text(lm.localizedString("feedback_success_title"))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(lm.localizedString("feedback_success_msg"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                }
                Spacer()
                Button { dismiss() } label: {
                    Text(lm.localizedString("done"))
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: 280).padding(.vertical, 14)
                        .background(Color.green)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .padding(.bottom, 50)
            }
        }
    }

    private var canSubmit: Bool {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 2000
    }

    private func diagnosticTitle(_ key: String) -> String {
        let shared = lm.localizedString(key)
        return shared == key ? ToolText.text(key) : shared
    }

    private func diagnosticValue(_ value: String) -> String {
        if value == "true" { return lm.localizedString("accessibility_enabled") }
        if value == "false" { return lm.localizedString("accessibility_disabled") }
        return value
    }

    private func submitFeedback() {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        Task {
            do {
                try await SouloFeedbackService.submit(type: feedbackType, content: trimmed,
                    contactInfo: contactInfo, diagnostics: includeDiagnostics ? diagnostics : nil)
                await MainActor.run {
                    isSubmitting = false
                    checkScale = 0.3
                    HapticsManager.success()
                    withAnimation(.easeOut(duration: 0.3)) { showSuccess = true }
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    private func typeIcon(_ type: String) -> String {
        switch type {
        case "bug": return "ladybug.fill"
        case "feature": return "lightbulb.fill"
        case "question": return "questionmark.circle.fill"
        default: return "ellipsis.circle.fill"
        }
    }
}
