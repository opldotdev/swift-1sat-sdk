import Foundation
import XCTest
import BSVCore
import BSVTransaction
import BSVWallet
import OneSatMetanet
import OneSatTemplates
@testable import OneSatColor

/// TS reads `p ...` labels and baskets with `startsWith` and `split(' ')`, on UTF-16 code units, so
/// a combining mark right after a prefix leaves the prefix in place. `String.hasPrefix` compares
/// characters, and the space and the mark are one character: each case here is refused, failed or
/// matched as the TS does it.
final class ColorPrefixBytesTests: XCTestCase {
    private let mark = "\u{301}"
    private let tag = String(repeating: "ab", count: 32) + "v0"

    private func assertColorError(
        _ expression: @autoclosure () throws -> Any?, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual(($0 as? ColorError)?.errorDescription, message, file: file, line: line)
        }
    }

    private func deploy(_ party: ColorWorld.Party) async throws -> ColorAssetID {
        let result = await OneColorActions.deploy(party.ctx, amount: 1_000, decimals: 2, symbol: "TST")
        XCTAssertNil(result.error)
        return try ColorAssetID(try XCTUnwrap(result.assetID))
    }

    private let plainScript: [UInt8] = [0x76, 0xa9, 0x14] + [UInt8](repeating: 7, count: 20) + [0x88, 0xac]

    // MARK: - Plan labels (TS `ColorPlan.fromLabels`, ColorPlan.ts:271)

    func test_aPlanLabelWithAMarkAfterThePrefixFailsAsTheModuleFailsIt() {
        // `startsWith('p color plan ')` selects each; `PLAN_LABEL` then fails it.
        for label in ["p color plan \(mark)0 1 7b7d", "p color plan 0\(mark) 1 7b7d", "p color plan 0 \(mark)1 7b7d",
                      "p color plan 0 1 \(mark)7b7d", "p color plan 0 1 7\(mark)b7d"] {
            assertColorError(try ColorPlan.fromLabels([label]), "BRC-207: invalid p color plan label")
        }
        XCTAssertNil(try ColorPlan.fromLabels(["p color pla\(mark)n 0 1 7b7d"]))
    }

    // MARK: - Baskets, protocol names and tags (TS identifiers.ts)

    func test_basketsAndProtocolNamesSplitOnSpacesAsTheModuleDoes() {
        // `split(' ')` leaves the mark on the tag, which `assetIdFromTag` refuses.
        assertColorError(try ColorIdentifiers.parseBasket("p color \(mark)\(tag)"), "BRC-207: invalid asset tag")
        assertColorError(try ColorIdentifiers.parseBasket("p color \(tag)\(mark)"), "BRC-207: invalid asset tag")
        assertColorError(try ColorIdentifiers.parseBalanceSelector("p color balance \(mark)\(tag)"), "BRC-207: invalid asset tag")
        XCTAssertNil(try ColorIdentifiers.parseBasket("p color \(tag) \(mark)authority"))
        assertColorError(try ColorIdentifiers.parseProtocolName("p color \(mark)\(tag) 61 62"), "BRC-207: invalid asset tag")
        assertColorError(try ColorIdentifiers.parseProtocolName("p color \(tag) 6\(mark)1 62"), "BRC-207: invalid p color remittance tags")
        XCTAssertFalse(ColorIdentifiers.isDerivationSuffixTag("p color \(mark)" + String(repeating: "ab", count: 32)))
        XCTAssertTrue(ColorIdentifiers.isDerivationSuffixTag("p color " + String(repeating: "ab", count: 32)))
        // `1` and a mark is one character that sorts between "0" and "9"; `ASSET_ID` refuses it.
        assertColorError(try ColorAssetID("1\(mark)" + String(repeating: "a", count: 61) + "_0"), "BRC-207: invalid asset ID")
        assertColorError(try ColorAssetID(String(repeating: "a", count: 64) + "_1\(mark)"), "BRC-207: invalid asset ID")
    }

    // MARK: - Caller labels and baskets (TS ColorPermissionModule.ts:1676-1681, :2186)

    func test_transferRefusesLabelsAndBasketsWithAMarkAfterTheirPrefix() async throws {
        let world = try ColorWorld()
        let assetID = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let script = try OneColor.value(tokenID: assetID.description, amount: 1, lock: .publicKeyHash([UInt8](repeating: 7, count: 20))).lock()
        let outputs = [try WalletCreateActionOutput(lockingScript: script.bytes, satoshis: 1, outputDescription: "x")]
        let colorLabel = await OneColorActions.transfer(world.alice.ctx, assetID: assetID, outputs: outputs, description: "x", labels: ["p color \(mark)x"])
        XCTAssertEqual(colorLabel.error, "BRC-207: unknown p color label")
        let handoff = await OneColorActions.transfer(
            world.alice.ctx, assetID: assetID, outputs: outputs, description: "x", labels: ["p nosend expiry \(mark)seconds 600"]
        )
        XCTAssertEqual(handoff.error, "BRC-207: a transfer is not a handoff; send hands tokens over")
        let plain = try WalletCreateActionOutput(lockingScript: plainScript, satoshis: 1, outputDescription: "x", basket: "p color \(mark)x")
        let basket = await OneColorActions.transfer(world.alice.ctx, assetID: assetID, outputs: [plain], description: "x")
        XCTAssertEqual(basket.error, "BRC-207: a p color basket can only receive BRC-162 token outputs")
        let requests = await world.alice.wallet.createRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func test_appSignedTransferRefusesLabelsAndBasketsWithAMarkAfterTheirPrefix() async throws {
        let world = try ColorWorld()
        let assetID = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let beef = try BEEF(merklePaths: [], transactions: [], limits: harnessBEEFLimits)
        let plain = try WalletCreateActionOutput(lockingScript: plainScript, satoshis: 1, outputDescription: "x", basket: "p color \(mark)x")
        let cases: [([String], [WalletCreateActionOutput], String)] = [
            (["p color \(mark)x"], [], "BRC-207: unknown p color label"),
            (["p nosend expiry \(mark)seconds 600"], [], "BRC-207: a transfer is not a handoff; send hands tokens over"),
            ([], [plain], "BRC-207: a p color basket can only receive BRC-162 token outputs"),
        ]
        for (labels, outputs, message) in cases {
            do {
                _ = try await ColorAppSignedTransfer.run(
                    world.alice.ctx, assetID: assetID, description: "x", inputBEEF: beef, inputs: [], outputs: outputs,
                    owned: [], labels: labels
                ) { _ in [:] }
                XCTFail("expected \(message)")
            } catch {
                XCTAssertEqual((error as? ColorError)?.errorDescription, message)
            }
        }
        let requests = await world.alice.wallet.createRequests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Received baskets (TS ColorPermissionModule.ts:322, 1sat-sdk metanet/receive.ts:200)

    func test_aReceivedBasketWithAMarkAfterThePrefixIsReadAsAColorBasket() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        let txid = try XCTUnwrap(sent.txid)
        let atomicBytes = try XCTUnwrap(sent.tx)
        let atomic = try AtomicBEEF(bytes: atomicBytes, limits: harnessBEEFLimits)
        let receipt = try ColorReceipt(assetID: assetID, derivationPrefix: "cA==", derivationSuffix: "cw==", senderIdentityKey: world.alice.key)
        let basket = "p color \(mark)" + ColorIdentifiers.basket(assetID, role: .value).dropFirst("p color ".count)
        let submitted = await world.overlay.submissions.count

        // The inbox: not skipped as an unsupported basket; `checkColorReceipt` fails its tag.
        let body = try TransactionDelivery(
            txid: try Hex.decode(txid, maximumDecodedByteCount: 32),
            beef: try atomic.beef.serialized(limits: harnessBEEFLimits),
            outputs: [.basketInsertion(outputIndex: 0, basket: basket, customInstructions: receipt.customInstructions, tags: nil)],
            lifecycles: [], memo: nil
        ).encoded()
        do {
            _ = try await TransactionInbox.internalizeTransactionDelivery(world.bob.ctx, body: body)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? ColorError)?.errorDescription, "BRC-207: invalid asset tag")
        }

        // The module's `internalizeAction`: `colorReceipts` takes it, `parseAssetBasket` fails it.
        do {
            _ = try await ColorInternalize.run(
                world.bob.ctx, atomicBEEF: atomicBytes,
                outputs: [.basketInsertion(outputIndex: 0, basket: basket, customInstructions: receipt.customInstructions)],
                description: "x", labels: []
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual((error as? ColorError)?.errorDescription, "BRC-207: invalid asset tag")
        }
        let internalized = await world.bob.wallet.internalized
        XCTAssertTrue(internalized.isEmpty)
        let submissions = await world.overlay.submissions.count
        XCTAssertEqual(submissions, submitted)
    }
}
