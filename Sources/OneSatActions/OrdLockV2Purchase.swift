import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// OrdLock v2 purchase apply: front funding plus the canonical layout.
///
/// Port of `@1sat/actions` `apply/ordlockPurchase.ts` (`applyOrdLockV2Purchase`).
/// The contract binds listing input `i` to the complete output `i`
/// (SIGHASH_SINGLE) and the listed satoshi follows first-sat ordering, so a
/// purchase is laid out as:
///
/// ```text
/// inputs:  0…m-1 front funding · m listing   · wallet fee inputs
/// outputs: 0…m-1 cushion/fillers · m payout  · receive · extras · wallet change
/// ```
///
/// Storage keeps explicit inputs in order, appends the funding inputs it
/// allocates after them, and appends change after the caller's outputs, but it
/// will not spend its own change as an explicit input. Front funding is
/// therefore a P1SAT P2PKH output parked in `1sat-deposit` under a short
/// `hold:` tag: an unexpired one is reused when it covers the payout, otherwise
/// a preparation action creates one first. The cushion (front funding minus
/// payout) goes back to the deposit basket under a fresh hold, and
/// ``SweepDeposit`` returns it to normal funding once the hold lapses.
public enum OrdLockV2Purchase {
    /// A spendable deposit-basket output usable as front funding.
    public struct FundingCandidate: Equatable, Sendable {
        public let outpoint: Outpoint
        public let satoshis: UInt64
        public let instructions: CustomInstructions

        public init(outpoint: Outpoint, satoshis: UInt64, instructions: CustomInstructions) {
            self.outpoint = outpoint
            self.satoshis = satoshis
            self.instructions = instructions
        }
    }

    /// The createAction shape of a laid-out purchase.
    public struct Layout: Sendable {
        public let inputs: [WalletCreateActionInput]
        public let outputs: [WalletCreateActionOutput]
        public let plan: OrdLockV2Spend.Plan
        /// Index of the listing input (equals the number of front funding inputs).
        public let listingInputIndex: Int
        /// Index of the buyer's receive output.
        public let receiveVout: Int
    }

    /// Most front funding inputs one purchase will combine.
    static let maximumFrontInputs = 4

    /// `selectFrontFunding`: the smallest single output that covers `needed`,
    /// else the largest few combined. nil when nothing does.
    public static func selectFrontFunding(
        _ candidates: [FundingCandidate],
        needed: UInt64
    ) -> [FundingCandidate]? {
        let ascending = candidates.sorted { $0.satoshis < $1.satoshis }
        if let single = ascending.first(where: { $0.satoshis >= needed }) {
            return [single]
        }
        var picked: [FundingCandidate] = []
        var sum: UInt64 = 0
        for candidate in ascending.reversed() {
            picked.append(candidate)
            let (next, overflow) = sum.addingReportingOverflow(candidate.satoshis)
            // A sum past UInt64.max covers any payout; planPurchase refuses the overflow.
            if overflow || next >= needed { return picked }
            sum = next
            if picked.count >= maximumFrontInputs { break }
        }
        return nil
    }

