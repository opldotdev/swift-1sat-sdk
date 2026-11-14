import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// BSV-21 transfer from `packages/actions/src/tokens/index.ts` `sendBsv21`.
public enum Tokens {
    public struct Recipient: Sendable {
        public let amount: UInt64
        public let destination: Destination

        public init(amount: UInt64, destination: Destination) {
            self.amount = amount
            self.destination = destination
        }
    }

    public struct SendRequest: Sendable {
        public let tokenId: String
        public let recipients: [Recipient]

        public init(tokenId: String, recipients: [Recipient]) {
            self.tokenId = tokenId
            self.recipients = recipients
        }
    }

    public struct PurchaseRequest: Sendable {
        public let tokenId: String
        public let outpoint: Outpoint
        public let amount: UInt64
        public let marketplaceAddress: String?
        public let marketplaceRate: Double?

        public init(
            tokenId: String,
            outpoint: Outpoint,
            amount: UInt64,
            marketplaceAddress: String? = nil,
            marketplaceRate: Double? = nil
        ) {
            self.tokenId = tokenId
            self.outpoint = outpoint
            self.amount = amount
            self.marketplaceAddress = marketplaceAddress
            self.marketplaceRate = marketplaceRate
        }
    }

    /// Overlay state of a token outpoint (`Bsv21OutputState` in `@1sat/types`).
    public enum OutputState: String, Equatable, Sendable {
        /// Indexed and unspent.
        case valid
        /// Indexed and spent.
        case spent
        /// Waiting in the token's indexing queue.
        case queued
        /// Neither indexed nor queued.
        case unknown
    }

    public struct OutputStatus: Equatable, Sendable {
        /// The outpoint exactly as it was sent.
        public let outpoint: String
        public let state: OutputState

        public init(outpoint: String, state: OutputState) {
            self.outpoint = outpoint
            self.state = state
        }
    }

    /// Payment outputs that fund a token's overlay (`Bsv21FundingTemplate`).
    public struct FundingTemplate: Equatable, Sendable {
        public struct Output: Equatable, Sendable {
            public let lockingScript: [UInt8]
            public let satoshis: UInt64
            public let outputDescription: String

            public init(lockingScript: [UInt8], satoshis: UInt64, outputDescription: String) {
                self.lockingScript = lockingScript
                self.satoshis = satoshis
                self.outputDescription = outputDescription
            }
        }

        public let outputs: [Output]

        public init(outputs: [Output]) {
            self.outputs = outputs
        }
    }

    /// The token's overlay status (`TokenStatus`) after a funding submission.
    public struct OverlayStatus: Equatable, Sendable {
        public let isActive: Bool?
        public let feeAddress: String?
        public let feePerOutput: UInt64?
        public let minFunding: UInt64?

        public init(
            isActive: Bool?,
            feeAddress: String? = nil,
            feePerOutput: UInt64? = nil,
            minFunding: UInt64? = nil
        ) {
            self.isActive = isActive
            self.feeAddress = feeAddress
            self.feePerOutput = feePerOutput
            self.minFunding = minFunding
        }
    }

    /// `fundBsv21Overlay` response: the payment's action fields plus the overlay status.
    public struct FundOverlayResult: Equatable, Sendable {
        public let txid: String?
        public let tx: [UInt8]?
        public let actionId: String?
        public let error: String?
        public let status: OverlayStatus?

        public init(
            txid: String? = nil,
            tx: [UInt8]? = nil,
            actionId: String? = nil,
            error: String? = nil,
            status: OverlayStatus? = nil
        ) {
            self.txid = txid
            self.tx = tx
            self.actionId = actionId
            self.error = error
            self.status = status
        }

        public static func failure(_ error: OneSatActionError, actionId: String? = nil) -> Self {
            Self(actionId: actionId, error: error.wireMessage)
        }
    }

    public struct SelectedInput: Equatable, Sendable {
        public let output: WalletOutput
        public let amount: UInt64
    }

    public struct PreparedSend: Sendable {
        public let description: String
        public let inputs: [WalletCreateActionInput]
        public let outputs: [WalletCreateActionOutput]
        public let labels: [String]
        public let signers: [Ordinals.P2PKHSigner]
        public let change: UInt64
    }

    /// `BSV21.transfer(tokenId, amount).lock(recipientScript)`.
    public static func transferScript(
        tokenId: String,
        amount: UInt64,
        recipient: Script
    ) throws -> Script {
        try BSV21.transfer(tokenID: tokenId, amount: String(amount)).lock(lockingScript: recipient)
    }

