import CoreTransferable
import UniformTypeIdentifiers
import UIKit
import SwiftUI

/// Copy provider-owned temporary files before their callback returns.
struct LibraryImportFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            LibraryImportFile(url: try LibraryFileImport.stage(received.file))
        }
    }
}

enum LibraryFileImport {
    static func stage(_ source: URL, name: String? = nil) throws -> URL {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw ReadingToolError.unsupported }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soulo-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            var filename = (name ?? source.lastPathComponent) as NSString
            filename = filename.lastPathComponent as NSString
            guard !filename.isEqual(to: "."), !filename.isEqual(to: ".."), filename.length > 0 else { throw ReadingToolError.unsafePath }
            let target = directory.appendingPathComponent(filename as String)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    static func discard(_ staged: URL) { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
    static func commit(_ staged: URL, to directory: URL) throws -> URL {
        defer { discard(staged) }
        let target = FileSafety.availableURL(name: staged.lastPathComponent, directory: directory)
        try FileManager.default.moveItem(at: staged, to: target)
        return target
    }
    static func receive(_ provider: NSItemProvider) async throws -> URL {
        let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .url)
        })
        // Some Files providers expose a file URL plus non-file metadata.
        if identifier == nil,
           provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        guard let url, url.isFileURL else { throw error ?? ReadingToolError.invalid }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        continuation.resume(returning: try stage(url))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        guard let identifier else { throw ReadingToolError.unsupported }
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                do {
                    guard let url else { throw error ?? ReadingToolError.invalid }
                    var name = suggestedName ?? url.lastPathComponent
                    if (name as NSString).pathExtension.isEmpty, let ext = UTType(identifier)?.preferredFilenameExtension {
                        name += "." + ext
                    }
                    continuation.resume(returning: try stage(url, name: name))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct LibraryFileDragModifier: ViewModifier {
    let url: URL
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onDrag {
                let provider = NSItemProvider(contentsOf: url) ?? NSItemProvider()
                provider.suggestedName = url.lastPathComponent
                return provider
            }
        } else { content }
    }
}
