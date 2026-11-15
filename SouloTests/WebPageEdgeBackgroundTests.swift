import XCTest
import UIKit
import WebKit
import SwiftUI
@testable import Soulo

@MainActor
final class WebPageEdgeBackgroundTests: XCTestCase {
    func testDirectPlayableMediaNavigationDoesNotShowPluginHandledLoadAsAnError() async throws {
        let movie = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let server = try DownloadPlaybackHTTPFixture(files: ["/direct.mp4": Data(contentsOf: movie)])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let model = WebViewModel(), address = base.appendingPathComponent("direct.mp4")
        model.loadURL(address)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model)); window.makeKeyAndVisible()
        defer { model.releaseWebViewRuntime(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        var ready = 0
        for _ in 0..<200 {
            ready = (try? await model.webView?.evaluateJavaScript("document.querySelector('video')?.readyState??0")) as? Int ?? 0
            if ready > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(ready, 0, model.errorMessage ?? "Native video document did not load")
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/direct.mp4" })
    }

    func testBackgroundUsesSolidColorsByDefaultAndRestoresGradientsOnDemand() throws {
        let key = AppConstants.StorageKeys.pageBackgroundGradient, defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.removeObject(forKey: key)
        let red = WebPageEdgeColor(red: 1, green: 0, blue: 0)
        let green = WebPageEdgeColor(red: 0, green: 1, blue: 0)
        let blue = WebPageEdgeColor(red: 0, green: 0, blue: 1)
        let model = WebViewModel()
        model.pageEdgePalette = WebPageEdgePalette(top: [red, green, blue], bottom: [red, blue, red])
        func pixels() throws -> [UInt8] {
            let renderer = ImageRenderer(content: WebPageEdgeBackground(model: model).frame(width: 96, height: 96)); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            var data = [UInt8](repeating: 0, count: 96 * 96 * 4)
            try data.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 96, height: 96, bitsPerComponent: 8,
                    bytesPerRow: 96 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 96))
            }
            return data
        }
        let solid = try pixels()
        for row in [12, 84] {
            for channel in 0..<3 {
                XCTAssertEqual(solid[(row * 96 + 8) * 4 + channel], solid[(row * 96 + 88) * 4 + channel], "Each edge must be a single solid color by default")
            }
        }
        XCTAssertEqual(model.pageEdgePalette?.forDisplay(gradients: false).bottom, [red], "The repeated background wins over the center outlier")
        defaults.set(true, forKey: key)
        let gradient = try pixels()
        XCTAssertNotEqual(gradient, solid)
        XCTAssertEqual(model.pageEdgePalette?.top, [red, green, blue], "Display style must preserve the sampled colors and frozen-page state")
    }
    func testFreezeAfterScrollStopsObservationAndRetainsFirstColorsUntilNewPage() async throws {
        let defaults = UserDefaults.standard
        let keys = [AppConstants.StorageKeys.extendPageBackground, AppConstants.StorageKeys.freezePageBackgroundOnScroll]
        let old = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, old) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.set(true, forKey: $0) }
        let server = try DownloadPlaybackHTTPFixture(files: ["/freeze": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><body id='ready' style='margin:0;background:red;height:2400px'>First colors</body>".utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let model = WebViewModel(), coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        let messages = EdgeMessages(coordinator), configuration = WKWebViewConfiguration()
        configuration.userContentController.add(messages, contentWorld: WebPageEdgeRuntime.world, name: WebPageEdgeRuntime.handler)
        configuration.userContentController.addUserScript(WKUserScript(source: WebPageEdgeRuntime.script(enabled: true), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: WebPageEdgeRuntime.world))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 350, height: 600), configuration: configuration)
        model.webView = web; web.navigationDelegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.rootViewController?.view.addSubview(web); window.makeKeyAndVisible()
        defer {
            configuration.userContentController.removeScriptMessageHandler(forName: WebPageEdgeRuntime.handler, contentWorld: WebPageEdgeRuntime.world)
            coordinator.invalidateObservations(); model.releaseWebViewRuntime()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        web.load(URLRequest(url: address.appendingPathComponent("freeze")))
        for _ in 0..<120 {
            if model.pageEdgePalette != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let first = try XCTUnwrap(model.pageEdgePalette)
        XCTAssertGreaterThan(first.top[0].red, 0.9)
        web.scrollView.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        coordinator.scrollViewDidScroll(web.scrollView)
        try await Task.sleep(for: .milliseconds(350))
        let baseline = messages.count
        _ = try await web.evaluateJavaScript("for(let i=0;i<100;i++)document.body.style.background=i%2?'blue':'green';true")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(messages.count, baseline, "Frozen pages must stop the mutation observer, not keep posting color work")
        XCTAssertEqual(model.pageEdgePalette, first)
        defaults.set(false, forKey: keys[1]); coordinator.synchronizePageEdges(on: web)
        for _ in 0..<100 {
            if (model.pageEdgePalette?.top[0].blue ?? 0) > 0.9 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(model.pageEdgePalette?.top[0].blue ?? 0, 0.9)
        model.beginPageNavigation()
        XCTAssertNil(model.pageEdgePalette); XCTAssertFalse(model.pageEdgesHaveScrolled)
    }

    private final class EdgeMessages: NSObject, WKScriptMessageHandler {
        let coordinator: WebViewRepresentable.Coordinator
        var count = 0
        init(_ coordinator: WebViewRepresentable.Coordinator) { self.coordinator = coordinator }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            count += 1
            coordinator.userContentController(controller, didReceive: message)
        }
    }

    func testNavigationUsesCurrentBackgroundExtensionSwitchInsteadOfInitialScriptValue() async throws {
        let defaults = UserDefaults.standard, key = AppConstants.StorageKeys.extendPageBackground
        let old = defaults.object(forKey: key)
        defer { defaults.set(old, forKey: key) }
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><body id='ready' style='background:red'>Page edges</body>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/first": Data(html.utf8), "/next": Data(html.utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        for initialEnabled in [false, true] {
            defaults.set(initialEnabled, forKey: key)
            let model = WebViewModel(), coordinator = WebViewRepresentable.Coordinator(viewModel: model)
            let messages = EdgeMessages(coordinator), configuration = WKWebViewConfiguration()
            let controller = configuration.userContentController
            controller.add(messages, contentWorld: WebPageEdgeRuntime.world, name: WebPageEdgeRuntime.handler)
            controller.addUserScript(WKUserScript(source: WebPageEdgeRuntime.script(enabled: initialEnabled),
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: WebPageEdgeRuntime.world))
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 350, height: 600), configuration: configuration)
            web.scrollView.contentInsetAdjustmentBehavior = .never
            model.webView = web; web.navigationDelegate = coordinator
            window.rootViewController?.view.addSubview(web)
            defer {
                controller.removeScriptMessageHandler(forName: WebPageEdgeRuntime.handler, contentWorld: WebPageEdgeRuntime.world)
                coordinator.invalidateObservations(); model.releaseWebViewRuntime(); web.removeFromSuperview()
            }
            func load(_ path: String) async throws {
                web.load(URLRequest(url: address.appendingPathComponent(path)))
                var ready = false
                for _ in 0..<100 {
                    let documentReady = (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true
                    ready = web.url?.lastPathComponent == path && !web.isLoading && documentReady
                    if ready { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertTrue(ready, "The actual navigation must finish")
                try await Task.sleep(for: .milliseconds(450))
            }
            try await load("first")
            coordinator.synchronizePageEdges(on: web)
            defaults.set(!initialEnabled, forKey: key)
            coordinator.synchronizePageEdges(on: web)
            try await load("next")
            let baseline = messages.count
            _ = try await web.evaluateJavaScript("document.body.style.background='blue';true")
            try await Task.sleep(for: .milliseconds(600))
            if initialEnabled {
                XCTAssertEqual(messages.count, baseline, "After switching off, a new document must not observe page colors")
            } else {
                XCTAssertGreaterThan(messages.count, baseline, "After switching on, a new document must still observe dynamic page colors")
            }
        }
    }

    func testDominantColorRejectsTextAndCompositesTransparentPixels() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 192, height: 18)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 192, height: 18))
            UIColor.white.setFill()
            for x in stride(from: 4, to: 190, by: 19) { context.fill(CGRect(x: x, y: 0, width: 2, height: 18)) }
        }
        let colors = try XCTUnwrap(WebPageEdgePalette.edgeColors(image, base: .white))
        for color in colors { XCTAssertGreaterThan(color.red, 0.9); XCTAssertLessThan(color.green, 0.1); XCTAssertLessThan(color.blue, 0.1) }
        let format = UIGraphicsImageRendererFormat(); format.opaque = false
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 9), format: format).image { _ in }
        let composite = try XCTUnwrap(WebPageEdgePalette.edgeColors(transparent, base: .blue))
        XCTAssertGreaterThan(try XCTUnwrap(composite.first).blue, 0.9)
    }

    func testNativeSnapshotsRecognizeDifferentTopBottomGradientsAndDynamicChanges() async throws {
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>html,body{margin:0;background:white}header,footer{position:fixed;left:0;right:0;height:65px}header{top:0;background:linear-gradient(90deg,#ff0000,#ffcc00)}footer{bottom:0;background:linear-gradient(90deg,#00aa44,#0022ff)}</style>
        <header></header><main id='ready'>Rendered edge fixture</main><footer></footer>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/colors": Data(html.utf8)])
        let address = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 350, height: 600))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.rootViewController?.view.addSubview(web)
        web.load(URLRequest(url: address.appendingPathComponent("colors")))
        defer { web.stopLoading() }
        var ready = false
        for _ in 0..<100 {
            ready = (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true
            if ready { break }; try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(ready)
        let sampler = WebPageEdgeSampler()
        let captured = await sampler.capture(web)
        let palette = try XCTUnwrap(captured)
        XCTAssertGreaterThan(palette.top[0].red, 0.9)
        XCTAssertLessThan(palette.top[0].blue, 0.1)
        XCTAssertGreaterThan(palette.top[2].green, 0.5)
        XCTAssertGreaterThan(palette.bottom[0].green, 0.4)
        XCTAssertGreaterThan(palette.bottom[2].blue, 0.7)
        _ = try await web.evaluateJavaScript("document.querySelector('header').style.background='#111111';document.querySelector('footer').style.background='#eeeeee';true")
        let changedCapture = await sampler.capture(web)
        let changed = try XCTUnwrap(changedCapture)
        XCTAssertEqual(changed.topScheme, .dark)
        XCTAssertEqual(changed.bottomScheme, .light)
        XCTAssertLessThan(changed.top[1].red, 0.1)
        XCTAssertGreaterThan(changed.bottom[1].red, 0.9)
        let attachment = XCTAttachment(image: try await web.takeSnapshot(configuration: nil)); attachment.name = "page-edge-rendered-dark-top-light-bottom"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDisabledSamplingDoesNotChangePaletteAndNavigationClearsIt() async throws {
        let key = AppConstants.StorageKeys.extendPageBackground
        let defaults = UserDefaults.standard, old = defaults.object(forKey: key)
        defer { defaults.set(old, forKey: key) }
        defaults.set(false, forKey: key)
        let model = WebViewModel(), web = WKWebView()
        let sampler = WebPageEdgeSampler()
        sampler.schedule(on: web, model: model)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.pageEdgePalette)
        let color = WebPageEdgeColor(red: 1, green: 0, blue: 0)
        model.pageEdgePalette = WebPageEdgePalette(top: [color], bottom: [color])
        model.beginPageNavigation()
        XCTAssertNil(model.pageEdgePalette)
    }

    func testChromeContrastDoesNotOverrideExplicitWebAppearance() {
        let defaults = UserDefaults.standard
        let keys = [AppConstants.StorageKeys.extendPageBackground, "appearance", AppConstants.StorageKeys.webFollowsAppColorScheme, AppConstants.StorageKeys.webForceDarkPages]
        let old = keys.map { defaults.object(forKey: $0) }
        defer { for (key,value) in zip(keys,old) { defaults.set(value, forKey: key) }; WebAppearanceService.shared.refreshFromDefaults() }
        defaults.set(true, forKey: keys[0]); defaults.set("light", forKey: keys[1]); defaults.set(true, forKey: keys[2]); defaults.set(false, forKey: keys[3])
        WebAppearanceService.shared.refreshFromDefaults()
        let web = WKWebView(); web.overrideUserInterfaceStyle = .dark
        WebAppearanceService.shared.apply(to: web)
        XCTAssertEqual(web.overrideUserInterfaceStyle, .light)
    }
}
