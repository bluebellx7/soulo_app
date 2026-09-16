import XCTest
@testable import Soulo

final class FeedbackServiceTests: XCTestCase {
    func testRequestKeepsContactAndDiagnosticPayloadSeparateFromUserText() throws {
        let diagnostics = FeedbackDiagnostics(fields: [.init(id: "device", titleKey: "unused", value: "iPhone18,1")])
        let request = try SouloFeedbackService.makeRequest(type: "bug", content: "\nExample issue\n", contactInfo: " person@example.com \n", diagnostics: diagnostics)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.dkluge.com/api/feedback")
        let payload = try JSONDecoder().decode(SouloFeedbackService.Payload.self, from: XCTUnwrap(request.httpBody))
        XCTAssertEqual(payload.content, "Example issue")
        XCTAssertEqual(payload.contact_info, "person@example.com")
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: Data(payload.device_info.utf8)), diagnostics.values)
        XCTAssertTrue(payload.page_url.contains("(\(SouloFeedbackService.buildNumber))"))
    }

    func testDiagnosticOptOutAndEmptyContactAreRespected() throws {
        let request = try SouloFeedbackService.makeRequest(type: "other", content: "Hello", contactInfo: " \n", diagnostics: nil)
        let payload = try JSONDecoder().decode(SouloFeedbackService.Payload.self, from: XCTUnwrap(request.httpBody))
        XCTAssertNil(payload.contact_info)
        XCTAssertEqual(payload.device_info, "{}")
        for value in [" \n", String(repeating: "a", count: 2001)] {
            XCTAssertThrowsError(try SouloFeedbackService.makeRequest(type: "bug", content: value, contactInfo: nil, diagnostics: nil))
        }
    }

    @MainActor func testCapturedDiagnosticsContainNoPersonalOrBrowsingFields() {
        let values = FeedbackDiagnostics.capture().values
        XCTAssertNotNil(values["device"])
        XCTAssertNotNil(values["app"])
        XCTAssertNotNil(values["userScripts"])
        XCTAssertTrue(Set(values.keys).isDisjoint(with: ["name", "email", "phone", "deviceName", "identifierForVendor", "advertisingIdentifier", "clipboard", "history", "pageURL", "ip", "location"]))
    }

    func testSuccessfulAndFailedResponsesWithoutSendingRealFeedback() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await SouloFeedbackService.submit(type: "bug", content: "accepted fixture", contactInfo: nil, diagnostics: nil, session: session)
        do {
            try await SouloFeedbackService.submit(type: "bug", content: "rejected fixture", contactInfo: nil, diagnostics: nil, session: session)
            XCTFail("Failed submissions must not show success")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }
}

private final class FeedbackStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let isRejected = String(decoding: body ?? Data(), as: UTF8.self).contains("rejected fixture")
        let response = HTTPURLResponse(url: request.url!, statusCode: isRejected ? 500 : 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
