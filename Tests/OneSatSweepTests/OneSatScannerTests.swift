import XCTest
import BSVKeys
import BSVScript
import ToolboxServices
@testable import OneSatSweep

/// Reading categorised outputs from the 1Sat indexer's SSE stream.
///
/// The unit tests parse a canned SSE body in the exact frame format the endpoint emits
/// (`event: txo` / `event: done`), so the parsing and the P2PKH-script reconstruction are checked
/// offline. The live test confirms the shape still holds against `api.1sat.app`.
final class OneSatScannerTests: XCTestCase {

    private struct StubHTTP: HTTPGet {
        let status: Int
        let body: [UInt8]
        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) { (status, body) }
    }

    private let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    private func p2pkh(_ address: String) throws -> [UInt8] {
        try Script.payToPublicKeyHash(Address(address).publicKeyHash, maximumByteCount: 1 << 20)
            .bytes
    }

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
        let outputs = try OneSatScanner.parse(sse: Array(sse.utf8), lockingScript: try p2pkh(address))

        XCTAssertEqual(outputs.count, 3)
        XCTAssertEqual(outputs[0].satoshis, 100_000)
        XCTAssertEqual(outputs[0].kind, .fundable)
        XCTAssertEqual(outputs[0].lockingScript, try p2pkh(address))
        XCTAssertEqual(outputs[1].kind, .bsv21(tokenID: "gold"))
        XCTAssertEqual(outputs[2].kind, .locked(until: 830_000))
    }

    /// The whole point: through the plan, only the coin is swept.
    func test_theScanFeedsASafePlan() throws {
        let outputs = try OneSatScanner.parse(sse: Array(sse.utf8), lockingScript: try p2pkh(address))

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
            sse: Array(withSpend.utf8), lockingScript: try p2pkh(address)
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
            sse: Array(onlyControl.utf8), lockingScript: try p2pkh(address)
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
