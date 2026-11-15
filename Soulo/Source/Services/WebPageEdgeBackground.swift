import SwiftUI
import WebKit

struct WebPageEdgeColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
    var luminance: Double { red * 0.2126 + green * 0.7152 + blue * 0.0722 }
}

struct WebPageEdgePalette: Equatable, Sendable {
    let top: [WebPageEdgeColor]
    let bottom: [WebPageEdgeColor]
    var topScheme: ColorScheme { top.map(\.luminance).reduce(0, +) / Double(max(1, top.count)) < 0.5 ? .dark : .light }
    var bottomScheme: ColorScheme { bottom.map(\.luminance).reduce(0, +) / Double(max(1, bottom.count)) < 0.5 ? .dark : .light }

    func forDisplay(gradients: Bool) -> Self {
        guard !gradients else { return self }
        func dominant(_ colors: [WebPageEdgeColor]) -> WebPageEdgeColor {
            // Prefer the repeated background color; a smooth gradient has no
            // dominant region, so use its middle sample instead of mixing hues.
            let middle = colors.count / 2
            func count(_ color: WebPageEdgeColor) -> Int {
                colors.filter { abs($0.red - color.red) < 0.08 && abs($0.green - color.green) < 0.08 && abs($0.blue - color.blue) < 0.08 }.count
            }
            return colors.indices.max {
                let lhs = count(colors[$0]), rhs = count(colors[$1])
                return lhs == rhs ? abs($0 - middle) > abs($1 - middle) : lhs < rhs
            }.map { colors[$0] } ?? WebPageEdgeColor(red: 1, green: 1, blue: 1)
        }
        return Self(top: [dominant(top)], bottom: [dominant(bottom)])
    }

    /// Ignore text/antialiasing outliers and retain three horizontal color stops.
    static func edgeColors(_ image: UIImage, base: UIColor) -> [WebPageEdgeColor]? {
        let width = 96, height = 9
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
        pixels.initialize(repeating: 0, count: width * height * 4)
        defer { pixels.deallocate() }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let cg = image.cgImage,
              let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(base.cgColor); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (0..<3).map { segment in
            var histogram: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
            for y in 1..<(height - 1) {
                for x in (segment * width / 3)..<((segment + 1) * width / 3) {
                    let i = (y * width + x) * 4
                    let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
                    let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                    let old = histogram[key] ?? (0, 0, 0, 0)
                    histogram[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
                }
            }
            let dominant = histogram.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }.first!.value
            let divisor = Double(dominant.count * 255)
            return WebPageEdgeColor(red: Double(dominant.r) / divisor, green: Double(dominant.g) / divisor, blue: Double(dominant.b) / divisor)
        }
    }
}

struct WebPageEdgeBackground: View {
    @ObservedObject var model: WebViewModel
    @AppStorage(AppConstants.StorageKeys.pageBackgroundGradient) private var pageBackgroundGradient = false
    var body: some View {
        Group {
            if let palette = model.pageEdgePalette?.forDisplay(gradients: pageBackgroundGradient) {
                if pageBackgroundGradient {
                ZStack {
                    LinearGradient(colors: palette.top.map(\.color), startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: palette.bottom.map(\.color), startPoint: .leading, endPoint: .trailing)
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0.3), .init(color: .black, location: 0.75)], startPoint: .top, endPoint: .bottom))
                }
                } else {
                    VStack(spacing: 0) {
                        (palette.top.first?.color ?? Color(uiColor: .systemBackground)).frame(maxHeight: .infinity)
                        (palette.bottom.first?.color ?? Color(uiColor: .systemBackground)).frame(maxHeight: .infinity)
                    }
                }
            } else { Color(uiColor: .systemBackground) }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Captures only two narrow strips of the actual rendered page, so CSS images,
