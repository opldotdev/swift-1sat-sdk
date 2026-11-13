import Foundation
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions

/// The SIGMA anchor-and-publish flow of `applyInscribeSigma` (`apply/inscribeSigma.ts`), shared by
/// `inscribe`, the collection mints and `deployOrdfsDir`.
///
/// TS builds the publish with a zeroed SIGMA tape, and the apply step then creates a 2-sat noSend
/// anchor keyed `anchor-<actionId>`, seals the tape against anchor input 0, puts the anchor at
/// input 0, and leaves the publish options below on the action. The publish is not `noSend`: it
/// goes out with the anchor in its `sendWith` batch.
enum SigmaPublish {
    /// The sealed script, its creator address, and the action id the anchor key is named after.
    struct Sealed: Sendable {
        let script: Script
        let creator: String
        let actionID: String

        /// The tags the TS apply step leaves on the sealed output: the caller's tags, then the
        /// managed `id:<actionId>_<index>` (`stampManagedOutputIds`), then `creator:` read from
        /// the sealed script (`stampScriptDerivedTags`).
        func tags(_ base: [String], index: Int) -> [String] {
            base.filter { !$0.hasPrefix("id:") && !$0.hasPrefix("creator:") }
                + [TrackedAction.idTag(actionID, index: index), "creator:\(creator)"]
        }
    }

    /// `sigmaAnchorKeyId` (`apply/inscribeSigma.ts`): the anchor key is named after the action
    /// id, so the anchor and the publish that spends it agree on it.
    static func anchorKeyID(_ actionID: String) -> String {
        "anchor-\(actionID)"
    }

    /// The options `applyInscribeSigma` leaves on the publish once the anchor exists: the
    /// anchor known and sent with the publish, and `trustSelf: 'known'`. The publish itself is
    /// not `noSend`.
    ///
    /// TS also copies the anchor's `noSendChange` onto the publish. Storage reads
    /// `noSendChange` only for a `noSend` action (wallet-toolbox `validateNoSendChange`), so on
    /// this publish it funds nothing; the BRC-100 options here refuse `noSendChange` without
    /// `noSend`, so it is left off rather than making the publish `noSend` to carry it.
    static func publishOptions(anchorTxid: String) -> TrackedAction.Options {
        TrackedAction.Options(
            randomizeOutputs: false,
            acceptDelayedBroadcast: true,
            knownTxids: [anchorTxid],
            sendWith: [anchorTxid],
            trustSelf: .known
        )
    }

    /// The error for a publish that returned no txid, where the TS action answers
    /// `no-txid-returned` (deploy and the collection mints).
    ///
    /// TS answers `no-txid-returned` whenever the tracked action comes back without a txid,
    /// which is where a signed action whose broadcast was rejected lands. A wallet failure
    /// there throws instead, and the action returns the thrown message; `TrackedAction` reports
    /// those as its error string, so they pass through.
    static func publishError(_ error: String?) -> String {
        guard let error, !error.hasPrefix("broadcast-") else {
            return OneSatActionError.noTxidReturned.wireMessage
        }
        return error
    }

