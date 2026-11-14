import Foundation
import BSVCompat
import BSVCore
import BSVCrypto
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxCore
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// The SIGMA publish of `inscribe` and the collection mints against `applyInscribeSigma`
/// (`apply/inscribeSigma.ts`), run against storage that accepts every action.
final class SigmaPublishTests: XCTestCase {
    // MARK: Shared pieces

    func test_publishOptionsMatchTheApplyStep() throws {
        let anchorTxid = String(repeating: "ab", count: 32)
        let options = SigmaPublish.publishOptions(anchorTxid: anchorTxid)
        XCTAssertEqual(options, TrackedAction.Options(
            randomizeOutputs: false,
            acceptDelayedBroadcast: true,
            knownTxids: [anchorTxid],
            sendWith: [anchorTxid],
            trustSelf: .known
        ))
        XCTAssertFalse(options.noSend)

        let request = try TrackedAction.request(
            description: "Create inscription",
            outputs: [],
            actionID: "aabbccdd",
            options: options
        )
        let wire = try XCTUnwrap(request.options)
        XCTAssertEqual(wire.trustSelf, .known)
        XCTAssertNotEqual(wire.noSend, true)
        XCTAssertEqual(wire.signAndProcess, false)
        XCTAssertEqual(wire.sendWith?.map(\.displayHex), [anchorTxid])
        XCTAssertEqual(wire.knownTransactionIDs?.map(\.displayHex), [anchorTxid])
        XCTAssertNil(wire.noSendChange)
        XCTAssertEqual(SigmaPublish.anchorKeyID("aabbccdd"), "anchor-aabbccdd")
    }

    func test_publishErrorPassesWalletFailuresThrough() {
        XCTAssertEqual(SigmaPublish.publishError(nil), "no-txid-returned")
        XCTAssertEqual(SigmaPublish.publishError("broadcast-sending"), "no-txid-returned")
        XCTAssertEqual(SigmaPublish.publishError("insufficient funds"), "insufficient funds")
    }

    func test_sealedTagsPutIdThenCreatorLast() throws {
        let sealed = SigmaPublish.Sealed(
            script: try Script(bytes: [0x51], maximumByteCount: 10),
            creator: "1Creator",
            actionID: "aabbccdd"
        )
        XCTAssertEqual(
            sealed.tags(["type:text/plain", "creator:1Old", "id:old_0", "origin"], index: 2),
            ["type:text/plain", "origin", "id:aabbccdd_2", "creator:1Creator"]
        )
        XCTAssertEqual(sealed.tags([], index: 0), ["id:aabbccdd_0", "creator:1Creator"])
    }

    func test_missingAnchorUsesTheApplyStepMessage() {
        XCTAssertEqual(
            OneSatActionError.sigmaAnchorFailed.wireMessage,
            "ordinal.inscribe-sigma apply: anchor failed"
        )
    }

    // MARK: inscribe (inscriptions/index.ts inscribeWithSigma)

    func test_inscribeWithSigmaMatchesTheApplyStep() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let request = Inscriptions.Request(
            content: Array("hello".utf8),
            contentType: "text/plain; charset=utf-8",
            map: [("name", "Hello")]
        )
        let result = await Inscriptions.inscribe(try context(transport), request, keyID: "inscribe-1")
        XCTAssertNil(result.error, result.error ?? "")

