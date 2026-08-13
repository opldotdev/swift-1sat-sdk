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

    public static func selectInputs(
        outputs: [WalletOutput],
        tokenId: String,
        amount: UInt64,
        validOutpoints: Set<String>?
    ) throws -> (selected: [SelectedInput], totalIn: UInt64) {
        var selected: [SelectedInput] = []
        var totalIn: UInt64 = 0
        for output in outputs {
            if totalIn >= amount { break }
            guard let idTag = output.tags?.first(where: { $0.hasPrefix("bsv21:") }),
                  idTag.dropFirst(6) == tokenId
            else { continue }
            guard let amtTag = output.tags?.first(where: { $0.hasPrefix("amt:") }),
                  let utxoAmount = UInt64(amtTag.dropFirst(4))
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

        var outputs: [WalletCreateActionOutput] = []
        for (recipient, amount) in zip(recipients, resolvedAmounts) {
            let destination = try ResolveDestination.resolve(
                identity: identity,
                destination: recipient.destination,
                protocolID: try OneSatConstants.p1satProtocolID,
                keyIDPrefix: tokenId,
                network: network
            )
            let script = try transferScript(
                tokenId: tokenId,
                amount: amount,
                recipient: destination.lockingScript
            )
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: script.bytes,
                    satoshis: 1,
                    outputDescription: "Send \(amount) tokens"
                )
            )
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
            var tags = [
                "bsv21:\(tokenId)",
                "amt:\(change)",
                "dec:\(details.decimals)",
            ]
            if let symbol = details.symbol { tags.append("sym:\(symbol)") }
            if let icon = details.icon { tags.append("icon:\(icon)") }
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: changeScript.bytes,
                    satoshis: 1,
                    outputDescription: "Token change",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: try CustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: changeKeyID,
                        symbol: details.symbol
                    ).encoded(),
                    tags: tags
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
