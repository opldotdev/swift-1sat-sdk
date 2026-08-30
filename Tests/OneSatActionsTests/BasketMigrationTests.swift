import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
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
