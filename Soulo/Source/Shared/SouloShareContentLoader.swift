import Foundation
import UniformTypeIdentifiers
import OSLog

/// Reads the host's registered representation rather than assuming every host
/// exports public.url as NSURL or public.plain-text as NSString.
enum SouloShareContentLoader {
    private static let maximumBytes = 64_000
    private static let logger = Logger(subsystem: "com.dkluge.Soulo", category: "ShareInput")

    @MainActor
    static func action(from items: [NSExtensionItem], timeout: TimeInterval = 12) async -> SouloSharedAction? {
        #if DEBUG
        SouloShareInputDiagnostic.begin(items)
        #endif
        let providers = Array(items.flatMap { $0.attachments ?? [] }.prefix(16))
        let deadline = Date().addingTimeInterval(timeout)
        // A title or image attachment may precede the actual link.
        for provider in providers {
            for identifier in identifiers(in: provider, conformingTo: .url) {
                if let text = await text(from: provider, identifier: identifier, deadline: deadline),
                   let url = SouloSharedContent.webURL(in: text) {
                    return SouloSharedAction(kind: .openURL, text: url.absoluteString)
                }
            }
        }
        var searchText: String?
        for provider in providers {
            // public.text is the parent of public.plain-text. A provider that
            // advertises only the parent does not conform to the child.
            for identifier in identifiers(in: provider, conformingTo: .text) {
                guard let text = await text(from: provider, identifier: identifier, deadline: deadline),
                      let action = SouloSharedContent.action(for: text) else { continue }
                if action.kind == .openURL { return action }
                let type = UTType(identifier)
                if searchText == nil && (type == .text || type?.conforms(to: .plainText) == true) {
                    searchText = text
                }
            }
        }
        for item in items {
            if let body = item.attributedContentText, let text = decodedText(body, identifier: UTType.text.identifier),
               let action = SouloSharedContent.action(for: text) {
                if action.kind == .openURL { return action }
                if searchText == nil { searchText = text }
            }
            // A URL in the title is useful, but a page title alone is not a
            // substitute for an unreadable link.
            if let title = item.attributedTitle,
               let text = decodedText(title, identifier: UTType.text.identifier),
               let url = SouloSharedContent.webURL(in: text) {
                return SouloSharedAction(kind: .openURL, text: url.absoluteString)
            }
        }
        for provider in providers {
            for identifier in identifiers(in: provider, conformingTo: .propertyList) {
                if let text = await text(from: provider, identifier: identifier, deadline: deadline),
                   let url = SouloSharedContent.webURL(in: text) {
                    return SouloSharedAction(kind: .openURL, text: url.absoluteString)
                }
            }
        }
        if let searchText { return SouloSharedContent.action(for: searchText) }
        // Record representation names only, never the user's URL or shared text.
        let types = providers.flatMap(\.registeredTypeIdentifiers).joined(separator: ",")
        logger.notice("No readable share content; representation types: \(types, privacy: .public)")
        #if DEBUG
        SouloShareInputDiagnostic.record(["stage": "unreadable"])
        #endif
        return nil
    }

    private static func identifiers(in provider: NSItemProvider, conformingTo type: UTType) -> [String] {
        Array(provider.registeredTypeIdentifiers.filter { identifier in
            guard let registered = UTType(identifier), !registered.conforms(to: .fileURL) else { return false }
            return registered.conforms(to: type)
        }.prefix(8))
    }

    @MainActor
    private static func text(from provider: NSItemProvider, identifier: String, deadline: Date) async -> String? {
        let result = await request(provider, identifier: identifier, deadline: deadline, dataRepresentation: false)
        if let result { return result }
        // Data-backed providers can reject the legacy object coercion API.
        return await request(provider, identifier: identifier, deadline: deadline, dataRepresentation: true)
    }