    /// `BSV20.transfer(tick, amount).lock(recipientScript)`.
    public static func transferBsv20Script(
        tick: String,
        amount: UInt64,
        recipient: Script
    ) throws -> Script {
        try BSV20.transfer(tick: tick, amount: String(amount)).lock(lockingScript: recipient)
    }

    /// Walks token outputs in list order. With `states` (keyed by wallet outpoint `txid.vout`),
    /// only `valid` outputs are spent and `queued` ones are tallied to tell a shortfall that
    /// indexing will resolve (`tokens-queued`) from one it will not (`insufficient-valid-tokens`).
    public static func selectInputs(
        outputs: [WalletOutput],
        tokenId: String,
        amount: UInt64,
        states: [String: OutputState]?
    ) throws -> (selected: [SelectedInput], totalIn: UInt64) {
        let wanted = Bsv21Remittance.normalizeTokenId(tokenId)
        var selected: [SelectedInput] = []
        var totalIn: UInt64 = 0
        var queuedIn: UInt64 = 0
        for output in outputs {
            if totalIn >= amount { break }
            guard matchesToken(output, normalizedTokenId: wanted) else { continue }
            let fields = Bsv21Remittance.fields(from: output)
            guard let amtText = fields.amt, let utxoAmount = UInt64(amtText), utxoAmount > 0
            else { continue }
            if let states {
                let state = states[output.outpoint.description]
                if state == .queued {
                    let (sum, overflow) = queuedIn.addingReportingOverflow(utxoAmount)
                    queuedIn = overflow ? .max : sum
                }
                guard state == .valid else { continue }
            }
            selected.append(SelectedInput(output: output, amount: utxoAmount))
            totalIn += utxoAmount
        }
        if totalIn < amount {
            guard states != nil else { throw OneSatActionError.insufficientTokens }
            // Queued outputs are not invalid, just not indexed yet.
            let (pending, overflow) = totalIn.addingReportingOverflow(queuedIn)
            throw overflow || pending >= amount
                ? OneSatActionError.tokensQueued
                : OneSatActionError.insufficientValidTokens
        }
        return (selected, totalIn)
    }

    static func matchesToken(_ output: WalletOutput, normalizedTokenId: String) -> Bool {
        guard let id = Bsv21Remittance.fields(from: output).tokenId else { return false }
        return Bsv21Remittance.normalizeTokenId(id) == normalizedTokenId
    }

