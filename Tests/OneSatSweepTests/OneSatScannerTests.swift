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
        let script = try OrdLockV2.lock(
            cancelAddress: address, payAddress: address, price: 1_000
        )
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: script),
            TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10)),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: Sweep.defaultLimits).displayHex
        let rows = """
            event: txo
            data: {"outpoint":"\(txid).0","satoshis":1,"events":["ordlock2"]}

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

    /// G7: the owner read asks the indexer to sync the address first, and sync frames before the
    /// outputs do not disturb the parse.
    func test_scanAsksForARefreshAndReadsPastSyncFrames() async throws {
        let script = try Script.payToPublicKeyHash(Address(address).publicKeyHash, maximumByteCount: 10_000)
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 7_000, lockingScript: script),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: Sweep.defaultLimits).displayHex
        let rows = """
            event: sync
            data: {"phase":"fetch","owner":"\(address)"}

            event: sync
            data: {"phase":"ingest","total":2,"processed":1,"owner":"\(address)"}

            event: txo
            data: {"outpoint":"\(txid).0","satoshis":7000,"events":[]}

            event: done
            data: {}

            """
        let http = SourceHTTP(stream: Array(rows.utf8), raw: try source.serialized(limits: Sweep.defaultLimits))
        let outputs = try await OneSatScanner(http: http).scan(address: address)
        XCTAssertEqual(outputs.map(\.kind), [.fundable])
        let urls = await http.urls
        let query = try XCTUnwrap(URLComponents(url: urls[0], resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertTrue(query.contains(URLQueryItem(name: "refresh", value: "true")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "10000")))

        let syncOnly = rows.components(separatedBy: "event: txo")[0]
        XCTAssertThrowsError(try OneSatScanner.parse(sse: Array(syncOnly.utf8)), "sync without done is incomplete")
    }

    /// G4: a funding output whose source transaction has a RUN output anywhere is held back.
    func test_aRunOutputInTheSourceTransactionHoldsBackItsFunding() async throws {
        let script = try Script.payToPublicKeyHash(Address(address).publicKeyHash, maximumByteCount: 10_000)
        func source(_ marker: [UInt8]) throws -> Transaction {
            Transaction(version: 1, inputs: [], outputs: [
                TransactionOutput(satoshis: 9_000, lockingScript: script),
                TransactionOutput(satoshis: 0, lockingScript: try Script(bytes: marker, maximumByteCount: 100)),
            ], lockTime: 0)
        }
        for (marker, expected) in [
            (ScannedOutput.runPrefix + [0x01, 0x05], AssetKind.run),
            (Array(ScannedOutput.runPrefix.dropLast()), AssetKind.fundable),
        ] {
            let tx = try source(marker)
            let txid = try tx.transactionID(limits: Sweep.defaultLimits).displayHex
            let rows = """
                event: txo
                data: {"outpoint":"\(txid).0","satoshis":9000}

                event: done
                data: {}

                """
            let http = SourceHTTP(stream: Array(rows.utf8), raw: try tx.serialized(limits: Sweep.defaultLimits))
            let outputs = try await OneSatScanner(http: http).scan(address: address)
            XCTAssertEqual(outputs.map(\.kind), [expected])
            XCTAssertEqual(outputs[0].sourceHasRunOutput, expected == .run)
        }
    }

    /// Twonks live under `twetch:<address>`, not the owner stream: they are looked up by key,
    /// resolved to their scripts, and come back as `.twetch`.
    func test_twetchNFTsAreFoundUnderTheirOwnKey() async throws {
        var bytes: [UInt8] = [0xa9, 0x14]
        bytes += [UInt8](repeating: 0x41, count: 20)
        bytes += [0x88, 0x76, 0xa9, 0x14]
        bytes += [UInt8](repeating: 0xbb, count: 20)
        bytes += [0x88, 0xac, 0x6a]
        let json = Array(#"{"title":"Muties #15"}"#.utf8)
        bytes.append(UInt8(json.count))
        bytes += json
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 2_180, lockingScript: try Script(bytes: bytes, maximumByteCount: 10_000)),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: Sweep.defaultLimits).displayHex
        let rows = #"[{"outpoint":"\#(txid).0","satoshis":2180,"events":["twetch","twetch:\#(address)"]}]"#
        let http = SearchHTTP(search: Array(rows.utf8), raw: try source.serialized(limits: Sweep.defaultLimits))

        let outputs = try await OneSatScanner(http: http).twetchNFTs(address: address)

        XCTAssertEqual(outputs.map(\.lockingScript), [bytes])
        XCTAssertEqual(outputs.first?.kind, .twetch)
        XCTAssertEqual(TwetchNFT.decode(bytes: bytes)?.title, "Muties #15")
        let urls = await http.urls
        XCTAssertEqual(urls.first?.path, "/1sat/txo/search")
        XCTAssertEqual(urls.first?.query?.contains("key=twetch%3A\(address)"), true)
    }

    func test_noTwetchNFTsIsAnEmptyList() async throws {
        let http = SearchHTTP(search: Array("null".utf8), raw: [])
        let outputs = try await OneSatScanner(http: http).twetchNFTs(address: address)
        XCTAssertTrue(outputs.isEmpty)
    }

    func test_anUnreadableTwetchSearchIsRefused() throws {
        XCTAssertThrowsError(try OneSatScanner.parse(search: Array("{}".utf8)))
        XCTAssertThrowsError(try OneSatScanner.parse(search: Array(#"[{"outpoint":"x"}]"#.utf8)))
    }

    private actor SearchHTTP: HTTPGet {
        let search: [UInt8]
        let raw: [UInt8]
        private(set) var urls: [URL] = []

        init(search: [UInt8], raw: [UInt8]) { self.search = search; self.raw = raw }

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            urls.append(url)
            return (200, url.path.hasSuffix("/search") ? search : raw)
        }
    }

    private actor SourceHTTP: HTTPGet {
        let stream: [UInt8]
        let raw: [UInt8]
        private(set) var paths: [String] = []
        private(set) var urls: [URL] = []

        init(stream: [UInt8], raw: [UInt8]) { self.stream = stream; self.raw = raw }

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            paths.append(url.path)
            urls.append(url)
            return (200, url.path.hasSuffix("/txos") ? stream : raw)
        }
    }

    func test_theNetworkPicksTheIndexerHostUnlessOneIsPassed() {
        XCTAssertEqual(OneSatScanner().baseURL, URL(string: "https://api.1sat.app"))
        XCTAssertEqual(OneSatScanner(network: .testnet).baseURL, URL(string: "https://testnet.api.1sat.app"))
        let custom = URL(string: "https://indexer.example")!
        XCTAssertEqual(OneSatScanner(baseURL: custom, network: .testnet).baseURL, custom)
    }

    /// `@1sat/types` constants.ts: ONESAT_{MAINNET,TESTNET}_URL and ONESAT_{MAINNET,TESTNET}_CONTENT_URL.
    func test_apiHostsMatchTheTypeScriptConstants() {
        XCTAssertEqual(OneSatAPI.baseURL(for: .mainnet).absoluteString, "https://api.1sat.app")
        XCTAssertEqual(OneSatAPI.baseURL(for: .testnet).absoluteString, "https://testnet.api.1sat.app")
        XCTAssertEqual(OneSatAPI.contentURL(for: .mainnet).absoluteString, "https://api.1sat.app/content")
        XCTAssertEqual(
            OneSatAPI.contentURL(for: .testnet).absoluteString,
            "https://testnet.api.1sat.app/content"
        )
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
