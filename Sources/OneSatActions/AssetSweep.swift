import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import OneSatSweep

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

    /// `SWEEP_BATCH_SIZE` (`@1sat/actions` `sweep/types.ts`): ordinals and OpNS names per
    /// transaction in the CLI, sweep-ui and Yours.
    public static let batchSize = 25

    /// One plain-BSV output held by a legacy key.
    public struct FundingInput: Sendable {
        public let outpoint: String
        public let satoshis: UInt64
        public let lockingScript: [UInt8]
        public let key: PrivateKey

        public init(outpoint: String, satoshis: UInt64, lockingScript: [UInt8], key: PrivateKey) {
            self.outpoint = outpoint
            self.satoshis = satoshis
            self.lockingScript = lockingScript
            self.key = key
        }
    }

    /// Sweeps legacy BSV into the destination wallet as a wallet action (`sweepBsv`,
    /// `@1sat/actions` `sweep/index.ts`).
    ///
    /// A full sweep has no explicit outputs: the wallet's own change absorbs the value (less the
    /// fee) under its own derivation, so it can fund the asset sweeps that follow in the same run.
    /// With `amount` below the input total, one P2PKH output returns `total - amount` to the
    /// first input's address and the change receives `amount - fee`.
    ///
    /// `Sweep.build`, a raw transaction to an address, is unchanged and still available.
    public static func bsv(
        _ ctx: OneSatContext,
        inputs: [FundingInput],
        inputBEEF: BEEF,
        amount: UInt64? = nil
    ) async -> ActionResult {
        do {
            let plan: BsvPlan
            switch try bsvPlan(ctx, inputs: inputs, inputBEEF: inputBEEF, amount: amount) {
            case .failure(let reason): return ActionResult.failure(reason)
            case .ready(let ready): plan = ready
            }
            let keyMap = plan.keysByOutpoint
            return try await TrackedAction.execute(
                ctx,
                description: plan.description,
                inputBEEF: inputBEEF,
                inputs: plan.inputs,
                outputs: plan.outputs,
                options: TrackedAction.Options(randomizeOutputs: false),
                sign: { tx in
                    try signLegacyInputs(transaction: tx, keysByOutpoint: keyMap, inputBEEF: inputBEEF)
                }
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(describing: error)
        }
    }

    /// The `createAction` request ``bsv(_:inputs:inputBEEF:amount:)`` sends.
    struct BsvPlan {
        let description: String
        let inputs: [WalletCreateActionInput]
        let outputs: [WalletCreateActionOutput]
        let keysByOutpoint: [String: PrivateKey]
    }

    enum BsvPlanResult {
        case ready(BsvPlan)
        /// TS's error strings: `no-inputs`, `invalid-amount`, `insufficient-funds`.
        case failure(String)
    }

    static func bsvPlan(
        _ ctx: OneSatContext,
        inputs: [FundingInput],
        inputBEEF: BEEF,
        amount: UInt64?
    ) throws -> BsvPlanResult {
        guard let first = inputs.first else { return .failure("no-inputs") }
        var inputTotal: UInt64 = 0
        for input in inputs {
            let (sum, overflow) = inputTotal.addingReportingOverflow(input.satoshis)
            guard !overflow else { throw SweepError.amountsOverflow }
            inputTotal = sum
        }
        if let amount {
            guard amount > 0 else { return .failure("invalid-amount") }
            guard amount <= inputTotal else { return .failure("insufficient-funds") }
        }
        let partial: UInt64? = amount.flatMap { $0 < inputTotal ? $0 : nil }

        let sources = try sourceOutputs(inputBEEF)
        var createInputs: [WalletCreateActionInput] = []
        var keysByOutpoint: [String: PrivateKey] = [:]
        for (index, input) in inputs.enumerated() {
            let parsed = try parseOutpoint(input.outpoint)
            guard let source = sources[parsed.description] else {
                throw OneSatActionError.missingSourceTransaction(inputIndex: index)
            }
            keysByOutpoint[parsed.description] = input.key
            keysByOutpoint[parsed.ordinalDescription] = input.key
            createInputs.append(
                try WalletCreateActionInput(
                    outpoint: parsed,
                    inputDescription: "Legacy BSV \(input.outpoint)",
                    unlockingScriptLength: legacyUnlockingScriptLength(source),
                    sequenceNumber: 0xffff_ffff
                )
            )
        }

        var outputs: [WalletCreateActionOutput] = []
        if let partial {
            let sourceAddress = Address(publicKey: first.key.publicKey, network: ctx.chain.network)
            outputs.append(
                try WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(sourceAddress).bytes,
                    satoshis: inputTotal - partial,
                    outputDescription: "Return to legacy address"
                )
            )
        }
        let plural = inputs.count == 1 ? "" : "s"
        let description = partial.map { "Sweep \($0) sats from \(inputs.count) legacy BSV UTXO\(plural)" }
            ?? "Sweep \(inputs.count) legacy BSV UTXO\(plural)"
        return .ready(BsvPlan(
            description: description, inputs: createInputs, outputs: outputs, keysByOutpoint: keysByOutpoint
        ))
    }

    /// `scan.ts` `isListedOutput`: an OrdLock v2 listing (`ordlock2` tag) or a `list:` event.
    public static func isListed(events: [String]) -> Bool {
        events.contains(OneSatConstants.ordlockV2Tag) || events.contains(where: { $0.hasPrefix("list:") })
    }

    /// `scan.ts` `bsv21SweepBatches` / `bsv20SweepBatches`: each listed output in its own batch
    /// (so one invalid listing cannot sink the rest), then every unlisted output together.
    public static func listedBatches<T>(_ items: [T], events: (T) -> [String]) -> [[T]] {
        var batches: [[T]] = []
        var unlisted: [T] = []
        for item in items {
            if isListed(events: events(item)) { batches.append([item]) } else { unlisted.append(item) }
        }
        if !unlisted.isEmpty { batches.append(unlisted) }
        return batches
    }

    /// Splits `items` into runs of at most `size` (sweep-ui `chunk`).
    public static func batches<T>(_ items: [T], size: Int = batchSize) -> [[T]] {
        precondition(size > 0, "batch size must be positive")
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<Swift.min($0 + size, items.count)])
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
                        unlockingScriptLength: legacyUnlockingScriptLength(source)
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
            return ActionResult.failure(describing: error)
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

            let prepared = try prepareTokenInputs(inputs, inputBEEF: inputBEEF)
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
            return ActionResult.failure(describing: error)
        }
    }

    /// `sweepBsv21` response: the action result plus the outpoints it spent.
    public struct SweepBsv21Result: Equatable, Sendable {
        public let result: ActionResult
        /// The inputs the transaction spent, as the caller gave them: those the overlay
        /// reported valid. `nil` when nothing was spent.
        public let spentOutpoints: [String]?

        public init(result: ActionResult, spentOutpoints: [String]? = nil) {
            self.result = result
            self.spentOutpoints = spentOutpoints
        }

        public var txid: String? { result.txid }
        public var tx: [UInt8]? { result.tx }
        public var actionId: String? { result.actionId }
        public var error: String? { result.error }
        /// Why the overlay was not told about a broadcast sweep (`ActionResult.submitError`).
        public var submitError: String? { result.submitError }

        static func failure(_ error: OneSatActionError) -> Self {
            Self(result: ActionResult.failure(error))
        }

        static func failure(_ message: String) -> Self {
            Self(result: ActionResult.failure(message))
        }
    }

    /// Consolidates one BSV-21 token onto a P1SAT-derived output plus the overlay fee.
    ///
    /// Spends only the inputs the overlay reports `valid`: one invalid input in the transfer
    /// would burn the valid ones alongside it.
    public static func bsv21(
        _ ctx: OneSatContext,
        inputs: [TokenInput],
        inputBEEF: BEEF,
        feeAddress: String,
        feePerOutput: UInt64,
        symbol: String?,
        decimals: Int
    ) async -> SweepBsv21Result {
        guard let overlay = ctx.bsv21 else { return .failure(.servicesRequired) }
        do {
            guard !inputs.isEmpty else { return .failure("no-inputs") }
            let tokenID = inputs[0].tokenID
            guard inputs.allSatisfy({ $0.tokenID == tokenID }) else {
                return .failure("mixed-token-ids")
            }

            // Outpoints go out as the caller gave them; the overlay echoes them back as sent.
            let statuses: [Tokens.OutputStatus]
            do {
                statuses = try await overlay.outputStatus(
                    tokenId: tokenID,
                    outpoints: inputs.map(\.outpoint)
                )
            } catch {
                OneSatLog.error(error, "BSV-21 sweep: overlay output status for \(tokenID)", category: "OneSatActions")
                return .failure(.overlayValidationFailed)
            }
            let valid = Set(statuses.filter { $0.state == .valid }.map(\.outpoint))
            let spending = inputs.filter { valid.contains($0.outpoint) }
            guard !spending.isEmpty else { return .failure(.unvalidatedInputs) }

            let total = spending.reduce(UInt64(0)) { $0 + $1.amount }
            guard total > 0 else { return .failure("no-token-amount") }

            // TS fetches BEEF for the spent txids only; trim the caller's graph to match.
            let inputBEEF = spending.count == inputs.count
                ? inputBEEF
                : try ancestry(of: try spending.map { try parseOutpoint($0.outpoint).transactionID }, in: inputBEEF)
            let prepared = try prepareTokenInputs(spending, inputBEEF: inputBEEF)

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
                description: "Sweep \(spending.count) token UTXO\(spending.count == 1 ? "" : "s")",
                inputBEEF: inputBEEF,
                inputs: prepared.createInputs,
                outputs: outputs,
                labels: [OneSatConstants.tokenLabel(tokenID)],
                options: TrackedAction.Options(randomizeOutputs: false),
                sign: { tx in
                    try signLegacyInputs(transaction: tx, keysByOutpoint: prepared.keysByOutpoint, inputBEEF: inputBEEF)
                }
            )
            let submitted = await ActionResult.submitting(result) {
                try await overlay.submitTransfer(tx: $0, tokenId: tokenID)
            }
            guard submitted.error == nil else { return SweepBsv21Result(result: submitted) }
            return SweepBsv21Result(result: submitted, spentOutpoints: spending.map(\.outpoint))
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return SweepBsv21Result(result: ActionResult.failure(describing: error))
        }
    }

    private static func prepareTokenInputs(
        _ inputs: [TokenInput],
        inputBEEF: BEEF
    ) throws -> (createInputs: [WalletCreateActionInput], keysByOutpoint: [String: PrivateKey]) {
        let sources = try sourceOutputs(inputBEEF)
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
                    unlockingScriptLength: legacyUnlockingScriptLength(sources[parsed.description])
                )
            )
        }
        return (createInputs, keysByOutpoint)
    }

    /// Unlock reservation for a legacy input: an OrdLock v2 listing is spent by
    /// its cancel branch (up to ``OrdLockV2/cancelUnlockLength`` bytes), anything
    /// else by P2PKH. TS reserves the P2PKH length for both, which under-sizes
    /// the fee for a swept listing.
    static func legacyUnlockingScriptLength(_ source: TransactionOutput?) -> UInt32 {
        guard let source, OrdLockV2.isOrdLockV2(source.lockingScript) else {
            return OneSatConstants.p2pkhUnlockingScriptLength
        }
        return UInt32(OrdLockV2.cancelUnlockLength)
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
            // TS `assignLegacyUnlock`: a listed output's only seller spend is the
            // v2 cancel branch, so importing one cancels the listing.
            if OrdLockV2.isOrdLockV2(source.lockingScript) {
                spends[UInt32(index)] = try UnlockScripts.ordLockV2Cancel(
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

    /// The records of `beef` that `transactionIDs` and their ancestors need, in their original
    /// order. Proofs referenced only by dropped records are dropped and indexes remapped, so the
    /// funded graph stays an exact ancestry of the spend.
    static func ancestry(of transactionIDs: [TransactionID], in beef: BEEF) throws -> BEEF {
        let limits = WalletBEEFLimits.standard
        var entries: [TransactionID: BEEFTransaction] = [:]
        for entry in beef.transactions {
            entries[try entry.transactionID(limits: limits.transactionLimits)] = entry
        }
        var needed = Set<TransactionID>()
        var pending = transactionIDs
        while let transactionID = pending.popLast() {
            guard needed.insert(transactionID).inserted,
                  let transaction = entries[transactionID]?.transaction
            else { continue }
            pending.append(contentsOf: transaction.inputs.map(\.previousOutput.transactionID))
        }

        var retained: [BEEFTransaction] = []
        var retainedPaths = Set<Int>()
        var droppedPaths = Set<Int>()
        for entry in beef.transactions {
            let keep = needed.contains(try entry.transactionID(limits: limits.transactionLimits))
            if keep { retained.append(entry) }
            if let index = entry.merklePathIndex {
                if keep { retainedPaths.insert(index) } else { droppedPaths.insert(index) }
            }
        }
        var pathMap: [Int: Int] = [:]
        var paths: [MerklePath] = []
        for (index, path) in beef.merklePaths.enumerated()
            where retainedPaths.contains(index) || !droppedPaths.contains(index)
        {
            pathMap[index] = paths.count
            paths.append(path)
        }
        let remapped = retained.map { entry -> BEEFTransaction in
            guard case .rawWithMerklePath(let transaction, let index) = entry,
                  let mapped = pathMap[index]
            else { return entry }
            return .rawWithMerklePath(transaction: transaction, merklePathIndex: mapped)
        }
        return try BEEF(
            version: beef.version,
            merklePaths: paths,
            transactions: remapped,
            limits: limits
        )
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
