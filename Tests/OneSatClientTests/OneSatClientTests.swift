import Foundation
import ToolboxServices
import XCTest
@testable import OneSatClient
import OneSatSweep

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

    /// A retired token (MNEE) is left out of balances, token outputs and the listed outpoints;
    /// the ordinal and the other tokens on the same address still read.
    func test_retiredTokenIsLeftOutOfEveryRead() async throws {
        let retired = RetiredTokens.ids.first!
        let extra = """
        event: txo
        data: {"outpoint":"\(String(repeating: "f", count: 64)).5","score":5,"satoshis":1,"events":["1sat","insc","type:application","type:application/bsv-20","bsv21:\(retired)"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"application/bsv-20"}},"bsv21":{"id":"\(retired)","op":"transfer","amt":"500","sym":"MNEE"}}}
        id: 5

        event: txo
        data: {"outpoint":"\(String(repeating: "f", count: 64)).6","score":6,"satoshis":1,"events":["1sat","insc"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"application/bsv-20"}},"bsv21":{"id":"\(retired)","op":"transfer","amt":"7","sym":"MNEE"}}}
        id: 6


        """
        let body = sse.replacingOccurrences(of: "event: done", with: extra + "event: done")
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(body.utf8)))

        let inventory = try await client.tokenInventory(forAddress: address)

        XCTAssertEqual(inventory.balances.map(\.tokenID), [tokenID, "SHUA"])
        XCTAssertFalse(inventory.outputs.contains { $0.tokenID == retired })
        let retiredRefs: Set<OutputRef> = [
            OutputRef(txid: String(repeating: "f", count: 64), vout: 5),
            OutputRef(txid: String(repeating: "f", count: 64), vout: 6),
        ]
        XCTAssertEqual(inventory.retired, retiredRefs)
        XCTAssertTrue(inventory.listed.isDisjoint(with: retiredRefs))
        XCTAssertEqual(inventory.listed.count, 4)
        let ordinals = try await client.ordinals(forAddress: address)
        XCTAssertEqual(ordinals.count, 1)
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

    func test_tokenOutputsKeepsEachUTXOAndItsProtocol() async throws {
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(sse.utf8)))

        let outputs = try await client.tokenOutputs(forAddress: address)

        XCTAssertEqual(
            outputs,
            [
                TokenOutput(
                    txid: String(repeating: "c", count: 64),
                    vout: 2,
                    tokenID: tokenID,
                    amount: 40,
                    symbol: "GOLD",
                    decimals: 0,
                    kind: .bsv21
                ),
                TokenOutput(
                    txid: String(repeating: "d", count: 64),
                    vout: 3,
                    tokenID: tokenID,
                    amount: 2,
                    symbol: nil,
                    decimals: 0,
                    kind: .bsv21
                ),
                TokenOutput(
                    txid: String(repeating: "e", count: 64),
                    vout: 4,
                    tokenID: "SHUA",
                    amount: 1000,
                    symbol: "SHUA",
                    decimals: 0,
                    kind: .bsv20
                ),
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
            URLQueryItem(name: "refresh", value: "true"),
        ])
    }

    /// A truncated listing could let a token pass as an ordinal, so it is refused.
    func test_aListingWithoutDoneOrAtTheRowLimitIsRefused() async throws {
        let noDone = sse.components(separatedBy: "event: done")[0]
        let errored = noDone + "event: error\ndata: boom\n\nevent: done\ndata: {}\n\n"
        for body in [noDone, errored] {
            let client = OneSatClient(http: StubHTTP(status: 200, body: Array(body.utf8)))
            do {
                _ = try await client.tokenInventory(forAddress: address)
                XCTFail("expected an incomplete listing to be refused")
            } catch let error as OneSatClientError {
                XCTAssertEqual(error, .unreadableResponse)
            }
        }
        let rows = (0..<10_000).map {
            "event: txo\ndata: {\"outpoint\":\"\(String(repeating: "a", count: 64)).\($0)\",\"satoshis\":1}\n\n"
        }.joined() + "event: done\ndata: {}\n\n"
        let capped = OneSatClient(http: StubHTTP(status: 200, body: Array(rows.utf8)))
        do {
            _ = try await capped.tokenInventory(forAddress: address)
            XCTFail("expected the row limit to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .outputLimitReached(limit: 10_000))
        }
    }

    /// The inventory lists every outpoint the read returned, token or not.
    func test_theInventoryListsEveryReturnedOutpoint() async throws {
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(sse.utf8)))
        let inventory = try await client.tokenInventory(forAddress: address)
        XCTAssertEqual(inventory.listed, [
            OutputRef(txid: String(repeating: "a", count: 64), vout: 1),
            OutputRef(txid: String(repeating: "c", count: 64), vout: 2),
            OutputRef(txid: String(repeating: "d", count: 64), vout: 3),
            OutputRef(txid: String(repeating: "e", count: 64), vout: 4),
        ])
    }

    /// G12: one unreadable BSV-21 amount is listed, not thrown; the other outputs still sum.
    func test_unreadableTokenAmountIsListedAndTheRestStillSum() async throws {
        let malformed = sse.replacingOccurrences(of: "\"amt\":\"40\"", with: "\"amt\":\"forty\"")
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(malformed.utf8)))

        let inventory = try await client.tokenInventory(forAddress: address)
        XCTAssertEqual(inventory.balances, [
            TokenBalance(tokenID: tokenID, amount: 2, symbol: nil, kind: .bsv21),
            TokenBalance(tokenID: "SHUA", amount: 1000, symbol: "SHUA", kind: .bsv20),
        ])
        XCTAssertEqual(inventory.unreadable, [OutputRef(txid: String(repeating: "c", count: 64), vout: 2)])
        let unreadable = try await client.unreadableTokenOutputs(forAddress: address)
        XCTAssertEqual(unreadable, inventory.unreadable)
        let balances = try await client.tokenBalances(forAddress: address)
        XCTAssertEqual(balances, inventory.balances)
        let outputs = try await client.tokenOutputs(forAddress: address)
        XCTAssertFalse(outputs.contains { $0.vout == 2 }, "an output with no amount cannot be swept")
        XCTAssertEqual(inventory.outputs, outputs)
    }

    /// `scan.ts` `parseBsv21Amount`: the `amt:` event is the last fallback, and 0 is no amount.
    func test_amountFallsBackToTheAmtEventAndRejectsZero() async throws {
        let id = String(repeating: "f", count: 64) + "_0"
        func row(_ vout: Int, _ events: String) -> String {
            """
            event: txo
            data: {"outpoint":"\(String(repeating: "f", count: 64)).\(vout)","satoshis":1,"events":[\(events)],"data":{}}

            """ + "\n"
        }
        let body = row(0, "\"bsv21:\(id)\",\"amt:75\"") + row(1, "\"bsv21:\(id)\",\"amt:0\"") + "event: done\ndata: {}\n\n"
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(body.utf8)))
        let inventory = try await client.tokenInventory(forAddress: address)
        XCTAssertEqual(inventory.balances, [TokenBalance(tokenID: id, amount: 75, symbol: nil, kind: .bsv21)])
        XCTAssertEqual(inventory.unreadable.map(\.vout), [1])
    }

    /// A balance that overflows is still refused.
    func test_overflowingBalanceIsStillRefused() async throws {
        let huge = sse.replacingOccurrences(of: "\"amt\":\"40\"", with: "\"amt\":\"\(UInt64.max)\"")
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(huge.utf8)))
        do {
            _ = try await client.tokenBalances(forAddress: address)
            XCTFail("expected the overflow to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        }
    }

    /// G14: the remaining `scan.ts` token signals keep an output off the ordinal path, and
    /// BSV-21 wins over a tick.
    func test_inscriptionTokenSignalsAreTokens() async throws {
        let deploy = String(repeating: "9", count: 64) + "_0"
        func row(_ vout: Int, events: String = "\"1sat\",\"insc\"", json: String) -> String {
            """
            event: txo
            data: {"outpoint":"\(String(repeating: "7", count: 64)).\(vout)","satoshis":1,"events":[\(events)],"data":{"insc":{"file":{"type":"text/plain"},"json":\(json)}}}

            """ + "\n"
        }
        let body = row(0, json: "{\"id\":\"\(deploy)\",\"amt\":\"5\",\"tick\":\"NOPE\"}")
            + row(1, json: "{\"op\":\"deploy+mint\",\"amt\":\"9\"}")
            + row(2, json: "{\"op\":\"AUTH\",\"amt\":\"3\"}")
            + row(3, json: "{\"tick\":\"PEPE\",\"amt\":\"8\"}")
            + row(4, events: "\"1sat\",\"insc\",\"tick:WOOF\",\"amt:6\"", json: "{}")
            + row(5, json: "{\"note\":\"hello\"}")
            + row(6, json: "{\"id\":\"not-an-outpoint\"}")
            + "event: done\ndata: {}\n\n"
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(body.utf8)))

        let outputs = try await client.tokenOutputs(forAddress: address)
        XCTAssertEqual(outputs.map(\.vout), [0, 1, 2, 3, 4])
        XCTAssertEqual(outputs.map(\.kind), [.bsv21, .bsv21, .bsv21, .bsv20, .bsv20])
        XCTAssertEqual(outputs.map(\.tokenID)[0], deploy, "bsv21 wins over tick")
        XCTAssertEqual(outputs.map(\.tokenID)[3...], ["PEPE", "WOOF"])
        let ordinals = try await client.ordinals(forAddress: address)
        XCTAssertEqual(ordinals.map(\.vout), [5, 6], "only the non-token inscriptions are ordinals")
        // A plain JSON inscription with a non-outpoint id and no amount is no token (`isBsv21Output`).
        let inventory = try await client.tokenInventory(forAddress: address)
        XCTAssertFalse(inventory.unreadable.contains { $0.vout == 6 })
        XCTAssertFalse(inventory.balances.contains { $0.tokenID == "not-an-outpoint" })
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
