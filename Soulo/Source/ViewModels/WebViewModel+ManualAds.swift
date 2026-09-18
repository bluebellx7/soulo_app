import WebKit
import UIKit

struct ManualAdSelection {
    let token: String
    let url: URL
    var hasSelection = false
    var canExpand = false
    var canShrink = false
    var isPreviewing = false
    var invalid = false
}

extension WebViewModel {
    var canMarkAdvertisement: Bool {
        webView?.url != nil && ManualAdBlockService.canUse(
            on: webView?.url ?? currentURL,
            enabled: UserDefaults.standard.object(forKey: "ad_block_enabled") as? Bool ?? true,
            allowlistedHosts: AdBlockSettingsService.shared.allowlistedHosts
        )
    }

    func beginMarkingAdvertisement() {
        guard canMarkAdvertisement, let webView, let url = webView.url else { return }
        cancelMarkingAdvertisement()
        let token = UUID().uuidString
        manualAdSelection = ManualAdSelection(token: token, url: url)
        manualAdBusy = true
        webView.endEditing(true)
        Task { @MainActor [weak self] in
            do {
                let result = try await webView.evaluateJavaScript(
                    "window.__souloManualAds.begin('\(token)')", in: nil, contentWorld: ManualAdBlockRuntime.world
                )
                guard self?.manualAdSelection?.token == token else { return }
                self?.manualAdBusy = false
                if result as? Bool != true { self?.failMarkingAdvertisement() }
            } catch {
                guard self?.manualAdSelection?.token == token else { return }
                self?.failMarkingAdvertisement()
            }
        }
    }

    /// Native hit testing cannot be swallowed by a site's JavaScript click handlers.
    func pickAdvertisement(at point: CGPoint) async {
        guard let selection = manualAdSelection, !manualAdBusy, let webView,
              webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        do {
            let result = try await webView.callAsyncJavaScript("""
                const viewport = window.visualViewport;
                const scale = (viewport?.width || innerWidth) / width;
                return window.__souloManualAds?.pickAtPoint(
                    (viewport?.offsetLeft || 0) + x * scale,
                    (viewport?.offsetTop || 0) + y * scale) ?? null;
                """, arguments: ["x": point.x, "y": point.y, "width": webView.bounds.width],
                in: nil, contentWorld: ManualAdBlockRuntime.world)
            guard manualAdSelection?.token == selection.token else { return }
            if let body = result as? [String: Any] { receiveManualAdSelection(body) }
        } catch {
            if manualAdSelection?.token == selection.token { failMarkingAdvertisement() }
        }
    }

    func receiveManualAdSelection(_ body: [String: Any]) {
        guard var selection = manualAdSelection,
              body["token"] as? String == selection.token,
              let urlString = body["url"] as? String, URL(string: urlString) == selection.url,
              webView?.url == selection.url else { return }
        selection.hasSelection = body["selected"] as? Bool == true && body["selector"] is String
        selection.canExpand = body["larger"] as? Bool == true
        selection.canShrink = body["smaller"] as? Bool == true
        selection.isPreviewing = body["preview"] as? Bool == true
        selection.invalid = body["invalid"] as? Bool == true
        manualAdSelection = selection
    }

    func adjustMarkedAdvertisement(_ action: String) {
        guard ["larger", "smaller", "preview"].contains(action), !manualAdBusy,
              let token = manualAdSelection?.token, let webView else { return }
        manualAdBusy = true
        Task { @MainActor [weak self] in
            defer { if self?.manualAdSelection?.token == token { self?.manualAdBusy = false } }
            do {
                let result = try await webView.evaluateJavaScript(
                    "window.__souloManualAds.command('\(action)')", in: nil, contentWorld: ManualAdBlockRuntime.world
                )
                guard self?.manualAdSelection?.token == token else { return }
                if let body = result as? [String: Any] { self?.receiveManualAdSelection(body) }
                else { self?.failMarkingAdvertisement() }
            } catch { if self?.manualAdSelection?.token == token { self?.failMarkingAdvertisement() } }
        }
    }

    func saveMarkedAdvertisement(wholeSite: Bool) {
        guard !manualAdBusy, let selection = manualAdSelection,
              selection.hasSelection, let webView, canMarkAdvertisement else { return }
        manualAdBusy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await webView.evaluateJavaScript(
                    "window.__souloManualAds.selection()", in: nil, contentWorld: ManualAdBlockRuntime.world
                )
                guard self.manualAdSelection?.token == selection.token else { return }
                guard self.canMarkAdvertisement, webView.url == selection.url,
                      let body = result as? [String: Any], body["token"] as? String == selection.token,
                      let current = body["url"] as? String, URL(string: current) == selection.url,
                      let selector = body["selector"] as? String,
                      let rule = ManualAdBlockService.shared.save(url: selection.url, selector: selector, wholeSite: wholeSite)
                else { self.failMarkingAdvertisement(); return }
                AdBlockSettingsService.shared.recordHiddenElementCount(1, for: selection.url.host)
                PrivacyProtectionService.shared.recordHiddenElementCount(1, for: selection.url.host)
                self.cancelMarkingAdvertisement()
                self.manualAdSavedRuleID = rule.id
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                if self.manualAdSelection?.token == selection.token { self.failMarkingAdvertisement() }
            }
        }
    }

    func cancelMarkingAdvertisement() {
        if manualAdSelection != nil { manualAdSelection = nil }
        if manualAdSavedRuleID != nil { manualAdSavedRuleID = nil }
        if manualAdBusy { manualAdBusy = false }
        webView?.evaluateJavaScript(
            "window.__souloManualAds?.command('cancel'); null", in: nil,
            in: ManualAdBlockRuntime.world, completionHandler: nil
        )
    }

    private func failMarkingAdvertisement() {
        cancelMarkingAdvertisement()
        manualAdError = true
    }
}
