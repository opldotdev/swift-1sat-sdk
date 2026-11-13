import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxBRC29
import ToolboxStorage

/// Tracked-action execute path from `utils/createTrackedAction.ts` + `completeSignedAction.ts`.
public enum TrackedAction {
    public struct Options: Equatable, Sendable {
        public var bypassP1Sat: Bool
        public var randomizeOutputs: Bool
        public var acceptDelayedBroadcast: Bool
        public var noSend: Bool
        public var noSendChange: [String]
        public var knownTxids: [String]
        public var sendWith: [String]
        /// `trustSelf: 'known'` lets storage accept inputs whose BEEF ancestry it already holds
        /// (the OrdLock v2 purchase apply step sets it for its front funding, the SIGMA apply
        /// step for its anchor). The remote `StorageClient` in swift-wallet-toolbox 5d8f781 does
        /// not put it on the wire yet, so both also send the full BEEF of what they spend.
        public var trustSelf: WalletTrustSelf?

        public init(
            bypassP1Sat: Bool = false,
            randomizeOutputs: Bool = true,
            acceptDelayedBroadcast: Bool = false,
            noSend: Bool = false,
            noSendChange: [String] = [],
            knownTxids: [String] = [],
            sendWith: [String] = [],
            trustSelf: WalletTrustSelf? = nil
        ) {
            self.bypassP1Sat = bypassP1Sat
            self.randomizeOutputs = randomizeOutputs
            self.acceptDelayedBroadcast = acceptDelayedBroadcast
            self.noSend = noSend
            self.noSendChange = noSendChange
            self.knownTxids = knownTxids
            self.sendWith = sendWith
            self.trustSelf = trustSelf
        }
    }

