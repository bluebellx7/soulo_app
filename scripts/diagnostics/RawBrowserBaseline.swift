import UIKit
import WebKit

@main @MainActor final class BaselineApp: UIResponder, UIApplicationDelegate, WKScriptMessageHandler {
    var window: UIWindow?
    let probe = ReadOnlyProbe()
    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let profile = UserDefaults.standard.string(forKey: "profile") ?? "system"
        probe.profile = profile
        probe.entry = UserDefaults.standard.string(forKey: "entry") ?? "manual"
        let config = WKWebViewConfiguration()
        if profile != "system" { config.allowsInlineMediaPlayback = true }
        if !["system", "inline"].contains(profile) { config.mediaTypesRequiringUserActionForPlayback = [] }
        if ["fullscreen","windows","routing","suspend"].contains(profile) || profile.hasPrefix("script-") { config.preferences.isElementFullscreenEnabled = true }
        if ["windows","routing","suspend"].contains(profile) || profile.hasPrefix("script-") { config.preferences.javaScriptCanOpenWindowsAutomatically = true }
        if UserDefaults.standard.bool(forKey:"cloneAudit") {
            config.userContentController.addUserScript(WKUserScript(source:ReadOnlyProbe.cloneAudit,injectionTime:.atDocumentStart,forMainFrameOnly:false,in:.page))
        }
        if profile.hasPrefix("script-"), let url=Bundle.main.url(forResource:"isolation-scripts",withExtension:"json"),
           let data=try? Data(contentsOf:url), let rows=(try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] {
            let names: Set<String> = profile == "script-all" ? Set(rows.compactMap{$0["name"] as? String}.filter{!$0.hasSuffix("-before")})
                : profile == "script-handoff" ? ["navigation","session"] : [String(profile.dropFirst(7))]
            var registeredWorlds = Set<String>()
            for row in rows where names.contains(row["name"] as? String ?? "") {
                guard let source=row["source"] as? String,let name=row["world"] as? String else{continue}
                let world: WKContentWorld = name == "page" ? .page : name == "defaultClient" ? .defaultClient : .world(name:name)
                config.userContentController.addUserScript(WKUserScript(source:source,injectionTime:row["end"] as? Bool == true ? .atDocumentEnd : .atDocumentStart,forMainFrameOnly:false,in:world))
                if registeredWorlds.insert(name).inserted {
                    for handler in ["souloContextResource","souloVideoAwake","souloMediaFrame","souloMediaSession","souloVideoOrientation","souloEpisodes","souloAdBlocker","souloPrivacy","souloPageReady","souloNavigationGesture"] {
                        config.userContentController.add(self,contentWorld:world,name:handler)
                    }
                }
            }
        }
        let web = WKWebView(frame: .zero, configuration: config)
        if !["system","inline","autoplay"].contains(profile) {
            web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        }
        let root = Browser(web: web, probe: probe, root: true)
        let nav = UINavigationController(rootViewController: root)
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        root.search()
        if UserDefaults.standard.string(forKey: "sampling") != "NO" {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak probe] _ in
                Task { @MainActor in await probe?.record() }
            }
        }
        return true
    }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard let body=message.body as? [String:Any], let web=message.webView else{return}
        if message.name == "souloMediaSession",body["ready"] as? Bool == true {
            web.callAsyncJavaScript("window.__souloMediaRestore?.(items);",arguments:["items":[]],in:message.frameInfo,in:message.world,completionHandler:nil)
            if message.frameInfo.isMainFrame,let browser=probe.controllers.compactMap({$0.value}).first(where:{$0.web===web}),
               let pending=browser.pendingHandoff,web.url?.host==pending.0.host,web.url?.path==pending.0.path,
               URLComponents(url:web.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="nid"})?.value == URLComponents(url:pending.0,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="nid"})?.value {
                browser.pendingHandoff=nil
                web.callAsyncJavaScript("window.__souloMediaRestorePlayback?.(intent);",arguments:["intent":pending.1],in:message.frameInfo,in:message.world,completionHandler:nil)
            }
        }
        if message.name == "souloNavigationGesture",let raw=body["videoLanding"] as? String,let target=URL(string:raw),
           let browser=probe.controllers.compactMap({$0.value}).first(where:{$0.web===web}) {
            if probe.profile == "script-handoff",let intent=body["videoPlayback"] as? [String:Any] {
                web.callAsyncJavaScript("return window.__souloMediaRetire?.();",arguments:[:],in:nil,in:.world(name:"SouloMediaSession")) { [weak browser,weak web] _ in
                    guard let browser,let web else{return}
                    browser.pendingHandoff=(target,intent)
                    browser.nativeRequests.insert(target)
                    web.load(URLRequest(url:target))
                }
            } else {
                browser.nativeRequests.insert(target)
                web.load(URLRequest(url:target))
            }
        }
    }
}

