import XCTest
@testable import Soulo

final class WebCompatibilityServiceTests: XCTestCase {
    func testXiaohongshuBypassesWebProtectionToPreserveAuthenticationUI() {
        XCTAssertTrue(
            WebCompatibilityService.shouldBypassWebProtection(
                for: URL(string: "https://www.xiaohongshu.com/search_result/?keyword=test")
            )
        )
        XCTAssertTrue(WebCompatibilityService.protectionBypassHosts().contains("xiaohongshu.com"))
    }

    func testOnlyXiaohongshuRequiresDesktopModeByHost() {
        XCTAssertTrue(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://www.xiaohongshu.com/search_result?keyword=test")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://www.baidu.com/s?wd=test")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://weixin.qq.com")
            )
        )
    }

    func testDetectsAuthenticatedXiaohongshuSessionCookie() throws {
        let authenticated = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".xiaohongshu.com",
                .path: "/",
                .name: "web_session",
                .value: "active-session",
                .secure: "TRUE",
            ])
        )
        let anonymous = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".xiaohongshu.com",
                .path: "/",
                .name: "a1",
                .value: "anonymous-device",
                .secure: "TRUE",
            ])
        )

        XCTAssertTrue(
            WebCompatibilityService.hasAuthenticatedXiaohongshuSession(in: [authenticated])
        )
        XCTAssertFalse(
            WebCompatibilityService.hasAuthenticatedXiaohongshuSession(in: [anonymous])
        )
    }

    func testBypassesProtectionForWeixinSubdomains() {
        let url = URL(string: "https://mp.weixin.qq.com/s/example")!

        XCTAssertTrue(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testBypassesProtectionForSensitiveChallengeURLs() {
        let url = URL(string: "https://example.com/mp/wappoc_appmsgcaptcha?poc_token=abc")!

        XCTAssertTrue(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testDoesNotBypassProtectionForNormalPages() {
        let url = URL(string: "https://example.com/articles/webview")!

        XCTAssertFalse(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testNativeViewportInsetRecognizesDouyinVideoSurfaces() {
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://www.douyin.com/video/7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas&actv_aid=7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://www.douyin.com/search/vitas?modal_id=7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas&aweme_id=7670376559123115750")
            )
        )
    }

    func testNativeViewportInsetRejectsOrdinaryAndNonDouyinPages() {
        XCTAssertFalse(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://example.com/video/7670376559123115750")
            )
        )
        XCTAssertFalse(WebCompatibilityService.isDouyinVideoSurface(nil))
    }
}
