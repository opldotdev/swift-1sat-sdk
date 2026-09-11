import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// Moves legacy WIF-held ordinals and tokens onto P1SAT-derived outputs.
///
/// Matches `@1sat/actions` `sweepOrdinals` / `sweepBsv21` and `js-1sat-ord`
/// `transferOrdTokens` for BSV-20. Tokens leave as transfer inscriptions.
/// The destination wallet owns the new outputs through BRC-42 key IDs.
public enum AssetSweep {
    public struct OrdinalInput: Sendable {
        public let outpoint: String
        public let satoshis: UInt64
        public let lockingScript: [UInt8]
        public let contentType: String?
        public let origin: String?
        public let name: String?
        public let key: PrivateKey

        public init(
            outpoint: String,
            satoshis: UInt64,
            lockingScript: [UInt8],
            contentType: String?,
            origin: String?,
            name: String?,
            key: PrivateKey
        ) {
            self.outpoint = outpoint
            self.satoshis = satoshis
            self.lockingScript = lockingScript
            self.contentType = contentType
            self.origin = origin
            self.name = name
            self.key = key
        }
    }

    public struct TokenInput: Sendable {
        public let outpoint: String
        public let satoshis: UInt64
        public let lockingScript: [UInt8]
        public let tokenID: String
        public let amount: UInt64
        public let key: PrivateKey

        public init(
            outpoint: String,
            satoshis: UInt64,
            lockingScript: [UInt8],
            tokenID: String,
            amount: UInt64,
            key: PrivateKey
        ) {
            self.outpoint = outpoint
            self.satoshis = satoshis
            self.lockingScript = lockingScript
            self.tokenID = tokenID
            self.amount = amount
            self.key = key
        }
    }

