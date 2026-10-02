import XCTest
import WebKit
@testable import Soulo

@MainActor
final class WebClipboardProtectionTests: XCTestCase {
    private func fixture() async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Instrument the native entry points before installing protection.
        config.userContentController.addUserScript(WKUserScript(source: #"""
            window.writes=[]; window.commands=[];
            const clipboard=Object.create({writeText(value){writes.push(value);return Promise.resolve()},
                write(value){writes.push(value);return Promise.resolve()}});
            Object.defineProperty(navigator,'clipboard',{value:clipboard});
            Document.prototype.execCommand=function(command){commands.push(command);return true};
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController.addUserScript(WKUserScript(source: WebViewScripts.clipboardProtection,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: config)
        web.loadHTMLString("<html><body><button id='copy'>Copy</button><iframe srcdoc='<p>Frame</p>'></iframe></body></html>",
            baseURL: URL(string: "https://example.test"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete' && !!document.getElementById('copy')")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Clipboard fixture did not load")
        return web
    }

    func testAutomaticWritesAndPrototypeCallsAreDenied() async throws {
        let web = try await fixture()
        let denied = try await web.callAsyncJavaScript(#"""
            const results=await Promise.all([
                navigator.clipboard.writeText('spam'),navigator.clipboard.write(['spam']),
                Object.getPrototypeOf(navigator.clipboard).writeText.call(navigator.clipboard,'spam')
            ].map(p=>p.then(()=>false,e=>e.name==='NotAllowedError')));
            return results.every(Boolean) && writes.length===0;
        """#, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? Bool, true)
    }

    func testSyntheticCopyButtonClickCannotAuthorizeClipboard() async throws {
        let web = try await fixture()
        let denied = try await web.callAsyncJavaScript(#"""
            document.getElementById('copy').click();
            try {await navigator.clipboard.writeText('spam');return false}
            catch(e){return e.name==='NotAllowedError' && writes.length===0}
        """#, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(denied as? Bool, true)
    }

    func testLegacyCopyBlockedWhileEditingCommandsRemainAvailable() async throws {
        let web = try await fixture()
        let results = try await web.evaluateJavaScript("""
            [document.execCommand('copy'),document.execCommand('cut'),
             document.execCommand('insertText',false,'hello'),commands.join(',')]
        """) as? [Any]
        XCTAssertEqual(results?[0] as? Bool, false)
        XCTAssertEqual(results?[1] as? Bool, false)
        XCTAssertEqual(results?[2] as? Bool, true)
        XCTAssertEqual(results?[3] as? String, "insertText")
    }

    func testCopyEventHijackingAndFrameWritesAreBlocked() async throws {
        let web = try await fixture()
        let result = try await web.callAsyncJavaScript(#"""
            let hijacked=false;
            document.addEventListener('copy',()=>{hijacked=true});
            const event=new Event('copy',{bubbles:true,cancelable:true});
            document.body.dispatchEvent(event);
            const frame=document.querySelector('iframe').contentWindow;
            let frameBlocked=false;
            try {await frame.navigator.clipboard.writeText('spam')}
            catch(e){frameBlocked=e.name==='NotAllowedError'}
            return event.defaultPrevented && !hijacked && frameBlocked && frame.writes.length===0;
        """#, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }
}
