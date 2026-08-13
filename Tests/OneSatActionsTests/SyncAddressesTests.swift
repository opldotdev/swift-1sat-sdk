import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatAddresses
import ToolboxActions
import ToolboxAuth
import ToolboxServices
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class SyncAddressesTests: XCTestCase {
    private let pinnedInstructions =
        "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\"}"

    func test_customInstructionsEmitsSelfWhenAsked() throws {
        let encoded = try CustomInstructions(keyID: "1sat 0")
            .encoded(includeSelfCounterparty: true)
        XCTAssertEqual(encoded, pinnedInstructions)
        let defaultEncoded = try CustomInstructions(keyID: "1sat 0").encoded()
        XCTAssertEqual(defaultEncoded, "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"1sat 0\"}")
    }

    func test_depositBasketName() {
        XCTAssertEqual(OneSatConstants.depositBasket, "1sat-deposit")
    }

    func test_missingServicesThrowsBeforeAnyNetworkCall() async throws {
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, services: nil)
        let sync = ProbeSync()
        let beef = ProbeBeef()
        let internalizer = CapturingInternalizer()
        let store = MemoryStore()

        do {
            _ = try await SyncAddresses.execute(
                ctx,
                internalizer: internalizer,
                beef: beef,
                syncSource: sync,
                store: store,
                request: SyncAddresses.Request()
            )
            XCTFail("missing services must throw")
        } catch let error as OneSatActionError {
            XCTAssertEqual(error, .servicesRequired)
        }
        let syncCalled = await sync.called
        let beefCalled = await beef.called
        let requestCount = await internalizer.requests.count
        XCTAssertFalse(syncCalled)
        XCTAssertFalse(beefCalled)
        XCTAssertEqual(requestCount, 0)
    }

    func test_nonPositiveCountDerivesNoAddresses() async throws {
        let identity = try ActionVectors.identity()
        let sync = ProbeSync()
        let internalizer = CapturingInternalizer()
        for count in [-1, 0] {
            let result = try await SyncAddresses.execute(
                try context(identity: identity, services: HeightServices(height: 100)),
                internalizer: internalizer,
                beef: ProbeBeef(),
                syncSource: sync,
                store: MemoryStore(),
                request: SyncAddresses.Request(count: count)
            )
            XCTAssertEqual(result.addresses, [])
            XCTAssertEqual(result.processed, 0)
            XCTAssertEqual(result.failed, 0)
        }
        let requestCount = await internalizer.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    func test_internalizesP2PKHMoneyAndSkipsDustAndNonP2PKH() async throws {
        let identity = try ActionVectors.identity()
        let fixture = try depositFixture(identity: identity)
        let store = MemoryStore()
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: fixture.beefBytes),
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(fixture.txid).0", score: 90),
            ]),
            store: store,
            request: SyncAddresses.Request()
        )

        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.addresses, [fixture.address])
        let stored = try await store.has(fixture.txid)
        XCTAssertTrue(stored)

        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.outputs.count, 1)
        XCTAssertEqual(request.outputs[0].outputIndex, 0)
        XCTAssertEqual(request.description, "Received 1000 sats")
        XCTAssertTrue(request.labels.isEmpty)
        switch request.outputs[0].remittance {
        case .walletPayment:
            XCTFail("deposit sync must not build walletPayment")
        case .basketInsertion(let insertion):
            XCTAssertEqual(insertion.basket, OneSatConstants.depositBasket)
            XCTAssertEqual(insertion.customInstructions, pinnedInstructions)
            XCTAssertEqual(insertion.tags.count, 1)
            XCTAssertTrue(insertion.tags[0].hasPrefix("id:"))
            XCTAssertTrue(insertion.tags[0].hasSuffix("_0"))
        }
    }

    func test_allSpentTxidIsMarkedProcessedWithoutInternalize() async throws {
        let identity = try ActionVectors.identity()
        let txid = String(repeating: "11", count: 32)
        let store = MemoryStore()
        let internalizer = CapturingInternalizer()
        let beef = ProbeBeef()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: beef,
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(txid).0", score: 90, spendTxid: "spent"),
            ]),
            store: store,
            request: SyncAddresses.Request()
        )
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 0)
        let stored = try await store.has(txid)
        let requestCount = await internalizer.requests.count
        let beefCalled = await beef.called
        XCTAssertTrue(stored)
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(beefCalled)
    }

    func test_alreadyProcessedTxidIsSkipped() async throws {
        let identity = try ActionVectors.identity()
        let fixture = try depositFixture(identity: identity)
        let store = MemoryStore()
        try await store.add(fixture.txid)
        let internalizer = CapturingInternalizer()
        let beef = ProbeBeef()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: beef,
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(fixture.txid).0", score: 90),
            ]),
            store: store,
            request: SyncAddresses.Request()
        )
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.failed, 0)
        let requestCount = await internalizer.requests.count
        let beefCalled = await beef.called
        XCTAssertEqual(requestCount, 0)
        XCTAssertFalse(beefCalled)
    }

    func test_lastScoreAdvancesOnlyPastReorgDepth() async throws {
        let identity = try ActionVectors.identity()
        let safe = String(repeating: "22", count: 32)
        let recent = String(repeating: "33", count: 32)
        let store = MemoryStore()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: CapturingInternalizer(),
            beef: ProbeBeef(),
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(safe).0", score: 94.5, spendTxid: "spent"),
                SyncOutput(outpoint: "\(recent).0", score: 95.0, spendTxid: "spent"),
            ]),
            store: store,
            request: SyncAddresses.Request()
        )
        XCTAssertEqual(result.lastScore, 94.5)
        let storedScore = try await store.lastScore()
        XCTAssertEqual(storedScore, 94.5)
    }

    func test_fileStorePersistsProcessedAndScore() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sync-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileProcessedTxStore(fileURL: url)
        let missing = try await store.has("abc")
        let initialScore = try await store.lastScore()
        XCTAssertFalse(missing)
        XCTAssertEqual(initialScore, 0)
        try await store.add("abc")
        try await store.setLastScore(12.5)
        let reopened = FileProcessedTxStore(fileURL: url)
        let persisted = try await reopened.has("abc")
        let persistedScore = try await reopened.lastScore()
        XCTAssertTrue(persisted)
        XCTAssertEqual(persistedScore, 12.5)
    }

    func test_descriptionMatchesTheMoneyBranch() {
        XCTAssertEqual(SyncAddresses.buildDescription(sats: 1_000), "Received 1000 sats")
        let maxSats = SyncAddresses.buildDescription(sats: UInt64.max)
        XCTAssertEqual(maxSats, "Received 18446744073709551615 sats")
        XCTAssertLessThanOrEqual(maxSats.count, 50)
    }

    private struct DepositFixture {
        let txid: String
        let address: String
        let beefBytes: [UInt8]
    }

    /// One tx: 1000-sat P2PKH, 1-sat P2PKH, and a non-P2PKH output.
    private func depositFixture(identity: PrivateKey) throws -> DepositFixture {
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let p2pkh = try Script.payToPublicKeyHash(
            address,
            maximumByteCount: Int(WalletTransactionLimits.standard.maximumScriptByteCount)
        )
        let other = try Script(bytes: [0x51], maximumByteCount: 10_000)
        let tx = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(satoshis: 1_000, lockingScript: p2pkh),
                TransactionOutput(satoshis: 1, lockingScript: p2pkh),
                TransactionOutput(satoshis: 5_000, lockingScript: other),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(tx)],
            limits: WalletBEEFLimits.standard
        )
        let txid = try tx.transactionID(limits: WalletBEEFLimits.standard.transactionLimits)
            .displayHex
        return DepositFixture(
            txid: txid,
            address: address.description,
            beefBytes: try beef.serialized(limits: WalletBEEFLimits.standard)
        )
    }

    private func context(
        identity: PrivateKey,
        services: (any WalletServices)?
    ) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: RejectTransport()
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            services: services
        )
    }
}