    /// Transfers each 1-sat inscription to a P1SAT address keyed by its outpoint.
    public static func ordinals(
        _ ctx: OneSatContext,
        inputs: [OrdinalInput],
        inputBEEF: BEEF
    ) async -> ActionResult {
        do {
            guard !inputs.isEmpty else { return ActionResult.failure("no-inputs") }
            if inputs.contains(where: { $0.contentType == "application/bsv-20" }) {
                return ActionResult.failure(
                    "Cannot sweep BSV-20 through ordinal sweep — use a token transfer."
                )
            }

            let sources = try sourceOutputs(inputBEEF)
            var createInputs: [WalletCreateActionInput] = []
            var outputs: [WalletCreateActionOutput] = []
            var keysByOutpoint: [String: PrivateKey] = [:]

            for (index, input) in inputs.enumerated() {
                let parsed = try parseOutpoint(input.outpoint)
                guard let source = sources[parsed.description] else {
                    throw OneSatActionError.missingSourceTransaction(inputIndex: index)
                }
                guard source.satoshis == 1 else { throw OneSatActionError.invalidSatoshis }
                let keyID = parsed.ordinalDescription
                keysByOutpoint[parsed.description] = input.key
                keysByOutpoint[parsed.ordinalDescription] = input.key
                createInputs.append(
                    try WalletCreateActionInput(
                        outpoint: parsed,
                        inputDescription: "Ordinal \(keyID)",
                        unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                    )
                )
                outputs.append(try ordinalOutput(ctx, input: input, keyID: keyID))
            }

            let keyMap = keysByOutpoint
            let outpoints = createInputs.map(\.outpoint)
            return try await TrackedAction.execute(
                ctx,
                description: "Sweep \(inputs.count) ordinal\(inputs.count == 1 ? "" : "s")",
                inputBEEF: inputBEEF,
                inputs: createInputs,
                outputs: outputs,
                options: TrackedAction.Options(randomizeOutputs: false),
                sign: { tx in
                    guard tx.inputs.prefix(outpoints.count).map(\.previousOutput) == outpoints else {
                        throw LegacySweepError.ordinalInputOrderChanged
                    }
                    return try signLegacyInputs(transaction: tx, keysByOutpoint: keyMap, inputBEEF: inputBEEF)
                }
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    static func ordinalOutput(
        _ ctx: OneSatContext,
        input: OrdinalInput,
        keyID: String
    ) throws -> WalletCreateActionOutput {
        let address = try P1SATKey.address(
            identity: ctx.identity,
            keyID: keyID,
            counterparty: .self,
            forSelf: true,
            network: ctx.chain.network
        )
        let resolved = Ordinals.resolveOrdinalTags(
            outpoint: keyID,
            tags: nil,
            contentType: input.contentType,
            origin: input.origin,
            name: input.name
        )
        return try WalletCreateActionOutput(
            lockingScript: try ActionScript.payToPublicKeyHash(address).bytes,
            satoshis: 1,
            outputDescription: "Ordinal \(input.origin ?? keyID)",
            basket: resolved.basket,
            customInstructions: OrdinalRemittance.buildCustomInstructions(
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: keyID,
                counterparty: "self",
                tags: resolved.tags,
                name: resolved.name
            ),
            tags: resolved.tags
        )
    }

    /// Consolidates one tick-based BSV-20 token onto a P1SAT-derived transfer output.
    ///
    /// Matches `js-1sat-ord` `transferOrdTokens` for `TokenType.BSV20`:
    /// `{p:"bsv-20",op:"transfer",tick,amt}` locked to the destination.
    public static func bsv20(
        _ ctx: OneSatContext,
        inputs: [TokenInput],
        inputBEEF: BEEF,
        decimals: Int
    ) async -> ActionResult {
        do {
            guard !inputs.isEmpty else { return ActionResult.failure("no-inputs") }
            let tick = inputs[0].tokenID
            guard inputs.allSatisfy({ $0.tokenID == tick }) else {
                return ActionResult.failure("mixed-token-ids")
            }
            let total = inputs.reduce(UInt64(0)) { $0 + $1.amount }
            guard total > 0 else { return ActionResult.failure("no-token-amount") }

            let prepared = try prepareTokenInputs(inputs)
            let keyID = "bsv20:\(tick)-\(Int64(Date().timeIntervalSince1970 * 1000))"
            let address = try P1SATKey.address(
                identity: ctx.identity,
                keyID: keyID,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let recipient = try ActionScript.payToPublicKeyHash(address)
            let tokenScript = try Tokens.transferBsv20Script(
                tick: tick,
                amount: total,
                recipient: recipient
            )
            let tags = ["bsv20:\(tick)", "amt:\(total)", "sym:\(tick)", "dec:\(decimals)"]
            let outputs = [
                try WalletCreateActionOutput(
                    lockingScript: tokenScript.bytes,
                    satoshis: 1,
                    outputDescription: "Sweep \(total) \(tick)",
                    basket: OneSatConstants.bsv20Basket,
                    customInstructions: try CustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: keyID,
                        name: tick
                    ).encoded(),
                    tags: tags
                ),
            ]

            return try await TrackedAction.execute(
                ctx,
                description: "Sweep \(inputs.count) BSV-20 UTXO\(inputs.count == 1 ? "" : "s")",
                inputBEEF: inputBEEF,
                inputs: prepared.createInputs,
                outputs: outputs,
                labels: ["p 1sat bsv20 \(tick)"],
                options: TrackedAction.Options(randomizeOutputs: false),
                sign: { tx in
                    try signLegacyInputs(transaction: tx, keysByOutpoint: prepared.keysByOutpoint, inputBEEF: inputBEEF)
                }
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// Consolidates one BSV-21 token onto a P1SAT-derived output plus the overlay fee.
    public static func bsv21(
        _ ctx: OneSatContext,
        inputs: [TokenInput],
        inputBEEF: BEEF,
        feeAddress: String,
        feePerOutput: UInt64,
        symbol: String?,
        decimals: Int
    ) async -> ActionResult {
        do {
            guard !inputs.isEmpty else { return ActionResult.failure("no-inputs") }
            let tokenID = inputs[0].tokenID
            guard inputs.allSatisfy({ $0.tokenID == tokenID }) else {
                return ActionResult.failure("mixed-token-ids")
            }
            let total = inputs.reduce(UInt64(0)) { $0 + $1.amount }
            guard total > 0 else { return ActionResult.failure("no-token-amount") }

            if let overlay = ctx.bsv21 {
                let candidates = try inputs.map { try parseOutpoint($0.outpoint).description }
                let valid = try await overlay.validateUnspentOutputs(
                    tokenId: tokenID,
                    outpoints: candidates
                )
                let invalid = candidates.filter { !valid.contains($0) }
                if !invalid.isEmpty {
                    return ActionResult.failure(
                        "unvalidated-inputs: \(invalid.joined(separator: ", "))"
                    )
                }
            }

            let prepared = try prepareTokenInputs(inputs)

            let keyID = "\(tokenID)-\(Int64(Date().timeIntervalSince1970 * 1000))"
            let address = try P1SATKey.address(
                identity: ctx.identity,
                keyID: keyID,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let recipient = try ActionScript.payToPublicKeyHash(address)
            let tokenScript = try Tokens.transferScript(
                tokenId: tokenID,
                amount: total,
                recipient: recipient
            )
            let protocolID = try OneSatConstants.p1satProtocolID
            let outputs = [
                try WalletCreateActionOutput(
                    lockingScript: tokenScript.bytes,
                    satoshis: 1,
                    outputDescription: "Sweep \(total) tokens",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: Bsv21Remittance.buildCustomInstructions(
                        token: Bsv21Remittance.Fields(
                            id: tokenID,
                            amt: String(total),
                            op: "transfer",
                            symbol: symbol,
                            decimals: String(decimals)
                        ),
                        protocolID: protocolID,
                        keyID: keyID,
                        counterparty: "self"
                    ),
                    tags: Bsv21Remittance.filterTags(tokenId: tokenID)
                ),
                try WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(feeAddress).bytes,
                    satoshis: feePerOutput,
                    outputDescription: "Overlay processing fee"
                ),
            ]

            let result = try await TrackedAction.execute(
                ctx,
                description: "Sweep \(inputs.count) token UTXO\(inputs.count == 1 ? "" : "s")",
                inputBEEF: inputBEEF,
                inputs: prepared.createInputs,
                outputs: outputs,
                labels: [OneSatConstants.tokenLabel(tokenID)],
                options: TrackedAction.Options(randomizeOutputs: false),
                sign: { tx in
                    try signLegacyInputs(transaction: tx, keysByOutpoint: prepared.keysByOutpoint, inputBEEF: inputBEEF)
                }
            )
            if let tx = result.tx {
                try? await ctx.bsv21?.submitTransfer(tx: tx, tokenId: tokenID)
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    private static func prepareTokenInputs(
        _ inputs: [TokenInput]
    ) throws -> (createInputs: [WalletCreateActionInput], keysByOutpoint: [String: PrivateKey]) {
        var createInputs: [WalletCreateActionInput] = []
        var keysByOutpoint: [String: PrivateKey] = [:]
        for input in inputs {
            let parsed = try parseOutpoint(input.outpoint)
            keysByOutpoint[parsed.description] = input.key
            keysByOutpoint[parsed.ordinalDescription] = input.key
            createInputs.append(
                try WalletCreateActionInput(
                    outpoint: parsed,
                    inputDescription: "Token input \(parsed.ordinalDescription)",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                )
            )
        }
        return (createInputs, keysByOutpoint)
    }

    static func signLegacyInputs(
        transaction: Transaction,
        keysByOutpoint: [String: PrivateKey],
        inputBEEF: BEEF
    ) throws -> [UInt32: Script] {
        let sources = try sourceOutputs(inputBEEF)
        var transaction = transaction
        var spends: [UInt32: Script] = [:]
        for (index, input) in transaction.inputs.enumerated() {
            let parsed = input.previousOutput
            guard let key = keysByOutpoint[parsed.description]
                ?? keysByOutpoint[parsed.ordinalDescription]
            else { continue }
            guard let source = sources[parsed.description] else {
                throw OneSatActionError.missingSourceTransaction(inputIndex: index)
            }
            transaction.inputs[index].sourceOutput = source
            if OrdLock.isOrdLock(source.lockingScript) {
                spends[UInt32(index)] = try UnlockScripts.ordLockCancel(
                    privateKey: key, transaction: transaction, inputIndex: index
                )
            } else {
                spends[UInt32(index)] = try SignP2PKH.unlockingScript(
                    privateKey: key,
                    transaction: transaction,
                    inputIndex: index,
                    hashType: ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true)
                )
            }
        }
        return spends
    }

    private static func sourceOutputs(_ beef: BEEF) throws -> [String: TransactionOutput] {
        var outputs: [String: TransactionOutput] = [:]
        for transaction in beef.transactions.compactMap(\.transaction) {
            let txid = try transaction.transactionID(limits: WalletTransactionLimits.standard)
            for (index, output) in transaction.outputs.enumerated() {
                outputs[Outpoint(transactionID: txid, outputIndex: UInt32(index)).description] = output
            }
        }
        return outputs
    }

    private static func parseOutpoint(_ value: String) throws -> Outpoint {
        if let parsed = try? Outpoint(value) { return parsed }
        return try Outpoint(ordinal: value)
    }
}

private enum LegacySweepError: LocalizedError {
    case ordinalInputOrderChanged

    var errorDescription: String? { "Ordinal input order changed during funding" }
}
