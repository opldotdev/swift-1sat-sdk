import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatAddresses
import OneSatClient
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxServices
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class SyncAddressesTests: XCTestCase {
    private let pinnedInstructions =
        "{\"protocolID\":[0,\"onesat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\"}"

    func test_customInstructionsEmitsSelfWhenAsked() throws {
        let encoded = try CustomInstructions(keyID: "1sat 0")
            .encoded(includeSelfCounterparty: true)
        XCTAssertEqual(encoded, pinnedInstructions)
        let defaultEncoded = try CustomInstructions(keyID: "1sat 0").encoded()
        XCTAssertEqual(defaultEncoded, "{\"protocolID\":[0,\"onesat\"],\"keyID\":\"1sat 0\"}")
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
                assets: NoAssets(),
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
                assets: NoAssets(),
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

    /// TS `internalizeBeef`: plain BSV goes to the deposit basket; a 1-sat P2PKH output with no
    /// 1-sat input at its position is its own origin (`OriginIndexer`) and goes to `1sat` with
    /// BRC-147 tags; a script that is not P2PKH is not the address's.
    func test_internalizesMoneyAndANewOriginOrdinalAndSkipsNonP2PKH() async throws {
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
            assets: NoAssets(),
            store: store,
            request: SyncAddresses.Request()
        )

        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.addresses.count, 2)
        XCTAssertEqual(result.addresses[0], fixture.address)
        let stored = try await store.has(fixture.txid)
        XCTAssertTrue(stored)

        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.outputs.map(\.outputIndex), [0, 1])
        XCTAssertEqual(request.description, "Received ordinal + 1000 sats")
        XCTAssertTrue(request.labels.isEmpty)

        let money = try insertion(request.outputs[0])
        XCTAssertEqual(money.basket, OneSatConstants.depositBasket)
        XCTAssertEqual(money.customInstructions, pinnedInstructions)
        XCTAssertEqual(money.tags.count, 1)
        XCTAssertTrue(money.tags[0].hasPrefix("id:"))
        XCTAssertTrue(money.tags[0].hasSuffix("_0"))

        let ordinal = try insertion(request.outputs[1])
        XCTAssertEqual(ordinal.basket, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(ordinal.tags.count, 2)
        XCTAssertEqual(ordinal.tags[0], "origin:\(fixture.txid)_1")
        XCTAssertTrue(ordinal.tags[1].hasPrefix("id:"))
        XCTAssertTrue(ordinal.tags[1].hasSuffix("_1"))
        XCTAssertEqual(
            ordinal.customInstructions,
            "{\"protocolID\":[0,\"onesat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\",\"origin\":\"\(fixture.txid)_1\"}"
        )
    }

    /// `/1sat/beef/:txid` answers Atomic BEEF (BRC-95). Plain `BEEF(bytes:)` refused it with
    /// `invalidVersion(0x01010101)`, so no deposit was ever internalized.
    func test_internalizesADepositServedAsAtomicBEEF() async throws {
        let identity = try ActionVectors.identity()
        let fixture = try atomicDepositFixture(identity: identity)
        XCTAssertEqual(Array(fixture.atomicBytes.prefix(4)), [0x01, 0x01, 0x01, 0x01])
        XCTAssertThrowsError(
            try BEEF(bytes: fixture.atomicBytes, limits: WalletBEEFLimits.standard)
        ) { error in
            XCTAssertEqual(error as? BEEFError, .invalidVersion(16_843_009))
        }

        let store = MemoryStore()
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: fixture.atomicBytes),
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(fixture.txid).1", score: 90),
            ]),
            assets: NoAssets(),
            store: store,
            request: SyncAddresses.Request()
        )

        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.failures, [])
        let stored = try await store.has(fixture.txid)
        XCTAssertTrue(stored)
        let storedScore = try await store.lastScore()
        XCTAssertEqual(storedScore, 90)

        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.transaction, fixture.atomic)
        // vout 0 is 1 sat at the start of a 2000-sat input: its own origin, as in TS.
        XCTAssertEqual(request.description, "Received ordinal + 1500 sats")
        XCTAssertEqual(request.outputs.map(\.outputIndex), [0, 1])
        XCTAssertEqual(try insertion(request.outputs[0]).basket, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(try insertion(request.outputs[1]).basket, OneSatConstants.depositBasket)
    }

    /// TS `syncAddresses`: a transaction that fails is logged and counted, the rest still sync,
    /// and the cursor stays put so the failure is fetched again next time.
    func test_aFailedTxidIsReportedWithoutStoppingTheRestAndHoldsTheCursor() async throws {
        let identity = try ActionVectors.identity()
        let fixture = try atomicDepositFixture(identity: identity)
        let broken = String(repeating: "44", count: 32)
        let store = MemoryStore()
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: BeefByTxid(bytes: [
                broken: [0xde, 0xad, 0xbe, 0xef],
                fixture.txid: fixture.atomicBytes,
            ]),
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(broken).0", score: 80),
                SyncOutput(outpoint: "\(fixture.txid).1", score: 90),
            ]),
            assets: NoAssets(),
            store: store,
            request: SyncAddresses.Request()
        )

        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.failures.map(\.txid), [broken])
        XCTAssertTrue(result.failures[0].message.contains("invalidVersion"), result.failures[0].message)
        XCTAssertEqual(result.lastScore, 90)
        let storedScore = try await store.lastScore()
        XCTAssertEqual(storedScore, 0)
        let brokenStored = try await store.has(broken)
        let goodStored = try await store.has(fixture.txid)
        XCTAssertFalse(brokenStored)
        XCTAssertTrue(goodStored)
        let requestCount = await internalizer.requests.count
        XCTAssertEqual(requestCount, 1)
    }

    /// TS logs a failed closing `sweepDeposit` and still returns the sync result; here the
    /// sweep's own error comes back, and the sync's work and cursor are unaffected.
    func test_aFailedSweepIsReportedWithItsErrorAndLeavesTheSyncResult() async throws {
        let identity = try ActionVectors.identity()
        let fixture = try atomicDepositFixture(identity: identity)
        let store = MemoryStore()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: CapturingInternalizer(),
            beef: FixedBeef(bytes: fixture.atomicBytes),
            syncSource: FixedSync(outputs: [
                SyncOutput(outpoint: "\(fixture.txid).1", score: 90),
            ]),
            assets: NoAssets(),
            store: store,
            request: SyncAddresses.Request()
        )
        XCTAssertEqual(result.processed, 1)
        XCTAssertEqual(result.failures, [])
        // The storage transport is offline, so the sweep's listOutputs is what fails.
        XCTAssertEqual(
            result.sweepError,
            String(describing: AuthTransportError.notImplemented("offline"))
        )
        let storedScore = try await store.lastScore()
        XCTAssertEqual(storedScore, 90)
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
            assets: NoAssets(),
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
            assets: NoAssets(),
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
            assets: NoAssets(),
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

    /// TS `SYNC_PROTOCOLS`: the legacy `[0, "p 1sat"]` set is synced after the ONESAT set, and
    /// a deposit to it records that protocol so the sweep derives the key that owns it.
    func test_syncsLegacyP1satAddressesAndRecordsTheirProtocol() async throws {
        let identity = try ActionVectors.identity()
        let legacy = try WalletProtocolID(securityLevel: .silent, name: "p 1sat")
        let key = try WalletKeyDeriver(rootKey: identity).derivePublicKey(
            protocolID: legacy,
            keyID: WalletKeyID("1sat 0"),
            counterparty: .self,
            forSelf: true
        )
        let legacyAddress = Address(publicKey: key, network: .mainnet)
        let tx = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 2_500, lockingScript: try p2pkh(legacyAddress))],
            lockTime: 0
        )
        let (txid, bytes) = try plainBEEF([tx])
        let sync = RecordingSync(outputs: [SyncOutput(outpoint: "\(txid).0", score: 90)])
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: bytes),
            syncSource: sync,
            assets: NoAssets(),
            store: MemoryStore(),
            request: SyncAddresses.Request()
        )

        let onesat = try DepositAddresses.address(identity: identity, index: 0)
        XCTAssertEqual(result.addresses, [onesat.description, legacyAddress.description])
        let owners = await sync.owners
        XCTAssertEqual(owners, [[onesat.description, legacyAddress.description]])
        let captured = await internalizer.requests
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.description, "Received 2500 sats")
        let filed = try insertion(request.outputs[0])
        XCTAssertEqual(filed.basket, OneSatConstants.depositBasket)
        XCTAssertEqual(
            filed.customInstructions,
            "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\"}"
        )
    }

    /// `OriginIndexer.resolveOrigins`: a 1-sat input at the output's first satoshi is a
    /// transfer; OrdFS (seq 0) names the origin, its type and MAP, and the input's source comes
    /// from `getRawTx` when the BEEF does not carry it.
    func test_aTransferredOrdinalIsFiledUnderItsOriginFromOrdFS() async throws {
        let identity = try ActionVectors.identity()
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let parent = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10)),
                TransactionOutput(satoshis: 900, lockingScript: try Script(bytes: [0x52], maximumByteCount: 10)),
            ],
            lockTime: 0
        )
        let parentID = try parent.transactionID(limits: WalletTransactionLimits.standard)
        let tx = try spending(parent: parentID, vouts: [0, 1], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: try p2pkh(address)),
        ])
        let txid = try tx.transactionID(limits: WalletTransactionLimits.standard).displayHex
        // Only the subject: the input's source has to come from getRawTx.
        let proof = try merkleProofOnly(tx)
        let origin = String(repeating: "cd", count: 32) + "_0"
        let assets = StubAssets(
            raw: [parentID.displayHex: try parent.serialized(limits: WalletTransactionLimits.standard)],
            metadata: OrdfsMetadata(
                outpoint: "\(parentID.displayHex)_0",
                origin: origin,
                sequence: 4,
                contentType: "image/png; charset=binary",
                contentLength: 4_000,
                map: ["app": .string("gallery"), "name": .string("Pic")]
            )
        )
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: proof),
            syncSource: FixedSync(outputs: [SyncOutput(outpoint: "\(txid).0", score: 90)]),
            assets: assets,
            store: MemoryStore(),
            request: SyncAddresses.Request()
        )

        XCTAssertEqual(result.failures, [])
        let metadataCalls = await assets.metadataCalls
        XCTAssertEqual(metadataCalls, ["\(parentID.displayHex).0:0"])
        let rawCalls = await assets.rawCalls
        XCTAssertEqual(rawCalls, [parentID.displayHex])
        let contentCalls = await assets.contentCalls
        XCTAssertEqual(contentCalls, [], "image content is never fetched")
        let captured = await internalizer.requests
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.description, "Received ordinal")
        let filed = try insertion(request.outputs[0])
        XCTAssertEqual(filed.basket, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(Array(filed.tags.dropLast()), ["origin:\(origin)", "app:gallery", "type:image/png"])
        XCTAssertTrue(filed.tags.last?.hasPrefix("id:") == true)
        XCTAssertEqual(
            filed.customInstructions,
            "{\"protocolID\":[0,\"onesat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\",\"origin\":\"\(origin)\",\"app\":\"gallery\"}"
        )
    }

    /// TS throws when OrdFS cannot name a transfer's origin: the transaction fails, nothing is
    /// internalized and the cursor holds, so a later sync files it.
    func test_anOrdinalWhoseOriginCannotBeReadFailsAndHoldsTheCursor() async throws {
        let identity = try ActionVectors.identity()
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let parent = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10))],
            lockTime: 0
        )
        let parentID = try parent.transactionID(limits: WalletTransactionLimits.standard)
        let tx = try spending(parent: parentID, vouts: [0], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: try p2pkh(address)),
        ])
        let (txid, bytes) = try plainBEEF([parent, tx])
        let store = MemoryStore()
        let internalizer = CapturingInternalizer()
        let result = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: bytes),
            syncSource: FixedSync(outputs: [SyncOutput(outpoint: "\(txid).0", score: 90)]),
            assets: StubAssets(),
            store: store,
            request: SyncAddresses.Request()
        )
        XCTAssertEqual(result.processed, 0)
        XCTAssertEqual(result.failures.map(\.txid), [txid])
        XCTAssertTrue(result.failures[0].message.contains("ordfs offline"), result.failures[0].message)
        let storedScore = try await store.lastScore()
        XCTAssertEqual(storedScore, 0)
        let processed = try await store.has(txid)
        XCTAssertFalse(processed)
        let requestCount = await internalizer.requests.count
        XCTAssertEqual(requestCount, 0)
    }

    /// `OpNSIndexer.summarize`: a transferred name is recognised by its origin's type and named
    /// from the origin's content.
    func test_aTransferredOpnsNameGoesToTheOpnsBasketWithItsName() async throws {
        let identity = try ActionVectors.identity()
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let parent = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10))],
            lockTime: 0
        )
        let parentID = try parent.transactionID(limits: WalletTransactionLimits.standard)
        let tx = try spending(parent: parentID, vouts: [0], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: try p2pkh(address)),
        ])
        let (txid, bytes) = try plainBEEF([parent, tx])
        let origin = String(repeating: "ef", count: 32) + "_0"
        let assets = StubAssets(
            metadata: OrdfsMetadata(
                outpoint: "\(parentID.displayHex)_0",
                origin: origin,
                sequence: 1,
                contentType: "application/op-ns",
                contentLength: 7
            ),
            content: Array("  alice\n".utf8)
        )
        let internalizer = CapturingInternalizer()
        _ = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: bytes),
            syncSource: FixedSync(outputs: [SyncOutput(outpoint: "\(txid).0", score: 90)]),
            assets: assets,
            store: MemoryStore(),
            request: SyncAddresses.Request()
        )
        let contentCalls = await assets.contentCalls
        XCTAssertEqual(contentCalls, [origin])
        let captured = await internalizer.requests
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.description, "Received OPNS name")
        let filed = try insertion(request.outputs[0])
        XCTAssertEqual(filed.basket, OneSatConstants.opnsBasket)
        XCTAssertEqual(Array(filed.tags.dropLast()), ["origin:\(origin)", "type:application/op-ns", "name:alice"])
        XCTAssertEqual(OrdinalRemittance.displayName(fromCustomInstructions: filed.customInstructions), "alice")
    }

    /// `Bsv21Indexer`: a BSV-21 transfer to a deposit address goes to `bsv21` with token CI, the
    /// overlay's `sym`/`dec`/`icon`, the `bsv21 <id>` label and an amount description.
    func test_aBsv21TransferIsFiledWithTokenInstructionsAndLabel() async throws {
        let identity = try ActionVectors.identity()
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let tokenID = ActionVectors.tokenID
        let lock = try BSV21.transfer(tokenID: tokenID, amount: "1500").lock(lockingScript: try p2pkh(address))
        let tx = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: lock)],
            lockTime: 0
        )
        let (txid, bytes) = try plainBEEF([tx])
        let assets = StubAssets(token: DepositTokenDetails(symbol: "TEST", decimals: 2, icon: "_1"))
        let internalizer = CapturingInternalizer()
        _ = try await SyncAddresses.execute(
            try context(identity: identity, services: HeightServices(height: 100)),
            internalizer: internalizer,
            beef: FixedBeef(bytes: bytes),
            syncSource: FixedSync(outputs: [SyncOutput(outpoint: "\(txid).0", score: 90)]),
            assets: assets,
            store: MemoryStore(),
            request: SyncAddresses.Request()
        )
        let tokenCalls = await assets.tokenCalls
        XCTAssertEqual(tokenCalls, [tokenID])
        let captured = await internalizer.requests
        let request = try XCTUnwrap(captured.first)
        XCTAssertEqual(request.description, "Received 15 TEST")
        XCTAssertEqual(request.labels, ["bsv21 \(tokenID)"])
        let filed = try insertion(request.outputs[0])
        XCTAssertEqual(filed.basket, OneSatConstants.bsv21Basket)
        XCTAssertEqual(filed.tags.first, "bsv21:\(tokenID)")
        XCTAssertEqual(filed.tags.count, 2)
        let icon = String(tokenID.prefix(64)) + "_1"
        XCTAssertEqual(
            filed.customInstructions,
            "{\"id\":\"\(tokenID)\",\"amt\":\"1500\",\"op\":\"transfer\",\"sym\":\"TEST\",\"dec\":\"2\",\"icon\":\"\(icon)\",\"protocolID\":[0,\"onesat\"],\"keyID\":\"1sat 0\",\"counterparty\":\"self\"}"
        )
    }

    private func insertion(_ output: WalletInternalizeOutput) throws -> WalletBasketInsertion {
        guard case .basketInsertion(let insertion) = output.remittance else {
            throw XCTSkip("deposit sync must not build walletPayment")
        }
        return insertion
    }

    private func p2pkh(_ address: Address) throws -> Script {
        try Script.payToPublicKeyHash(
            address,
            maximumByteCount: Int(WalletTransactionLimits.standard.maximumScriptByteCount)
        )
    }

    private func spending(
        parent: TransactionID,
        vouts: [UInt32],
        outputs: [TransactionOutput]
    ) throws -> Transaction {
        Transaction(
            version: 1,
            inputs: try vouts.map {
                TransactionInput(
                    previousOutput: Outpoint(transactionID: parent, outputIndex: $0),
                    unlockingScript: try Script(bytes: [], maximumByteCount: 10)
                )
            },
            outputs: outputs,
            lockTime: 0
        )
    }

    private func plainBEEF(_ txs: [Transaction]) throws -> (txid: String, bytes: [UInt8]) {
        let beef = try BEEF(merklePaths: [], transactions: txs.map { .raw($0) }, limits: WalletBEEFLimits.standard)
        let txid = try XCTUnwrap(txs.last).transactionID(limits: WalletTransactionLimits.standard).displayHex
        return (txid, try beef.serialized(limits: WalletBEEFLimits.standard))
    }

    /// A mined subject served alone, with a one-leaf BUMP, as `/1sat/beef` serves a confirmed tx.
    private func merkleProofOnly(_ tx: Transaction) throws -> [UInt8] {
        let id = try tx.transactionID(limits: WalletTransactionLimits.standard)
        let path = try MerklePath(
            blockHeight: 80,
            levels: [[.hash(offset: 0, hash: try Hash256(id.wireBytes), isTransactionID: true)]]
        )
        let beef = try BEEF(
            merklePaths: [path],
            transactions: [.rawWithMerklePath(transaction: tx, merklePathIndex: 0)],
            limits: WalletBEEFLimits.standard
        )
        return try OneSatTestBEEF.atomicEnvelope(beef, subject: id)
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

    private struct AtomicDepositFixture {
        let txid: String
        let atomic: AtomicBEEF
        let atomicBytes: [UInt8]
    }

    /// What `/1sat/beef/:txid` serves: the subject (dust at vout 0, 1500 sats to deposit address 0
    /// at vout 1) and the parent it spends, in a BRC-95 envelope naming the subject.
    private func atomicDepositFixture(identity: PrivateKey) throws -> AtomicDepositFixture {
        let address = try DepositAddresses.address(identity: identity, index: 0)
        let p2pkh = try Script.payToPublicKeyHash(
            address,
            maximumByteCount: Int(WalletTransactionLimits.standard.maximumScriptByteCount)
        )
        let opTrue = try Script(bytes: [0x51], maximumByteCount: 10_000)
        let limits = WalletBEEFLimits.standard
        let parent = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 2_000, lockingScript: opTrue)],
            lockTime: 0
        )
        let parentID = try parent.transactionID(limits: limits.transactionLimits)
        let subject = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(transactionID: parentID, outputIndex: 0),
                    unlockingScript: try Script(bytes: [], maximumByteCount: 10)
                ),
            ],
            outputs: [
                TransactionOutput(satoshis: 1, lockingScript: p2pkh),
                TransactionOutput(satoshis: 1_500, lockingScript: p2pkh),
            ],
            lockTime: 0
        )
        let subjectID = try subject.transactionID(limits: limits.transactionLimits)
        let atomic = try AtomicBEEF(
            subjectTransactionID: subjectID,
            beef: try BEEF(
                merklePaths: [],
                transactions: [.raw(parent), .raw(subject)],
                limits: limits
            ),
            limits: limits
        )
        return AtomicDepositFixture(
            txid: subjectID.displayHex,
            atomic: atomic,
            atomicBytes: try atomic.serialized(limits: limits)
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

/// Fails every read: a sync that reaches one is filing something it should not.
private struct NoAssets: DepositAssetSource {
    func rawTransaction(txid: String) async throws -> [UInt8] { throw StubFailure("rawTx \(txid)") }
    func ordinalMetadata(outpoint: String, seq: Int) async throws -> OrdfsMetadata {
        throw StubFailure("metadata \(outpoint)")
    }
    func ordinalContent(outpoint: String) async throws -> [UInt8] { throw StubFailure("content \(outpoint)") }
    func tokenDetails(tokenID: String) async throws -> DepositTokenDetails? { throw StubFailure("token \(tokenID)") }
}

private struct StubFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private actor StubAssets: DepositAssetSource {
    let raw: [String: [UInt8]]
    let metadata: OrdfsMetadata?
    let content: [UInt8]?
    let token: DepositTokenDetails?
    private(set) var rawCalls: [String] = []
    private(set) var metadataCalls: [String] = []
    private(set) var contentCalls: [String] = []
    private(set) var tokenCalls: [String] = []

    init(
        raw: [String: [UInt8]] = [:],
        metadata: OrdfsMetadata? = nil,
        content: [UInt8]? = nil,
        token: DepositTokenDetails? = nil
    ) {
        self.raw = raw
        self.metadata = metadata
        self.content = content
        self.token = token
    }

    func rawTransaction(txid: String) async throws -> [UInt8] {
        rawCalls.append(txid)
        guard let found = raw[txid] else { throw StubFailure("no raw tx \(txid)") }
        return found
    }

    func ordinalMetadata(outpoint: String, seq: Int) async throws -> OrdfsMetadata {
        metadataCalls.append("\(outpoint):\(seq)")
        guard let metadata else { throw StubFailure("ordfs offline") }
        return metadata
    }

    func ordinalContent(outpoint: String) async throws -> [UInt8] {
        contentCalls.append(outpoint)
        guard let content else { throw StubFailure("no content") }
        return content
    }

    func tokenDetails(tokenID: String) async throws -> DepositTokenDetails? {
        tokenCalls.append(tokenID)
        return token
    }
}

private actor RecordingSync: OwnerSyncSource {
    let outputs: [SyncOutput]
    private(set) var owners: [[String]] = []
    init(outputs: [SyncOutput]) { self.outputs = outputs }
    func syncOutputs(owners: [String], from: Double?) async throws -> [SyncOutput] {
        self.owners.append(owners)
        return outputs
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

private struct BeefByTxid: ListingBeefSource {
    let bytes: [String: [UInt8]]
    func beef(forTxid txid: String) async throws -> [UInt8] {
        guard let found = bytes[txid] else { throw ServiceError.notImplemented("beef \(txid)") }
        return found
    }
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
