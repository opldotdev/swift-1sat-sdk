import Foundation
import XCTest
@testable import OneSatClient

/// `BeefClient.getBeef` and `OverlayClient`'s BSV-21 submits from `@1sat/client`, offline.
final class BeefAndOverlayClientTests: XCTestCase {
    private actor ScriptedHTTP: OneSatHTTPTransport {
        struct Call: Equatable {
            let method: String
            let url: URL
            let headers: [String: String]
            let body: [UInt8]?
        }
        private var responses: [(Int, [UInt8])]
        private var calls: [Call] = []

        init(_ responses: [(Int, [UInt8])]) { self.responses = responses }

        func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: [UInt8]?
        ) async throws -> (status: Int, body: [UInt8]) {
            calls.append(.init(method: method, url: url, headers: headers, body: body))
            return responses.removeFirst()
        }

        func recorded() -> [Call] { calls }
    }

    private let base = URL(string: "https://api.example")!
    private let txid = String(repeating: "ab", count: 32)

    func test_beefIsAGetOfTheTxidUnderOneSatBeef() async throws {
        let http = ScriptedHTTP([(200, [0x01, 0x01, 0x01, 0x01])])
        let beef = try await BeefClient(baseURL: base, transport: http).beef(forTxid: txid)

        XCTAssertEqual(beef, [0x01, 0x01, 0x01, 0x01])
        let calls = await http.recorded()
        XCTAssertEqual(calls.map(\.method), ["GET"])
        XCTAssertEqual(calls.first?.url.absoluteString, "https://api.example/1sat/beef/\(txid)")
        XCTAssertEqual(BeefClient.url(forTxid: txid, baseURL: base), calls.first?.url)
    }

    func test_beefThrowsTheStatusOfAFailure() async {
        let http = ScriptedHTTP([(404, Array(#"{"message":"not found"}"#.utf8))])
        do {
            _ = try await BeefClient(baseURL: base, transport: http).beef(forTxid: txid)
            XCTFail("expected the HTTP failure")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .httpFailure(statusCode: 404))
        }
    }

    func test_submitBsv21PostsTheTransactionToTheTokenTopic() async throws {
        let tokenID = String(repeating: "c", count: 64) + "_0"
        let http = ScriptedHTTP([(200, Array(#"{"tm_x":{}}"#.utf8))])
        try await OverlayClient(baseURL: base, transport: http).submitBsv21(tx: [1, 2, 3], tokenID: tokenID)

        let calls = await http.recorded()
        XCTAssertEqual(
            calls,
            [.init(
                method: "POST",
                url: URL(string: "https://api.example/1sat/bsv21/overlay/submit")!,
                headers: ["Content-Type": "application/octet-stream", "X-Topics": "tm_\(tokenID)"],
                body: [1, 2, 3]
            )]
        )
    }

    func test_submitBsv21DiscoveryPostsToTheDiscoveryTopic() async throws {
        let http = ScriptedHTTP([(200, [])])
        try await OverlayClient(baseURL: base, transport: http).submitBsv21Discovery(tx: [4])

        let calls = await http.recorded()
        XCTAssertEqual(calls.first?.url, OverlayClient.bsv21SubmitURL(baseURL: base))
        XCTAssertEqual(calls.first?.headers["X-Topics"], "tm_bsv21")
        XCTAssertEqual(calls.first?.body, [4])
    }

    /// A 2xx is a submit the overlay took, whatever its body; anything else throws its status.
    func test_submitThrowsTheStatusOfARefusal() async {
        let http = ScriptedHTTP([(503, [])])
        do {
            try await OverlayClient(baseURL: base, transport: http).submitBsv21Discovery(tx: [4])
            XCTFail("expected the HTTP failure")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .httpFailure(statusCode: 503))
        }
    }

    func test_submitListingPostsTheBEEFToTheMarketTopic() async throws {
        let http = ScriptedHTTP([(200, Array(#"{"tm_ordlock_v2":{"outputsToAdmit":[0]}}"#.utf8))])
        try await OverlayClient(baseURL: base, transport: http).submitListing(tx: [9, 8, 7])

        let calls = await http.recorded()
        XCTAssertEqual(
            calls,
            [.init(
                method: "POST",
                url: URL(string: "https://api.example/1sat/market/overlay/submit")!,
                headers: ["Content-Type": "application/octet-stream", "X-Topics": "tm_ordlock_v2"],
                body: [9, 8, 7]
            )]
        )
        XCTAssertEqual(OverlayClient.marketSubmitURL(baseURL: base), calls.first?.url)
    }

    func test_submitListingThrowsTheMarketOverlaysRefusal() async {
        let http = ScriptedHTTP([(400, Array(#"{"message":"invalid BEEF"}"#.utf8))])
        do {
            try await OverlayClient(baseURL: base, transport: http).submitListing(tx: [1])
            XCTFail("expected the HTTP failure")
        } catch let OneSatClientError.httpFailure(status, detail) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(detail?.service, "the market overlay")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
