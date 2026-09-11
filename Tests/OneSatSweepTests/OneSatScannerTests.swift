import XCTest
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatTemplates
import ToolboxServices
@testable import OneSatSweep

/// Reading categorised outputs from the 1Sat indexer's SSE stream.
///
/// The unit tests parse a canned SSE body in the exact frame format the endpoint emits
/// (`event: txo` / `event: done`), so parsing and source-script resolution are checked
/// offline. The live test confirms the shape still holds against `api.1sat.app`.
final class OneSatScannerTests: XCTestCase {

    private struct StubHTTP: HTTPGet {
        let status: Int
        let body: [UInt8]
        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) { (status, body) }
    }

    private let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    /// A stream with a plain coin, a token, a lock, and the done marker.
    private let sse = """
        event: sync
        data: {"phase":"done"}

        event: txo
        data: {"outpoint":"8ac7230489e80000000000000000000000000000000000000000000000000001.0","satoshis":100000,"events":[]}
        id: 1

        event: txo
        data: {"outpoint":"8ac7230489e80000000000000000000000000000000000000000000000000001.1","satoshis":1,"events":["bsv21:gold"]}
        id: 2

        event: txo
        data: {"outpoint":"8ac7230489e80000000000000000000000000000000000000000000000000001.2","satoshis":5000,"events":["lock:830000"]}
        id: 3

        event: done
        data: {}

        """

    func test_theStreamParsesIntoCategorisedOutputs() throws {
        let outputs = try OneSatScanner.parse(sse: Array(sse.utf8))

        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(outputs[0].satoshis, 100_000)
        XCTAssertEqual(outputs[0].kind, .fundable)
        XCTAssertEqual(outputs[0].lockingScript, [], "source bytes are resolved during scan")
        XCTAssertEqual(outputs[1].kind, .bsv21(tokenID: "gold"))
        XCTAssertEqual(outputs[2].kind, .locked(until: 830_000))
    }

    /// The whole point: through the plan, only the coin is swept.
    func test_theScanFeedsASafePlan() throws {
        let outputs = try OneSatScanner.parse(sse: Array(sse.utf8))

        let plan = SweepPlan.from(scan: outputs)

        XCTAssertEqual(plan.fundable.count, 1)
        XCTAssertEqual(plan.fundable[0].satoshis, 100_000)
        XCTAssertEqual(plan.remaining.bsv21.count, 1)
        XCTAssertEqual(plan.remaining.locked.count, 1)
        XCTAssertEqual(plan.remaining.nextUnlockHeight, 830_000)
    }

    func test_aSpentOutputIsSkipped() throws {
        let withSpend = """
            event: txo
            data: {"outpoint":"8ac7230489e80000000000000000000000000000000000000000000000000001.0","satoshis":1,"events":[],"spend":"deadbeef"}

            event: done
            data: {}

            """
        let outputs = try OneSatScanner.parse(
            sse: Array(withSpend.utf8)
        )

        XCTAssertTrue(outputs.isEmpty, "an already-spent output is not swept")
    }

    func test_syncAndDoneFramesCarryNoOutputs() throws {
        let onlyControl = """
            event: sync
            data: {"phase":"syncing"}

            event: done
            data: {}

            """
        let outputs = try OneSatScanner.parse(
            sse: Array(onlyControl.utf8)
        )

        XCTAssertTrue(outputs.isEmpty)
    }

    func test_outpointSplitting() {
        XCTAssertEqual(
            OneSatScanner.splitOutpoint(String(repeating: "a", count: 64) + ".3")?.vout, 3
        )
        XCTAssertNil(OneSatScanner.splitOutpoint(String(repeating: "b", count: 64) + "_7"))
        XCTAssertNil(OneSatScanner.splitOutpoint("not-an-outpoint"))
    }

    func test_scanResolvesAnOrdLockSourceAndCachesTheTransaction() async throws {
        let script = try OrdLock.lock(
            cancelAddress: address, payAddress: address, price: 1_000
        )
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: script),
            TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10)),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: Sweep.defaultLimits).displayHex
        let rows = """
            event: txo
            data: {"outpoint":"\(txid).0","satoshis":1,"events":["ordlock"]}

            event: txo
            data: {"outpoint":"\(txid).1","satoshis":1,"events":["ord"]}

            event: done
            data: {}

            """
        let http = SourceHTTP(stream: Array(rows.utf8), raw: try source.serialized(limits: Sweep.defaultLimits))
        let outputs = try await OneSatScanner(http: http).scan(address: address)
        XCTAssertEqual(outputs.map(\.lockingScript), source.outputs.map { $0.lockingScript.bytes })
        XCTAssertEqual(outputs[0].kind, .ordinal)
        let paths = await http.paths
        XCTAssertEqual(paths.count, 2, "fetch each source transaction once")
        XCTAssertEqual(paths[1], "/1sat/beef/\(txid)/tx")
    }

    func test_plainFundingRowWithoutEventsResolvesAndRemainsFundable() async throws {
        let script = try Script.payToPublicKeyHash(
            Address(address).publicKeyHash, maximumByteCount: 10_000
        )
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 100_000, lockingScript: script),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: Sweep.defaultLimits).displayHex
        // The owner API's events,omitempty omits the field when this output has no events.
        let rows = """
            event: txo
            data: {"outpoint":"\(txid).0","score":1,"satoshis":100000}

            event: done
            data: {}

            """
        let http = SourceHTTP(stream: Array(rows.utf8), raw: try source.serialized(limits: Sweep.defaultLimits))
        let outputs = try await OneSatScanner(http: http).scan(address: address)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].events, [])
        XCTAssertEqual(outputs[0].kind, .fundable)
        XCTAssertEqual(outputs[0].lockingScript, script.bytes)
        XCTAssertEqual(SweepPlan.from(scan: outputs).fundable.first?.satoshis, 100_000)

        for malformed in ["null", "true", "{}", "[1]", "[\"ordlock\",1]"] {
            let invalid = rows.replacingOccurrences(
                of: "\"satoshis\":100000", with: "\"satoshis\":100000,\"events\":\(malformed)"
            )
            XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(invalid.utf8)))
        }
        XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(
            rows.replacingOccurrences(of: ",\"satoshis\":100000", with: "").utf8
        )))
    }

    func test_incompleteStreamsAndScanLimitFailExplicitly() throws {
        XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(sse.utf8), limit: 3)) { error in
            XCTAssertEqual(error as? AssetScannerError, .scanLimitReached(limit: 3))
        }
        let incomplete = sse.components(separatedBy: "event: done")[0]
        XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(incomplete.utf8)))
        let failed = incomplete + "event: error\ndata: failed\n\nevent: done\ndata: {}\n\n"
        XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(failed.utf8)))
    }

    private actor SourceHTTP: HTTPGet {
        let stream: [UInt8]
        let raw: [UInt8]
        private(set) var paths: [String] = []

        init(stream: [UInt8], raw: [UInt8]) { self.stream = stream; self.raw = raw }

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            paths.append(url.path)
            return (200, url.path.hasSuffix("/txos") ? stream : raw)
        }
    }

    /// Against the real indexer. Skipped unless asked for.
    func test_liveScanAgainstARealAddress() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TEST_RUNNER_LIVE_CHAIN"] != nil,
            "set TEST_RUNNER_LIVE_CHAIN to hit the real 1Sat indexer"
        )
        let scanner = OneSatScanner()

        // A well-known ordinals address is not needed; any address returns a valid (possibly empty)
        // scan. This confirms the endpoint, SSE parse, and categorisation hold end to end.
        let outputs = try await scanner.scan(address: address)

        XCTAssertTrue(outputs.allSatisfy { !$0.txid.isEmpty })
        let plan = SweepPlan.from(scan: outputs)
        XCTAssertNotNil(plan)
    }
}
