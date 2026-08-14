import Foundation
import ToolboxServices
import XCTest
@testable import OneSatClient

/// Proves the display client preserves the exact owner-stream metadata emitted by 1sat-stack.
final class OneSatClientTests: XCTestCase {
    private actor URLRecorder {
        private var url: URL?

        func record(_ url: URL) { self.url = url }
        func value() -> URL? { url }
    }

    private struct StubHTTP: HTTPGet {
        let status: Int
        let body: [UInt8]

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            (status, body)
        }
    }

    private struct RecordingHTTP: HTTPGet {
        let recorder: URLRecorder
        let body: [UInt8]

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            await recorder.record(url)
            return (200, body)
        }
    }

    private let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
    private let tokenID = String(repeating: "b", count: 64) + "_0"

    /// One ordinal and two token outputs exercise filtering, metadata, and balance aggregation.
    private var sse: String {
        """
        event: sync
        data: {"phase":"done"}

        event: txo
        data: {"outpoint":"\(String(repeating: "a", count: 64)).1","score":1,"satoshis":1,"events":["1sat","insc","type:image","type:image/png"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"image/png"}}}}
        id: 1

        event: txo
        data: {"outpoint":"\(String(repeating: "c", count: 64)).2","score":2,"satoshis":1,"events":["1sat","insc","type:application","type:application/bsv-20","bsv21:\(tokenID)"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"application/bsv-20"}},"bsv21":{"id":"\(tokenID)","op":"transfer","amt":"40","sym":"GOLD"}}}
        id: 2

        event: txo
        data: {"outpoint":"\(String(repeating: "d", count: 64)).3","score":3,"satoshis":1,"events":["1sat","insc","type:application","type:application/bsv-20","bsv21:\(tokenID)"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"application/bsv-20"}},"bsv21":{"id":"\(tokenID)","op":"transfer","amt":"2"}}}
        id: 3

        event: txo
        data: {"outpoint":"\(String(repeating: "e", count: 64)).4","score":4,"satoshis":1,"events":["1sat","insc","type:application","type:application/bsv-20"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"application/bsv-20"},"json":{"p":"bsv-20","op":"transfer","tick":"SHUA","amt":"1000"}},"bsv20":{"tick":"SHUA","op":"transfer","amt":"1000"}}}
        id: 4

        event: done
        data: {}

        """
    }

    func test_ordinalsReturnsOnlyTheNonTokenInscription() async throws {
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(sse.utf8)))

        let ordinals = try await client.ordinals(forAddress: address)

        XCTAssertEqual(
            ordinals,
            [
                OrdinalOutput(
                    txid: String(repeating: "a", count: 64),
                    vout: 1,
                    satoshis: 1,
                    contentType: "image/png"
                )
            ]
        )
    }

    func test_tokenBalancesGroupsOutputsAndSumsProtocolAmounts() async throws {
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(sse.utf8)))

        let balances = try await client.tokenBalances(forAddress: address)

        XCTAssertEqual(
            balances,
            [
                TokenBalance(tokenID: tokenID, amount: 42, symbol: "GOLD", kind: .bsv21),
                TokenBalance(tokenID: "SHUA", amount: 1000, symbol: "SHUA", kind: .bsv20),
            ]
        )
    }

    func test_requestsTheOwnerStreamWithInscriptionAndTokenData() async throws {
        let recorder = URLRecorder()
        let client = OneSatClient(http: RecordingHTTP(recorder: recorder, body: Array(sse.utf8)))

        _ = try await client.ordinals(forAddress: address)

        let recordedURL = await recorder.value()
        let url = try XCTUnwrap(recordedURL)
        XCTAssertEqual(url.path, "/1sat/owner/\(address)/txos")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items, [
            URLQueryItem(name: "limit", value: "10000"),
            URLQueryItem(name: "tags", value: "insc,bsv20,bsv21"),
        ])
    }

    func test_unreadableTokenAmountIsRefused() async throws {
        let malformed = sse.replacingOccurrences(of: "\"amt\":\"40\"", with: "\"amt\":\"forty\"")
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(malformed.utf8)))

        do {
            _ = try await client.tokenBalances(forAddress: address)
            XCTFail("expected the malformed amount to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        }
    }

    func test_nonSuccessStatusIsTyped() async throws {
        let client = OneSatClient(http: StubHTTP(status: 503, body: []))

        do {
            _ = try await client.ordinals(forAddress: address)
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 503))
        }
    }

    /// A real call catches owner-route or tag-shape drift when live-chain testing is requested.
    func test_liveReadsAgainstARealAddress() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TEST_RUNNER_LIVE_CHAIN"] != nil,
            "set TEST_RUNNER_LIVE_CHAIN to hit the real 1Sat indexer"
        )
        let client = OneSatClient()

        _ = try await client.ordinals(forAddress: address)
        _ = try await client.tokenBalances(forAddress: address)
    }
}
