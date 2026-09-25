import XCTest
@testable import Soulo

final class SouloURLRouteTests: XCTestCase {
    func testCommandsAliasesAndCase() throws {
        let examples: [(String, SouloURLRoute)] = [
            ("soulo://", .home), ("SOULO://HOME", .home),
            ("soulo://Search", .search(nil)), ("soulo://search/", .search(nil)),
            ("soulo://QRCode", .scan), ("soulo://scan", .scan),
            ("soulo://Files", .files), ("soulo://Books", .files), ("soulo://bookshelf", .files),
            ("soulo://Bookmarks", .bookmarks), ("soulo://history", .history), ("soulo://downloads", .downloads)
        ]
        for (source, expected) in examples { XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: source))), expected, source) }
    }

    func testQueryValuesDecodeOnceAndKeepReservedCharacters() throws {
        let target = "https://example.com/a%2Fb?q=%E4%B8%AD%E6%96%87&plus=a+b#part"
        var open = URLComponents(string: "soulo://open")!
        open.queryItems = [URLQueryItem(name: "url", value: target)]
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(open.url)), .open(try XCTUnwrap(URL(string: target))))
        open.host = "download"
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(open.url)), .download(try XCTUnwrap(URL(string: target))))
        for key in ["q", "text", "query"] {
            var search = URLComponents(string: "soulo://search")!
            search.queryItems = [URLQueryItem(name: key, value: "中文 & + # 100%")]
            XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(search.url)), .search("中文 & + # 100%"))
        }
    }

    func testLegacyDirectAndDownloadPathsPreserveNestedURL() throws {
        let address = "https://example.com/book%20one.epub?url=other&x=1#part"
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: "soulo://" + address))), .open(try XCTUnwrap(URL(string: address))))
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: "soulo://download/" + address))), .download(try XCTUnwrap(URL(string: address))))
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: "soulo://%E4%B8%AD%E6%96%87%20%E6%90%9C%E7%B4%A2"))), .search("中文 搜索"))
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: "soulo://search/hello%20world"))), .search("hello world"))
        XCTAssertEqual(SouloURLRoute.parse(try XCTUnwrap(URL(string: "soulo://https%3A%2F%2Fexample.com%2F"))), .open(try XCTUnwrap(URL(string: "https://example.com/"))))
    }

    func testDirectWebURLDeliveryOpensExactAddress() throws {
        for address in [
            "https://example.com/book%20one?q=a%2Bb#part",
            "http://example.org/path?x=1"
        ] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(SouloURLRoute.parse(url), .open(url))
        }
    }

    func testInvalidAndReservedRoutesDoNotNavigateOrDownload() throws {
        for source in ["file:///etc/hosts", "javascript:alert(1)", "soulo://action", "soulo://open", "soulo://download", "soulo://download?url=file%3A%2F%2F%2Fetc%2Fhosts", "soulo://open?url=javascript%3Aalert(1)", "soulo://open?url=https%3A%2F%2F", "soulo://download?url=not-a-url", "soulo://file:///example"] {
            XCTAssertNil(SouloURLRoute.parse(try XCTUnwrap(URL(string: source))), source)
        }
    }
}
