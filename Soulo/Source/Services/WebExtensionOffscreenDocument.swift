import Foundation
import UIKit
import WebKit

/// A real extension-origin document. Its lifetime belongs to the loaded
/// extension context, never to the worker JavaScript heap.
@MainActor
@available(iOS 18.4, *)
final class WebExtensionOffscreenDocument: NSObject, WKNavigationDelegate {
    let id = UUID().uuidString
    let url: URL
    private let context: WKWebExtensionContext
    private var webView: WKWebView?
    private var container: UIView?
    private var completion: ((Any?, Error?) -> Void)?
    private var timeout: Task<Void, Never>?
    private var pendingMessages: [UUID: (reply: (Any?, Error?) -> Void, timeout: Task<Void, Never>)] = [:]
    var access: WebExtensionAccess?

    static func resource(_ reference: String, root: URL) throws -> URL {
        guard let components = URLComponents(string: reference), components.scheme == nil,
              components.host == nil, components.query == nil, components.fragment == nil,
              !components.path.isEmpty, !components.path.contains("\\"), !components.path.contains("\0"),
              !components.path.split(separator: "/").contains("..") else {
            throw failure("Offscreen documents must use a bundled HTML resource.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let relative = String(components.path.drop(while: { $0 == "/" }))
        let file = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(base.path + "/"), ["html", "htm"].contains(file.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: file.path),
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw failure("The offscreen document is not a bundled HTML file.")
        }
        return file
    }

    init(reference: String, root: URL, context: WKWebExtensionContext, access: WebExtensionAccess?) throws {
        let file = try Self.resource(reference, root: root)
        let relative = String(file.path.dropFirst(root.resolvingSymlinksInPath().standardizedFileURL.path.count + 1))
        url = context.baseURL.appendingPathComponent(relative)
        self.context = context
        self.access = access
        super.init()
    }

    func open(completion: @escaping (Any?, Error?) -> Void) {
        guard let configuration = context.webViewConfiguration else {
            completion(nil, Self.failure("The extension context is unavailable.")); return
        }
        self.completion = completion
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        // WebKit suspends timers and asynchronous work in an unattached view.
        // Keep a noninteractive, inaccessible host underneath the app's root
        // view. It has no visible surface and never becomes a browser tab.
        if let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) {
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            host.isUserInteractionEnabled = false; host.accessibilityElementsHidden = true
            host.clipsToBounds = true; host.alpha = 0.01
            host.addSubview(view); window.insertSubview(host, at: 0); container = host
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.completion != nil else { return }
            self.close(error: Self.failure("The offscreen document did not finish loading."))
        }
        view.load(URLRequest(url: url))
    }

    var descriptor: [String: Any]? {
        guard webView != nil else { return nil }
        return ["contextId": id, "contextType": "OFFSCREEN_DOCUMENT", "documentId": id,
                "documentUrl": url.absoluteString, "documentOrigin": context.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                "tabId": -1, "windowId": -1, "frameId": 0, "incognito": false]
    }

    func close(error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        container?.removeFromSuperview(); container = nil
        finish(error: error ?? Self.failure("The offscreen document was closed before loading completed."))
        let pending = Array(pendingMessages.values); pendingMessages.removeAll()
        for message in pending { message.timeout.cancel(); message.reply(nil, error ?? Self.failure("The offscreen document was closed.")) }
    }

    func sendStructuredMessage(_ packet: Any, completion: @escaping (Any?, Error?) -> Void) {
        guard let view = webView else { completion(nil, Self.failure("There is no open offscreen document.")); return }
        let requestID = UUID()
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.finishMessage(requestID, value: nil, error: Self.failure("The offscreen message timed out."))
        }
        pendingMessages[requestID] = (completion, deadline)
        Task { @MainActor [weak self] in
            do {
                let result = try await view.callAsyncJavaScript(#"""
                const codec=\#(WebExtensionStructuredMessageCodec.javaScript);
                const target=navigator.serviceWorker;
                if(typeof target?.onmessage!=='function')throw Error('The offscreen document has no worker message handler.');
                return await new Promise((resolve,reject)=>{
                  const channel=new MessageChannel();
                  const cleanup=()=>{clearTimeout(timer);channel.port1.close();channel.port2.close();};
                  const timer=setTimeout(()=>{cleanup();reject(Error('The offscreen message timed out.'));},12000);
                  channel.port1.onmessage=async event=>{try{const reply=await codec.encode(event.data);cleanup();resolve(reply);}catch(error){cleanup();reject(error);}};
                  channel.port1.onmessageerror=()=>{cleanup();reject(Error('The offscreen reply could not be decoded.'));};
                  try{target.onmessage(new MessageEvent('message',{data:codec.decode(packet),ports:[channel.port2]}));}
                  catch(error){cleanup();reject(error);}
                });
                """#, arguments: ["packet": packet], in: nil, contentWorld: .page)
                self?.finishMessage(requestID, value: result, error: nil)
            } catch { self?.finishMessage(requestID, value: nil, error: error) }
        }
    }

    private func finishMessage(_ id: UUID, value: Any?, error: Error?) {
        guard let pending = pendingMessages.removeValue(forKey: id) else { return }
        pending.timeout.cancel(); pending.reply(value, error)
    }

    private func finish(error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        let reply = completion; completion = nil
        reply?(error == nil ? ["success": true] : nil, error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { close(error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { close(error: error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(error: Self.failure("The offscreen document process terminated."))
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let destination = action.request.url else { decisionHandler(.cancel); return }
        let sameOrigin = destination.scheme == context.baseURL.scheme && destination.host == context.baseURL.host
        if action.targetFrame?.isMainFrame != false {
            decisionHandler(sameOrigin && destination.path == url.path ? .allow : .cancel)
        } else if sameOrigin || ["about", "blob", "data"].contains(destination.scheme ?? "") {
            decisionHandler(.allow)
        } else {
            decisionHandler(access?.blocks(destination) != true && context.hasAccess(to: destination) ? .allow : .cancel)
        }
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Soulo.WebExtension.Offscreen", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
