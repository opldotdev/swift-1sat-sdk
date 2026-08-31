import Foundation
import XCTest
@testable import OneSatClient

final class Bsv21ClientTests: XCTestCase {
    private actor ScriptedHTTP: OneSatHTTPTransport {
        struct Call: Equatable { let method: String; let url: URL; let body: [UInt8]? }
        let responses: [(Int, [UInt8])]
        private var calls: [Call] = []

        init(_ responses: [(Int, [UInt8])]) { self.responses = responses }

        func send(
            method: String,
            url: URL,
            headers _: [String: String],
            body: [UInt8]?
        ) async throws -> (status: Int, body: [UInt8]) {
            calls.append(.init(method: method, url: url, body: body))
            return responses[calls.count - 1]
        }

        func recorded() -> [Call] { calls }
    }

    private let tokenID = String(repeating: "a", count: 64) + "_1"

    func test_readsTokenDetailsAndValidatesUnspentOutputs() async throws {
        let details = #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)","op":"deploy+mint","amt":"21","sym":"GOLD","dec":2},"status":{"is_active":true}}"#
        let output = String(repeating: "b", count: 64) + ".2"
        let validated = #"[{"outpoint":"\#(output)"}]"#
        let http = ScriptedHTTP([
            (200, Array(details.utf8)),
            (200, Array(validated.utf8)),
        ])
        let client = Bsv21Client(baseURL: URL(string: "https://example.test")!, transport: http)

        let token = try await client.tokenDetails(tokenID: tokenID)
        let outputs = try await client.validateOutputs(
            tokenID: tokenID,
            outpoints: [output],
            unspent: true
        )

        XCTAssertEqual(token.token.symbol, "GOLD")
        XCTAssertEqual(token.token.decimals, "2")
        XCTAssertEqual(token.status.isActive, true)
        XCTAssertEqual(outputs, [.init(outpoint: output)])
        let calls = await http.recorded()
        XCTAssertEqual(calls.map(\.method), ["GET", "POST"])
        XCTAssertEqual(calls[0].url.path, "/1sat/bsv21/\(tokenID)")
        XCTAssertEqual(calls[1].url.path, "/1sat/bsv21/\(tokenID)/outputs")
        XCTAssertEqual(calls[1].url.query, "unspent=true")
        XCTAssertEqual(
            try JSONDecoder().decode([String].self, from: Data(calls[1].body ?? [])),
            [output]
        )
    }
}
