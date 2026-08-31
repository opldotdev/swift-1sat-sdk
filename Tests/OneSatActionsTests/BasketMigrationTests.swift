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