private struct HeightServices: WalletServices {
    let height: UInt32

    func rawTX(txid: String) async throws -> [UInt8] {
        throw ServiceError.notImplemented("rawTX")
    }
    func postBEEF(_ beef: [UInt8], txids: [String]) async throws -> [BroadcastOutcome] {
        throw ServiceError.notImplemented("postBEEF")
    }
    func merklePath(txid: String) async throws -> [UInt8]? {
        throw ServiceError.notImplemented("merklePath")
    }
    func currentHeight() async throws -> UInt32 { height }
    func chainTipHeader() async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("chainTipHeader")
    }
    func header(atHeight height: UInt32) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header")
    }
    func header(forHash hash: String) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header")
    }
    func isValidRoot(_ root: [UInt8], atHeight height: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isValidRoot")
    }
    func statusForTXIDs(_ txids: [String]) async throws -> [TransactionStatusReport] {
        throw ServiceError.notImplemented("status")
    }
    func isUTXO(scriptHash: String, txid: String, vout: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isUTXO")
    }
    func scriptHashHistory(_ scriptHash: String) async throws -> [ScriptHistoryEntry] {
        throw ServiceError.notImplemented("history")
    }
    func usdPerBSV() async throws -> Double {
        throw ServiceError.notImplemented("usd")
    }
}

private struct FixedSync: OwnerSyncSource {
    let outputs: [SyncOutput]
    func syncOutputs(owners: [String], from: Double?) async throws -> [SyncOutput] { outputs }
}

private struct FixedBeef: ListingBeefSource {
    let bytes: [UInt8]
    func beef(forTxid _: String) async throws -> [UInt8] { bytes }
}

private actor ProbeSync: OwnerSyncSource {
    private(set) var called = false
    func syncOutputs(owners: [String], from: Double?) async throws -> [SyncOutput] {
        called = true
        return []
    }
}

private actor ProbeBeef: ListingBeefSource {
    private(set) var called = false
    func beef(forTxid _: String) async throws -> [UInt8] {
        called = true
        return []
    }
}

private actor CapturingInternalizer: ActionInternalizer {
    private(set) var requests: [WalletInternalizeActionRequest] = []
    func internalizeAction(
        _ request: WalletInternalizeActionRequest
    ) async throws -> WalletInternalizeActionResult {
        requests.append(request)
        return WalletInternalizeActionResult(accepted: true)
    }
}

private actor MemoryStore: ProcessedTxStore {
    private var processed: Set<String> = []
    private var score: Double = 0
    func has(_ txid: String) async throws -> Bool { processed.contains(txid) }
    func add(_ txid: String) async throws { processed.insert(txid) }
    func lastScore() async throws -> Double { score }
    func setLastScore(_ score: Double) async throws { self.score = score }
}

private struct RejectTransport: AuthenticatedTransport {
    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        throw AuthTransportError.notImplemented("offline")
    }
}