@MainActor final class Browser: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    let probe: ReadOnlyProbe
    let root: Bool
    let location = UILabel()
    let status = UILabel()
    var nativeRequests = Set<URL>()
    var suspended = false
    var pendingHandoff: (URL,[String:Any])?
    init(web: WKWebView, probe: ReadOnlyProbe, root: Bool) {
        self.web = web; self.probe = probe; self.root = root
        super.init(nibName: nil, bundle: nil)
        probe.views.append(WeakWeb(web, root: root))
        probe.controllers.append(WeakBrowser(self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = ["system":"0 原始 · 系统默认", "inline":"1 仅内联播放", "autoplay":"2 加自动播放", "ua":"3 加 Soulo UA", "fullscreen":"4 加全屏开关", "windows":"5 加弹窗开关", "routing":"6 加导航重载", "suspend":"7 加媒体挂起", "script-all":"8 七项脚本组合", "script-handoff":"9 播放接续链"][probe.profile] ?? "单项 · \(probe.profile)"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: root ? "返回" : "关闭", style: .plain, target: self, action: #selector(back))
        let sampling = UserDefaults.standard.string(forKey: "sampling") != "NO"
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: "搜索页", style: .plain, target: self, action: #selector(search))
        ]
        if sampling { navigationItem.rightBarButtonItems?.insert(UIBarButtonItem(title: "采样", style: .plain, target: self, action: #selector(mark)), at: 0) }
        location.font = .systemFont(ofSize: 12)
        location.accessibilityIdentifier = "baseline.location"
        location.text = "about:blank"
        status.font = .systemFont(ofSize: 12)
        status.accessibilityIdentifier = "baseline.state"
        status.text = sampling ? "仅采样，不改网页" : "原始网页 · 无注入、拦截或媒体接管"
        probe.labels.append(WeakLabel(status))
        status.translatesAutoresizingMaskIntoConstraints = false
        web.translatesAutoresizingMaskIntoConstraints = false
        location.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(web); view.addSubview(location); view.addSubview(status)
        NSLayoutConstraint.activate([
            location.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            location.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            location.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            location.heightAnchor.constraint(equalToConstant: 24),
            web.topAnchor.constraint(equalTo: location.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: status.topAnchor),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 24)
        ])
        web.navigationDelegate = self
        web.uiDelegate = self
    }
    @objc func search() {
        var url = URLComponents(string: "https://www.baidu.com/s")!
        url.queryItems = [URLQueryItem(name: "wd", value: "20201年喜剧电影解说")]
        nativeRequests.insert(url.url!)
        web.load(URLRequest(url: url.url!))
    }
    @objc func back() {
        if !root { dismiss(animated: false) }
        else if web.canGoBack { web.goBack() }
    }
    @objc func mark() { probe.phase += 1; Task { await probe.record() } }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        setSuspended(false)
        location.text = (webView.url?.host ?? "") + (webView.url?.path ?? "")
    }
    func setSuspended(_ value: Bool) {
        guard probe.profile == "suspend" || probe.profile.hasPrefix("script-"), suspended != value else { return }
        suspended = value
        web.setAllMediaPlaybackSuspended(value, completionHandler: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { setSuspended(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { setSuspended(false) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { setSuspended(false) }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy)->Void) {
        let native = action.request.url.flatMap { nativeRequests.remove($0) } != nil
        if (["routing","suspend"].contains(probe.profile) || probe.profile.hasPrefix("script-")), !native,
           action.targetFrame?.isMainFrame != false,
           let url=action.request.url, ["https","http"].contains(url.scheme ?? ""),
           (action.request.httpMethod ?? "GET") == "GET", ![.backForward,.reload].contains(action.navigationType) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self, weak webView] in
                self?.nativeRequests.insert(url)
                webView?.load(action.request)
            }
            return
        }
        if action.targetFrame?.isMainFrame == true { setSuspended(true) }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Basic browser window support only. Preserve WebKit's configuration;
        // never rewrite the URL or mutate either document/media element.
        let child = WKWebView(frame: .zero, configuration: configuration)
        child.customUserAgent = webView.customUserAgent
        let controller = Browser(web: child, probe: probe, root: false)
        let nav = UINavigationController(rootViewController: controller)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: false)
        return child
    }
    func webViewDidClose(_ webView: WKWebView) { if !root { dismiss(animated: false) } }
}

@MainActor final class WeakWeb {
    weak var web: WKWebView?
    let root: Bool
    let id = UUID().uuidString
    init(_ web: WKWebView, root: Bool) { self.web = web; self.root = root }
}

