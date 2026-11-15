import WebKit

enum WebKitNativeContentWorld {
    /// These retained worlds are exclusively for Soulo's media integration.
    /// Third-party extensions keep WebKit's own per-extension permissions/worlds.
    static func media(name: String) -> WKContentWorld {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            let configuration = WKContentWorld.Configuration()
            configuration.allowAccessingClosedShadowRoots = true
            configuration.autofillScriptingEnabled = false
            configuration.isInspectable = false
            return WKContentWorld(configuration: configuration)
        }
        #endif
        return WKContentWorld.world(name: name)
    }
}