    @MainActor
    private static func request(_ provider: NSItemProvider, identifier: String, deadline: Date,
                                dataRepresentation: Bool) async -> String? {
        let remaining = min(3, deadline.timeIntervalSinceNow)
        guard remaining > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            let request = ShareContentRequest(continuation: continuation)
            request.scheduleTimeout(after: remaining)
            if dataRepresentation {
                let progress = provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    #if DEBUG
                    SouloShareInputDiagnostic.loaded(data, error: error, identifier: identifier, method: "data")
                    #endif
                    request.finish(error == nil ? data.flatMap { decodedText($0, identifier: identifier) } : nil)
                }
                request.setProgress(progress)
            } else {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    #if DEBUG
                    SouloShareInputDiagnostic.loaded(item, error: error, identifier: identifier, method: "item")
                    #endif
                    request.finish(error == nil ? item.flatMap { decodedText($0, identifier: identifier) } : nil)
                }
            }
        }
    }

    static func decodedText(_ item: Any, identifier: String) -> String? {
        if let url = item as? URL {
            if !url.isFileURL { return clean(url.absoluteString) }
            // Text may be delivered as a temporary file. Never read a generic
            // file URL or a large document merely to look for a browser link.
            guard UTType(identifier)?.conforms(to: .text) == true else { return nil }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes,
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maximumBytes + 1) else { return nil }
            return decodedText(data, identifier: identifier)
        }
        if let attributed = item as? NSAttributedString {
            guard attributed.length <= maximumBytes else { return nil }
            var link: String?
            attributed.enumerateAttribute(NSAttributedString.Key("NSLink"),
                in: NSRange(location: 0, length: attributed.length)) { value, _, stop in
                if let value, let text = decodedText(value, identifier: UTType.url.identifier),
                   let url = SouloSharedContent.webURL(in: text) {
                    link = url.absoluteString; stop.pointee = true
                }
            }
            return link ?? clean(attributed.string)
        }
        if let string = item as? String { return clean(string) }
        if let data = item as? Data {
            guard !data.isEmpty, data.count <= maximumBytes else { return nil }
            if UTType(identifier)?.conforms(to: .propertyList) == true,
               let object = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                return dictionaryURL(object)
            }
            var encodings: [String.Encoding] = [.utf8]
            if data.starts(with: [0xFF, 0xFE]) { encodings = [.utf16LittleEndian, .utf8] }
            else if data.starts(with: [0xFE, 0xFF]) { encodings = [.utf16BigEndian, .utf8] }
            else if identifier == UTType.utf16PlainText.identifier || identifier == UTType.utf16ExternalPlainText.identifier {
                encodings = [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8]
            }
            for encoding in encodings {
                if let text = String(data: data, encoding: encoding), let text = clean(text) { return text }
            }
            return nil
        }
        return dictionaryURL(item)
    }

    private static func clean(_ string: String) -> String? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}\0")))
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count <= maximumBytes else { return nil }
        return text
    }

    private static func dictionaryURL(_ item: Any) -> String? {
        guard let dictionary = item as? [String: Any] else { return nil }
        let values = (dictionary["NSExtensionJavaScriptPreprocessingResultsKey"] as? [String: Any]) ?? dictionary
        for key in ["url", "URL", "webURL", "link", "href"] {
            let value = values[key]
            let text = (value as? URL)?.absoluteString ?? (value as? String)
            if let text, let url = SouloSharedContent.webURL(in: text) { return url.absoluteString }
        }
        return nil
    }
}

#if DEBUG
/// Device QA only. Contains representation metadata and error codes, never
/// shared text, URL addresses, filenames, or error descriptions.
enum SouloShareInputDiagnostic {
    private static let lock = NSLock()
    private static var events: [[String: Any]] = []

    static func begin(_ items: [NSExtensionItem]) {
        lock.lock()
        events = [["stage": "input", "time": Date().timeIntervalSince1970,
                   "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                   "items": items.map { item in
                       ["types": (item.attachments ?? []).map(\.registeredTypeIdentifiers),
                        "bodyPresent": item.attributedContentText != nil,
                        "titlePresent": item.attributedTitle != nil] as [String: Any]
                   }]]
        persist()
        lock.unlock()
    }

    static func loaded(_ item: Any?, error: Error?, identifier: String, method: String) {
        var event: [String: Any] = ["stage": "load", "type": identifier, "method": method]
        if let item { event["class"] = String(reflecting: type(of: item)) }
        if let data = item as? Data { event["byteCount"] = data.count }
        if let url = item as? URL { event["isFileURL"] = url.isFileURL; event["fileExtension"] = url.isFileURL ? url.pathExtension : "" }
        if let error { let ns = error as NSError; event["errorDomain"] = ns.domain; event["errorCode"] = ns.code }
        record(event)
    }

    static func record(_ event: [String: Any]) {
        lock.lock()
        if events.count < 80 { events.append(event) }
        persist()
        lock.unlock()
    }

    private static func persist() {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SouloSharedConstants.appGroupIdentifier),
              let data = try? JSONSerialization.data(withJSONObject: events, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("ShareInputDiagnostic.json"), options: .atomic)
    }
}
#endif

/// A host may invoke its completion more than once or never invoke it. A late
/// callback after timeout must not resume the continuation or navigate again.
private final class ShareContentRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var progress: Progress?
    private var timer: DispatchWorkItem?

    init(continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

    func scheduleTimeout(after seconds: TimeInterval) {
        let timer = DispatchWorkItem { [self] in finish(nil, cancel: true) }
        lock.lock(); self.timer = timer; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: timer)
    }

    func setProgress(_ progress: Progress) {
        lock.lock()
        let finished = continuation == nil
        if !finished { self.progress = progress }
        lock.unlock()
        if finished { progress.cancel() }
    }

    func finish(_ text: String?, cancel: Bool = false) {
        lock.lock()
        let continuation = self.continuation, progress = self.progress, timer = self.timer
        self.continuation = nil; self.progress = nil; self.timer = nil
        lock.unlock()
        timer?.cancel()
        if cancel { progress?.cancel() }
        continuation?.resume(returning: text)
    }
}
