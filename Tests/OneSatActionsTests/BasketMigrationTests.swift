import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class BasketMigrationTests: XCTestCase {
    func test_sameBasketIsANoOp() async throws {
        let listed = try WalletListOutputsResult(totalOutputs: 0, outputs: [])
        let internalizer = CapturingInternalizer()
        let result = try await BasketMigration.moveBasketOutputs(
            from: "p 1sat ordinals",
            to: "p 1sat ordinals",
            listed: listed,
            internalizer: internalizer
        )
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertTrue(result.complete)
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func test_emptySourceDoesNotInternalize() async throws {
        let listed = try WalletListOutputsResult(totalOutputs: 0, outputs: [])
        let internalizer = CapturingInternalizer()
        let result = try await BasketMigration.moveBasketOutputs(
            from: "p 1sat ordinals",
            to: "1sat",
            listed: listed,
            internalizer: internalizer
        )
        XCTAssertEqual(result.moved, 0)
        XCTAssertTrue(result.complete)
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func test_outputsWithoutBEEFThrow() async throws {
        let listed = try WalletListOutputsResult(
            totalOutputs: 1,
            outputs: [
                try WalletOutput(
                    satoshis: 1,
                    spendable: true,
                    customInstructions: "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"x\"}",
                    tags: ["origin:aa"],
                    outpoint: try Outpoint(ActionVectors.outpoint)
                ),
            ]
        )
        do {
            _ = try await BasketMigration.moveBasketOutputs(
                from: "p 1sat ordinals",
                to: "1sat",
                listed: listed,
                internalizer: CapturingInternalizer()
            )
            XCTFail("missing BEEF must throw")
        } catch let error as OneSatActionError {
            XCTAssertEqual(
                error,
                .moveBasketMissingBEEF(basket: "p 1sat ordinals")
            )
        }
    }

    func test_refilesPreservingTagsAndCustomInstructions() async throws {
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
                ),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        let txid = try source.transactionID(limits: WalletTransactionLimits.standard)
        let outpoint = Outpoint(transactionID: txid, outputIndex: 0)
        let instructions = "{\"protocolID\":[0,\"p 1sat\"],\"keyID\":\"ord-0\"}"
        let listed = try WalletListOutputsResult(
            totalOutputs: 1,
            beef: beef,
            outputs: [
                try WalletOutput(
                    satoshis: 1,
                    spendable: true,
                    customInstructions: instructions,
                    tags: ["type:image/png", "origin:\(outpoint.description)"],
                    outpoint: outpoint
                ),
            ]
        )
        let internalizer = CapturingInternalizer()
        let result = try await BasketMigration.moveBasketOutputs(
            from: "p 1sat ordinals",
            to: "1sat",
            listed: listed,
            internalizer: internalizer
        )
        XCTAssertEqual(result.moved, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(result.outpoints, [outpoint.description])
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertFalse(result.complete)

        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].description, "move basket p 1sat ordinals → 1sat")
        XCTAssertEqual(requests[0].outputs.count, 1)
        XCTAssertEqual(requests[0].outputs[0].outputIndex, 0)
        switch requests[0].outputs[0].remittance {
        case .basketInsertion(let insertion):
            XCTAssertEqual(insertion.basket, "1sat")
            XCTAssertEqual(insertion.customInstructions, instructions)
            XCTAssertEqual(insertion.tags, ["type:image/png", "origin:\(outpoint.description)"])
        case .walletPayment:
            XCTFail("migration must be basket insertion, not a wallet payment")
        }
    }

    func test_internalizeFailureIsNotComplete() async throws {
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
                ),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        let txid = try source.transactionID(limits: WalletTransactionLimits.standard)
        let outpoint = Outpoint(transactionID: txid, outputIndex: 0)
        let listed = try WalletListOutputsResult(
            totalOutputs: 1,
            beef: beef,
            outputs: [
                try WalletOutput(
                    satoshis: 1,
                    spendable: true,
                    outpoint: outpoint
                ),
            ]
        )
        let result = try await BasketMigration.moveBasketOutputs(
            from: "ordinals",
            to: "1sat",
            listed: listed,
            internalizer: FailingInternalizer()
        )
        XCTAssertEqual(result.moved, 0)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertFalse(result.complete)
    }

    func test_cancellationStopsBeforeNextOutputInternalization() async throws {
        let listed = try migrationOutputs(count: 2)
        let internalizer = GatedInternalizer()
        let task = Task {
            try await BasketMigration.moveBasketOutputs(
                from: "ordinals",
                to: "1sat",
                listed: listed,
                internalizer: internalizer
            )
        }

        await internalizer.waitUntilStarted()
        task.cancel()
        await internalizer.release()

        do {
            _ = try await task.value
            XCTFail("cancelled migration must stop before the next internalization")
        } catch is CancellationError {}
        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
    }

    func test_cancellationFromSoleInternalizationIsRethrown() async throws {
        let internalizer = GatedInternalizer(checkCancellationOnRelease: true)
        let task = Task {
            try await BasketMigration.moveBasketOutputs(
                from: "ordinals",
                to: "1sat",
                listed: try migrationOutputs(count: 1),
                internalizer: internalizer
            )
        }

        await internalizer.waitUntilStarted()
        task.cancel()
        await internalizer.release()

        do {
            _ = try await task.value
            XCTFail("final internalizer cancellation must propagate")
        } catch is CancellationError {}
        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
    }

    func test_cancellationAfterSoleIgnoringInternalizationIsObserved() async throws {
        let internalizer = GatedInternalizer()
        let task = Task {
            try await BasketMigration.moveBasketOutputs(
                from: "ordinals",
                to: "1sat",
                listed: try migrationOutputs(count: 1),
                internalizer: internalizer
            )
        }

        await internalizer.waitUntilStarted()
        task.cancel()
        await internalizer.release()

        do {
            _ = try await task.value
            XCTFail("cancellation after the final successful internalization must propagate")
        } catch is CancellationError {}
        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
    }

    func test_cancellationStopsBeforeNextDrainPage() async throws {
        let listed = try migrationOutputs(count: 1)
        let transport = DrainingListingTransport(firstPage: listed)
        let internalizer = GatedInternalizer()
        let task = Task {
            try await BasketMigration.migrateLegacyP1SatBaskets(
                try migrationContext(transport: transport),
                internalizer: internalizer
            )
        }

        await internalizer.waitUntilStarted()
        task.cancel()
        await internalizer.release()

        do {
            _ = try await task.value
            XCTFail("cancelled migration must stop before listing the next page")
        } catch is CancellationError {}
        let baskets = await transport.baskets
        XCTAssertEqual(baskets, [OneSatConstants.legacyP1SatBasketMigrations[0].from])
    }

    func test_cancellationDuringFinalEmptyPageIsObserved() async throws {
        let transport = GatedEmptyListingTransport()
        let task = Task {
            try await BasketMigration.migrateLegacyP1SatBaskets(
                try migrationContext(transport: transport),
                internalizer: CapturingInternalizer()
            )
        }

        await transport.waitUntilStarted()
        task.cancel()
        await transport.release()

        do {
            _ = try await task.value
            XCTFail("cancellation during a final empty page must propagate")
        } catch is CancellationError {}
        let baskets = await transport.baskets
        XCTAssertEqual(baskets, [OneSatConstants.legacyP1SatBasketMigrations[0].from])
    }

    func test_contextMoveCancellationAfterEmptyListIsObserved() async throws {
        let transport = GatedEmptyListingTransport()
        let task = Task {
            try await BasketMigration.moveBasketOutputs(
                try migrationContext(transport: transport),
                internalizer: CapturingInternalizer(),
                from: "ordinals",
                to: "1sat"
            )
        }

        await transport.waitUntilStarted()
        task.cancel()
        await transport.release()

        do {
            _ = try await task.value
            XCTFail("context move must observe cancellation after its final list")
        } catch is CancellationError {}
        let baskets = await transport.baskets
        XCTAssertEqual(baskets, ["ordinals"])
    }

    func test_migrateDrainsMovedPageThenEmptyAndCompletesAggregate() async throws {
        let transport = DrainingListingTransport(firstPage: try migrationOutputs(count: 1))
        let result = try await BasketMigration.migrateLegacyP1SatBaskets(
            try migrationContext(transport: transport),
            internalizer: CapturingInternalizer()
        )

        XCTAssertEqual(result.totalMoved, 1)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.results[0].moved, 1)
        XCTAssertTrue(result.results.allSatisfy(\.complete))

        let baskets = await transport.baskets
        let sources = OneSatConstants.legacyP1SatBasketMigrations.map(\.from)
        XCTAssertEqual(baskets, [sources[0], sources[0]] + sources.dropFirst())
    }

    func test_migrateEmptySourcesIsCompleteAndListsOrdinalsBasket() async throws {
        let transport = ListingTransport()
        let identity = try ActionVectors.identity()
        let ctx = OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
        let result = try await BasketMigration.migrateLegacyP1SatBaskets(
            ctx,
            internalizer: CapturingInternalizer()
        )
        XCTAssertEqual(result.totalMoved, 0)
        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.results.count, OneSatConstants.legacyP1SatBasketMigrations.count)
        XCTAssertTrue(result.results.allSatisfy(\.complete))

        let baskets = await transport.baskets
        XCTAssertEqual(baskets, OneSatConstants.legacyP1SatBasketMigrations.map(\.from))
        XCTAssertTrue(baskets.contains("ordinals"))
        XCTAssertTrue(baskets.contains("p 1sat ordinals"))
    }
}

