import Foundation
import AVFAudio
import UserNotifications
import WebKit
import zlib

/// Converts store packages into a private resource directory and installs a
/// small compatibility layer before an extension's own background code runs.
/// WebKit remains the extension engine; this only fills APIs that have a safe,
/// native iOS equivalent.
enum WebExtensionPackagePreparer {
    static let preparedResourceName = "Extension"
    static var compatibilitySourceForTesting: String { compatibilityJavaScript }

    static func prepare(sourceURL: URL, in installDirectory: URL) throws -> URL {
        let destination = installDirectory.appendingPathComponent(
            preparedResourceName,
            isDirectory: true
        )
        if sourceURL.standardizedFileURL == destination.standardizedFileURL {
            try installCompatibilityLayer(in: destination)
            return destination
        }

        let fileManager = FileManager.default
        try? fileManager.removeItem(at: destination)
        do {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw BrowserExtensionError.invalidExtension
            }
            if isDirectory.boolValue {
                try fileManager.copyItem(at: sourceURL, to: destination)
            } else {
                let packageData = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                let zipData = try zipPayload(from: packageData)
                try SafeZIPExtractor.extract(zipData, to: destination)
            }
            try installCompatibilityLayer(in: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    static func installCompatibilityLayer(in resourceDirectory: URL) throws {
        let manifestURL = resourceDirectory.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        else {
            throw BrowserExtensionError.invalidExtension
        }

        let permissions = (manifest["permissions"] as? [String]) ?? []
        let needsNotifications = permissions.contains("notifications")
        let needsOffscreen = permissions.contains("offscreen")
        guard needsNotifications || needsOffscreen else { return }

        var updatedPermissions = permissions
        if !updatedPermissions.contains("nativeMessaging") {
            updatedPermissions.append("nativeMessaging")
            manifest["permissions"] = updatedPermissions
        }

        let compatibilityFilename = "__soulo_webextension_compatibility.js"
        let compatibilityURL = resourceDirectory.appendingPathComponent(compatibilityFilename)
        try Data(compatibilityJavaScript.utf8).write(to: compatibilityURL, options: .atomic)

        if var background = manifest["background"] as? [String: Any] {
            if let serviceWorker = background["service_worker"] as? String,
               serviceWorker != "__soulo_webextension_background_v3.js" {
                // Version the wrapper name so an extension whose first worker
                // failed during startup is not permanently served WebKit's
                // cached copy after Soulo improves its compatibility layer.
                let wrapperName = "__soulo_webextension_background_v3.js"
                let isModule = (background["type"] as? String)?.lowercased() == "module"
                let escapedWorker = javaScriptString(normalizedResourcePath(serviceWorker))
                let wrapper: String
                if isModule {
                    wrapper = "import \"./\(compatibilityFilename)\";\nimport \"./\(escapedWorker)\";\n"
                } else {
                    wrapper = "importScripts(\"\(compatibilityFilename)\", \"\(escapedWorker)\");\n"
                }
                try Data(wrapper.utf8).write(
                    to: resourceDirectory.appendingPathComponent(wrapperName),
                    options: .atomic
                )
                background["service_worker"] = wrapperName
            } else if var scripts = background["scripts"] as? [String],
                      !scripts.contains(compatibilityFilename) {
                scripts.insert(compatibilityFilename, at: 0)
                background["scripts"] = scripts
            }
            manifest["background"] = background
        }

        for page in extensionPages(in: manifest) {
            try injectCompatibilityScript(
                filename: compatibilityFilename,
                into: resourceDirectory.appendingPathComponent(normalizedResourcePath(page))
            )
        }
        makeUnsupportedListenerNamespacesOptional(in: resourceDirectory)

        let updatedManifest = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try updatedManifest.write(to: manifestURL, options: .atomic)
    }

    /// Some Chromium extensions register optional desktop-only APIs during
    /// background startup. WebKit can omit an entire namespace on iOS; a
    /// direct listener registration then aborts the service worker before its
    /// otherwise-supported runtime/storage listeners are installed. Optional
    /// chaining preserves the supported portion of those extensions.
    private static func makeUnsupportedListenerNamespacesOptional(in resourceDirectory: URL) {
        let replacements = [
            (".notifications.onClicked.addListener", ".notifications?.onClicked?.addListener"),
            (".notifications.onButtonClicked.addListener", ".notifications?.onButtonClicked?.addListener"),
            (".notifications.create(", ".notifications?.create?.("),
            (".notifications.clear(", ".notifications?.clear?.("),
            (".commands.onCommand.addListener", ".commands?.onCommand?.addListener"),
            (".offscreen.createDocument(", ".offscreen?.createDocument?.("),
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: resourceDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "js" {
            if fileURL.lastPathComponent.hasPrefix("__soulo_webextension_") { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]) else {
                continue
            }
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= 32 * 1_024 * 1_024,
                  var source = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let original = source
            for (needle, replacement) in replacements {
                source = source.replacingOccurrences(of: needle, with: replacement)
            }
            if source != original {
                try? Data(source.utf8).write(to: fileURL, options: .atomic)
            }
        }
    }

    private static func extensionPages(in manifest: [String: Any]) -> Set<String> {
        var pages = Set<String>()
        for key in ["action", "browser_action", "page_action"] {
            if let values = manifest[key] as? [String: Any],
               let popup = values["default_popup"] as? String,
               !popup.isEmpty {
                pages.insert(popup)
            }
        }
        if let page = manifest["options_page"] as? String, !page.isEmpty {
            pages.insert(page)
        }
        if let options = manifest["options_ui"] as? [String: Any],
           let page = options["page"] as? String,
           !page.isEmpty {
            pages.insert(page)
        }
        return pages
    }

    private static func injectCompatibilityScript(filename: String, into pageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: pageURL.path),
              var html = try? String(contentsOf: pageURL, encoding: .utf8),
              !html.contains(filename) else { return }
        let tag = "<script src=\"/\(filename)\"></script>"
        if let headRange = html.range(of: "<head", options: .caseInsensitive),
           let closeRange = html.range(of: ">", range: headRange.lowerBound..<html.endIndex) {
            html.insert(contentsOf: tag, at: closeRange.upperBound)
        } else {
            html.insert(contentsOf: tag, at: html.startIndex)
        }
        try Data(html.utf8).write(to: pageURL, options: .atomic)
    }

    private static func normalizedResourcePath(_ path: String) -> String {
        var value = path
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    private static func javaScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func zipPayload(from data: Data) throws -> Data {
        guard data.count >= 4 else { throw BrowserExtensionError.invalidExtension }
        if data[0] == 0x50, data[1] == 0x4B {
            return data
        }
        guard String(data: data.prefix(4), encoding: .ascii) == "Cr24",
              let version = data.littleEndianUInt32(at: 4) else {
            throw BrowserExtensionError.invalidExtension
        }
        let offset: Int
        switch version {
        case 2:
            guard let publicKeyLength = data.littleEndianUInt32(at: 8),
                  let signatureLength = data.littleEndianUInt32(at: 12) else {
                throw BrowserExtensionError.invalidExtension
            }
            offset = 16 + Int(publicKeyLength) + Int(signatureLength)
        case 3:
            guard let headerLength = data.littleEndianUInt32(at: 8) else {
                throw BrowserExtensionError.invalidExtension
            }
            offset = 12 + Int(headerLength)
        default:
            throw BrowserExtensionError.invalidExtension
        }
        guard offset >= 0, offset + 4 <= data.count,
              data[offset] == 0x50, data[offset + 1] == 0x4B else {
            throw BrowserExtensionError.invalidExtension
        }
        return data.subdata(in: offset..<data.count)
    }

    private static let compatibilityJavaScript = #"""
    (() => {
      'use strict';
      const root = globalThis;
      const chrome = root.chrome || root.browser;
      if (!chrome || !chrome.runtime || root.__souloCompatibilityInstalled) return;
      try { Object.defineProperty(root, '__souloCompatibilityInstalled', { value: true }); }
      catch (_) { root.__souloCompatibilityInstalled = true; }
      if (!root.chrome) {
        try { root.chrome = chrome; } catch (_) {}
      }
      const setIfMissing = (target, key, value) => {
        if (!target || target[key]) return target && target[key];
        try { target[key] = value; } catch (_) {}
        if (target[key]) return target[key];
        try { Object.defineProperty(target, key, { configurable: true, value }); } catch (_) {}
        return target[key] || value;
      };
      const host = 'com.dkluge.Soulo.WebExtensionCompatibility';
      const event = () => ({
        addListener() {}, removeListener() {}, hasListener() { return false; },
        hasListeners() { return false; }
      });
      const native = (payload, callback, transform = value => value) => {
        let settled = false;
        const done = value => {
          if (settled) return;
          settled = true;
          if (typeof callback === 'function') callback(transform(value));
        };
        try {
          if (typeof chrome.runtime.sendNativeMessage !== 'function') {
            done(null);
            return typeof callback === 'function' ? undefined : Promise.resolve(transform(null));
          }
          const result = chrome.runtime.sendNativeMessage(host, payload, done);
          if (result && typeof result.then === 'function') {
            return result.then(transform, () => transform(null));
          }
        } catch (_) {
          done(null);
        }
        if (typeof callback !== 'function') return Promise.resolve(transform(null));
      };

      const notifications = chrome.notifications || {};
      setIfMissing(notifications, 'onClicked', event());
      setIfMissing(notifications, 'onButtonClicked', event());
      setIfMissing(notifications, 'onClosed', event());
      setIfMissing(notifications, 'onPermissionLevelChanged', event());
      if (typeof notifications.create !== 'function') {
        setIfMissing(notifications, 'create', function(id, options, callback) {
            if (typeof id === 'object') { callback = options; options = id; id = ''; }
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'create',
              id: id || '', options: options || {} }, callback, value => value && value.id || id || 'soulo');
          });
      }
      if (typeof notifications.update !== 'function') {
        setIfMissing(notifications, 'update', function(id, options, callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'update',
              id, options: options || {} }, callback, value => !!(value && value.success));
          });
      }
      if (typeof notifications.clear !== 'function') {
        setIfMissing(notifications, 'clear', function(id, callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'clear', id },
              callback, value => !!(value && value.success));
          });
      }
      if (typeof notifications.getAll !== 'function') {
        setIfMissing(notifications, 'getAll', function(callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'getAll' },
              callback, value => value && value.notifications || {});
          });
      }
      if (typeof notifications.getPermissionLevel !== 'function') {
        setIfMissing(notifications, 'getPermissionLevel', function(callback) {
            return native({ souloCompatibility: 1, api: 'notifications', operation: 'permission' },
              callback, value => value && value.level || 'denied');
          });
      }
      setIfMissing(chrome, 'notifications', notifications);
      if (root.browser && root.browser !== chrome) {
        const browserNotifications = root.browser.notifications || {};
        for (const key of Object.keys(notifications)) {
          setIfMissing(browserNotifications, key, notifications[key]);
        }
        setIfMissing(root.browser, 'notifications', browserNotifications);
      }

      // Chrome's legacy extension.getViews API has no iOS equivalent. Returning
      // an empty list preserves the common "focus existing, otherwise tabs.create"
      // flow used by options, history and dashboard buttons.
      const extension = chrome.extension || {};
      setIfMissing(extension, 'getViews', function() { return []; });
      setIfMissing(extension, 'getBackgroundPage', function() { return null; });
      setIfMissing(chrome, 'extension', extension);
      if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'extension', extension);

      let offscreenOpen = false;
      const offscreen = chrome.offscreen || {};
      setIfMissing(offscreen, 'Reason', { AUDIO_PLAYBACK: 'AUDIO_PLAYBACK', CLIPBOARD: 'CLIPBOARD',
        DOM_PARSER: 'DOM_PARSER', LOCAL_STORAGE: 'LOCAL_STORAGE' });
      if (typeof offscreen.createDocument !== 'function') setIfMissing(offscreen, 'createDocument', function() {
        offscreenOpen = true; return Promise.resolve();
      });
      if (typeof offscreen.closeDocument !== 'function') setIfMissing(offscreen, 'closeDocument', function() {
        offscreenOpen = false; return Promise.resolve();
      });
      if (typeof offscreen.hasDocument !== 'function') {
        setIfMissing(offscreen, 'hasDocument', function() { return Promise.resolve(offscreenOpen); });
      }
      setIfMissing(chrome, 'offscreen', offscreen);
      if (root.browser && root.browser !== chrome) setIfMissing(root.browser, 'offscreen', offscreen);

      // Tomato Clock's MV3 worker cannot currently be kept alive by WebKit on
      // iOS. Keep its public message/storage contract intact in extension
      // pages so the original panel, options and persistence continue to work.
      // The command check deliberately limits this adapter to Tomato Clock.
      const manifest = typeof chrome.runtime.getManifest === 'function'
        ? chrome.runtime.getManifest() : {};
      const usesTomatoTimerContract = !!(manifest.commands && manifest.commands['start-tomato']
        && manifest.commands['start-short-break'] && manifest.commands['start-long-break']);
      const localStorageArea = chrome.storage && chrome.storage.local;
      const storageCall = (method, value) => new Promise((resolve, reject) => {
        if (!localStorageArea || typeof localStorageArea[method] !== 'function') {
          reject(new Error('Local extension storage is unavailable.'));
          return;
        }
        let settled = false;
        const done = result => { if (!settled) { settled = true; resolve(result); } };
        try {
          const result = localStorageArea[method](value, done);
          if (result && typeof result.then === 'function') result.then(done, reject);
        } catch (error) { reject(error); }
      });
      const idleTimerState = () => ({ status: 'idle', type: null,
        scheduledTime: null, totalTime: null });
      const getTomatoTimerState = async () => {
        const values = await storageCall('get', 'timer');
        const state = values && values.timer;
        if (!state || state.status === 'idle') return idleTimerState();
        if (state.status === 'running' && Number(state.scheduledTime) <= Date.now()) {
          await storageCall('remove', 'timer');
          return idleTimerState();
        }
        return state;
      };
      const setTomatoTimerState = async state => {
        await storageCall('set', { timer: state });
        return state;
      };
      const handleTomatoTimerMessage = async message => {
        const action = String(message && message.action || '');
        if (action === 'getTimerState') return getTomatoTimerState();
        if (action === 'resetTimer') {
          await storageCall('remove', 'timer');
          return idleTimerState();
        }
        if (action === 'setTimer') {
          const type = message && message.data && message.data.type;
          const settingsValues = await storageCall('get', 'settings');
          const settings = settingsValues && settingsValues.settings || {};
          const minutes = type === 'shortBreak' ? Number(settings.minutesInShortBreak || 5)
            : type === 'longBreak' ? Number(settings.minutesInLongBreak || 15)
            : Number(settings.minutesInTomato || 25);
          const totalTime = Math.max(1, minutes) * 60 * 1000;
          return setTomatoTimerState({ status: 'running', type: type || 'tomato',
            scheduledTime: Date.now() + totalTime, totalTime });
        }
        if (action === 'pauseTimer') {
          const state = await getTomatoTimerState();
          if (state.status !== 'running') return state;
          return setTomatoTimerState({ status: 'paused', type: state.type,
            remainingTime: Math.max(0, state.scheduledTime - Date.now()), totalTime: state.totalTime });
        }
        if (action === 'resumeTimer') {
          const state = await getTomatoTimerState();
          if (state.status !== 'paused') return state;
          return setTomatoTimerState({ status: 'running', type: state.type,
            scheduledTime: Date.now() + state.remainingTime, totalTime: state.totalTime });
        }
        return undefined;
      };

      const originalSendMessage = typeof chrome.runtime.sendMessage === 'function'
        ? chrome.runtime.sendMessage.bind(chrome.runtime) : null;
      const compatibleSendMessage = function(...args) {
        const firstMessageIndex = typeof args[0] === 'string' ? 1 : 0;
        const message = args[firstMessageIndex];
        const action = String(message && message.action || '').toLowerCase();
        const source = message && message.data && message.data.src;
        const callback = typeof args[args.length - 1] === 'function'
          ? args[args.length - 1] : undefined;
        if (usesTomatoTimerContract && ['settimer', 'resettimer', 'gettimerstate',
          'pausetimer', 'resumetimer'].includes(action)) {
          const result = handleTomatoTimerMessage(message);
          if (callback) {
            result.then(callback, () => callback(undefined));
            return undefined;
          }
          return result;
        }
        if (offscreenOpen && action.includes('offscreen') && (source || action.includes('stop'))) {
          return native({ souloCompatibility: 1, api: 'audio',
            operation: action.includes('stop') ? 'stop' : 'play', source: source || '' }, callback);
        }
        return originalSendMessage ? originalSendMessage(...args) : Promise.resolve();
      };
      try { chrome.runtime.sendMessage = compatibleSendMessage; } catch (_) {}
    })();
    """#
}

private enum SafeZIPExtractor {
    private struct Entry {
        let path: String
        let flags: UInt16
        let compressionMethod: UInt16
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private static let maximumEntryCount = 20_000
    private static let maximumEntrySize = 256 * 1_024 * 1_024
    private static let maximumExpandedSize = 768 * 1_024 * 1_024

    static func extract(_ archive: Data, to destination: URL) throws {
        let entries = try centralDirectoryEntries(in: archive)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let rootPath = destination.standardizedFileURL.path + "/"

        for entry in entries {
            guard !entry.path.isEmpty, !entry.path.hasPrefix("/"), !entry.path.contains("\0") else {
                throw BrowserExtensionError.invalidExtension
            }
            let outputURL = destination
                .appendingPathComponent(entry.path)
                .standardizedFileURL
            guard outputURL.path.hasPrefix(rootPath) else {
                throw BrowserExtensionError.invalidExtension
            }
            if entry.path.hasSuffix("/") {
                try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
                continue
            }
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = try payload(for: entry, in: archive)
            try payload.write(to: outputURL, options: .atomic)
        }
    }

    private static func centralDirectoryEntries(in data: Data) throws -> [Entry] {
        let eocdSignature: UInt32 = 0x06054B50
        let minimumEOCDSize = 22
        guard data.count >= minimumEOCDSize else { throw BrowserExtensionError.invalidExtension }
        let searchStart = max(0, data.count - minimumEOCDSize - 65_535)
        var eocdOffset: Int?
        var cursor = data.count - minimumEOCDSize
        while cursor >= searchStart {
            if data.littleEndianUInt32(at: cursor) == eocdSignature {
                eocdOffset = cursor
                break
            }
            cursor -= 1
        }
        guard let eocdOffset,
              data.littleEndianUInt16(at: eocdOffset + 4) == 0,
              data.littleEndianUInt16(at: eocdOffset + 6) == 0,
              let entryCountValue = data.littleEndianUInt16(at: eocdOffset + 10),
              let directorySizeValue = data.littleEndianUInt32(at: eocdOffset + 12),
              let directoryOffsetValue = data.littleEndianUInt32(at: eocdOffset + 16)
        else { throw BrowserExtensionError.invalidExtension }

        let entryCount = Int(entryCountValue)
        let directorySize = Int(directorySizeValue)
        let directoryOffset = Int(directoryOffsetValue)
        guard entryCount <= maximumEntryCount,
              directoryOffset >= 0,
              directorySize >= 0,
              directoryOffset + directorySize <= data.count else {
            throw BrowserExtensionError.invalidExtension
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var totalExpandedSize = 0
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard data.littleEndianUInt32(at: offset) == 0x02014B50,
                  let flags = data.littleEndianUInt16(at: offset + 8),
                  let method = data.littleEndianUInt16(at: offset + 10),
                  let crc = data.littleEndianUInt32(at: offset + 16),
                  let compressedValue = data.littleEndianUInt32(at: offset + 20),
                  let uncompressedValue = data.littleEndianUInt32(at: offset + 24),
                  let nameLengthValue = data.littleEndianUInt16(at: offset + 28),
                  let extraLengthValue = data.littleEndianUInt16(at: offset + 30),
                  let commentLengthValue = data.littleEndianUInt16(at: offset + 32),
                  let localOffsetValue = data.littleEndianUInt32(at: offset + 42)
            else { throw BrowserExtensionError.invalidExtension }
            guard flags & 0x0001 == 0 else { throw BrowserExtensionError.invalidExtension }

            let compressedSize = Int(compressedValue)
            let uncompressedSize = Int(uncompressedValue)
            let nameLength = Int(nameLengthValue)
            let extraLength = Int(extraLengthValue)
            let commentLength = Int(commentLengthValue)
            let nextOffset = offset + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, nextOffset <= data.count,
                  compressedSize <= maximumEntrySize,
                  uncompressedSize <= maximumEntrySize else {
                throw BrowserExtensionError.invalidExtension
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let path = String(data: nameData, encoding: .utf8)
                    ?? String(data: nameData, encoding: .isoLatin1) else {
                throw BrowserExtensionError.invalidExtension
            }
            totalExpandedSize += uncompressedSize
            guard totalExpandedSize <= maximumExpandedSize else {
                throw BrowserExtensionError.invalidExtension
            }
            entries.append(Entry(
                path: path.replacingOccurrences(of: "\\", with: "/"),
                flags: flags,
                compressionMethod: method,
                crc: crc,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: Int(localOffsetValue)
            ))
            offset = nextOffset
        }
        return entries
    }

    private static func payload(for entry: Entry, in data: Data) throws -> Data {
        let offset = entry.localHeaderOffset
        guard data.littleEndianUInt32(at: offset) == 0x04034B50,
              let nameLength = data.littleEndianUInt16(at: offset + 26),
              let extraLength = data.littleEndianUInt16(at: offset + 28) else {
            throw BrowserExtensionError.invalidExtension
        }
        let payloadOffset = offset + 30 + Int(nameLength) + Int(extraLength)
        guard payloadOffset >= 0,
              entry.compressedSize >= 0,
              payloadOffset + entry.compressedSize <= data.count else {
            throw BrowserExtensionError.invalidExtension
        }
        let compressed = data.subdata(in: payloadOffset..<(payloadOffset + entry.compressedSize))
        let result: Data
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw BrowserExtensionError.invalidExtension
            }
            result = compressed
        case 8:
            result = try inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw BrowserExtensionError.invalidExtension
        }
        let calculatedCRC = result.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
        }
        guard UInt32(calculatedCRC) == entry.crc else {
            throw BrowserExtensionError.invalidExtension
        }
        return result
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else { throw BrowserExtensionError.invalidExtension }
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        var stream = z_stream()
        let status: Int32 = compressed.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                stream.next_in = UnsafeMutablePointer(
                    mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress
                )
                stream.avail_in = uInt(inputBytes.count)
                stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBytes.count)
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    return Z_STREAM_ERROR
                }
                defer { inflateEnd(&stream) }
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END,
              stream.total_out == expectedSize,
              stream.avail_in == 0 else {
            throw BrowserExtensionError.invalidExtension
        }
        return output
    }
}

private extension Data {
    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func littleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

@MainActor
@available(iOS 18.4, *)
final class WebExtensionCompatibilityHost {
    static let applicationIdentifier = "com.dkluge.Soulo.WebExtensionCompatibility"

    private var audioPlayers: [ObjectIdentifier: AVAudioPlayer] = [:]

    func handle(
        message: Any,
        applicationIdentifier: String?,
        context: WKWebExtensionContext,
        resourceURL: URL?,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) -> Bool {
        guard applicationIdentifier == Self.applicationIdentifier,
              let values = message as? [String: Any],
              (values["souloCompatibility"] as? Int) == 1,
              let api = values["api"] as? String else { return false }
        switch api {
        case "notifications":
            handleNotification(values, context: context, replyHandler: replyHandler)
        case "audio":
            handleAudio(values, context: context, resourceURL: resourceURL, replyHandler: replyHandler)
        case "lifecycle":
            // Accepted for packages prepared by an earlier compatibility wrapper.
            replyHandler(["success": true], nil)
        default:
            replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedAPI)
        }
        return true
    }

    func remove(context: WKWebExtensionContext) {
        let key = ObjectIdentifier(context)
        audioPlayers[key]?.stop()
        audioPlayers.removeValue(forKey: key)
    }

    private func handleNotification(
        _ values: [String: Any],
        context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        let operation = values["operation"] as? String ?? ""
        let extensionPrefix = context.uniqueIdentifier + ":"
        let requestedID = (values["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notificationID = extensionPrefix + ((requestedID?.isEmpty == false) ? requestedID! : UUID().uuidString)

        switch operation {
        case "create", "update":
            let options = values["options"] as? [String: Any] ?? [:]
            let content = UNMutableNotificationContent()
            content.title = (options["title"] as? String)?.nonEmpty
                ?? context.webExtension.displayName?.nonEmpty
                ?? "Soulo"
            content.body = (options["message"] as? String)?.nonEmpty
                ?? (options["contextMessage"] as? String)?.nonEmpty
                ?? ""
            content.sound = .default
            Task { @MainActor in
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                    guard granted else {
                        replyHandler(["id": String(notificationID.dropFirst(extensionPrefix.count))], nil)
                        return
                    }
                    try await center.add(UNNotificationRequest(
                        identifier: notificationID,
                        content: content,
                        trigger: nil
                    ))
                    replyHandler([
                        "id": String(notificationID.dropFirst(extensionPrefix.count)),
                        "success": true
                    ], nil)
                } catch {
                    replyHandler(nil, error)
                }
            }
        case "clear":
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.removeDeliveredNotifications(withIdentifiers: [notificationID])
            replyHandler(["success": true], nil)
        case "getAll":
            Task { @MainActor in
                let requests = await center.pendingNotificationRequests()
                let pairs: [(String, [String: Any])] = requests.compactMap { request in
                    guard request.identifier.hasPrefix(extensionPrefix) else { return nil }
                    return (String(request.identifier.dropFirst(extensionPrefix.count)), [:] as [String: Any])
                }
                let notifications = Dictionary(uniqueKeysWithValues: pairs)
                replyHandler(["notifications": notifications], nil)
            }
        case "permission":
            Task { @MainActor in
                let settings = await center.notificationSettings()
                var granted: Set<UNAuthorizationStatus> = [.authorized, .provisional]
                #if os(iOS)
                granted.insert(.ephemeral)
                #endif
                replyHandler(["level": granted.contains(settings.authorizationStatus) ? "granted" : "denied"], nil)
            }
        default:
            replyHandler(nil, NativeWebExtensionCompatibilityError.unsupportedOperation)
        }
    }

    private func handleAudio(
        _ values: [String: Any],
        context: WKWebExtensionContext,
        resourceURL: URL?,
        replyHandler: @escaping (Any?, Error?) -> Void
    ) {
        let key = ObjectIdentifier(context)
        if values["operation"] as? String == "stop" {
            audioPlayers[key]?.stop()
            audioPlayers.removeValue(forKey: key)
            replyHandler(["success": true], nil)
            return
        }
        guard values["operation"] as? String == "play",
              let resourceURL,
              var relativePath = values["source"] as? String else {
            replyHandler(nil, NativeWebExtensionCompatibilityError.invalidResource)
            return
        }
        while relativePath.hasPrefix("/") { relativePath.removeFirst() }
        let audioURL = resourceURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = resourceURL.standardizedFileURL.path + "/"
        guard audioURL.path.hasPrefix(rootPath), FileManager.default.fileExists(atPath: audioURL.path) else {
            replyHandler(nil, NativeWebExtensionCompatibilityError.invalidResource)
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            guard player.play() else { throw NativeWebExtensionCompatibilityError.audioPlaybackFailed }
            audioPlayers[key] = player
            replyHandler(["success": true], nil)
        } catch {
            replyHandler(nil, error)
        }
    }
}

private enum NativeWebExtensionCompatibilityError: LocalizedError {
    case unsupportedAPI
    case unsupportedOperation
    case invalidResource
    case audioPlaybackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedAPI: "The requested compatibility API is unsupported."
        case .unsupportedOperation: "The requested compatibility operation is unsupported."
        case .invalidResource: "The extension resource is invalid or unavailable."
        case .audioPlaybackFailed: "The extension audio resource could not be played."
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
