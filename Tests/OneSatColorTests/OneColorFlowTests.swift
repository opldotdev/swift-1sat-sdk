import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxStorage
import OneSatMetanet
@testable import OneSatColor

/// Deploy, send and receive end to end over an in-memory wallet, overlay and messagebox: the
/// BRC-207 flow two Swift wallets run against each other.
final class OneColorFlowTests: XCTestCase {

    private func deploy(_ party: ColorWorld.Party, amount: UInt64 = 1_000) async throws -> ColorAssetID {
        let result = await OneColorActions.deploy(party.ctx, amount: amount, decimals: 2, symbol: "TST")
        XCTAssertNil(result.error)
        return try ColorAssetID(try XCTUnwrap(result.assetID))
    }

    private func handoff(_ result: Send1ColorResult) throws -> (Transaction, BEEF) {
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(result.tx), limits: harnessBEEFLimits)
        let transaction = try XCTUnwrap(try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: harnessTxLimits))
        return (transaction, atomic.beef)
    }

    // MARK: - Deploy

    func test_deployFilesTheAssetEncryptedAndSubmitsItToDiscovery() async throws {
        let world = try ColorWorld()
        let result = await OneColorActions.deploy(world.alice.ctx, amount: 1_000, decimals: 2, symbol: "TST")
        XCTAssertNil(result.error)
        let txid = try XCTUnwrap(result.txid)
        XCTAssertEqual(result.assetID, "\(txid)_0")
        let assetID = try ColorAssetID(try XCTUnwrap(result.assetID))

        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic]])
        let balance = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(balance, 1_000)

        let found = await world.alice.wallet.record("\(txid).0")
        let record = try XCTUnwrap(found)
        XCTAssertEqual(record.basket, ColorIdentifiers.basket(assetID, role: .value))
        let stored = try XCTUnwrap(record.customInstructions)
        XCTAssertFalse(stored.hasPrefix("{"), "custody is encrypted at rest")
        let plaintext = await ColorMetadata.decrypt(stored, identity: world.alice.identity)
        let custody = try ColorCustody.parse(try XCTUnwrap(plaintext))
        XCTAssertEqual(custody.asset, .issue)
        XCTAssertEqual(custody.senderIdentityKey, world.alice.key)
        XCTAssertEqual(record.tags, [custody.suffixTag])

        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.first?.description, "Deploy 1Color token (fixed supply)")
        let internalized = await world.alice.wallet.internalized
        XCTAssertEqual(internalized.map(\.description), ["File the deployed asset"])

        // The deploy output pays the custody key.
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(result.tx), limits: harnessBEEFLimits)
        let deploy = try XCTUnwrap(try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: harnessTxLimits))
        let token = try XCTUnwrap(try ColorTokenOutput.read(deploy.outputs[0].lockingScript, txid: txid, vout: 0))
        XCTAssertTrue(token.deploy)
        XCTAssertNoThrow(try ColorKeys.assertOwned(token, custody: custody, identity: world.alice.identity))
    }

    func test_anAuthorityDeployFilesIntoTheAuthorityBasket() async throws {
        let world = try ColorWorld()
        let result = await OneColorActions.deploy(world.alice.ctx, amount: 0)
        XCTAssertNil(result.error)
        let assetID = try ColorAssetID(try XCTUnwrap(result.assetID))
        let authorities = try await OneColorActions.balance(world.alice.ctx, assetID: assetID, role: .authority)
        XCTAssertEqual(authorities, 1)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.first?.description, "Deploy 1Color token (authority)")
    }

    func test_deployAndSendNeedAnOverlay() async throws {
        let world = try ColorWorld()
        let ctx = world.withoutOverlay(world.alice)
        let deployed = await OneColorActions.deploy(ctx, amount: 10)
        XCTAssertEqual(deployed.error, ColorError.overlay("overlay-required").localizedDescription)
        let requests = await world.alice.wallet.createRequests
        XCTAssertTrue(requests.isEmpty)
    }

    func test_aFailedSubmissionStillReturnsTheDeploy() async throws {
        let world = try ColorWorld()
        await world.overlay.failNext(OneColorConstants.submitAttempts)
        let result = await OneColorActions.deploy(world.alice.ctx, amount: 10)
        XCTAssertNotNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertNotNil(result.tx)
        XCTAssertNotNil(result.assetID)
    }

    // MARK: - Send and receive

    func test_sendTheWholeBalanceThenTheRecipientReceivesIt() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.delivered)
        XCTAssertEqual(sent.messageID, "msg-1")

        // No split: the handoff spends the deploy and the BRC-177 anchor, and every input unlocks.
        let (transaction, beef) = try handoff(sent)
        XCTAssertEqual(transaction.inputs.count, 2)
        XCTAssertEqual(transaction.inputs[0].previousOutput.description, "\(assetID.txid).0")
        XCTAssertNoThrow(try ColorModule.assertUnlocks(transaction, in: beef))
        let token = try XCTUnwrap(try ColorTokenOutput.read(transaction.outputs[0].lockingScript, txid: try XCTUnwrap(sent.txid), vout: 0))
        XCTAssertEqual(token.assetID, assetID)
        XCTAssertEqual(token.amount, 1_000)
        let armed = await world.alice.wallet.armed
        XCTAssertEqual(armed.count, 1)
        let processed = await world.alice.wallet.processed
        XCTAssertEqual(processed.last?.isNoSend, true)
        let requests = await world.alice.wallet.createRequests
        let send = try XCTUnwrap(requests.last)
        XCTAssertEqual(send.description, "Send 1000 1Color tokens to @bob@example.com")
        XCTAssertTrue(send.labels?.contains("p nosend expiry seconds \(OneColorConstants.sendExpirySeconds)") ?? false)
        XCTAssertTrue(send.labels?.contains(where: { $0.hasPrefix(OneColorConstants.sendLabelPrefix) }) ?? false)
        let left = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(left, 0)

        // Bob collects the box: submitted, checked, filed encrypted, acknowledged.
        let synced = await TransactionInbox.sync(world.bob.ctx)
        XCTAssertNil(synced.error)
        XCTAssertEqual(synced.skipped, [])
        XCTAssertEqual(synced.received.map(\.assetIDs), [[assetID.description]])
        XCTAssertEqual(synced.received.map(\.deliveredOutputs), [[assetID.description: [0]]])
        XCTAssertEqual(synced.received.first?.sender, world.alice.key)
        XCTAssertEqual(synced.received.first?.txid, sent.txid)
        let received = try await OneColorActions.balance(world.bob.ctx, assetID: assetID)
        XCTAssertEqual(received, 1_000)
        let acknowledged = await world.server.acknowledged
        XCTAssertEqual(acknowledged, ["msg-1"])
        let remaining = await world.server.messages
        XCTAssertTrue(remaining.isEmpty)
        let internalized = await world.bob.wallet.internalized
        XCTAssertEqual(internalized.map(\.description), ["Receive 1Color tokens"])

        let txid = try XCTUnwrap(sent.txid)
        let found = await world.bob.wallet.record("\(txid).0")
        let record = try XCTUnwrap(found)
        let stored = try XCTUnwrap(record.customInstructions)
        XCTAssertFalse(stored.hasPrefix("{"))
        let plaintext = await ColorMetadata.decrypt(stored, identity: world.bob.identity)
        let custody = try ColorCustody.parse(try XCTUnwrap(plaintext))
        XCTAssertEqual(custody.senderIdentityKey, world.alice.key)
        XCTAssertEqual(record.tags, [custody.suffixTag])

        let unspent = await world.overlay.unspent
        XCTAssertNotNil(unspent["\(txid).0"])
        XCTAssertNil(unspent["\(assetID.txid).0"])
    }

    func test_aPartialSendSplitsFirstAndKeepsTheChange() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "@bob@example.com")
        XCTAssertNil(sent.error)
        XCTAssertTrue(sent.delivered)

        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.map(\.description), [
            "Deploy 1Color token (fixed supply)", "Split tokens for a handoff", "Send 300 1Color tokens to @bob@example.com",
        ])
        let split = requests[1]
        XCTAssertEqual(split.outputs?.map(\.outputDescription), ["BRC-207 token change", "BRC-207 token change"])
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic], [ColorIdentifiers.topic(assetID)]])

        // The handoff spends exactly the 300 output of the split.
        let (transaction, beef) = try handoff(sent)
        let source = transaction.inputs[0].previousOutput
        XCTAssertEqual(source.outputIndex, 0)
        let splitTx = try XCTUnwrap(try beef.transaction(for: source.transactionID, limits: harnessTxLimits))
        let exact = try XCTUnwrap(try ColorTokenOutput.read(splitTx.outputs[0].lockingScript, txid: source.transactionID.displayHex, vout: 0))
        XCTAssertEqual(exact.amount, 300)
        XCTAssertNoThrow(try ColorModule.assertUnlocks(transaction, in: beef))
        XCTAssertNoThrow(try ColorModule.assertUnlocks(splitTx, in: beef))

        let change = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(change, 700)

        let synced = await TransactionInbox.sync(world.bob.ctx)
        XCTAssertEqual(synced.received.count, 1)
        // The receipt names the handoff output the delivery filed: the 300, nothing else.
        let delivered = try XCTUnwrap(synced.received.first?.deliveredOutputs[assetID.description])
        XCTAssertEqual(delivered.count, 1)
        let sentTxid = try XCTUnwrap(sent.txid)
        let filed = try XCTUnwrap(try ColorTokenOutput.read(
            transaction.outputs[Int(delivered[0])].lockingScript, txid: sentTxid, vout: delivered[0]
        ))
        XCTAssertEqual(filed.amount, 300)
        let received = try await OneColorActions.balance(world.bob.ctx, assetID: assetID)
        XCTAssertEqual(received, 300)
    }

    func test_receivedTokensCanBeSentOnAndBack() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let first = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        XCTAssertNil(first.error)
        _ = await TransactionInbox.sync(world.bob.ctx)

        // Bob's custody came from a receipt keyed with alice as the counterparty.
        let back = await OneColorActions.send(world.bob.ctx, assetID: assetID.description, amount: 400, to: "alice@example.com", memo: "change")
        XCTAssertNil(back.error)
        XCTAssertTrue(back.delivered)
        let bobLeft = try await OneColorActions.balance(world.bob.ctx, assetID: assetID)
        XCTAssertEqual(bobLeft, 600)

        let synced = await TransactionInbox.sync(world.alice.ctx)
        XCTAssertEqual(synced.skipped, [])
        XCTAssertEqual(synced.received.map(\.assetIDs), [[assetID.description]])
        XCTAssertEqual(synced.received.map { $0.deliveredOutputs.keys.sorted() }, [[assetID.description]])
        let aliceHas = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(aliceHas, 400)
    }

    func test_anOutputTheOverlayLostIsResubmittedBeforeSelection() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        await world.overlay.forget(assetID.outpoint)

        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        XCTAssertNil(sent.error)
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions, [[ColorIdentifiers.discoveryTopic], [ColorIdentifiers.discoveryTopic]])
    }

    func test_anOutputTheOverlayNeverHadIsNotSelected() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        await world.overlay.forget(assetID.outpoint)
        await world.overlay.refuse(ColorIdentifiers.discoveryTopic)

        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1, to: "bob@example.com")
        XCTAssertEqual(sent.error, ColorError.custody("insufficient spendable balance of \(assetID)").localizedDescription)
        XCTAssertNil(sent.txid)
    }

    func test_sendRefusesBadArgumentsAndShortBalances() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        for bad in ["ISSUE", "nothex_0", assetID.txid] {
            let result = await OneColorActions.send(world.alice.ctx, assetID: bad, amount: 1, to: "bob@example.com")
            XCTAssertEqual(result.error, "invalid-asset-id: expected <txid>_<vout>", bad)
        }
        let zero = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 0, to: "bob@example.com")
        XCTAssertEqual(zero.error, "amount-must-be-positive")

        let short = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_001, to: "bob@example.com")
        XCTAssertEqual(short.error, ColorError.custody("insufficient spendable balance of \(assetID)").localizedDescription)

        let unknown = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1, to: "carol@example.com")
        XCTAssertNotNil(unknown.error)

        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1, "nothing is created after the deploy")
    }

    // MARK: - Receive rejections

    func test_anUnreadableMessageStaysInTheBox() async throws {
        let world = try ColorWorld()
        _ = await world.server.inject(
            recipient: world.bob.identity.publicKey.compressedBytes, box: OneColorConstants.transactionDeliveryBox,
            body: [0x01, 0x02], sender: world.alice.identity.publicKey.compressedBytes
        )
        let synced = await TransactionInbox.sync(world.bob.ctx)
        XCTAssertEqual(synced.received, [])
        XCTAssertEqual(synced.skipped, [TransactionInboxSkip(messageID: "msg-1", reason: "not a DAG-CBOR BRC-169 envelope")])
        let acknowledged = await world.server.acknowledged
        XCTAssertTrue(acknowledged.isEmpty)
        let remaining = await world.server.messages
        XCTAssertEqual(remaining.count, 1)
    }

    func test_aDeliveryTheOverlayDoesNotAdmitIsLeftInTheBox() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        XCTAssertNil(sent.error)
        await world.overlay.refuse(ColorIdentifiers.topic(assetID))

        let synced = await TransactionInbox.sync(world.bob.ctx)
        XCTAssertEqual(synced.received, [])
        let txid = try XCTUnwrap(sent.txid)
        XCTAssertEqual(synced.skipped.map(\.reason), ["\(ColorIdentifiers.topic(assetID)) did not admit \(txid).0"])
        let internalized = await world.bob.wallet.internalized
        XCTAssertTrue(internalized.isEmpty)
        let remaining = await world.server.messages
        XCTAssertEqual(remaining.count, 1)
    }

    func test_receivingNeedsAnOverlay() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        _ = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        let synced = await TransactionInbox.sync(world.withoutOverlay(world.bob))
        XCTAssertEqual(synced.skipped.map(\.reason), ["overlay-required"])
    }

    func test_aReceiptForAKeyBobDoesNotHoldIsRefused() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        let txid = try XCTUnwrap(sent.txid)
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(sent.tx), limits: harnessBEEFLimits)
        let forged = try ColorReceipt(
            assetID: assetID, derivationPrefix: Data("other-prefix".utf8).base64EncodedString(),
            derivationSuffix: Data("other-suffix".utf8).base64EncodedString(), senderIdentityKey: world.alice.key
        )
        let body = try TransactionDelivery(
            txid: try Hex.decode(txid, maximumDecodedByteCount: 32),
            beef: try atomic.beef.serialized(limits: harnessBEEFLimits),
            outputs: [.basketInsertion(
                outputIndex: 0, basket: ColorIdentifiers.basket(assetID, role: .value),
                customInstructions: forged.customInstructions, tags: nil
            )],
            lifecycles: [], memo: nil
        ).encoded()
        do {
            _ = try await TransactionInbox.internalizeTransactionDelivery(world.bob.ctx, body: body)
            XCTFail("expected a refusal")
        } catch {}
        let internalized = await world.bob.wallet.internalized
        XCTAssertTrue(internalized.isEmpty)
    }

    func test_aReceiptInTheWrongBasketIsRefused() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        let txid = try XCTUnwrap(sent.txid)
        let atomic = try AtomicBEEF(bytes: try XCTUnwrap(sent.tx), limits: harnessBEEFLimits)
        let receipt = try ColorReceipt(
            assetID: assetID, derivationPrefix: "cA==", derivationSuffix: "cw==", senderIdentityKey: world.alice.key
        )
        let body = try TransactionDelivery(
            txid: try Hex.decode(txid, maximumDecodedByteCount: 32),
            beef: try atomic.beef.serialized(limits: harnessBEEFLimits),
            outputs: [.basketInsertion(
                outputIndex: 0, basket: ColorIdentifiers.basket(assetID, role: .authority),
                customInstructions: receipt.customInstructions, tags: nil
            )],
            lifecycles: [], memo: nil
        ).encoded()
        do {
            _ = try await TransactionInbox.internalizeTransactionDelivery(world.bob.ctx, body: body)
            XCTFail("expected a refusal")
        } catch {}
        let submissions = await world.overlay.submissions
        XCTAssertEqual(submissions.count, 1, "a malformed receipt is refused before any submit")
    }

    // MARK: - Review fixes

    func test_unsupportedNoSendExpiryFailsBeforeTheSplit() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        await world.alice.wallet.setNoSendSupported(false)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com")
        XCTAssertEqual(sent.error, NoSendExpiryError.unsupported.localizedDescription)
        XCTAssertNil(sent.txid)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1, "only the deploy was created")
        let processed = await world.alice.wallet.processed
        XCTAssertEqual(processed.count, 1, "only the deploy was processed")
        let balance = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(balance, 1_000)
    }

    func test_anInvalidExpiryFailsBeforeTheSplit() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        for expiry in [0, -5] {
            let sent = await OneColorActions.send(
                world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com", expirySeconds: expiry
            )
            XCTAssertNotNil(sent.error, "\(expiry)")
            XCTAssertNil(sent.txid)
        }
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.count, 1)
        let processed = await world.alice.wallet.processed
        XCTAssertEqual(processed.count, 1)
        let checks = await world.alice.wallet.capabilityChecks
        XCTAssertEqual(checks, 0, "the expiry is validated before storage is asked")
    }

    func test_aResolverThatAnswersNilLeavesTheDeliveryInTheBox() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 1_000, to: "bob@example.com")
        XCTAssertNil(sent.error)
        let before = await world.overlay.submissions

        let synced = await TransactionInbox.sync(world.bob.ctx, overlayFor: { _ in nil })
        XCTAssertEqual(synced.received, [])
        XCTAssertEqual(synced.skipped.map(\.reason), ["overlay-required"])
        let after = await world.overlay.submissions
        XCTAssertEqual(after, before, "nothing was submitted")
        let internalized = await world.bob.wallet.internalized
        XCTAssertTrue(internalized.isEmpty)
        let acknowledged = await world.server.acknowledged
        XCTAssertTrue(acknowledged.isEmpty)
        let remaining = await world.server.messages
        XCTAssertEqual(remaining.count, 1)
    }
}