    public static func randomActionID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Hex.encode(bytes)
    }

    /// The managed `id:<actionId>_<index>` tag.
    public static func idTag(_ actionID: String, index: Int) -> String {
        "id:\(actionID)_\(index)"
    }

    /// Injects `id:<actionId>_<index>` on basketed outputs.
    ///
    /// An output that already carries exactly this tag, and no other `id:` tag, is left as is,
    /// so a caller that stamps the id before adding later tags keeps that order.
    ///
    /// The released local pipeline does not add a permission-module dispatch label;
    /// that routing label is opt-in in the TypeScript implementation.
    public static func applyTracking(
        outputs: [WalletCreateActionOutput],
        labels: [String],
        actionID: String,
        bypassP1Sat: Bool
    ) throws -> (outputs: [WalletCreateActionOutput], labels: [String]) {
        if bypassP1Sat {
            return (outputs, labels)
        }
        let tracked = try outputs.enumerated().map { index, output -> WalletCreateActionOutput in
            guard output.basket != nil else { return output }
            let tag = idTag(actionID, index: index)
            let others = output.tags.filter { !$0.hasPrefix("id:") }
            if output.tags.count == others.count + 1, output.tags.contains(tag) {
                return output
            }
            return try WalletCreateActionOutput(
                lockingScript: output.lockingScript,
                satoshis: output.satoshis,
                outputDescription: output.outputDescription,
                basket: output.basket,
                customInstructions: output.customInstructions,
                tags: others + [tag]
            )
        }
        return (tracked, labels)
    }

    /// Parses caller BEEF bytes. Empty or absent is no graph.
    public static func parseInputBEEF(_ bytes: [UInt8]?) throws -> BEEF? {
        guard let bytes, !bytes.isEmpty else { return nil }
        return try BEEF(bytes: bytes, limits: WalletBEEFLimits.standard)
    }

    /// Builds the ABI request `createTrackedAction` would send (`signAndProcess: false`).
    public static func request(
        description: String,
        inputBEEF: BEEF? = nil,
        inputs: [WalletCreateActionInput] = [],
        outputs: [WalletCreateActionOutput],
        labels: [String] = [],
        lockTime: UInt32? = nil,
        actionID: String,
        options: Options = Options()
    ) throws -> WalletCreateActionRequest {
        let tracked = try applyTracking(
            outputs: outputs,
            labels: labels,
            actionID: actionID,
            bypassP1Sat: options.bypassP1Sat
        )
        return try WalletCreateActionRequest(
            description: description,
            inputBEEF: inputBEEF,
            inputs: inputs.isEmpty ? nil : inputs,
            outputs: tracked.outputs,
            lockTime: lockTime,
            labels: tracked.labels.isEmpty ? nil : tracked.labels,
            options: WalletCreateActionOptions(
                signAndProcess: false,
                acceptDelayedBroadcast: options.acceptDelayedBroadcast,
                trustSelf: options.trustSelf,
                knownTransactionIDs: try options.knownTxids.map { try TransactionID(displayHex: $0) },
                noSend: options.noSend ? true : nil,
                noSendChange: options.noSendChange.isEmpty
                    ? nil
                    : try options.noSendChange.map { try Outpoint($0) },
                sendWith: try options.sendWith.map { try TransactionID(displayHex: $0) },
                randomizeOutputs: options.randomizeOutputs
            )
        )
    }

    /// Funds, verifies, signs mixed P1SAT + BRC-29 inputs, and processes.
    ///
    /// `ActionSigner.sign` refuses any input without BRC-29 derivation, so funding inputs
    /// are signed with the same `BRC29.receivingPrivateKey` + `signPayToPublicKeyHashInput`
    /// calls `ActionSigner` uses. Caller inputs are signed by `sign`.
    public static func execute(
        _ ctx: OneSatContext,
        description: String,
        inputBEEF: BEEF? = nil,
        inputs: [WalletCreateActionInput] = [],
        outputs: [WalletCreateActionOutput],
        labels: [String] = [],
        lockTime: UInt32? = nil,
        actionID: String? = nil,
        options: Options = Options(),
        batch: ActionBatchController? = nil,
        fundFrom: [String] = [],
        sign: @Sendable (Transaction) throws -> [UInt32: Script] = { _ in [:] }
    ) async throws -> ActionResult {
        let actionID = actionID ?? randomActionID()
        let createRequest = try request(
            description: description,
            inputBEEF: inputBEEF,
            inputs: inputs,
            outputs: outputs,
            labels: labels,
            lockTime: lockTime,
            actionID: actionID,
            options: options
        )
        // TS createAction asks the wallet's action batch to plan first and falls back to storage.
        let funded: StorageCreateActionResult
        do {
            if let batch, let planned = try await batch.plan(
                ctx.auth, createRequest, fundFrom: try fundFrom.map { try Outpoint($0) }
            ) {
                funded = planned
            } else {
                funded = try await ctx.storage.createAction(ctx.auth, createRequest)
            }
        } catch {
            return ActionResult.failure(error.localizedDescription, actionId: actionID)
        }

        do {
            try ActionAssembler.requireFeeWithin(ctx.maximumFee, for: funded)
            var transaction = try ActionAssembler.assemble(
                funded,
                requested: createRequest.outputs ?? [],
                changeKey: ctx.identity
            )
            applyRequestedSequences(inputs, onto: &transaction, funded: funded)

            let spends = try sign(transaction)
            for (index, script) in spends {
                let i = Int(index)
                guard transaction.inputs.indices.contains(i) else {
                    throw OneSatActionError.missingSourceTransaction(inputIndex: i)
                }
                transaction.inputs[i].unlockingScript = script
            }

            try signFundingInputs(
                &transaction,
                funded: funded,
                identity: ctx.identity,
                alreadySigned: Set(spends.keys.map(Int.init))
            )

            let signed = try SignedAction(funded: funded, transaction: transaction)
            // TS completeSignedAction: signAction runs with acceptDelayedBroadcast false and
            // noSend carried over from createAction, so a noSend action is held for its batch.
            let processed: StorageProcessActionResult
            if let batch, let staged = try await batch.process(
                ctx.auth, signed, sendWith: options.sendWith, isNoSend: options.noSend, isDelayed: false
            ) {
                processed = staged
            } else {
                processed = try await ctx.storage.processAction(
                    ctx.auth,
                    try signed.processRequest(sendWith: options.sendWith, isNoSend: options.noSend, isDelayed: false)
                )
            }
            if let failed = processed.sendWithResults.first(where: { $0.status != .unproven }) {
                return ActionResult.failure("broadcast-\(failed.status.rawValue)", actionId: actionID)
            }
            let changeOutpoints: [String]?
            if options.noSend {
                let txid = signed.transactionID.displayHex
                changeOutpoints = funded.outputs.filter(\.isChange).map { "\(txid).\($0.vout)" }
            } else {
                changeOutpoints = nil
            }
            return ActionResult(
                txid: signed.transactionID.displayHex,
                tx: try signed.atomicBEEF(),
                actionId: actionID,
                noSendChange: changeOutpoints
            )
        } catch {
            let reference = funded.reference
            if let batch, await batch.owns(reference: reference) {
                // Storage never saw a batch member on its own; releasing the batch frees its inputs.
                await batch.abort(ctx.auth)
            } else if let bytes = Data(base64Encoded: reference) {
                let abort = WalletAbortActionRequest(reference: try WalletBase64Data(Array(bytes)))
                _ = try? await ctx.storage.abortAction(ctx.auth, abort)
            }
            if let actionError = error as? OneSatActionError {
                return ActionResult.failure(actionError, actionId: actionID)
            }
            return ActionResult.failure(error.localizedDescription, actionId: actionID)
        }
    }

    /// `ActionAssembler` writes `0xffffffff` on every input. CLTV unlocks need the
    /// caller sequence from the request, matched by outpoint.
    static func applyRequestedSequences(
        _ requested: [WalletCreateActionInput],
        onto transaction: inout Transaction,
        funded: StorageCreateActionResult
    ) {
        for input in requested {
            guard let sequence = input.sequenceNumber else { continue }
            guard let fundedIndex = funded.inputs.firstIndex(where: {
                $0.sourceTXID.caseInsensitiveCompare(input.outpoint.transactionID.displayHex)
                    == .orderedSame
                    && $0.sourceVout == input.outpoint.outputIndex
            }) else { continue }
            guard transaction.inputs.indices.contains(fundedIndex) else { continue }
            transaction.inputs[fundedIndex].sequence = sequence
        }
    }

    /// Signs storage-chosen BRC-29 funding inputs. Caller-signed indexes are skipped.
    static func signFundingInputs(
        _ transaction: inout Transaction,
        funded: StorageCreateActionResult,
        identity: PrivateKey,
        alreadySigned: Set<Int>
    ) throws {
        for (index, input) in funded.inputs.enumerated() {
            if alreadySigned.contains(index) { continue }
            guard let prefix = input.derivationPrefix, let suffix = input.derivationSuffix else {
                continue
            }
            let sender: PublicKey
            if let senderHex = input.senderIdentityKey {
                let bytes = try Hex.decode(senderHex, maximumDecodedByteCount: 33)
                sender = try PublicKey(bytes)
            } else {
                sender = identity.publicKey
            }
            let spendingKey = try BRC29.receivingPrivateKey(
                recipient: identity,
                sender: sender,
                prefix: prefix,
                suffix: suffix
            )
            try transaction.signPayToPublicKeyHashInput(
                at: index,
                with: spendingKey,
                limits: WalletTransactionLimits.standard
            )
        }
    }
}
