import CoreImage.CIFilterBuiltins
import SwiftUI

struct WiFiTransferView: View {
    let directory: URL
    @AppStorage("wifi.requiresPairing") private var requiresPairing = true
    @State private var sessionID = UUID()
    @State private var transfers: [WiFiTransferEvent] = []
    @State private var transferCount = 0
    @State private var server: WiFiTransferServer?
    @State private var address: String?
    @State private var code = ""
    @State private var copiedValue: String?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var error: String?
    var body: some View {

        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    if address == nil {
                        ToolIllustration(scene: .transfer, height: 170)
                    }

                    Text(ToolText.text("wifi_hint")).font(.body).foregroundStyle(.secondary).multilineTextAlignment(
                        .center)
                    if server == nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(ToolText.text("require_pairing"), isOn: $requiresPairing)
                            Text(ToolText.text(requiresPairing ? "pairing_on_hint" : "pairing_off_hint"))
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let address {
                        if let qr = qr(address) {
                            Image(uiImage: qr).interpolation(.none).resizable().frame(width: 160, height: 160).padding(
                                12
                            )
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        }
                        HStack(spacing: 8) {
                            Text(address).font(.subheadline.monospaced()).textSelection(.enabled)
                                .lineLimit(2).minimumScaleFactor(0.8)
                            copyButton(address, label: ToolText.text("copy_address"))
                        }
                        if requiresPairing {
                        HStack(spacing: 8) {
                            Text(code).font(.system(size: 30, weight: .medium, design: .monospaced)).tracking(4)
                                .textSelection(.enabled)
                            copyButton(code, label: ToolText.text("copy_pairing_code"))
                        }
                        Text(ToolText.text("pairing_code")).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label(ToolText.text("pairing_disabled"), systemImage: "lock.open")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button(ToolText.text("stop"), role: .destructive) { stop() }
                            .buttonStyle(CompactActionButtonStyle())
                            .frame(maxWidth: 180)
                    } else if server != nil {
                        ProgressView()
                        Button(ToolText.text("cancel")) { stop() }
                    } else {
                        Button(ToolText.text("start_transfer")) { start() }
                            .buttonStyle(CompactActionButtonStyle(prominent: true))
                            .frame(maxWidth: 180)
                    }
                    if !transfers.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(ToolText.text("recent_transfers")).font(.subheadline.weight(.semibold))
                            ForEach(transfers) { event in
                                HStack(spacing: 12) {
                                    Image(systemName: FilePresentation(kind: event.kind, fileExtension: "", size: event.size).symbol)
                                        .foregroundStyle(.tint).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(event.name).font(.subheadline).lineLimit(2).truncationMode(.middle)
                                        Text(ToolText.text(event.direction == .received ? "transfer_received" : "transfer_sent") + " · " + ByteCountFormatter.string(fromByteCount: event.size, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }.accessibilityElement(children: .combine)
                            }
                        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    Text(directory.lastPathComponent).font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 56))
                .padding(28)
            }
        }
        .navigationTitle(ToolText.text("wifi_transfer"))
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemGroupedBackground))
        .sensoryFeedback(.success, trigger: transferCount)
        .mediaPlayerNavigation()
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            stop()
        }

    }
    private func copyButton(_ value: String, label: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            copiedValue = value
            copyResetTask?.cancel()
            copyResetTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { copiedValue = nil }
            }
        } label: {
            CompactIconLabel(systemImage: copiedValue == value ? "checkmark" : "doc.on.doc", emphasized: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copiedValue == value ? ToolText.text("copied") : label)
        .accessibilityValue(value)
        .overlay(alignment: .bottom) {
            if copiedValue == value {
                Text(ToolText.text("copied")).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize().offset(y: 10).allowsHitTesting(false)
            }
        }
    }
    private func start() {
        guard server == nil else { return }
        error = nil
        sessionID = UUID()
        let id = sessionID
        guard let ip = WiFiTransferServer.address() else {
            error = ToolText.text("wifi_required")
            return
        }
        let server = WiFiTransferServer(directory: directory, requiresPairing: requiresPairing)
        self.server = server
        code = server.code
        server.onState = { port, error in
            Task { @MainActor in
                guard sessionID == id else { return }
                if port == nil { self.server = nil }
                if let port { address = "http://\(ip):\(port)" } else { address = nil }
                self.error = error
            }
        }
        server.onTransfer = { event in
            Task { @MainActor in
                guard sessionID == id else { return }
                transfers.insert(event, at: 0)
                transfers = Array(transfers.prefix(5))
                transferCount += 1
            }
        }
        do { try server.start() } catch {
            self.error = error.localizedDescription
            self.server = nil
        }
    }
    private func stop() {
        copyResetTask?.cancel(); copiedValue = nil
        sessionID = UUID()
        server?.stop()
        server = nil
        address = nil
        code = ""
    }
    private func qr(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            let cg = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}
