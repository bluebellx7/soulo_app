import XCTest
@testable import Soulo

final class PeerDownloadLinkTests: XCTestCase {
    private let fileHash = "6CC0B357A958A18260D45D47B9D4C8DF"

    func testED2KAndThunderKeepLargeFileSizeAndFilenameThroughPersistence() throws {
        let raw = "ed2k://|file|中文%20name+100%25.mp4|5263316776|\(fileHash)|/"
        guard case .ed2k(let file) = try PeerDownloadLink.parse(raw) else { return XCTFail() }
        XCTAssertEqual(file.size, 5_263_316_776)
        XCTAssertEqual(file.name, "中文 name+100%.mp4")
        XCTAssertEqual(try PeerDownloadLink.parse(file.url.absoluteString), .ed2k(file))
        let wrapped = "thunder://" + Data(("AA" + raw + "ZZ").utf8).base64EncodedString()
        XCTAssertEqual(try PeerDownloadLink.parse(wrapped), .ed2k(file))
    }

    func testThunderAlsoUnwrapsWebAndMagnetLinks() throws {
        for target in ["https://example.com/file.zip", "magnet:?xt=urn:btih:0123456789012345678901234567890123456789"] {
            let wrapped = "thunder://" + Data(("AA" + target + "ZZ").utf8).base64EncodedString()
            XCTAssertEqual(try PeerDownloadLink.parse(wrapped), try PeerDownloadLink.parse(target))
        }
    }

    func testRejectsMalformedAndNestedLinks() {
        for value in ["ed2k://|file|x|0|\(fileHash)|/", "ed2k://|file|x|-1|\(fileHash)|/",
            "ed2k://|file|x|5|bad-hash|/", "thunder://@@@",
            "thunder://" + Data("AAthunder://nestedZZ".utf8).base64EncodedString(), "file:///etc/passwd"] {
            XCTAssertThrowsError(try PeerDownloadLink.parse(value), value)
        }
    }

    func testTorrentRecognitionDoesNotConfuseWebErrorsOrMediaWithMetadata() {
        XCTAssertTrue(TorrentMetadataFetcher.looksLikeTorrent(Data("d8:announce20:https://example.test4:infod".utf8)))
        XCTAssertTrue(TorrentMetadataFetcher.looksLikeTorrent(Data("d4:infod4:name4:test".utf8)))
        for value in ["<!doctype html>", "{\"error\":1}", "ftypisom", "d999999999:announce"] {
            XCTAssertFalse(TorrentMetadataFetcher.looksLikeTorrent(Data(value.utf8)))
        }
    }
}