@MainActor final class ReadOnlyProbe {
    var profile = "system"
    var entry = "manual"
    var phase = 0
    var views: [WeakWeb] = []
    var labels: [WeakLabel] = []
    var controllers: [WeakBrowser] = []
    var busy = false
    var records: [[String: Any]] = []
    func record() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        var states: [[String: Any]] = []
        for entry in views {
            guard let web = entry.web else { continue }
            let state = (try? await web.evaluateJavaScript(Self.readOnly)) as? [String: Any] ?? [:]
            let native = await withCheckedContinuation { c in web.requestMediaPlaybackState { c.resume(returning: $0.rawValue) } }
            let frame = web.convert(web.bounds, to: nil)
            states.append(["id":entry.id,"root":entry.root,"inWindow":web.window != nil,
                "scripts":web.configuration.userContentController.userScripts.count,"native":native,
                "inline":web.configuration.allowsInlineMediaPlayback,
                "autoplayPolicy":web.configuration.mediaTypesRequiringUserActionForPlayback.rawValue,
                "fullscreen":web.configuration.preferences.isElementFullscreenEnabled,
                "automaticWindows":web.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
                "query":(URLComponents(url:web.url ?? URL(string:"about:blank")!,resolvingAgainstBaseURL:false)?.queryItems ?? []).filter { ["pd","nid","frsrcid","atn","nonTips","ms","top","fr0","fr1"].contains($0.name) }.reduce(into:[String:String]()) { $0[$1.name]=$1.value ?? "" },
                "frame":["x":frame.minX,"y":frame.minY,"w":frame.width,"h":frame.height],
                "url":(web.url?.host ?? "")+(web.url?.path ?? ""),"state":state])
        }
        let record: [String:Any] = ["profile":profile,"entry":entry,"time":Date().timeIntervalSince1970,"phase":phase,"views":states]
        records.append(record)
        if let data = try? JSONSerialization.data(withJSONObject: record), let value=String(data:data,encoding:.utf8) {
            for label in labels {
                label.value?.accessibilityValue=value
                label.value?.text="\(profile) · \(states.count) 个网页 · 采样 \(phase)"
            }
        }
        if records.count > 180 { records.removeFirst() }
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted,.sortedKeys]) {
            try? data.write(to: folder.appendingPathComponent("baseline-\(profile)-\(entry).json"), options: .atomic)
        }
    }
    // Diagnostic only: weak references observe objects created by the original
    // cloneNode. They neither retain players nor call play/pause/mute/load.
    static let cloneAudit = #"""
    (()=>{
      const original=Node.prototype.cloneNode,refs=[];
      Node.prototype.cloneNode=function(...args){
        const result=original.apply(this,args),media=[...(result.querySelectorAll?.('video,audio')||[])];
        if(result.matches?.('video,audio'))media.push(result);
        media.forEach(m=>{if(refs.length<128)refs.push(new WeakRef(m));});
        return result;
      };
      window.__baselineClonedMedia=()=>refs.map(ref=>ref.deref()).filter(Boolean).map(m=>({connected:m.isConnected,paused:m.paused,muted:m.muted,time:m.currentTime,ready:m.readyState,tag:m.tagName}));
    })();
    """#
    static let readOnly = #"""
    (()=>{
      const off=document.querySelector('[class*=voiceControlContainer] [class*=voiceOffSvg]');
      const rect=s=>{const n=document.querySelector(s);if(!n)return null;const r=n.getBoundingClientRect();return {x:r.x,y:r.y,w:r.width,h:r.height};};
      return {clones:window.__baselineClonedMedia?.()||[],title:document.title,ua:navigator.userAgent,visibility:document.visibilityState,body:document.body?.innerText.slice(0,2000)||'',
        innerWidth, soundRect:rect('[class*=voiceControlContainer]'),playRect:rect('[class*=playControlContainer]'),
        iconMuted:!!off&&getComputedStyle(off).display!=='none',
        media:[...document.querySelectorAll('video,audio')].map(v=>{
          const r=v.getBoundingClientRect();return {time:v.currentTime,paused:v.paused,muted:v.muted,volume:v.volume,ready:v.readyState,controls:v.controls,
          duration:Number.isFinite(v.duration)?v.duration:0,width:v.videoWidth||0,height:v.videoHeight||0,
          x:r.x,y:r.y,w:r.width,h:r.height};
        })};
    })()
    """#
}

@MainActor final class WeakLabel {
    weak var value: UILabel?
    init(_ value: UILabel) { self.value=value }
}

@MainActor final class WeakBrowser {
    weak var value: Browser?
    init(_ value:Browser) {self.value=value}
}
