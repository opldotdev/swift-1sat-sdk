import Foundation
import XCTest
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
@testable import OneSatColor

/// Minting from an authority end to end over the in-memory wallet and overlay.
final class OneColorMintFlowTests: XCTestCase {
    private func authorityDeploy(_ party: ColorWorld.Party) async throws -> ColorAssetID {
        let result = await OneColorActions.deploy(party.ctx, amount: 0, decimals: 2, symbol: "MNT")
        XCTAssertNil(result.error)
        return try ColorAssetID(try XCTUnwrap(result.assetID))
    }

    private func transaction(_ tx: [UInt8]?) throws -> (Transaction, BEEF) {
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(tx), limits: harnessBEEFLimits)
        return (try XCTUnwrap(try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: harnessTxLimits)), atomic.beef)
    }

    private func amounts(_ transaction: Transaction, txid: String) throws -> [UInt64] {
        try transaction.outputs.enumerated().compactMap { vout, output in
            try ColorTokenOutput.read(output.lockingScript, txid: txid, vout: UInt32(vout))?.amount
        }
    }

    private func insufficient(_ assetID: ColorAssetID) -> String {
        ColorError.custody("insufficient spendable authority of \(assetID)").localizedDescription
    }

    // MARK: - Mint

    func test_mintSpendsTheDeployAuthorityAndKeepsANewOne() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let holds = try await OneColorActions.holdsAuthority(world.alice.ctx, assetID: assetID)
        XCTAssertTrue(holds)

        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 2_500)
        XCTAssertNil(minted.error)
        XCTAssertTrue(minted.submitted)
        let txid = try XCTUnwrap(minted.txid)
        XCTAssertEqual(minted.assetID, assetID.description)
        XCTAssertEqual(minted.authorityOutpoint, "\(txid).1")

        let requests = await world.alice.wallet.createRequests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.description, "Mint 2500 1Color tokens")
        XCTAssertEqual(request.inputs?.map(\.outpoint.description), [assetID.outpoint])
        let plan = try XCTUnwrap(try ColorPlan.fromLabels(request.labels ?? []))
        XCTAssertEqual(plan.operations.map(\.operation), [.mint, .authorityTransfer])
        XCTAssertEqual(plan.ownedOutputs.map(\.outputIndex), [0, 1])

        let (transaction, beef) = try transaction(minted.tx)
        XCTAssertEqual(transaction.inputs[0].previousOutput.description, assetID.outpoint)
        XCTAssertNoThrow(try ColorModule.assertUnlocks(transaction, in: beef))
        XCTAssertEqual(try amounts(transaction, txid: txid), [2_500, 0])
        let value = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(value, 2_500)
        let authorities = try await OneColorActions.balance(world.alice.ctx, assetID: assetID, role: .authority)
        XCTAssertEqual(authorities, 1)
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic], [ColorIdentifiers.topic(assetID)]])

        // The continuing authority's custody names the asset, not ISSUE.
        let found = await world.alice.wallet.record("\(txid).1")
        let record = try XCTUnwrap(found)
        XCTAssertEqual(record.basket, ColorIdentifiers.basket(assetID, role: .authority))
        let plaintext = await ColorMetadata.decrypt(try XCTUnwrap(record.customInstructions), identity: world.alice.identity)
        let custody = try ColorCustody.parse(try XCTUnwrap(plaintext))
        XCTAssertEqual(custody.asset, .asset(assetID))
        XCTAssertEqual(record.tags, [custody.suffixTag])
    }

    func test_aSecondMintSpendsTheFirstMintsAuthority() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let first = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 5)
        XCTAssertNil(first.error)
        let second = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 7)
        XCTAssertNil(second.error)
        let (transaction, beef) = try transaction(second.tx)
        XCTAssertEqual(transaction.inputs[0].previousOutput.description, first.authorityOutpoint)
        XCTAssertNoThrow(try ColorModule.assertUnlocks(transaction, in: beef))
        let value = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(value, 12)
        let authorities = try await OneColorActions.balance(world.alice.ctx, assetID: assetID, role: .authority)
        XCTAssertEqual(authorities, 1)
    }

    func test_aFinalMintEndsMinting() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 10, endMinting: true)
        XCTAssertNil(minted.error)
        XCTAssertTrue(minted.submitted)
        XCTAssertNil(minted.authorityOutpoint)
        let requests = await world.alice.wallet.createRequests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.description, "Mint 10 1Color tokens and end minting")
        XCTAssertEqual(request.outputs?.count, 1)
        let plan = try XCTUnwrap(try ColorPlan.fromLabels(request.labels ?? []))
        XCTAssertEqual(plan.operations.map(\.operation), [.mint, .authorityEnd])

        let value = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(value, 10)
        let authorities = try await OneColorActions.balance(world.alice.ctx, assetID: assetID, role: .authority)
        XCTAssertEqual(authorities, 0)
        let holds = try await OneColorActions.holdsAuthority(world.alice.ctx, assetID: assetID)
        XCTAssertFalse(holds)

        let again = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 1)
        XCTAssertEqual(again.error, insufficient(assetID))
        XCTAssertNil(again.txid)
    }

    func test_mintedTokensCanBeSent() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 300)
        XCTAssertNil(minted.error)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.delivered)
        _ = await TransactionInbox.sync(world.bob.ctx)
        let received = try await OneColorActions.balance(world.bob.ctx, assetID: assetID)
        XCTAssertEqual(received, 300)
        // The authority stays with alice.
        let authorities = try await OneColorActions.balance(world.alice.ctx, assetID: assetID, role: .authority)
        XCTAssertEqual(authorities, 1)
    }

    // MARK: - Refusals

    func test_mintRefusesBadArguments() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        for bad in ["ISSUE", "nothex_0", assetID.txid] {
            let result = await OneColorActions.mint(world.alice.ctx, assetID: bad, amount: 1)
            XCTAssertEqual(result.error, "invalid-asset-id: expected <txid>_<vout>", bad)
        }
        for end in [false, true] {
            let zero = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 0, endMinting: end)
            XCTAssertEqual(zero.error, "amount-must-be-positive")
        }
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1, "nothing is created after the deploy")
    }

    func test_aFixedSupplyDeployHasNoAuthority() async throws {
        let world = try ColorWorld()
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 1_000)
        let assetID = try ColorAssetID(try XCTUnwrap(deployed.assetID))
        let holds = try await OneColorActions.holdsAuthority(world.alice.ctx, assetID: assetID)
        XCTAssertFalse(holds)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 1)
        XCTAssertEqual(minted.error, insufficient(assetID))
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1)
    }

    func test_mintNeedsAnOverlay() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let minted = await OneColorActions.mint(world.withoutOverlay(world.alice), assetID: assetID.description, amount: 1)
        XCTAssertEqual(minted.error, ColorError.overlay("overlay-required").localizedDescription)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1)
    }

    func test_mintNeedsTheOverlayToKnowTheDeploy() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        let other = MockOverlay()
        let ctx = OneColorContext(
            identity: world.alice.identity, storage: world.alice.wallet, auth: world.alice.ctx.auth,
            maximumFee: world.alice.ctx.maximumFee, overlay: other, handles: world.alice.ctx.handles,
            relay: world.alice.ctx.relay
        )
        let minted = await OneColorActions.mint(ctx, assetID: assetID.description, amount: 1)
        XCTAssertEqual(minted.error, ColorError.overlay("the overlay has no admitted deploy for \(assetID)").localizedDescription)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1)
    }

    func test_anAuthorityHeldByAPendingActionIsNotSelected() async throws {
        let world = try ColorWorld()
        let ctx = world.alice.ctx
        let assetID = try await authorityDeploy(world.alice)
        let overlay = try ctx.requireOverlay()
        let held = try await ColorModule.selectInputs(ctx, overlay: overlay, assetID: assetID, role: .authority, target: 1)
        XCTAssertEqual(held.map(\.outpoint), [assetID.outpoint])
        _ = try await world.alice.wallet.colorCreateAction(ctx.auth, try WalletCreateActionRequest(
            description: "Pending", inputBEEF: try await ColorModule.inputBEEF(ctx, inputs: held),
            inputs: try ColorExecutor.tokenInputs(held), options: try ColorExecutor.options()
        ))
        let minted = await OneColorActions.mint(ctx, assetID: assetID.description, amount: 1)
        XCTAssertEqual(minted.error, insufficient(assetID))
    }

    // MARK: - Submit failures and recovery

    func test_aFailedSubmitKeepsTheMintForResubmit() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        await world.overlay.failNext(OneColorConstants.submitAttempts)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 40)
        XCTAssertFalse(minted.submitted)
        XCTAssertEqual(minted.error, ColorError.overlay("overlay unavailable").localizedDescription)
        let txid = try XCTUnwrap(minted.txid)
        XCTAssertEqual(minted.authorityOutpoint, "\(txid).1")
        XCTAssertEqual(minted.assetID, assetID.description)
        // The wallet already holds the minted units.
        let value = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(value, 40)

        let resubmitted = await OneColorActions.resubmitMint(world.alice.ctx, tx: try XCTUnwrap(minted.tx))
        XCTAssertNil(resubmitted.error)
        XCTAssertTrue(resubmitted.submitted)
        XCTAssertEqual(resubmitted.txid, txid)
        XCTAssertEqual(resubmitted.assetID, assetID.description)
        XCTAssertEqual(resubmitted.authorityOutpoint, "\(txid).1")
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions.last, [ColorIdentifiers.topic(assetID)])
        let unspent = await world.overlay.unspent
        XCTAssertNotNil(unspent["\(txid).0"])
        XCTAssertNotNil(unspent["\(txid).1"])
        XCTAssertNil(unspent[assetID.outpoint])
    }

    func test_anUnsubmittedMintIsResubmittedBeforeTheNextMint() async throws {
        let world = try ColorWorld()
        let assetID = try await authorityDeploy(world.alice)
        await world.overlay.failNext(OneColorConstants.submitAttempts)
        let first = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 1)
        XCTAssertFalse(first.submitted)

        let second = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 2)
        XCTAssertNil(second.error)
        XCTAssertTrue(second.submitted)
        let (transaction, _) = try transaction(second.tx)
        XCTAssertEqual(transaction.inputs[0].previousOutput.description, first.authorityOutpoint)
        let topic = ColorIdentifiers.topic(assetID)
        let submissions = await world.overlay.submissions
        // Deploy, three failed tries, the first mint's resubmission, the second mint.
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic], [topic], [topic], [topic], [topic], [topic]])
        let unspent = await world.overlay.unspent
        XCTAssertNotNil(unspent["\(try XCTUnwrap(first.txid)).0"], "the first mint's value output is admitted")
    }

    func test_resubmitMintRefusesOtherTransactions() async throws {
        let world = try ColorWorld()
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 0)
        let refused = ColorError.invalid("mint transaction").localizedDescription
        let deploy = await OneColorActions.resubmitMint(world.alice.ctx, tx: try XCTUnwrap(deployed.tx))
        XCTAssertEqual(deploy.error, refused)

        let plain = Transaction(
            version: 1, inputs: [], outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x51], maximumByteCount: 10))],
            lockTime: 0
        )
        let id = try plain.transactionID(limits: harnessTxLimits)
        let atomic = try AtomicBEEF(subjectTransactionID: id, beef: try graph([plain]), limits: harnessBEEFLimits)
        let none = await OneColorActions.resubmitMint(world.alice.ctx, tx: try atomic.serialized(limits: harnessBEEFLimits))
        XCTAssertEqual(none.error, refused)

        // A plain transfer spends no authority.
        let value = await OneColorActions.deploy(world.alice.ctx, amount: 50)
        let valueID = try ColorAssetID(try XCTUnwrap(value.assetID))
        let split = try await ColorModule.split(
            world.alice.ctx, overlay: world.overlay, assetID: valueID,
            selected: try await ColorModule.selectInputs(world.alice.ctx, overlay: world.overlay, assetID: valueID, target: 10),
            amount: 10
        )
        let before = await world.overlay.submissions.count
        let splitBEEF = try XCTUnwrap(split.sourceBEEF)
        let splitID = try Outpoint(split.outpoint).transactionID
        let transfer = await OneColorActions.resubmitMint(
            world.alice.ctx,
            tx: try AtomicBEEF(subjectTransactionID: splitID, beef: splitBEEF, limits: harnessBEEFLimits).serialized(limits: harnessBEEFLimits)
        )
        XCTAssertEqual(transfer.error, refused)
        let after = await world.overlay.submissions.count
        XCTAssertEqual(after, before, "a refused resubmission sends nothing")
    }
}