    /// `loadHeldFunding`: deposit-basket outputs still under hold, with their BEEF.
    public static func loadHeldFunding(
        _ ctx: OneSatContext,
        excluding: Set<String>,
        nowMilliseconds: UInt64
    ) async throws -> (candidates: [FundingCandidate], beef: BEEF?) {
        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.depositBasket,
                include: .entireTransactions,
                includeCustomInstructions: true,
                includeTags: true,
                pagination: WalletPagination(limit: 200)
            )
        )
        var candidates: [FundingCandidate] = []
        for output in listed.outputs {
            guard output.spendable,
                  let text = output.customInstructions,
                  OneSatConstants.isDepositHeld(output.tags, nowMilliseconds: nowMilliseconds),
                  !excluding.contains(output.outpoint.description),
                  let instructions = try? CustomInstructions.parse(text)
            else { continue }
            candidates.append(FundingCandidate(
                outpoint: output.outpoint,
                satoshis: output.satoshis,
                instructions: instructions
            ))
        }
        return (candidates, listed.beef)
    }

    /// P1SAT funding key: P2PKH locking script and its spend instructions.
    static func fundingKey(
        _ ctx: OneSatContext,
        keyID: String
    ) throws -> (lockingScript: Script, instructions: CustomInstructions) {
        let address = try P1SATKey.address(
            identity: ctx.identity,
            keyID: keyID,
            counterparty: .self,
            forSelf: true,
            network: ctx.chain.network
        )
        return (
            try ActionScript.payToPublicKeyHash(address),
            try CustomInstructions(keyID: keyID, counterparty: .self)
        )
    }

    /// The deposit output a purchase parks funding in: `ordlock-funding` plus a hold.
    static func heldDepositOutput(
        lockingScript: Script,
        satoshis: UInt64,
        description: String,
        instructions: CustomInstructions,
        nowMilliseconds: UInt64
    ) throws -> WalletCreateActionOutput {
        try WalletCreateActionOutput(
            lockingScript: lockingScript.bytes,
            satoshis: satoshis,
            outputDescription: description,
            basket: OneSatConstants.depositBasket,
            customInstructions: instructions.encoded(includeSelfCounterparty: true),
            tags: [
                OneSatConstants.ordlockFundingTag,
                OneSatConstants.depositHoldTag(
                    untilMilliseconds: nowMilliseconds + OneSatConstants.ordlockFundingHoldMilliseconds
                ),
            ]
        )
    }

    /// `prepareFrontFunding`: one held P2PKH output of `satoshis` in the deposit
    /// basket, broadcast now so the purchase built right after can spend it.
    public static func prepareFrontFunding(
        _ ctx: OneSatContext,
        keyID: String,
        satoshis: UInt64,
        nowMilliseconds: UInt64
    ) async throws -> (candidate: FundingCandidate, beef: BEEF) {
        let key = try fundingKey(ctx, keyID: keyID)
        let result = try await TrackedAction.execute(
            ctx,
            description: String("Fund OrdLock purchase (\(satoshis) sats)".prefix(50)),
            outputs: [
                try heldDepositOutput(
                    lockingScript: key.lockingScript,
                    satoshis: satoshis,
                    description: "OrdLock purchase funding",
                    instructions: key.instructions,
                    nowMilliseconds: nowMilliseconds
                ),
            ],
            options: TrackedAction.Options(
                bypassP1Sat: true, randomizeOutputs: false, acceptDelayedBroadcast: false
            )
        )
        // TS lets the wallet's own createAction error through unchanged.
        if let error = result.error {
            throw OneSatActionError.ordLockV2FrontFundingFailed(error)
        }
        guard let txid = result.txid, let tx = result.tx else {
            throw OneSatActionError.ordLockV2FrontFundingFailed(nil)
        }
        let beef = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard).beef
        return (
            FundingCandidate(
                outpoint: try Outpoint("\(txid).0"),
                satoshis: satoshis,
                instructions: key.instructions
            ),
            beef
        )
    }

    /// Lays one listing purchase out canonically (pure; no storage calls).
    ///
    /// - inputs: front funding first, then the listing with its exact unlock reservation;
    /// - outputs: cushion / fillers, the payout at the listing's index, the
    ///   basketed 1-sat receive, then `extras` (marketplace and overlay fees).
    public static func layout(
        listingOutpoint: Outpoint,
        listingScript: Script,
        listingInputDescription: String,
        receive: WalletCreateActionOutput,
        extras: [WalletCreateActionOutput],
        front: [FundingCandidate],
        cushion: WalletCreateActionOutput
    ) throws -> Layout {
        guard receive.basket != nil, receive.satoshis == 1 else {
            throw OneSatActionError.ordLockV2Refused(
                "ordlock.purchase apply: 1 listing input(s) need 1 basketed 1-sat receive output(s), found 0"
            )
        }
        let receiveScript = try Script(bytes: receive.lockingScript, maximumByteCount: ActionScript.maximumByteCount)
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: front.map(\.satoshis),
            listings: [listingScript],
            receives: [TransactionOutput(satoshis: 1, lockingScript: receiveScript)],
            cushionScript: try Script(bytes: cushion.lockingScript, maximumByteCount: ActionScript.maximumByteCount)
        )
        var outputs: [WalletCreateActionOutput] = []
        for (vout, planned) in plan.outputs.enumerated() {
            if vout == plan.cushionVout {
                outputs.append(try WalletCreateActionOutput(
                    lockingScript: cushion.lockingScript,
                    satoshis: planned.satoshis,
                    outputDescription: cushion.outputDescription,
                    basket: cushion.basket,
                    customInstructions: cushion.customInstructions,
                    tags: cushion.tags
                ))
            } else if plan.fillerVouts.contains(vout) {
                outputs.append(try WalletCreateActionOutput(
                    lockingScript: OrdLockV2Spend.fillerScriptBytes,
                    satoshis: 0,
                    outputDescription: "OrdLock index filler",
                    tags: []
                ))
            } else if plan.payoutVouts.contains(vout) {
                outputs.append(try WalletCreateActionOutput(
                    lockingScript: planned.lockingScript.bytes,
                    satoshis: planned.satoshis,
                    outputDescription: "Payment to seller",
                    tags: []
                ))
            } else {
                outputs.append(receive)
            }
        }
        outputs.append(contentsOf: extras)

        var inputs = try front.map {
            try WalletCreateActionInput(
                outpoint: $0.outpoint,
                inputDescription: "OrdLock purchase funding",
                unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
            )
        }
        inputs.append(try WalletCreateActionInput(
            outpoint: listingOutpoint,
            inputDescription: listingInputDescription,
            unlockingScriptLength: UInt32(try OrdLockV2.estimatePurchaseUnlockLength(listingScript))
        ))
        return Layout(
            inputs: inputs,
            outputs: outputs,
            plan: plan,
            listingInputIndex: front.count,
            receiveVout: plan.receiveVouts[0]
        )
    }

    /// Funds, lays out, signs and processes one OrdLock v2 purchase.
    ///
    /// `receive` is the buyer's basketed 1-sat output; `extras` are outputs that
    /// follow it (marketplace fee, overlay fee). The payout is read from the listing.
    public static func execute(
        _ ctx: OneSatContext,
        description: String,
        listingOutpoint: Outpoint,
        listingScript: Script,
        listingInputDescription: String,
        listingBEEF: BEEF,
        receive: WalletCreateActionOutput,
        extras: [WalletCreateActionOutput],
        labels: [String],
        nowMilliseconds: UInt64 = OneSatConstants.nowMilliseconds()
    ) async throws -> ActionResult {
        let needed = try OrdLockV2.payoutOutput(listingScript).satoshis
        let held = try await loadHeldFunding(
            ctx, excluding: [listingOutpoint.description], nowMilliseconds: nowMilliseconds
        )
        let applyID = TrackedAction.randomActionID()
        var front = selectFrontFunding(held.candidates, needed: needed)
        var fundingBEEF = held.beef
        if front == nil {
            let prepared = try await prepareFrontFunding(
                ctx,
                keyID: "\(OneSatConstants.ordlockFundingKeyPrefix) \(applyID)",
                satoshis: needed,
                nowMilliseconds: nowMilliseconds
            )
            front = [prepared.candidate]
            fundingBEEF = prepared.beef
        }
        let funding = front ?? []

        let cushionKey = try fundingKey(
            ctx, keyID: "\(OneSatConstants.ordlockFundingKeyPrefix) cushion \(applyID)"
        )
        let cushion = try heldDepositOutput(
            lockingScript: cushionKey.lockingScript,
            satoshis: 0,
            description: "OrdLock funding cushion",
            instructions: cushionKey.instructions,
            nowMilliseconds: nowMilliseconds
        )
        let laidOut = try layout(
            listingOutpoint: listingOutpoint,
            listingScript: listingScript,
            listingInputDescription: listingInputDescription,
            receive: receive,
            extras: extras,
            front: funding,
            cushion: cushion
        )

        var inputBEEF = listingBEEF
        if let fundingBEEF {
            inputBEEF = try inputBEEF.merging(fundingBEEF, limits: WalletBEEFLimits.standard)
        }
        let expectedInputs = funding.map(\.outpoint) + [listingOutpoint]
        let delivery = OrdLockV2Spend.DeliveryTarget(
            vout: laidOut.receiveVout,
            lockingScript: try Script(bytes: receive.lockingScript, maximumByteCount: ActionScript.maximumByteCount)
        )
        let listingIndex = laidOut.listingInputIndex
        let identity = ctx.identity
        return try await TrackedAction.execute(
            ctx,
            description: description,
            inputBEEF: inputBEEF,
            inputs: laidOut.inputs,
            outputs: laidOut.outputs,
            labels: labels,
            actionID: applyID,
            options: TrackedAction.Options(randomizeOutputs: false, trustSelf: .known)
        ) { transaction in
            // The sat map depends on the explicit inputs keeping their order.
            guard transaction.inputs.count >= expectedInputs.count,
                  Array(transaction.inputs.prefix(expectedInputs.count).map(\.previousOutput))
                    == expectedInputs
            else {
                throw OneSatActionError.ordLockV2Refused(
                    "ordlock.purchase apply: storage reordered the front funding and listing inputs"
                )
            }
            var spends: [UInt32: Script] = [:]
            for (index, candidate) in funding.enumerated() {
                spends[UInt32(index)] = try SignP2PKH.unlockingScript(
                    identity: identity,
                    transaction: transaction,
                    inputIndex: index,
                    protocolID: candidate.instructions.protocolID,
                    keyID: candidate.instructions.keyID,
                    counterparty: candidate.instructions.counterparty
                )
            }
            spends[UInt32(listingIndex)] = try UnlockScripts.ordLockV2Purchase(
                transaction: transaction,
                inputIndex: listingIndex,
                deliveries: [delivery]
            )
            return spends
        }
    }
}