private func migrationContext(
    transport: any AuthenticatedTransport
) throws -> OneSatContext {
    let identity = try ActionVectors.identity()
    return OneSatContext(
        identity: identity,
        storage: StorageClient(
            endpoint: URL(string: "https://example.invalid")!,
            transport: transport
        ),
        auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
    )
}

private func migrationOutputs(count: Int) throws -> WalletListOutputsResult {
    let source = Transaction(
        version: 1,
        inputs: [],
        outputs: try (0..<count).map { _ in
            TransactionOutput(
                satoshis: 1,
                lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
            )
        },
        lockTime: 0
    )
    let beef = try BEEF(
        merklePaths: [],
        transactions: [.raw(source)],
        limits: WalletBEEFLimits.standard
    )
    let txid = try source.transactionID(limits: WalletTransactionLimits.standard)
    return try WalletListOutputsResult(
        totalOutputs: UInt32(count),
        beef: beef,
        outputs: (0..<count).map { index in
            try WalletOutput(
                satoshis: 1,
                spendable: true,
                outpoint: Outpoint(transactionID: txid, outputIndex: UInt32(index))
            )
        }
    )
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

private actor FailingInternalizer: ActionInternalizer {
    func internalizeAction(
        _: WalletInternalizeActionRequest
    ) async throws -> WalletInternalizeActionResult {
        throw OneSatActionError.moveBasketBasketsRequired
    }
}

private actor GatedInternalizer: ActionInternalizer {
    private let checkCancellationOnRelease: Bool
    private(set) var requests: [WalletInternalizeActionRequest] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(checkCancellationOnRelease: Bool = false) {
        self.checkCancellationOnRelease = checkCancellationOnRelease
    }

    func waitUntilStarted() async {
        guard requests.isEmpty else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func internalizeAction(
        _ request: WalletInternalizeActionRequest
    ) async throws -> WalletInternalizeActionResult {
        requests.append(request)
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
        if checkCancellationOnRelease {
            try Task.checkCancellation()
        }
        return WalletInternalizeActionResult(accepted: true)
    }
}

private actor GatedEmptyListingTransport: AuthenticatedTransport {
    private(set) var baskets: [String] = []
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilStarted() async {
        guard baskets.isEmpty else { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let params = object?["params"] as? [Any]
        let args = params?.dropFirst().first as? [String: Any]
        baskets.append(args?["basket"] as? String ?? "")
        startedWaiter?.resume()
        startedWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }

        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": object?["id"] as Any,
            "result": ["totalOutputs": 0, "outputs": []],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}

private actor DrainingListingTransport: AuthenticatedTransport {
    private let firstPage: WalletListOutputsResult
    private(set) var baskets: [String] = []
    private var returnedFirstPage = false

    init(firstPage: WalletListOutputsResult) {
        self.firstPage = firstPage
    }

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let rpcMethod = object?["method"] as? String ?? ""
        guard rpcMethod == "listOutputs" else {
            throw AuthTransportError.notImplemented("offline")
        }
        let params = object?["params"] as? [Any]
        let args = params?.dropFirst().first as? [String: Any]
        let basket = args?["basket"] as? String ?? ""
        baskets.append(basket)

        let firstSource = OneSatConstants.legacyP1SatBasketMigrations[0].from
        let result: [String: Any]
        if basket == firstSource, !returnedFirstPage {
            returnedFirstPage = true
            let beef = try XCTUnwrap(firstPage.beef)
            result = [
                "totalOutputs": firstPage.totalOutputs,
                "BEEF": try beef.serialized(limits: WalletBEEFLimits.standard),
                "outputs": firstPage.outputs.map { output in
                    [
                        "satoshis": output.satoshis,
                        "spendable": output.spendable,
                        "outpoint": output.outpoint.description,
                    ]
                },
            ]
        } else {
            result = ["totalOutputs": 0, "outputs": []]
        }
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": object?["id"] as Any,
            "result": result,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}

private actor ListingTransport: AuthenticatedTransport {
    private(set) var baskets: [String] = []

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let rpcMethod = object?["method"] as? String ?? ""
        if rpcMethod == "listOutputs" {
            let params = object?["params"] as? [Any]
            let args = params?.dropFirst().first as? [String: Any]
            if let basket = args?["basket"] as? String {
                baskets.append(basket)
            }
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": object?["id"] as Any,
                "result": ["totalOutputs": 0, "outputs": []],
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
        }
        throw AuthTransportError.notImplemented("offline")
    }
}