    /// Creates the anchor, seals `script` against anchor input 0, and publishes the outputs
    /// `outputs` builds from the sealed script, spending the anchor at input 0.
    ///
    /// A wallet failure on the anchor comes back as its error string (TS throws the wallet's
    /// message); an anchor without a txid or transaction fails with the TS message.
    static func publish(
        _ ctx: OneSatContext,
        description: String,
        sealing script: Script,
        outputs: (Sealed) throws -> [WalletCreateActionOutput]
    ) async throws -> ActionResult {
        let actionID = TrackedAction.randomActionID()
        let anchorKeyID = anchorKeyID(actionID)
        // TS runs the anchor and the publish through the wallet's action batch, so the publish can
        // be funded from the anchor's change before either reaches storage.
        let batch = ActionBatchController(storage: ctx.storage)
        let anchorAddress = try P1SATKey.address(
            identity: ctx.identity,
            keyID: anchorKeyID,
            counterparty: .self,
            forSelf: true,
            network: ctx.chain.network
        )
        let anchor = try await TrackedAction.execute(
            ctx,
            description: "Sigma anchor output",
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(anchorAddress).bytes,
                    satoshis: 2,
                    outputDescription: "Sigma anchor",
                    basket: OneSatConstants.sigmaBasket,
                    customInstructions: try CustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: anchorKeyID
                    ).encoded()
                ),
            ],
            options: TrackedAction.Options(
                bypassP1Sat: true,
                randomizeOutputs: false,
                acceptDelayedBroadcast: true,
                noSend: true
            ),
            batch: batch
        )
        if let error = anchor.error {
            await batch.abort(ctx.auth)
            return ActionResult(error: error)
        }
        // Storage without an action batch took the anchor through processAction and holds it as
        // nosend. If the publish never sends it, abort it so its change is not left locked.
        // TS leaves the anchor held; storage accepts the txid as the reference of a nosend action.
        let batched = await batch.isActive
        func release() async {
            if batched {
                await batch.abort(ctx.auth)
            } else if let txid = anchor.txid {
                await abortHeldAnchor(ctx, txid: txid)
            }
        }
        guard let anchorTxid = anchor.txid, let anchorTx = anchor.tx else {
            await release()
            throw OneSatActionError.sigmaAnchorFailed
        }

        let result: ActionResult
        do {
            let sealed = try await Sigma.applyWithCreator(
                ctx,
                to: script,
                inputTxid: anchorTxid,
                inputVout: 0
            )
            result = try await publishSpending(
                ctx, anchorTxid: anchorTxid, anchorTx: anchorTx, anchorKeyID: anchorKeyID,
                anchorChange: anchor.noSendChange ?? [], description: description,
                outputs: try outputs(Sealed(script: sealed.script, creator: sealed.creator, actionID: actionID)),
                actionID: actionID, batch: batch
            )
        } catch {
            await release()
            throw error
        }
        // A committed batch is finished, so this only releases one the publish never committed.
        // A rejected broadcast already handed the anchor to the network with the publish.
        if let error = result.error, !error.hasPrefix("broadcast-") { await release() }
        return result
    }

    /// Aborts an anchor storage holds as nosend. Best effort: storage refuses one it has sent.
    private static func abortHeldAnchor(_ ctx: OneSatContext, txid: String) async {
        guard let reference = Data(base64Encoded: txid) else { return }
        guard let data = try? WalletBase64Data(Array(reference)) else { return }
        _ = try? await ctx.storage.abortAction(ctx.auth, WalletAbortActionRequest(reference: data))
    }

    /// The publish: spends the anchor at input 0, funded first from the anchor's change.
    private static func publishSpending(
        _ ctx: OneSatContext,
        anchorTxid: String,
        anchorTx: [UInt8],
        anchorKeyID: String,
        anchorChange: [String],
        description: String,
        outputs: [WalletCreateActionOutput],
        actionID: String,
        batch: ActionBatchController
    ) async throws -> ActionResult {
        try await TrackedAction.execute(
            ctx,
            description: description,
            inputBEEF: try AtomicBEEF(bytes: anchorTx, limits: WalletBEEFLimits.standard).beef,
            inputs: [
                try WalletCreateActionInput(
                    outpoint: try Outpoint("\(anchorTxid).0"),
                    inputDescription: "Sigma anchor",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: outputs,
            actionID: actionID,
            options: publishOptions(anchorTxid: anchorTxid),
            batch: batch,
            fundFrom: anchorChange,
            sign: { tx in
                [
                    0: try SignP2PKH.unlockingScript(
                        identity: ctx.identity,
                        transaction: tx,
                        inputIndex: 0,
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: anchorKeyID
                    ),
                ]
            }
        )
    }
}
