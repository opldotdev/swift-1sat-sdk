import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// BSV-21 transfer from `packages/actions/src/tokens/index.ts` `sendBsv21`.
public enum Tokens {
    /// `tokens/index.ts:876` `unlockingScriptLength` for token purchase. Not the ordinal 1368.
    public static let purchaseUnlockingScriptLength: UInt32 = 1_402

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

    public static func selectInputs(
        outputs: [WalletOutput],
        tokenId: String,
        amount: UInt64,
        validOutpoints: Set<String>?
    ) throws -> (selected: [SelectedInput], totalIn: UInt64) {
        let wanted = Bsv21Remittance.normalizeTokenId(tokenId)
        var selected: [SelectedInput] = []
        var totalIn: UInt64 = 0
        for output in outputs {
            if totalIn >= amount { break }
            let fields = Bsv21Remittance.fields(from: output)
            guard let id = fields.tokenId,
                  Bsv21Remittance.normalizeTokenId(id) == wanted
            else { continue }
            guard let amtText = fields.amt, let utxoAmount = UInt64(amtText), utxoAmount > 0
            else { continue }
            if let validOutpoints, !validOutpoints.contains(output.outpoint.description) {
                continue
            }
            selected.append(SelectedInput(output: output, amount: utxoAmount))
            totalIn += utxoAmount
        }
        if totalIn < amount { throw OneSatActionError.insufficientTokens }
        return (selected, totalIn)
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
            let details = try await bsv21.tokenDetails(tokenId: request.tokenId)
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
            let valid: Set<String>
            do {
                valid = try await bsv21.validateUnspentOutputs(
                    tokenId: request.tokenId,
                    outpoints: listed.outputs.map(\.outpoint.description)
                )
            } catch {
                return ActionResult.failure(.overlayValidationFailed)
            }
            let totalAmount = request.recipients.reduce(UInt64(0)) { $0 + $1.amount }
            let selected = try selectInputs(
                outputs: listed.outputs,
                tokenId: request.tokenId,
                amount: totalAmount,
                validOutpoints: valid
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
                try await bsv21.validateOutput(
                    tokenId: request.tokenId,
                    outpoint: request.outpoint.ordinalDescription
                )
            } catch {
                return ActionResult.failure(.listingNotFoundInOverlay)
            }
            let details = try await bsv21.tokenDetails(tokenId: request.tokenId)
            let beef = try await listings.beef(forTxid: request.outpoint.transactionID.displayHex)
            let parsed = try BEEF(bytes: beef, limits: WalletBEEFLimits.standard)
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
            guard let decoded = OrdLock.decode(
                listingOutput.lockingScript,
                network: ctx.chain.network
            ) else {
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

            let payout = try Ordinals.payoutOutput(decoded.payout)
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

            let result = try await TrackedAction.execute(
                ctx,
                description: "Purchase \(request.amount) tokens for \(payout.satoshis) sats",
                inputBEEF: parsed,
                inputs: [
                    try WalletCreateActionInput(
                        outpoint: request.outpoint,
                        inputDescription: "Listed token",
                        unlockingScriptLength: purchaseUnlockingScriptLength
                    ),
                ],
                outputs: outputs,
                labels: [OneSatConstants.tokenLabel(request.tokenId)],
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                let index = try Ordinals.inputIndex(request.outpoint, in: transaction)
                return [
                    UInt32(index): try UnlockScripts.ordLockPurchase(
                        transaction: transaction, inputIndex: index
                    ),
                ]
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
        var merged = try BEEF(
            bytes: try await listings.beef(forTxid: first),
            limits: WalletBEEFLimits.standard
        )
        for txid in txids.dropFirst() {
            let next = try BEEF(
                bytes: try await listings.beef(forTxid: txid),
                limits: WalletBEEFLimits.standard
            )
            merged = try merged.merging(next, limits: WalletBEEFLimits.standard)
        }
        return merged
    }
}
