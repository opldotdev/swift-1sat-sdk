import Foundation
import XCTest
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
@testable import OneSatColor

/// A 1Color action counts as submitted only when the overlay's STEAK admits the transaction's own
/// token outputs. A 200 that admits nothing (or less) is a refusal: the result says so and keeps
/// the BEEF and custody, and the resubmit paths finish it later.
///
/// The 0.2.3 module completes on any 2xx answer; this check goes beyond it, as `@1sat/actions`
/// `receive` already does for a delivery.
final class OneColorAcceptanceTests: XCTestCase {
    private func notAdmitted(_ topic: String, _ outpoints: [String]) -> String {
        ColorError.notAdmitted(topic: topic, outpoints: outpoints).localizedDescription
    }

    private func authorityDeploy(_ world: ColorWorld) async throws -> ColorAssetID {
        let result = await OneColorActions.deploy(world.alice.ctx, amount: 0, decimals: 2, symbol: "MNT")
        XCTAssertNil(result.error)
        XCTAssertTrue(result.submitted)
        return try ColorAssetID(try XCTUnwrap(result.assetID))
    }

    // MARK: - Deploy

    func test_aDeployAnsweredWithNothingAdmittedIsNotSubmitted() async throws {
        let world = try ColorWorld()
        await world.overlay.admitNothingNext(1)
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 1_000, decimals: 2, symbol: "TST")
        let txid = try XCTUnwrap(deployed.txid)
        XCTAssertFalse(deployed.submitted)
        XCTAssertEqual(deployed.error, notAdmitted(ColorIdentifiers.discoveryTopic, ["\(txid).0"]))
        XCTAssertEqual(deployed.error, "BRC-207: the overlay did not admit \(txid).0 to tm_color")
        XCTAssertEqual(deployed.assetID, "\(txid)_0")
        XCTAssertNotNil(deployed.tx)
        XCTAssertNotNil(deployed.customInstructions)
        // A refusal is an answer, not a transport failure: it is not retried.
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic]])
        // The deploy is filed; only the overlay lacks it.
        let assetID = try ColorAssetID(try XCTUnwrap(deployed.assetID))
        let balance = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(balance, 1_000)
        let unspent = await world.overlay.unspent
        XCTAssertNil(unspent["\(txid).0"])

        let resubmitted = await OneColorActions.resubmitDeploy(
            world.alice.ctx, tx: try XCTUnwrap(deployed.tx), customInstructions: deployed.customInstructions
        )
        XCTAssertNil(resubmitted.error, resubmitted.error ?? "")
        XCTAssertTrue(resubmitted.submitted)
        XCTAssertEqual(resubmitted.txid, txid)
        let admitted = await world.overlay.unspent
        XCTAssertNotNil(admitted["\(txid).0"])
    }

    func test_aResubmittedDeployAnsweredWithNothingAdmittedIsNotSubmitted() async throws {
        let world = try ColorWorld()
        await world.overlay.admitNothingNext(2)
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 0)
        XCTAssertFalse(deployed.submitted)
        let tx = try XCTUnwrap(deployed.tx)
        let txid = try XCTUnwrap(deployed.txid)

        let refused = await OneColorActions.resubmitDeploy(world.alice.ctx, tx: tx)
        XCTAssertFalse(refused.submitted)
        XCTAssertEqual(refused.error, notAdmitted(ColorIdentifiers.discoveryTopic, ["\(txid).0"]))
        XCTAssertEqual(refused.tx, tx)
        XCTAssertEqual(refused.assetID, "\(txid)_0")

        let accepted = await OneColorActions.resubmitDeploy(world.alice.ctx, tx: tx)
        XCTAssertNil(accepted.error, accepted.error ?? "")
        XCTAssertTrue(accepted.submitted)
        // The authority deploy is admitted, so it can mint.
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: "\(txid)_0", amount: 1)
        XCTAssertTrue(minted.submitted, minted.error ?? "")
    }

    // MARK: - Mint

    func test_aMintAnsweredWithNothingAdmittedIsNotSubmitted() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world)
        await world.overlay.admitNothingNext(1)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 40)
        let txid = try XCTUnwrap(minted.txid)
        XCTAssertFalse(minted.submitted)
        XCTAssertEqual(minted.error, notAdmitted(ColorIdentifiers.topic(assetID), ["\(txid).0", "\(txid).1"]))
        XCTAssertEqual(minted.assetID, assetID.description)
        XCTAssertEqual(minted.authorityOutpoint, "\(txid).1")
        XCTAssertNotNil(minted.tx)
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions.count, 2, "deploy and one mint submission, no retry")

        let resubmitted = await OneColorActions.resubmitMint(world.alice.ctx, tx: try XCTUnwrap(minted.tx))
        XCTAssertNil(resubmitted.error, resubmitted.error ?? "")
        XCTAssertTrue(resubmitted.submitted)
        XCTAssertEqual(resubmitted.txid, txid)
        let unspent = await world.overlay.unspent
        XCTAssertNotNil(unspent["\(txid).0"])
        XCTAssertNotNil(unspent["\(txid).1"])
    }

    func test_aMintWhoseAuthorityIsNotAdmittedIsNotSubmitted() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world)
        await world.overlay.withholdNext([1])
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 7)
        let txid = try XCTUnwrap(minted.txid)
        XCTAssertFalse(minted.submitted)
        XCTAssertEqual(minted.error, notAdmitted(ColorIdentifiers.topic(assetID), ["\(txid).1"]))

        let resubmitted = await OneColorActions.resubmitMint(world.alice.ctx, tx: try XCTUnwrap(minted.tx))
        XCTAssertTrue(resubmitted.submitted, resubmitted.error ?? "")
        // The continuing authority is admitted now, so the next mint can spend it.
        let next = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 1)
        XCTAssertTrue(next.submitted, next.error ?? "")
        let (transaction, _) = try subject(next.tx)
        XCTAssertEqual(transaction.inputs[0].previousOutput.description, "\(txid).1")
    }

    func test_anEndingMintNeedsOnlyItsValueOutputAdmitted() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world)
        await world.overlay.withholdNext([1])
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 3, endMinting: true)
        XCTAssertNil(minted.error, minted.error ?? "")
        XCTAssertTrue(minted.submitted)
        XCTAssertNil(minted.authorityOutpoint)
    }

    func test_aResubmittedMintAnsweredWithNothingAdmittedIsNotSubmitted() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world)
        await world.overlay.failNext(OneColorConstants.submitAttempts)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 9)
        XCTAssertFalse(minted.submitted)
        let tx = try XCTUnwrap(minted.tx)
        let txid = try XCTUnwrap(minted.txid)

        await world.overlay.admitNothingNext(1)
        let refused = await OneColorActions.resubmitMint(world.alice.ctx, tx: tx)
        XCTAssertFalse(refused.submitted)
        XCTAssertEqual(refused.error, notAdmitted(ColorIdentifiers.topic(assetID), ["\(txid).0", "\(txid).1"]))
        XCTAssertEqual(refused.txid, txid)
        XCTAssertEqual(refused.tx, tx)
        XCTAssertEqual(refused.authorityOutpoint, "\(txid).1")

        let accepted = await OneColorActions.resubmitMint(world.alice.ctx, tx: tx)
        XCTAssertNil(accepted.error, accepted.error ?? "")
        XCTAssertTrue(accepted.submitted)
    }

    // MARK: - Send

    func test_aSplitAnsweredWithNothingAdmittedStopsTheSendAndIsResubmittedNextTime() async throws {
        let world = try ColorWorld()
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 1_000)
        let assetID = try ColorAssetID(try XCTUnwrap(deployed.assetID))
        await world.overlay.admitNothingNext(1)

        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com")
        let basket = ColorIdentifiers.basket(assetID, role: .value)
        let held = await world.alice.wallet.records.filter { $0.basket == basket && $0.outpoint.transactionID.displayHex != assetID.txid }
        XCTAssertEqual(held.count, 2, "the split's exact output and change stay in the wallet")
        let splitTxid = try XCTUnwrap(held.first?.outpoint.transactionID.displayHex)
        XCTAssertEqual(sent.error, notAdmitted(ColorIdentifiers.topic(assetID), ["\(splitTxid).0", "\(splitTxid).1"]))
        XCTAssertNil(sent.txid, "the handoff was never built")
        XCTAssertFalse(sent.delivered)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.map(\.description), ["Deploy 1Color token (fixed supply)", "Split tokens for a handoff"])
        let kept = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(kept, 1_000)

        // The next send resubmits the held split before it selects its outputs.
        let retried = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com")
        XCTAssertNil(retried.error, retried.error ?? "")
        XCTAssertTrue(retried.delivered)
        let topic = ColorIdentifiers.topic(assetID)
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic], [topic], [topic], [topic]],
                       "deploy, refused split, its resubmission, the second split")
        let synced = await TransactionInbox.sync(world.bob.ctx)
        XCTAssertEqual(synced.received.count, 1)
        let received = try await OneColorActions.balance(world.bob.ctx, assetID: assetID)
        XCTAssertEqual(received, 300)
    }

    func test_aSplitWhoseChangeIsNotAdmittedStopsTheSend() async throws {
        let world = try ColorWorld()
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 50)
        let assetID = try ColorAssetID(try XCTUnwrap(deployed.assetID))
        await world.overlay.withholdNext([1])
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 20, to: "bob@example.com")
        let error = try XCTUnwrap(sent.error)
        XCTAssertTrue(error.hasPrefix("BRC-207: the overlay did not admit "), error)
        XCTAssertTrue(error.hasSuffix(".1 to \(ColorIdentifiers.topic(assetID))"), error)
        XCTAssertNil(sent.txid)
    }

    // MARK: - The check itself

    func test_admissionNeedsEveryTopicToAdmitItsOwnOutputs() throws {
        let assetID = try ColorAssetID(txid: String(repeating: "ab", count: 32), vout: 0)
        let other = try ColorAssetID(txid: String(repeating: "cd", count: 32), vout: 1)
        let lock = OneColorLock.publicKeyHash([UInt8](repeating: 7, count: 20))
        let transaction = Transaction(
            version: 1, inputs: [],
            outputs: [
                TransactionOutput(satoshis: 1, lockingScript: try OneColor.value(tokenID: assetID.description, amount: 5, lock: lock).lock()),
                TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10)),
                TransactionOutput(satoshis: 1, lockingScript: try OneColor.authority(tokenID: assetID.description, lock: lock).lock()),
                TransactionOutput(satoshis: 1, lockingScript: try OneColor.value(tokenID: other.description, amount: 1, lock: lock).lock()),
            ],
            lockTime: 0
        )
        let txid = try transaction.transactionID(limits: harnessTxLimits).displayHex
        let topic = ColorIdentifiers.topic(assetID)
        let otherTopic = ColorIdentifiers.topic(other)
        XCTAssertEqual(
            ColorModule.expectedAdmissions(transaction, txid: txid, topics: [topic, otherTopic, ColorIdentifiers.discoveryTopic]),
            [topic: [0, 2], otherTopic: [3], ColorIdentifiers.discoveryTopic: []]
        )

        func check(_ steak: [String: ColorAdmittance], _ topics: [String]) throws {
            try ColorModule.assertAdmitted(steak, topics: topics, transaction: transaction, txid: txid)
        }
        XCTAssertNoThrow(try check([topic: ColorAdmittance(outputsToAdmit: [2, 0, 1])], [topic]))
        // A topic missing from the STEAK admitted nothing.
        XCTAssertThrowsError(try check([:], [topic])) { error in
            XCTAssertEqual(error as? ColorError, .notAdmitted(topic: topic, outpoints: ["\(txid).0", "\(txid).2"]))
        }
        // Retained coins without admitted outputs are not admission.
        XCTAssertThrowsError(try check([topic: ColorAdmittance(outputsToAdmit: [], coinsToRetain: [0])], [topic]))
        // Every topic is checked, in order.
        XCTAssertThrowsError(try check(
            [topic: ColorAdmittance(outputsToAdmit: [0, 2]), otherTopic: ColorAdmittance(outputsToAdmit: [0])],
            [topic, otherTopic]
        )) { error in
            XCTAssertEqual(error as? ColorError, .notAdmitted(topic: otherTopic, outpoints: ["\(txid).3"]))
        }
        // A topic with none of this transaction's outputs expects none.
        XCTAssertNoThrow(try check([:], [ColorIdentifiers.discoveryTopic]))
    }

    private func subject(_ tx: [UInt8]?) throws -> (Transaction, BEEF) {
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(tx), limits: harnessBEEFLimits)
        return (try XCTUnwrap(try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: harnessTxLimits)), atomic.beef)
    }
}