        let flow = try await assertApplyStepFlow(
            transport,
            identity: identity,
            description: "Create inscription",
            outputDescription: "Inscription",
            result: result
        )
        let prepared = try Inscriptions.prepare(identity: identity, request, keyID: "inscribe-1")
        XCTAssertEqual(prepared.tags.prefix(2), ["type:text/plain", "origin"])
        XCTAssertEqual(
            flow.output["tags"] as? [String],
            storageTags(prepared.tags + ["id:\(flow.actionID)_0", "creator:\(flow.creator)"])
        )
        // The CI built for the output goes out unchanged, as the TS apply step leaves it.
        XCTAssertEqual(flow.output["customInstructions"] as? String, prepared.customInstructions)
        let instructions = try CustomInstructions.parse(try XCTUnwrap(prepared.customInstructions))
        XCTAssertEqual(instructions.keyID, "inscribe-1")
        XCTAssertEqual(instructions.name, "Hello")
        XCTAssertEqual(try XCTUnwrap(Inscription.decode(flow.lockingScript)).content, Array("hello".utf8))
    }

    func test_inscribeWithSigmaKeepsTheDestinationCounterpartyInTheCI() async throws {
        let identity = try ActionVectors.identity()
        let recipient = try ActionVectors.recipient().publicKey
        let transport = PublishTransport()
        let request = Inscriptions.Request(
            content: Array("hi".utf8),
            contentType: "text/plain",
            destination: Destination(counterparty: .publicKey(recipient))
        )
        let result = await Inscriptions.inscribe(try context(transport), request, keyID: "inscribe-2")
        XCTAssertNil(result.error, result.error ?? "")

        let creates = try SigmaAssert.createActions(await transport.bodies)
        let output = try XCTUnwrap((creates.last?["outputs"] as? [[String: Any]])?.first)
        let ci = try XCTUnwrap(output["customInstructions"] as? String)
        XCTAssertEqual(ci, try Inscriptions.prepare(identity: identity, request, keyID: "inscribe-2").customInstructions)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ci.utf8)) as? [String: Any])
        XCTAssertEqual(object["counterparty"] as? String, Hex.encode(recipient.compressedBytes))
    }

    func test_inscribeWithSigmaPassesARejectedBroadcastThrough() async throws {
        // TS returns the tracked action's result as is, so its broadcast error stands.
        let transport = PublishTransport(sendWithStatus: "failed")
        let result = await Inscriptions.inscribe(
            try context(transport),
            Inscriptions.Request(content: Array("hi".utf8), contentType: "text/plain")
        )
        XCTAssertEqual(result.error, "broadcast-failed")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        // The publish asks storage for its action-batch capabilities first, as the TS wallet does.
        XCTAssertEqual(methods, ["getCapabilities", "createAction", "processAction", "listOutputs", "createAction", "processAction"])
    }

    /// Storage without the action batch holds the anchor as nosend. When the publish then
    /// cannot be funded, the anchor is aborted by its txid so its change is not left locked.
    func test_inscribeWithSigmaAbortsTheHeldAnchorWhenThePublishFailsWithoutABatch() async throws {
        let transport = PublishTransport(failingCreates: [1])
        let result = await Inscriptions.inscribe(
            try context(transport),
            Inscriptions.Request(content: Array("hi".utf8), contentType: "text/plain")
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "createAction", "processAction", "listOutputs", "createAction", "abortAction"])
        let processed = await transport.processed
        XCTAssertEqual(processed.count, 1)
        XCTAssertTrue(processed[0].isNoSend)
        let aborted = await transport.abortedReferences
        XCTAssertEqual(aborted, [processed[0].txid])
    }

    // MARK: Action batch (a wallet with a single unspent output)

    /// Storage that speaks the action batch reserves the wallet's one unspent output for the
    /// anchor; the publish spends the anchor and is funded by the anchor's change, which storage
    /// has not seen yet; one commit carries both. Ordinary createAction could not fund the publish.
    func test_inscribeWithSigmaFromASingleUTXOCommitsAnchorAndPublishInOneBatch() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport(actionBatch: .init(identity: identity))
        let request = Inscriptions.Request(
            content: Array("hello".utf8),
            contentType: "text/plain; charset=utf-8",
            map: [("name", "Hello")]
        )
        let result = await Inscriptions.inscribe(try context(transport), request, keyID: "inscribe-1")
        XCTAssertNil(result.error, result.error ?? "")

        // Neither action reaches createAction or processAction (the fake fails the test if they
        // do), the BAP identity is read between them, and nothing is aborted.
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "beginActionBatch", "listOutputs", "commitActionBatch"])
        let aborted = await transport.abortedBatches
        XCTAssertEqual(aborted, [])
        let processed = await transport.processed
        XCTAssertTrue(processed.isEmpty)
        let bodies = await transport.bodies

        // The anchor began the batch.
        let begin = try XCTUnwrap(try Self.params(bodies[1]).last?["firstAction"])
        XCTAssertEqual(begin["description"]?.stringValue, "Sigma anchor output")
        XCTAssertEqual(begin["isNoSend"], .bool(true))
        XCTAssertEqual(begin["outputs"]?.arrayValue?.map { $0["satoshis"]?.int64Value }, [2])

        // One commit, with a digest storage recomputes to the same value.
        let manifest = try XCTUnwrap(try Self.params(bodies[3]).last)
        XCTAssertTrue(try ActionBatchDigest.verify(manifest), "storage recomputes the same digest")
        let batchId = await transport.batchId
        XCTAssertEqual(manifest["batchId"]?.stringValue, try XCTUnwrap(batchId))
        let actions = try XCTUnwrap(manifest["actions"]?.arrayValue)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(
            actions.map { $0["metadata"]?["description"]?.stringValue },
            ["Sigma anchor output", "Create inscription"],
            "the anchor, then the publish that spends it"
        )
        XCTAssertEqual(actions.map { $0["metadata"]?["isNoSend"] }, [.bool(true), .bool(false)])
        let blobs = try XCTUnwrap(manifest["inlineBlobs"]?.members)
        let transactions = try actions.map { action -> Transaction in
            let bytes = try XCTUnwrap(blobs.first { $0.key == action["rawTxDigest"]?.stringValue }?.value.arrayValue)
                .compactMap { $0.int64Value.flatMap(UInt8.init(exactly:)) }
            return try Transaction(bytes: bytes, limits: WalletTransactionLimits.standard)
        }
        let anchorTx = transactions[0]
        let publishTx = transactions[1]
        let anchorTxid = try anchorTx.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let publishTxid = try publishTx.transactionID(limits: WalletTransactionLimits.standard).displayHex
        XCTAssertEqual(actions.map { $0["txid"]?.stringValue }, [anchorTxid, publishTxid])
        XCTAssertEqual(manifest["sendWith"], .strings([anchorTxid, publishTxid]))

        // The single reserved output funds the anchor; the anchor's output and its change fund
        // the publish.
        let reserved = await transport.fundingTransaction
        let funding = try XCTUnwrap(reserved)
        let fundingTxid = try funding.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let changeVout = try XCTUnwrap(
            actions[0]["plan"]?["noSendChangeOutputVouts"]?.arrayValue?.compactMap(\.int64Value).first
        )
        XCTAssertEqual(anchorTx.inputs.map(\.previousOutput.description), ["\(fundingTxid).0"])
        XCTAssertEqual(anchorTx.outputs.count, 2, "the anchor and its change")
        XCTAssertEqual(anchorTx.outputs[0].satoshis, 2)
        XCTAssertEqual(
            publishTx.inputs.map(\.previousOutput.description),
            ["\(anchorTxid).0", "\(anchorTxid).\(changeVout)"]
        )
        XCTAssertEqual(result.txid, publishTxid)

        // Every input is signed for what it spends, and each action pays storage's fee rate.
        let sources = [fundingTxid: funding, anchorTxid: anchorTx]
        for transaction in [anchorTx, publishTx] {
            var spent: UInt64 = 0
            for (index, input) in transaction.inputs.enumerated() {
                let source = try XCTUnwrap(sources[input.previousOutput.transactionID.displayHex])
                    .outputs[Int(input.previousOutput.outputIndex)]
                spent += source.satoshis
                let execution = try ScriptInterpreter.execute(
                    unlockingScript: input.unlockingScript,
                    lockingScript: source.lockingScript,
                    configuration: ScriptExecutionConfiguration(
                        era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                        resourceLimits: .standard
                    ),
                    context: ScriptExecutionContext(
                        transaction: transaction, inputIndex: index, spentOutput: source,
                        transactionLimits: WalletTransactionLimits.standard
                    )
                )
                XCTAssertEqual(execution.stack.last, [1])
            }
            let paid = transaction.outputs.reduce(UInt64(0)) { $0 + $1.satoshis }
            let size = try transaction.serialized(limits: WalletTransactionLimits.standard).count
            XCTAssertGreaterThanOrEqual(spent - paid, UInt64((Double(size) * 100 / 1000).rounded(.up)))
        }

        // The publish seals its inscription against anchor input 0, as without a batch.
        let inscription = publishTx.outputs[0]
        XCTAssertEqual(inscription.satoshis, 1)
        XCTAssertEqual(try XCTUnwrap(Inscription.decode(inscription.lockingScript)).content, Array("hello".utf8))
        _ = try SigmaAssert.sealed(inscription.lockingScript, anchorTxid: anchorTxid, identity: identity)
        let anchorKeyID = try CustomInstructions.parse(try XCTUnwrap(
            begin["outputs"]?.arrayValue?.first?["customInstructions"]?.stringValue
        )).keyID
        let anchorKey = try P1SATKey.privateKey(identity: identity, keyID: anchorKeyID)
        XCTAssertEqual(
            try ActionScript.payToPublicKeyHash(Address(publicKey: anchorKey.publicKey, network: .mainnet)).bytes,
            anchorTx.outputs[0].lockingScript.bytes
        )
    }

    func test_inscribeWithSigmaAbortsTheBatchOnceWhenTheCommitFails() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport(actionBatch: .init(
            identity: identity,
            commitError: ["name": "WERR_INVALID_OPERATION", "message": "commit refused"]
        ))
        let result = await Inscriptions.inscribe(
            try context(transport),
            Inscriptions.Request(content: Array("hi".utf8), contentType: "text/plain")
        )
        XCTAssertEqual(result.error, "commit refused")
        XCTAssertNil(result.txid)

        let methods = await transport.methods
        XCTAssertEqual(
            methods,
            ["getCapabilities", "beginActionBatch", "listOutputs", "commitActionBatch", "abortActionBatch"]
        )
        let aborted = await transport.abortedBatches
        let batchId = await transport.batchId
        XCTAssertEqual(aborted, [try XCTUnwrap(batchId)])
    }

    /// A batch refuses a member it cannot plan (here a description under the 5 bytes storage
    /// requires at commit) but stays open; TrackedAction releases it rather than leave the
    /// staged anchor's reservation locked until the lease lapses.
    func test_trackedActionReleasesTheBatchWhenAMemberCannotBePlanned() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport(actionBatch: .init(identity: identity))
        let ctx = try context(transport)
        let batch = ActionBatchController(storage: ctx.storage)
        let script = try ActionScript.payToPublicKeyHash(
            try P1SATKey.address(identity: identity, keyID: "anchor-test", counterparty: .self, forSelf: true, network: ctx.chain.network)
        ).bytes
        let anchor = try await TrackedAction.execute(
            ctx,
            description: "Sigma anchor output",
            outputs: [try WalletCreateActionOutput(lockingScript: script, satoshis: 2, outputDescription: "Sigma anchor")],
            options: TrackedAction.Options(bypassP1Sat: true, randomizeOutputs: false, noSend: true),
            batch: batch
        )
        XCTAssertNil(anchor.error)
        let anchorTxid = try XCTUnwrap(anchor.txid)
        let staged = await batch.isActive
        XCTAssertTrue(staged)

        let refused = try await TrackedAction.execute(
            ctx,
            description: "pub",
            inputBEEF: try AtomicBEEF(bytes: try XCTUnwrap(anchor.tx), limits: WalletBEEFLimits.standard).beef,
            inputs: [try WalletCreateActionInput(
                outpoint: try Outpoint("\(anchorTxid).0"),
                inputDescription: "Sigma anchor",
                unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
            )],
            outputs: [try WalletCreateActionOutput(lockingScript: script, satoshis: 1, outputDescription: "inscription")],
            options: TrackedAction.Options(bypassP1Sat: true, sendWith: [anchorTxid]),
            batch: batch,
            fundFrom: anchor.noSendChange ?? []
        )
        XCTAssertNotNil(refused.error)
        let active = await batch.isActive
        XCTAssertFalse(active)
        let aborted = await transport.abortedBatches
        let batchId = await transport.batchId
        XCTAssertEqual(aborted, [try XCTUnwrap(batchId)])
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "beginActionBatch", "abortActionBatch"])
    }

    // MARK: Collections (collections/index.ts mintWithSigma)

    func test_mintCollectionMatchesTheApplyStep() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let result = await Collections.mint(
            try context(transport),
            Collections.MintRequest(
                base64Content: "cm9vdA==",
                contentType: "image/png; profile=test",
                name: "Root",
                description: "Collection root",
                quantity: 2
            )
        )
        XCTAssertNil(result.error, result.error ?? "")
        let flow = try await assertApplyStepFlow(
            transport,
            identity: identity,
            description: "Create collection: Root",
            outputDescription: "Collection inscription",
            result: ActionResult(txid: result.txid, tx: result.tx)
        )
        XCTAssertEqual(result.collectionId, "\(try XCTUnwrap(result.txid))_0")
        XCTAssertEqual(
            flow.output["tags"] as? [String],
            storageTags(["type:image/png", "origin", "subType:collection", "id:\(flow.actionID)_0", "creator:\(flow.creator)"])
        )
        try assertCollectionCI(flow.output, name: "Root", collection: nil)
    }

    func test_mintCollectionItemMatchesTheApplyStep() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let collectionId = String(repeating: "b", count: 64) + "_1"
        let result = await Collections.mintItem(
            try context(transport),
            Collections.MintItemRequest(
                base64Content: "aW1hZ2U=",
                contentType: "image/png",
                name: "Item",
                collectionId: collectionId,
                mintNumber: 1
            )
        )
        XCTAssertNil(result.error, result.error ?? "")
        let flow = try await assertApplyStepFlow(
            transport,
            identity: identity,
            description: "Create collection item: Item",
            outputDescription: "Collection item inscription",
            result: result
        )
        XCTAssertEqual(
            flow.output["tags"] as? [String],
            storageTags([
                "type:image/png",
                "origin",
                "subType:collectionItem",
                "collection:\(collectionId)",
                "id:\(flow.actionID)_0",
                "creator:\(flow.creator)",
            ])
        )
        try assertCollectionCI(flow.output, name: "Item", collection: collectionId)
    }

    func test_collectionMintsReportARejectedBroadcastAsNoTxidReturned() async throws {
        let mint = await Collections.mint(
            try context(PublishTransport(sendWithStatus: "failed")),
            Collections.MintRequest(
                base64Content: "cm9vdA==",
                contentType: "text/plain",
                name: "Root",
                description: "Collection root",
                quantity: 1
            )
        )
        XCTAssertEqual(mint, Collections.MintResult(error: "no-txid-returned"))

        let item = await Collections.mintItem(
            try context(PublishTransport(sendWithStatus: "failed")),
            Collections.MintItemRequest(
                base64Content: "eA==",
                contentType: "text/plain",
                name: "Item",
                collectionId: String(repeating: "b", count: 64) + "_1"
            )
        )
        XCTAssertEqual(item.error, "no-txid-returned")
        XCTAssertNil(item.txid)
    }

    // MARK: Helpers

    private struct Flow {
        let actionID: String
        let creator: String
        let output: [String: Any]
        let lockingScript: Script
    }

    /// Checks the two actions the TS apply step makes: the 2-sat noSend anchor keyed
    /// `anchor-<actionId>`, then the publish of one sealed 1-sat ordinal spending the anchor at
    /// input 0, sent with the anchor rather than held back as noSend.
    private func assertApplyStepFlow(
        _ transport: PublishTransport,
        identity: PrivateKey,
        description: String,
        outputDescription: String,
        result: ActionResult
    ) async throws -> Flow {
        let methods = await transport.methods
        // The publish asks storage for its action-batch capabilities first, as the TS wallet does.
        XCTAssertEqual(methods, ["getCapabilities", "createAction", "processAction", "listOutputs", "createAction", "processAction"])
        let creates = try SigmaAssert.createActions(await transport.bodies)
        XCTAssertEqual(creates.map { $0["description"] as? String }, ["Sigma anchor output", description])

        let anchorArgs = creates[0]
        let anchorOptions = try XCTUnwrap(anchorArgs["options"] as? [String: Any])
        XCTAssertEqual(anchorOptions["noSend"] as? Bool, true)
        XCTAssertEqual(anchorOptions["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(anchorOptions["acceptDelayedBroadcast"] as? Bool, true)
        XCTAssertEqual(anchorArgs["labels"] as? [String], [])
        let anchorOutputs = try XCTUnwrap(anchorArgs["outputs"] as? [[String: Any]])
        XCTAssertEqual(anchorOutputs.count, 1)
        XCTAssertEqual((anchorOutputs[0]["satoshis"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(anchorOutputs[0]["basket"] as? String, OneSatConstants.sigmaBasket)
        XCTAssertEqual(anchorOutputs[0]["outputDescription"] as? String, "Sigma anchor")
        XCTAssertEqual(anchorOutputs[0]["tags"] as? [String], [])
        let anchorKeyID = try CustomInstructions.parse(
            try XCTUnwrap(anchorOutputs[0]["customInstructions"] as? String)
        ).keyID
        XCTAssertTrue(anchorKeyID.hasPrefix("anchor-"))
        let actionID = String(anchorKeyID.dropFirst("anchor-".count))
        XCTAssertEqual(actionID.count, 16)

        let processed = await transport.processed
        XCTAssertEqual(processed.count, 2)
        let anchor = processed[0]
        let publish = processed[1]
        let anchorTxid = anchor.txid
        XCTAssertEqual(anchor.sendWith, [])
        // TS completeSignedAction processes the publish with isDelayed false. The anchor, which TS
        // creates with acceptDelayedBroadcast true, goes through the same path here; noSend makes
        // storage hold it as nosend either way, until the publish sends it.
        XCTAssertTrue(anchor.isNoSend)
        XCTAssertFalse(anchor.isDelayed)
        XCTAssertFalse(publish.isNoSend)
        XCTAssertFalse(publish.isDelayed)

        let main = creates[1]
        let inputs = try XCTUnwrap(main["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(storageOutpoint(inputs[0]["outpoint"]), "\(anchorTxid).0")
        XCTAssertEqual(inputs[0]["inputDescription"] as? String, "Sigma anchor")
        XCTAssertEqual((inputs[0]["unlockingScriptLength"] as? NSNumber)?.intValue, 108)
        let options = try XCTUnwrap(main["options"] as? [String: Any])
        XCTAssertEqual(options["noSend"] as? Bool, false)
        XCTAssertEqual(main["isNoSend"] as? Bool, false)
        XCTAssertEqual(main["isSendWith"] as? Bool, true)
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, true)
        XCTAssertEqual(options["knownTxids"] as? [String], [anchorTxid])
        XCTAssertEqual(options["sendWith"] as? [String], [anchorTxid])
        XCTAssertEqual(options["noSendChange"] as? [String], [])
        // `trustSelf: 'known'` is set on the request (test_publishOptionsMatchTheApplyStep);
        // where the storage client carries it, it must say so.
        if let trustSelf = options["trustSelf"] {
            XCTAssertEqual(trustSelf as? String, "known")
        }

        let outputs = try XCTUnwrap(main["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        let output = outputs[0]
        XCTAssertEqual((output["satoshis"] as? NSNumber)?.intValue, 1)
        XCTAssertEqual(output["basket"] as? String, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(output["outputDescription"] as? String, outputDescription)

        // The publish goes out with the anchor, spending it at input 0 with the anchor key.
        XCTAssertEqual(publish.sendWith, [anchorTxid])
        XCTAssertEqual(result.txid, publish.txid)
        if let resultActionID = result.actionId {
            XCTAssertEqual(resultActionID, actionID)
        }
        let tx = publish.transaction
        XCTAssertEqual(tx.inputs[0].previousOutput.description, "\(anchorTxid).0")
        let anchorKey = try P1SATKey.privateKey(identity: identity, keyID: anchorKeyID)
        let unlock = try tx.inputs[0].unlockingScript.operations(
            maximumPushDataByteCount: ActionScript.maximumByteCount
        )
        XCTAssertEqual(unlock.last?.pushedData, anchorKey.publicKey.compressedBytes)
        XCTAssertEqual(
            try ActionScript.payToPublicKeyHash(Address(publicKey: anchorKey.publicKey, network: .mainnet)).bytes,
            anchor.transaction.outputs[0].lockingScript.bytes
        )

        let lockingScript = tx.outputs[0].lockingScript
        XCTAssertEqual(lockingScript.hex, output["lockingScript"] as? String)
        let creator = try SigmaAssert.sealed(lockingScript, anchorTxid: anchorTxid, identity: identity)
        return Flow(actionID: actionID, creator: creator, output: output, lockingScript: lockingScript)
    }

    /// `buildOrdinalCustomInstructions` with `counterparty: 'self'`, as the TS mints build it.
    private func assertCollectionCI(_ output: [String: Any], name: String, collection: String?) throws {
        let ci = try XCTUnwrap(output["customInstructions"] as? String)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ci.utf8)) as? [String: Any])
        XCTAssertEqual(object["counterparty"] as? String, "self")
        XCTAssertEqual(object["name"] as? String, name)
        XCTAssertEqual(object["collection"] as? String, collection)
        let keyID = try XCTUnwrap(object["keyID"] as? String)
        XCTAssertNotNil(Int64(keyID))
        let parsed = try CustomInstructions.parse(ci)
        XCTAssertEqual(parsed.counterparty, .self)
        // Key order as TS writes it: derivation, then counterparty, then remittance.
        XCTAssertNotNil(ci.range(of: #""keyID":"\#(keyID)","counterparty":"self""#), ci)
    }

    /// The JSON-RPC params of a captured request, in the order they were sent.
    private static func params(_ body: [UInt8]) throws -> [OrderedJSON] {
        try XCTUnwrap(try OrderedJSON.parse(body)["params"]?.arrayValue)
    }

    private func context(_ transport: PublishTransport) throws -> OneSatContext {
        let identity = try ActionVectors.identity()
        return OneSatContext(
            identity: identity,
            storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: transport),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }
}
