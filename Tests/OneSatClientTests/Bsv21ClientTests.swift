import Foundation
import XCTest
@testable import OneSatClient

final class Bsv21ClientTests: XCTestCase {
    private actor ScriptedHTTP: OneSatHTTPTransport {
        struct Call: Equatable {
            let method: String
            let url: URL
            let headers: [String: String]
            let body: [UInt8]?
        }
        let responses: [(Int, [UInt8])]
        private var calls: [Call] = []

        init(_ responses: [(Int, [UInt8])]) { self.responses = responses }

        func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: [UInt8]?
        ) async throws -> (status: Int, body: [UInt8]) {
            calls.append(.init(method: method, url: url, headers: headers, body: body))
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

    func test_outputStatusPostsSequentialBatchesOfOneThousandInRequestOrder() async throws {
        let outpoints = (0..<2001).map { index -> String in
            let hex = String(index, radix: 16)
            return String(repeating: "0", count: 64 - hex.count) + hex + ".0"
        }
        let states = ["valid", "spent", "queued", "unknown"]
        func answer(_ slice: ArraySlice<String>) -> (Int, [UInt8]) {
            let rows = slice.enumerated().map { offset, outpoint in
                #"{"outpoint":"\#(outpoint)","state":"\#(states[(slice.startIndex + offset) % 4])"}"#
            }
            return (200, Array("[\(rows.joined(separator: ","))]".utf8))
        }
        let http = ScriptedHTTP([
            answer(outpoints[0..<1000]),
            answer(outpoints[1000..<2000]),
            answer(outpoints[2000..<2001]),
        ])
        let client = Bsv21Client(baseURL: URL(string: "https://example.test")!, transport: http)

        let result = try await client.outputStatus(tokenID: tokenID, outpoints: outpoints)

        XCTAssertEqual(result.map(\.outpoint), outpoints)
        XCTAssertEqual(result[0].state, .valid)
        XCTAssertEqual(result[1].state, .spent)
        XCTAssertEqual(result[2].state, .queued)
        XCTAssertEqual(result[2000].state, .valid)
        XCTAssertEqual(result[1999].state, .unknown)
        let calls = await http.recorded()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "POST"])
        XCTAssertEqual(
            Set(calls.map(\.url.path)),
            ["/1sat/bsv21/\(tokenID)/outputs/status"]
        )
        XCTAssertEqual(calls[0].headers["Content-Type"], "application/json")
        let bodies = try calls.map {
            try JSONDecoder().decode([String].self, from: Data($0.body ?? []))
        }
        XCTAssertEqual(bodies.map(\.count), [1000, 1000, 1])
        XCTAssertEqual(bodies.flatMap { $0 }, outpoints)
    }

    func test_outputStatusSendsNothingForNoOutpoints() async throws {
        let http = ScriptedHTTP([])
        let client = Bsv21Client(baseURL: URL(string: "https://example.test")!, transport: http)

        let result = try await client.outputStatus(tokenID: tokenID, outpoints: [])

        XCTAssertEqual(result, [])
        let calls = await http.recorded()
        XCTAssertEqual(calls, [])
    }

    func test_fundingTemplateAndSubmitFundingUseTheFundRoute() async throws {
        let template = #"{"outputs":[{"lockingScript":"76a914cc5f973def854a5a6015dc619462497473c0b02e88ac","satoshis":10010000,"outputDescription":"Fund TEST overlay"}]}"#
        let status = #"{"is_active":true,"fee_address":"1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2","fee_per_output":1000,"min_funding":10000000,"output_count":3}"#
        let http = ScriptedHTTP([
            (200, Array(template.utf8)),
            (200, Array(status.utf8)),
            (502, []),
        ])
        let client = Bsv21Client(baseURL: URL(string: "https://example.test")!, transport: http)

        let funding = try await client.fundingTemplate(tokenID: tokenID)
        let submitted = try await client.submitFunding(tokenID: tokenID, beef: [1, 2, 3])
        do {
            _ = try await client.submitFunding(tokenID: tokenID, beef: [4])
            XCTFail("expected an HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 502))
        }

        XCTAssertEqual(funding, .init(outputs: [.init(
            lockingScript: "76a914cc5f973def854a5a6015dc619462497473c0b02e88ac",
            satoshis: 10_010_000,
            outputDescription: "Fund TEST overlay"
        )]))
        XCTAssertEqual(submitted, .init(
            isActive: true,
            feeAddress: "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2",
            feePerOutput: 1000,
            minFunding: 10_000_000
        ))
        let calls = await http.recorded()
        XCTAssertEqual(calls.map(\.method), ["GET", "POST", "POST"])
        XCTAssertEqual(calls[0].url.path, "/1sat/bsv21/\(tokenID)/fund")
        XCTAssertEqual(calls[1].url.path, "/1sat/bsv21/\(tokenID)/fund")
        XCTAssertEqual(calls[1].headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(calls[1].body, [1, 2, 3])
    }

    func test_emptyFundingTemplateDecodes() async throws {
        let http = ScriptedHTTP([(200, Array(#"{"outputs":[]}"#.utf8))])
        let client = Bsv21Client(baseURL: URL(string: "https://example.test")!, transport: http)

        let funding = try await client.fundingTemplate(tokenID: tokenID)

        XCTAssertEqual(funding.outputs, [])
    }
}