/// gradients, transparency, frames and forced-dark rendering all count.
@MainActor
final class WebPageEdgeSampler {
    private final class SnapshotReply {
        var continuation: CheckedContinuation<UIImage?, Never>?
        var timeout: Task<Void, Never>?
        func finish(_ image: UIImage?) {
            guard let continuation else { return }
            self.continuation = nil; timeout?.cancel(); timeout = nil
            continuation.resume(returning: image)
        }
    }
    private var pending: Task<Void, Never>?
    private var generation = UUID()
    private var lastCapture = Date.distantPast
    static func shouldFreeze(_ model: WebViewModel, enabled: Bool? = nil) -> Bool {
        (enabled ?? UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.freezePageBackgroundOnScroll))
            && model.pageEdgesHaveScrolled && model.pageEdgePalette != nil
    }
    func reset() { generation = UUID(); pending?.cancel(); pending = nil }
    func schedule(on web: WKWebView, model: WebViewModel) {
        guard UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.extendPageBackground),
              !Self.shouldFreeze(model),
              web.window != nil, !web.isHidden, model.hasPresentedContent, pending == nil else { return }
        let token = generation, url = web.url
        pending = Task { @MainActor [weak self, weak web, weak model] in
            guard let self else { return }
            defer { if self.generation == token { self.pending = nil } }
            do { try await Task.sleep(for: .seconds(max(0.2, 0.8 - Date().timeIntervalSince(self.lastCapture)))) } catch { return }
            guard let web, let model, self.generation == token, web.url == url,
                  UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.extendPageBackground), web.window != nil else { return }
            guard !Self.shouldFreeze(model) else { return }
            // Wait for touch/deceleration to settle instead of competing with scrolling.
            if web.scrollView.isDragging || web.scrollView.isDecelerating { return }
            self.lastCapture = Date()
            guard let palette = await self.capture(web), self.generation == token, web.url == url, !Task.isCancelled else { return }
            if model.pageEdgePalette != palette { model.pageEdgePalette = palette }
        }
    }
    func capture(_ web: WKWebView) async -> WebPageEdgePalette? {
        let bounds = web.bounds
        let inset = web.scrollView.adjustedContentInset
        let top = max(0, inset.top), bottom = min(bounds.height, bounds.height - max(0, inset.bottom))
        guard bounds.width > 1, bottom - top > 24 else { return nil }
        let base = web.underPageBackgroundColor ?? web.backgroundColor ?? .systemBackground
        let height = min(12, (bottom - top) / 4)
        let topRect = CGRect(x: 0, y: top, width: bounds.width, height: height)
        let bottomRect = CGRect(x: 0, y: bottom - height, width: bounds.width, height: height)
        func strip(_ rect: CGRect) async -> UIImage? {
            let config = WKSnapshotConfiguration(); config.rect = rect; config.snapshotWidth = 144
            return await withCheckedContinuation { continuation in
                let reply = SnapshotReply(); reply.continuation = continuation
                reply.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    reply.finish(nil)
                }
                web.takeSnapshot(with: config) { image, _ in reply.finish(image) }
            }
        }
        guard let first = await strip(topRect), !Task.isCancelled, let last = await strip(bottomRect), !Task.isCancelled,
              let topColors = WebPageEdgePalette.edgeColors(first, base: base), let bottomColors = WebPageEdgePalette.edgeColors(last, base: base) else { return nil }
        return WebPageEdgePalette(top: topColors, bottom: bottomColors)
    }
}

enum WebPageEdgeRuntime {
    static let world = WKContentWorld.world(name: "SouloPageEdges")
    static let handler = "souloPageEdges"
    static func script(enabled: Bool) -> String {
        #"""
        (()=>{
          if(window!==top)return;
          let enabled=false,timer=null,observer=null;
          const notify=()=>{if(!enabled||timer||document.hidden)return;timer=setTimeout(()=>{timer=null;try{webkit.messageHandlers.souloPageEdges.postMessage({changed:true});}catch(_){}},250);};
          function setEnabled(value){
            enabled=!!value;observer?.disconnect();observer=null;
            if(!enabled){clearTimeout(timer);timer=null;return;}
            observer=new MutationObserver(records=>{
              if(records.some(r=>{if(r.target===document.documentElement||r.target===document.body||r.target.nodeName==='HEAD'||r.target.parentElement?.nodeName==='STYLE')return true;const box=r.target.getBoundingClientRect?.();return box&&box.width>innerWidth*.5&&(box.top<20||box.bottom>innerHeight-20);}))notify();
            });
            if(document.documentElement)observer.observe(document.documentElement,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','style']});
            notify();
          }
          for(const event of ['load','pageshow','resize','scroll'])addEventListener(event,notify,{passive:true});
          document.addEventListener('load',notify,true);
          document.addEventListener('transitionend',notify,{passive:true});
          document.addEventListener('DOMContentLoaded',()=>setEnabled(enabled),{once:true});
          matchMedia('(prefers-color-scheme: dark)').addEventListener('change',notify);
          globalThis.__souloPageEdges={setEnabled};setEnabled(__ENABLED__);
        })();
        """#.replacingOccurrences(of: "__ENABLED__", with: enabled ? "true" : "false")
    }
}
