import XCTest

final class WebPageProtectionUITests: XCTestCase {
    @MainActor
    private func runPage(_ html: String, check: (XCUIApplication) throws -> Void) async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html":Data(html.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language","en-US","-privacy_https_upgrade_enabled","NO",
            "-ad_block_enabled","YES","-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO"]
        app.launch()
        var route = URLComponents()
        route.scheme="soulo";route.host="open"
        route.queryItems=[URLQueryItem(name:"url",value:root.appendingPathComponent("page.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Protection fixture"].firstMatch.waitForExistence(timeout:20),app.debugDescription)
        try check(app)
    }

    @MainActor
    func testGenericTapCannotCopySpamButExplicitCopyButtonsWork() async throws {
        try await runPage(#"""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font:20px system-ui"><h3>Protection fixture</h3>
        <button id="ordinary">Ordinary action</button><p id="spam">Waiting</p>
        <button id="copy-async">Copy text</button><p id="modern">Modern waiting</p>
        <button id="copy-legacy">Copy legacy</button><p id="legacy">Legacy waiting</p>
        <textarea id="value">User chosen text</textarea>
        <script>
        document.body.addEventListener('click',function firstClick(){
          document.body.removeEventListener('click',firstClick);
          navigator.clipboard.writeText('advertising garbage').then(()=>spam.textContent='Spam copied',()=>spam.textContent='Spam blocked');
          const t=document.createElement('textarea');t.value='advertising garbage';t.style.display='none';document.body.append(t);t.select();
          if(document.execCommand('copy'))spam.textContent='Spam copied';t.remove();
        });
        document.getElementById('copy-async').onclick=()=>Promise.resolve().then(()=>navigator.clipboard.writeText('User chosen text'))
          .then(()=>modern.textContent='Modern copied',()=>modern.textContent='Modern failed');
        document.getElementById('copy-legacy').onclick=()=>{value.select();legacy.textContent=document.execCommand('copy')?'Legacy copied':'Legacy failed'};
        </script></body></html>
        """#) { app in
            app.webViews.buttons["Ordinary action"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["Spam blocked"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
            app.webViews.buttons["Copy text"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["Modern copied"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
            app.webViews.buttons["Copy legacy"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["Legacy copied"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        }
    }

    @MainActor
    func testOffsetTransparentAdCoverLeavesUnderlyingButtonUsable() async throws {
        try await runPage(#"""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="margin:8px;font:20px system-ui"><h3>Protection fixture</h3>
        <p id="status">Action waiting</p>
        <button id="underlying" style="position:fixed;bottom:85px;left:80px;width:200px;height:50px" onclick="document.getElementById('status').textContent='Action worked'">Underlying action</button>
        <script>
        for(let row=0;row<4;row++)for(let col=0;col<10;col++){
          const tile=document.createElement('qa-random-ad');
          tile.style.cssText='position:fixed;width:10%;height:30px;bottom:'+row*30+'px;left:'+col*10+'%;z-index:2147483647;background-image:linear-gradient(red,red);background-position:'+(-col*39)+'px '+(-row*30)+'px';
          document.body.append(tile);
        }
        const mask=document.createElement('div');
        mask.style.cssText='position:fixed;bottom:0;width:'+innerWidth+'px;height:120px;z-index:2147483647;background:transparent';
        mask.addEventListener('touchstart',()=>{document.getElementById('status').textContent='Ad jumped';location.href='/advertisement'});
        document.body.append(mask);
        </script></body></html>
        """#) { app in
            let button=app.webViews.buttons["Underlying action"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout:5),app.debugDescription)
            button.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            XCTAssertTrue(app.webViews.staticTexts["Action worked"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        }
    }
}