    public static func buildSend(
        identity: PrivateKey,
        tokenId: String,
        recipients: [Recipient],
        selected: [SelectedInput],
        totalIn: UInt64,
        details: Bsv21TokenDetails,
        network: BitcoinNetwork = .mainnet,
        changeKeyID: String
    ) throws -> PreparedSend {
        guard !recipients.isEmpty else { throw OneSatActionError.noRecipients }
        var resolvedAmounts: [UInt64] = []
        for recipient in recipients {
            guard recipient.amount > 0 else { throw OneSatActionError.amountMustBePositive }
            resolvedAmounts.append(recipient.amount)
        }
        let totalAmount = resolvedAmounts.reduce(0, +)
        guard totalIn >= totalAmount else { throw OneSatActionError.insufficientTokens }

        let fromTip = selected.first.map { Bsv21Remittance.fields(from: $0.output) }
        let tokenTags = Bsv21Remittance.filterTags(tokenId: tokenId)
        let protocolID = try OneSatConstants.p1satProtocolID
        func tokenFields(amount: UInt64) -> Bsv21Remittance.Fields {
            Bsv21Remittance.Fields(
                id: tokenId,
                amt: String(amount),
                op: "transfer",
                symbol: details.symbol ?? fromTip?.symbol,
                decimals: String(details.decimals),
                icon: details.icon ?? fromTip?.icon
            )
        }

        var outputs: [WalletCreateActionOutput] = []
        for (recipient, amount) in zip(recipients, resolvedAmounts) {
            let destination = try ResolveDestination.resolve(
                identity: identity,
                destination: recipient.destination,
                protocolID: protocolID,
                keyIDPrefix: tokenId,
                network: network
            )
            let script = try transferScript(
                tokenId: tokenId,
                amount: amount,
                recipient: destination.lockingScript
            )
            let isSelf = recipient.destination.counterparty == .self
                || destination.customInstructions?.counterparty == .self
            if isSelf {
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: script.bytes,
                        satoshis: 1,
                        outputDescription: "Send \(amount) tokens",
                        basket: OneSatConstants.bsv21Basket,
                        customInstructions: destination.customInstructions.map { instructions in
                            Bsv21Remittance.buildCustomInstructions(
                                token: tokenFields(amount: amount),
                                protocolID: protocolID,
                                keyID: instructions.keyID,
                                counterparty: "self"
                            )
                        },
                        tags: tokenTags
                    )
                )
            } else {
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: script.bytes,
                        satoshis: 1,
                        outputDescription: "Send \(amount) tokens"
                    )
                )
            }
        }

        let change = totalIn - totalAmount
        var tokenOutputCount = recipients.count
        if change > 0 {
            tokenOutputCount += 1
            let changeAddress = try P1SATKey.address(
                identity: identity,
                keyID: changeKeyID,
                counterparty: .self,
                forSelf: true,
                network: network
            )
            let changeScript = try transferScript(
                tokenId: tokenId,
                amount: change,
                recipient: ActionScript.payToPublicKeyHash(changeAddress)
            )
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: changeScript.bytes,
                    satoshis: 1,
                    outputDescription: "Token change",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: Bsv21Remittance.buildCustomInstructions(
                        token: tokenFields(amount: change),
                        protocolID: protocolID,
                        keyID: changeKeyID,
                        counterparty: "self"
                    ),
                    tags: tokenTags
                )
            )
        }

        try outputs.append(
            WalletCreateActionOutput(
                lockingScript: try ActionScript.payToPublicKeyHash(details.feeAddress).bytes,
                satoshis: details.feePerOutput * UInt64(tokenOutputCount),
                outputDescription: "Overlay processing fee",
                tags: []
            )
        )

        var signers: [Ordinals.P2PKHSigner] = []
        var inputs: [WalletCreateActionInput] = []
        var inputLabels: [String] = []
        for item in selected {
            try inputs.append(
                WalletCreateActionInput(
                    outpoint: item.output.outpoint,
                    inputDescription: "Token input",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                )
            )
            guard let instructions = item.output.customInstructions else {
                throw OneSatActionError.missingCustomInstructions
            }
            let parsed = try CustomInstructions.parse(instructions)
            signers.append(
                Ordinals.P2PKHSigner(
                    outpoint: item.output.outpoint,
                    protocolID: parsed.protocolID,
                    keyID: parsed.keyID,
                    counterparty: parsed.counterparty
                )
            )
            if let id = OneSatConstants.assetID(in: item.output.tags) {
                inputLabels.append(
                    OneSatConstants.inputAssetLabel(basket: OneSatConstants.bsv21Basket, id: id)
                )
            }
        }

        let symbol = details.symbol ?? String(tokenId.prefix(8))
        let description = recipients.count == 1
            ? "Send \(symbol) to 1 recipient"
            : "Send \(symbol) to \(recipients.count) recipients"
        return PreparedSend(
            description: description,
            inputs: inputs,
            outputs: outputs,
            labels: [OneSatConstants.tokenLabel(tokenId)] + inputLabels,
            signers: signers,
            change: change
        )
    }

    public static func send(
        _ ctx: OneSatContext,
        _ request: SendRequest
    ) async -> ActionResult {
        do {
            guard !request.recipients.isEmpty else {
                return ActionResult.failure(.noRecipients)
            }
            for recipient in request.recipients where recipient.amount == 0 {
                return ActionResult.failure(.amountMustBePositive)
            }
            guard let bsv21 = ctx.bsv21 else {
                return ActionResult.failure(.servicesRequired)
            }
            let details: Bsv21TokenDetails
            do {
                details = try await bsv21.tokenDetails(tokenId: request.tokenId, fresh: true)
            } catch {
                return ActionResult.failure(.tokenNotFound)
            }
            guard details.isActive else { return ActionResult.failure(.tokenNotActive) }

            let listed = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.bsv21Basket,
                    include: .entireTransactions,
                    includeCustomInstructions: true,
                    includeTags: true,
                    pagination: WalletPagination(limit: 10_000)
                )
            )
            let wanted = Bsv21Remittance.normalizeTokenId(request.tokenId)
            let tokenOutputs = listed.outputs.filter { matchesToken($0, normalizedTokenId: wanted) }
            // Spend only tips the overlay reports valid.
            var states: [String: OutputState] = [:]
            if !tokenOutputs.isEmpty {
                do {
                    let statuses = try await bsv21.outputStatus(
                        tokenId: request.tokenId,
                        outpoints: tokenOutputs.map(\.outpoint.description)
                    )
                    for status in statuses {
                        states[status.outpoint] = status.state
                    }
                } catch {
                    return ActionResult.failure(.overlayValidationFailed)
                }
            }
            let totalAmount = request.recipients.reduce(UInt64(0)) { $0 + $1.amount }
            let selected = try selectInputs(
                outputs: tokenOutputs,
                tokenId: request.tokenId,
                amount: totalAmount,
                states: states
            )
            let changeKeyID = "\(request.tokenId)-\(Int(Date().timeIntervalSince1970 * 1000))"
            let prepared = try buildSend(
                identity: ctx.identity,
                tokenId: request.tokenId,
                recipients: request.recipients,
                selected: selected.selected,
                totalIn: selected.totalIn,
                details: details,
                network: ctx.chain.network,
                changeKeyID: changeKeyID
            )
            let inputBEEF = try await resolveInputBEEF(
                listed: listed,
                selected: selected.selected,
                listings: ctx.listings
            )
            let result = try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                inputBEEF: inputBEEF,
                inputs: prepared.inputs,
                outputs: prepared.outputs,
                labels: prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                try Ordinals.signP2PKHInputs(ctx.identity, transaction, prepared.signers)
            }
            if let tx = result.tx {
                try? await bsv21.submitTransfer(tx: tx, tokenId: request.tokenId)
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func purchase(
        _ ctx: OneSatContext,
        _ request: PurchaseRequest
    ) async -> ActionResult {
        do {
            guard let bsv21 = ctx.bsv21, let listings = ctx.listings else {
                return ActionResult.failure(.servicesRequiredForPurchase)
            }
            do {
                let statuses = try await bsv21.outputStatus(
                    tokenId: request.tokenId,
                    outpoints: [request.outpoint.ordinalDescription]
                )
                guard statuses.first?.state == .valid else {
                    return ActionResult.failure(.listingNotFoundInOverlay)
                }
            } catch {
                return ActionResult.failure(.listingNotFoundInOverlay)
            }
            let details = try await bsv21.tokenDetails(tokenId: request.tokenId, fresh: true)
            let parsed = try await listings.beefGraph(forTxid: request.outpoint.transactionID.displayHex)
            let limits = WalletBEEFLimits.standard.transactionLimits
            guard let listingTx = parsed.transactions.compactMap(\.transaction).first(where: {
                (try? $0.transactionID(limits: limits).displayHex)
                    == request.outpoint.transactionID.displayHex
            }) else {
                return ActionResult.failure(.listingTransactionNotFound)
            }
            let vout = Int(request.outpoint.outputIndex)
            guard listingTx.outputs.indices.contains(vout) else {
                return ActionResult.failure(.listingOutputNotFound)
            }
            let listingOutput = listingTx.outputs[vout]
            // OrdLock v2 only; the vestigial TS v1 fallback is dropped on purpose (8fb809d5).
            guard OrdLockV2.isOrdLockV2(listingOutput.lockingScript) else {
                return ActionResult.failure(.notAnOrdLockListing)
            }

            let keyID = "\(request.tokenId)-\(request.outpoint.description)"
            let buyer = try P1SATKey.address(
                identity: ctx.identity,
                keyID: keyID,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let protocolID = try OneSatConstants.p1satProtocolID
            // Draft shape (TS): receive, payout, fees. The apply step lays it out.
            var outputs: [WalletCreateActionOutput] = [
                try WalletCreateActionOutput(
                    lockingScript: try transferScript(
                        tokenId: request.tokenId,
                        amount: request.amount,
                        recipient: ActionScript.payToPublicKeyHash(buyer)
                    ).bytes,
                    satoshis: 1,
                    outputDescription: "Purchased tokens",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: Bsv21Remittance.buildCustomInstructions(
                        token: Bsv21Remittance.Fields(
                            id: request.tokenId,
                            amt: String(request.amount),
                            op: "transfer",
                            symbol: details.symbol,
                            decimals: String(details.decimals),
                            icon: details.icon
                        ),
                        protocolID: protocolID,
                        keyID: keyID,
                        counterparty: "self"
                    ),
                    tags: Bsv21Remittance.filterTags(tokenId: request.tokenId)
                ),
            ]

            let payout = try OrdLockV2.payoutOutput(listingOutput.lockingScript)
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: payout.script.bytes,
                    satoshis: payout.satoshis,
                    outputDescription: "Payment to seller",
                    tags: []
                )
            )

            if let marketplaceAddress = request.marketplaceAddress,
               let marketplaceRate = request.marketplaceRate,
               marketplaceRate > 0 {
                let marketFee = UInt64((Double(payout.satoshis) * marketplaceRate).rounded(.up))
                if marketFee > 0 {
                    try outputs.append(
                        WalletCreateActionOutput(
                            lockingScript: try ActionScript.payToPublicKeyHash(marketplaceAddress)
                                .bytes,
                            satoshis: marketFee,
                            outputDescription: "Marketplace fee",
                            tags: []
                        )
                    )
                }
            }

            if details.isActive {
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: try ActionScript.payToPublicKeyHash(details.feeAddress).bytes,
                        satoshis: details.feePerOutput,
                        outputDescription: "Overlay processing fee",
                        tags: []
                    )
                )
            }

            let result = try await OrdLockV2Purchase.execute(
                ctx,
                description: "Purchase \(request.amount) tokens for \(payout.satoshis) sats",
                listingOutpoint: request.outpoint,
                listingScript: listingOutput.lockingScript,
                listingInputDescription: "Listed token",
                listingBEEF: parsed,
                receive: outputs[0],
                extras: Array(outputs.dropFirst(2)),
                labels: [OneSatConstants.tokenLabel(request.tokenId)]
            )
            if let tx = result.tx {
                try? await bsv21.submitTransfer(tx: tx, tokenId: request.tokenId)
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `tokens/index.ts` `fundBsv21Overlay`: pays the overlay's funding template as a plain
    /// payment, then submits it so the overlay starts indexing the token.
    public static func fundOverlay(
        _ ctx: OneSatContext,
        tokenId: String
    ) async -> FundOverlayResult {
        do {
            guard let bsv21 = ctx.bsv21 else { return .failure(.servicesRequired) }
            let template = try await bsv21.fundingTemplate(tokenId: tokenId)
            guard let first = template.outputs.first else { return .failure(.fundingNotNeeded) }
            let outputs = try template.outputs.map { output in
                try WalletCreateActionOutput(
                    lockingScript: output.lockingScript,
                    satoshis: output.satoshis,
                    outputDescription: output.outputDescription,
                    tags: []
                )
            }
            let result = try await TrackedAction.execute(
                ctx,
                description: first.outputDescription,
                outputs: outputs,
                options: TrackedAction.Options(acceptDelayedBroadcast: false)
            )
            if let error = result.error {
                return FundOverlayResult(actionId: result.actionId, error: error)
            }
            guard let txid = result.txid, let tx = result.tx else {
                return .failure(.noTxidReturned, actionId: result.actionId)
            }
            // The payment is broadcast either way; if the overlay misses this submission
            // it still finds the payment on its next fee-address check.
            do {
                let status = try await bsv21.submitFunding(tokenId: tokenId, beef: tx)
                return FundOverlayResult(txid: txid, tx: tx, actionId: result.actionId, status: status)
            } catch {
                return FundOverlayResult(
                    txid: txid,
                    tx: tx,
                    actionId: result.actionId,
                    error: OneSatActionError.fundingSubmitFailed.wireMessage
                )
            }
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return FundOverlayResult(error: error.localizedDescription)
        }
    }

    /// `tokens/index.ts` `sendBsv21`: prefer `listOutputs` BEEF, else `getBeefForTxid`.
    public static func resolveInputBEEF(
        listed: WalletListOutputsResult,
        selected: [SelectedInput],
        listings: (any ListingBeefSource)?
    ) async throws -> BEEF {
        if let beef = listed.beef {
            return beef
        }
        guard let listings else { throw OneSatActionError.noBeefAvailable }
        var txids: [String] = []
        for item in selected {
            let txid = item.output.outpoint.transactionID.displayHex
            if !txids.contains(txid) { txids.append(txid) }
        }
        guard let first = txids.first else { throw OneSatActionError.noBeefAvailable }
        var merged = try await listings.beefGraph(forTxid: first)
        for txid in txids.dropFirst() {
            let next = try await listings.beefGraph(forTxid: txid)
            merged = try merged.merging(next, limits: WalletBEEFLimits.standard)
        }
        return merged
    }
}
