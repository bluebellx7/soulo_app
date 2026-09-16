import SwiftUI

struct SiteCertificateView: View {
    @Environment(\.dismiss) private var dismiss
    let host: String
    let certificates: [SiteCertificateInfo]
    @State private var copied: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label { Text(host).font(.headline).textSelection(.enabled) } icon: {
                        IconBadge(systemName: "lock.doc", color: Color(uiColor: .secondaryLabel))
                    }
                    Text(ToolText.text("certificate_source")).font(.footnote).foregroundStyle(.secondary)
                }
                if certificates.isEmpty {
                    Section { Text(ToolText.text("certificate_unavailable")).foregroundStyle(.secondary) }
                }
                ForEach(Array(certificates.enumerated()), id: \.offset) { index, certificate in
                    Section {
                        field("certificate_subject", certificate.subject)
                        field("certificate_issuer", certificate.issuer)
                        if let date = certificate.notBefore { field("certificate_from", date.formatted(date: .abbreviated, time: .standard)) }
                        if let date = certificate.notAfter { field("certificate_until", date.formatted(date: .abbreviated, time: .standard)) }
                        field("certificate_serial", certificate.serial, monospaced: true)
                        field("certificate_public_key", certificate.publicKey)
                        if !certificate.domains.isEmpty { field("certificate_domains", certificate.domains.joined(separator: "\n")) }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("SHA-256").font(.subheadline.weight(.medium))
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = certificate.fingerprint
                                    copied = certificate.id
                                    HapticsManager.selection()
                                } label: {
                                    Image(systemName: copied == certificate.id ? "checkmark" : "doc.on.doc").foregroundStyle(.primary)
                                        .frame(width: 44, height: 44)
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel(ToolText.text(copied == certificate.id ? "copied" : "copy"))
                            }
                            Text(certificate.fingerprint).font(.caption.monospaced())
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } header: {
                        Text(index == 0 ? ToolText.text("certificate_leaf") : String(format: ToolText.text("certificate_chain_item"), index + 1))
                    }
                }
            }
            .navigationTitle(ToolText.text("certificate_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { dismiss() } } }
            .accessibilityIdentifier("site.certificate-details")
        }
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copied = nil
        }
    }
    private func field(_ key: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ToolText.text(key)).font(.subheadline.weight(.medium))
            Text(value).font(monospaced ? .caption.monospaced() : .subheadline)
                .foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }
}
