import Foundation
import XCTest
@testable import OneSatSweep

/// The two layers of a failed 1Sat request: a short user message and a full log line.
final class OneSatHTTPFailureTests: XCTestCase {
    private let url = URL(string: "https://proxy-api.mnee.net/v1/tx/abc?auth_token=secret-key")!

    private func failure(_ status: Int, _ body: String, service: String = "the MNEE service") -> OneSatHTTPFailure {
        OneSatHTTPFailure(
            service: service, operation: "MneeClient.fetchRawTx", method: "GET", url: url,
            statusCode: status, body: Array(body.utf8)
        )
    }

    func test_serverReasonReadsJSONMessageFirst() {
        XCTAssertEqual(
            OneSatHTTPFailure.serverReason(from: Array(#"{"error":"Bad Request","message":"fee too low"}"#.utf8)),
            "fee too low"
        )
    }

    func test_serverReasonReadsNestedErrorMessage() {
        XCTAssertEqual(
            OneSatHTTPFailure.serverReason(from: Array(#"{"error":{"code":"ERR_X","message":"no such token"}}"#.utf8)),
            "no such token"
        )
    }

    func test_serverReasonTakesShortPlainTextAndRefusesHTML() {
        XCTAssertEqual(OneSatHTTPFailure.serverReason(from: Array("  rate limited\nretry later".utf8)), "rate limited")
        XCTAssertNil(OneSatHTTPFailure.serverReason(from: Array("<html><body>502</body></html>".utf8)))
        XCTAssertNil(OneSatHTTPFailure.serverReason(from: []))
        XCTAssertNil(OneSatHTTPFailure.serverReason(from: Array(#"{"ok":false}"#.utf8)))
    }

    func test_serverReasonIsCutTo120Characters() {
        let long = String(repeating: "x", count: 200)
        let reason = OneSatHTTPFailure.serverReason(from: Array(#"{"message":"\#(long)"}"#.utf8))
        XCTAssertEqual(reason?.count, 120)
        XCTAssertEqual(reason?.hasSuffix("…"), true)
    }

    func test_userMessageNamesTheServiceStatusAndReason() {
        XCTAssertEqual(
            failure(400, #"{"message":"fee too low"}"#).userMessage,
            "The MNEE service refused the request (HTTP 400): fee too low."
        )
        XCTAssertEqual(failure(404, "").userMessage, "The MNEE service refused the request (HTTP 404).")
    }

    func test_userMessageSuggestsRetryForServerErrors() {
        XCTAssertEqual(
            failure(503, "<html>down</html>").userMessage,
            "The MNEE service could not answer (HTTP 503). Try again in a minute."
        )
    }

    func test_debugDescriptionCarriesCallHostPathStatusAndBodyButNoQuery() {
        let text = failure(401, #"{"message":"bad key"}"#).debugDescription
        XCTAssertTrue(text.contains("MneeClient.fetchRawTx"))
        XCTAssertTrue(text.contains("GET proxy-api.mnee.net/v1/tx/abc"))
        XCTAssertTrue(text.contains("HTTP 401"))
        XCTAssertTrue(text.contains(#"{"message":"bad key"}"#))
        XCTAssertFalse(text.contains("auth_token"))
        XCTAssertFalse(text.contains("secret-key"))
    }

    func test_logTextIsCappedAt2000Characters() {
        let body = Array(String(repeating: "a", count: 5_000).utf8)
        let text = OneSatHTTPFailure.logText(body)
        XCTAssertTrue(text.hasPrefix(String(repeating: "a", count: 2_000)))
        XCTAssertTrue(text.hasSuffix("… (5000 bytes)"))
    }

    func test_assetScannerErrorShowsDetailAndComparesByStatus() {
        let detail = failure(500, #"{"message":"indexer restarting"}"#, service: "the 1Sat indexer")
        let error = AssetScannerError.httpFailure(statusCode: 500, detail: detail)
        XCTAssertEqual(
            error.errorDescription,
            "Asset discovery failed. The 1Sat indexer could not answer (HTTP 500): indexer restarting. Try again in a minute."
        )
        XCTAssertEqual(AssetScannerError.httpFailure(statusCode: 500).errorDescription, "Asset discovery failed (HTTP 500).")
        XCTAssertEqual(error, .httpFailure(statusCode: 500))
        XCTAssertNotEqual(error, .httpFailure(statusCode: 502))
        XCTAssertTrue(String(reflecting: error).contains("proxy-api.mnee.net/v1/tx/abc"))
    }
}
