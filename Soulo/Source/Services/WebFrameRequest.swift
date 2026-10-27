import WebKit

extension WKFrameInfo {
    /// iOS 17.0 can return nil despite the nonnull request declaration. Read the
    /// public Objective-C property without Swift's unconditional URLRequest bridge.
    var requestURL: URL? {
        (value(forKey: #keyPath(WKFrameInfo.request)) as? NSURLRequest)?.url
    }
}
