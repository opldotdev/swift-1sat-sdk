import Foundation
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
import BSVInterpreter
import ToolboxActions
import OneSatTemplates

/// The parts of `@bopen-io/color-permission-module` 0.2.2 (no processing profiles) that a Swift
/// wallet runs itself, since it has no permissions manager in front of storage: input selection
/// against the overlay, resubmission of held outputs, the exact split before a handoff, the
/// source BEEF of token inputs, submission, and receipt verification.
enum ColorModule {
    static let beefLimits = WalletBEEFLimits.standard
    static let txLimits = WalletBEEFLimits.standard.transactionLimits

    // MARK: - Listing

    /// All outputs of one basket, with locking scripts and custom instructions.
    static func listBasket(
        _ ctx: OneColorContext, basket: String, tags: [String] = [], includeTags: Bool = false
    ) async throws -> [WalletOutput] {
        var outputs: [WalletOutput] = []
        while true {
            let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
                basket: basket, tags: tags, include: .lockingScripts, includeCustomInstructions: true,
                includeTags: includeTags ? true : nil,
                pagination: try WalletPagination(limit: OneColorConstants.listPageLimit, offset: UInt32(outputs.count))
            ))
            outputs += page.outputs
            if page.outputs.count < Int(OneColorConstants.listPageLimit) { return outputs }
        }
    }

    static func script(_ output: WalletOutput) throws -> Script {
        guard let bytes = output.lockingScript else { throw ColorError.custody("the wallet omitted a locking script") }
        return try Script(bytes: bytes, maximumByteCount: Int(txLimits.maximumScriptByteCount))
    }

    static func read(_ script: Script, outpoint: Outpoint) -> ColorTokenOutput? {
        try? ColorTokenOutput.read(script, txid: outpoint.transactionID.displayHex, vout: outpoint.outputIndex)
    }

    // MARK: - Selection

    struct Candidate {
        let output: WalletOutput
        let script: Script
        let token: ColorTokenOutput
    }

    static func candidates(_ ctx: OneColorContext, assetID: ColorAssetID, role: ColorTokenRole) async throws -> [Candidate] {
        let outputs = try await listBasket(ctx, basket: ColorIdentifiers.basket(assetID, role: role), includeTags: true)
        return outputs.compactMap { output in
            guard output.spendable, output.customInstructions != nil,
                  (output.tags ?? []).contains(where: ColorIdentifiers.isDerivationSuffixTag),
                  let script = try? script(output),
                  let token = read(script, outpoint: output.outpoint),
                  token.assetID == assetID, token.role == role else { return nil }
            return Candidate(output: output, script: script, token: token)
        }
    }

    /// TS `selectInputs`: admitted, unspent outputs of the asset's value or authority basket. For
    /// `.value`, `target` is units, covered largest first; for `.authority` it is a count of
    /// outputs, taken in listing order (all amounts are 0). Rejected outputs are skipped and the
    /// choice retried.
    static func selectInputs(
        _ ctx: OneColorContext, overlay: any ColorOverlayProvider, assetID: ColorAssetID,
        role: ColorTokenRole = .value, target: UInt64
    ) async throws -> [ColorManagedInput] {
        let candidates = try await candidates(ctx, assetID: assetID, role: role)
            .enumerated().sorted { $0.element.token.amount != $1.element.token.amount
                ? $0.element.token.amount > $1.element.token.amount : $0.offset < $1.offset }
            .map(\.element)
        var rejected: Set<String> = []
        while true {
            var chosen: [Candidate] = []
            var total: UInt64 = 0
            for candidate in candidates {
                if total >= target { break }
                if rejected.contains(candidate.output.outpoint.description) { continue }
                chosen.append(candidate)
                total += role == .value ? candidate.token.amount : 1
            }
            guard total >= target else {
                throw ColorError.custody("insufficient spendable \(role == .value ? "balance" : "authority") of \(assetID)")
            }
            if let selected = try await checkChosen(
                ctx, overlay: overlay, assetID: assetID, role: role, chosen: chosen, rejected: &rejected
            ) {
                return selected
            }
        }
    }

    static func checkChosen(
        _ ctx: OneColorContext, overlay: any ColorOverlayProvider, assetID: ColorAssetID, role: ColorTokenRole,
        chosen: [Candidate], rejected: inout Set<String>
    ) async throws -> [ColorManagedInput]? {
        var selected: [ColorManagedInput] = []
        var unreadable = false
        for candidate in chosen {
            if let input = await readableInput(ctx, candidate) {
                selected.append(input)
            } else {
                rejected.insert(candidate.output.outpoint.description)
                unreadable = true
            }
        }
        if unreadable { return nil }
        let admitted = try await spendable(overlay, assetID: assetID, outputs: selected.map(source))
        let unlisted = selected.filter { !admitted.contains($0.outpoint) }
        let recovered = try await resubmitHeld(ctx, overlay: overlay, assetID: assetID, role: role, outputs: unlisted.map(source))
        let missing = unlisted.filter { !recovered.contains($0.outpoint) }
        if missing.isEmpty { return selected }
        for input in missing { rejected.insert(input.outpoint) }
        return nil
    }

    static func readableInput(_ ctx: OneColorContext, _ candidate: Candidate) async -> ColorManagedInput? {
        guard let stored = candidate.output.customInstructions,
              let plaintext = await ColorMetadata.decrypt(stored, identity: ctx.identity),
              let custody = try? ColorCustody.parse(plaintext, label: "managed output customInstructions"),
              candidate.token.isSelected(by: custody.asset),
              let suffixTag = (candidate.output.tags ?? []).first(where: ColorIdentifiers.isDerivationSuffixTag) else {
            return nil
        }
        return ColorManagedInput(
            outpoint: candidate.output.outpoint.description, lockingScript: candidate.script,
            satoshis: candidate.output.satoshis, assetID: candidate.token.assetID, role: candidate.token.role,
            amount: candidate.token.amount, custody: custody, suffixTag: suffixTag
        )
    }

    struct SourceOutput {
        let outpoint: String
        let lockingScript: Script
        let satoshis: UInt64
    }

    static func source(_ input: ColorManagedInput) -> SourceOutput {
        SourceOutput(outpoint: input.outpoint, lockingScript: input.lockingScript, satoshis: input.satoshis)
    }

    // MARK: - Overlay

    /// The queried outputs the overlay reports admitted and unspent. An answer whose bytes differ
    /// from the source output fails.
    static func spendable(
        _ overlay: any ColorOverlayProvider, assetID: ColorAssetID, outputs: [SourceOutput]
    ) async throws -> Set<String> {
        if outputs.isEmpty { return [] }
        let outpoints = outputs.map(\.outpoint)
        let listed = try ColorOverlay.readOutputList(
            try await overlay.spendability(assetID: assetID, outpoints: outpoints), queried: outpoints
        )
        for output in outputs {
            if let answer = listed[output.outpoint],
               answer.satoshis != output.satoshis || answer.lockingScript.bytes != output.lockingScript.bytes {
                throw ColorError.overlay("the overlay answer for \(output.outpoint) does not match its source output")
            }
        }
        return Set(listed.keys)
    }

    /// The 0.1.0 support check: the overlay must report the asset's deploy as admitted, and the
    /// deploy must require no processing profiles.
    static func assertSupportedAsset(_ overlay: any ColorOverlayProvider, _ assetID: ColorAssetID) async throws {
        let outpoint = assetID.outpoint
        guard let deploy = try ColorOverlay.readOutputList(
            try await overlay.admission(assetID: assetID, outpoints: [outpoint]), queried: [outpoint]
        )[outpoint] else {
            throw ColorError.overlay("the overlay has no admitted deploy for \(assetID)")
        }
        guard let token = try ColorTokenOutput.read(deploy.lockingScript, txid: assetID.txid, vout: assetID.vout),
              token.deploy else {
            throw ColorError.overlay("\(assetID) is not a token deploy")
        }
    }

    /// Submits to the given topics, up to three attempts.
    static func submit(_ overlay: any ColorOverlayProvider, topics: [String], beef: [UInt8]) async throws {
        var failure: (any Error)?
        for _ in 0..<OneColorConstants.submitAttempts {
            do {
                _ = try await overlay.submit(topics: topics, beef: beef)
                return
            } catch {
                failure = error
            }
        }
        throw failure ?? ColorError.overlay("submit failed")
    }

    /// The topics a transaction goes to: the discovery topic for a deploy, and each asset that
    /// its inputs spend or its outputs carry.
    static func topics(of transaction: Transaction, in beef: BEEF) throws -> [String] {
        let txid = try transaction.transactionID(limits: txLimits).displayHex
        var assets: [ColorAssetID] = []
        func add(_ id: ColorAssetID) { if !assets.contains(id) { assets.append(id) } }
        for input in transaction.inputs {
            let previous = input.previousOutput
            guard let source = try beef.transaction(for: previous.transactionID, limits: txLimits),
                  source.outputs.indices.contains(Int(previous.outputIndex)),
                  let token = read(source.outputs[Int(previous.outputIndex)].lockingScript, outpoint: previous) else { continue }
            add(token.assetID)
        }
        var deploy = false
        for (vout, output) in transaction.outputs.enumerated() {
            guard let token = try? ColorTokenOutput.read(output.lockingScript, txid: txid, vout: UInt32(vout)) else { continue }
            if token.deploy { deploy = deploy || vout == 0 } else { add(token.assetID) }
        }
        return (deploy ? [ColorIdentifiers.discoveryTopic] : []) + assets.map(ColorIdentifiers.topic)
    }

    /// Resubmits the wallet's own copies of the transactions behind outputs the overlay does not
    /// report, then asks again.
    static func resubmitHeld(
        _ ctx: OneColorContext, overlay: any ColorOverlayProvider, assetID: ColorAssetID,
        role: ColorTokenRole, outputs: [SourceOutput]
    ) async throws -> Set<String> {
        if outputs.isEmpty { return [] }
        var txids: [TransactionID] = []
        for output in outputs {
            let id = try Outpoint(output.outpoint).transactionID
            if !txids.contains(id) { txids.append(id) }
        }
        var beef = try BEEF(merklePaths: [], transactions: [], limits: beefLimits)
        var offset: UInt32 = 0
        while try txids.contains(where: { try beef.entry(for: $0, limits: txLimits) == nil }) {
            let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
                basket: ColorIdentifiers.basket(assetID, role: role), include: .entireTransactions,
                pagination: try WalletPagination(limit: OneColorConstants.listPageLimit, offset: offset)
            ))
            if let pageBEEF = page.beef { beef = try beef.merging(pageBEEF, limits: beefLimits) }
            offset += UInt32(page.outputs.count)
            if page.outputs.count < Int(OneColorConstants.listPageLimit) { break }
        }
        for txid in txids {
            guard try beef.transaction(for: txid, limits: txLimits) != nil,
                  let atomic = try? ColorBEEF.atomic(txid, in: beef),
                  let held = try atomic.beef.transaction(for: txid, limits: txLimits),
                  let bytes = try? atomic.serialized(limits: beefLimits) else { continue }
            let topics = try topics(of: held, in: atomic.beef)
            guard !topics.isEmpty else { continue }
            // A refused resubmission leaves the output unlisted; the spendability check decides.
            _ = try? await overlay.submit(topics: topics, beef: bytes)
        }
        return try await spendable(overlay, assetID: assetID, outputs: outputs)
    }

    // MARK: - Source BEEF

    /// The source transactions of the inputs, each with its proof or unproven ancestors.
    static func inputBEEF(_ ctx: OneColorContext, inputs: [ColorManagedInput]) async throws -> BEEF? {
        if inputs.isEmpty { return nil }
        var beef = try BEEF(merklePaths: [], transactions: [], limits: beefLimits)
        var byBasket: [(String, [ColorManagedInput])] = []
        for input in inputs {
            if let source = input.sourceBEEF {
                beef = try beef.merging(try ColorBEEF.sources([input.outpoint], from: source), limits: beefLimits)
                continue
            }
            let basket = ColorIdentifiers.basket(input.assetID, role: input.role)
            if let index = byBasket.firstIndex(where: { $0.0 == basket }) {
                byBasket[index].1.append(input)
            } else {
                byBasket.append((basket, [input]))
            }
        }
        for (basket, selected) in byBasket {
            let sources = try await sourceTransactions(ctx, basket: basket, selected: selected)
            beef = try beef.merging(try ColorBEEF.sources(selected.map(\.outpoint), from: sources), limits: beefLimits)
        }
        return beef
    }

    /// The selected inputs' transactions, listed by suffix tag with `tagQueryMode: any`.
    static func sourceTransactions(_ ctx: OneColorContext, basket: String, selected: [ColorManagedInput]) async throws -> BEEF {
        let wanted = Set(selected.map(\.outpoint))
        var seen: Set<String> = []
        var found: Set<String> = []
        var sources = try BEEF(merklePaths: [], transactions: [], limits: beefLimits)
        var offset: UInt32 = 0
        var limit = min(UInt32(selected.count), OneColorConstants.listPageLimit)
        var total: UInt32?
        while true {
            let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
                basket: basket, tags: selected.map(\.suffixTag), tagQueryMode: .any, include: .entireTransactions,
                pagination: try WalletPagination(limit: limit, offset: offset)
            ))
            if let total, page.totalOutputs != total {
                throw ColorError.custody("the matching output count changed during listing")
            }
            total = page.totalOutputs
            for output in page.outputs {
                let outpoint = output.outpoint.description
                guard seen.insert(outpoint).inserted else { throw ColorError.custody("the listing repeated an output") }
                if wanted.contains(outpoint) { found.insert(outpoint) }
            }
            if let pageBEEF = page.beef { sources = try sources.merging(pageBEEF, limits: beefLimits) }
            if found == wanted { return sources }
            offset += UInt32(page.outputs.count)
            guard !page.outputs.isEmpty, let total, offset < total else {
                throw ColorError.custody("the wallet returned other outputs than the selected token inputs")
            }
            limit = min(OneColorConstants.listPageLimit, total - offset)
        }
    }

    // MARK: - Split

    /// A new token output this wallet keeps (TS `ownedOutput`): a value output of `amount`, or an
    /// authority output (`amount` must be 0), in the asset's basket for that role, with its custody
    /// encrypted and one suffix tag. `custody` defaults to new random derivation for this wallet.
    static func newManagedOutput(
        _ ctx: OneColorContext, assetID: ColorAssetID, amount: UInt64, role: ColorTokenRole = .value,
        custody given: ColorCustody? = nil, outputDescription: String = "BRC-207 token change"
    ) async throws -> (output: WalletCreateActionOutput, custody: ColorCustody, script: Script) {
        let custody = try given ?? ColorCustody(
            asset: .asset(assetID), derivationPrefix: ColorExecutor.randomBase64(),
            derivationSuffix: ColorExecutor.randomBase64(), senderIdentityKey: ctx.identityKey
        )
        guard custody.asset == .asset(assetID) else {
            throw ColorError.custody("an owned output remittance names another asset")
        }
        let key = try ColorKeys.ownPublicKey(identity: ctx.identity, custody: custody)
        let lock = OneColorLock.publicKeyHash(ColorKeys.hash160(key))
        let script: Script
        switch role {
        case .value:
            script = try OneColor.value(tokenID: assetID.description, amount: amount, lock: lock).lock()
        case .authority:
            guard amount == 0 else { throw ColorError.invalid("authority output amount") }
            script = try OneColor.authority(tokenID: assetID.description, lock: lock).lock()
        }
        let output = try WalletCreateActionOutput(
            lockingScript: script.bytes, satoshis: OneColorConstants.carrierSatoshis,
            outputDescription: outputDescription,
            basket: ColorIdentifiers.basket(assetID, role: role),
            customInstructions: try await ColorMetadata.encrypt(custody.json, identity: ctx.identity),
            tags: [custody.suffixTag]
        )
        return (output, custody, script)
    }

    /// Splits the selected inputs into an output of exactly `amount` and token change, broadcast
    /// and submitted, and returns the exact output as the handoff's input.
    static func split(
        _ ctx: OneColorContext, overlay: any ColorOverlayProvider, assetID: ColorAssetID,
        selected: [ColorManagedInput], amount: UInt64
    ) async throws -> ColorManagedInput {
        let change = selected.reduce(0) { $0 + $1.amount } - amount
        let exact = try await newManagedOutput(ctx, assetID: assetID, amount: amount)
        let rest = try await newManagedOutput(ctx, assetID: assetID, amount: change)
        let plan = ColorPlan(
            assets: [.asset(assetID)],
            ownedOutputs: [exact.custody, rest.custody].enumerated().map { index, custody in
                ColorPlan.Remittance(
                    outputIndex: UInt32(index), asset: custody.asset, derivationPrefix: custody.derivationPrefix,
                    derivationSuffix: custody.derivationSuffix, senderIdentityKey: custody.senderIdentityKey
                )
            },
            operations: [.init(asset: .asset(assetID), operation: .transfer)]
        )
        let request = try WalletCreateActionRequest(
            description: "Split tokens for a handoff",
            inputBEEF: try await inputBEEF(ctx, inputs: selected),
            inputs: try ColorExecutor.tokenInputs(selected),
            outputs: [exact.output, rest.output],
            labels: try plan.labels(),
            options: try ColorExecutor.options()
        )
        let signed = try await ColorExecutor.execute(ctx, request: request, tokenInputs: selected)
        let atomic = try signed.atomicBEEF()
        try await submit(overlay, topics: [ColorIdentifiers.topic(assetID)], beef: atomic)
        return ColorManagedInput(
            outpoint: "\(signed.transactionID.displayHex).0", lockingScript: exact.script,
            satoshis: OneColorConstants.carrierSatoshis, assetID: assetID, role: .value, amount: amount,
            custody: exact.custody, suffixTag: exact.custody.suffixTag,
            sourceBEEF: try AtomicBEEF(bytes: atomic, limits: beefLimits).beef
        )
    }

    // MARK: - Receipts

    /// Every input unlocks its source in the BEEF.
    static func assertUnlocks(_ transaction: Transaction, in beef: BEEF) throws {
        let configuration = try ScriptExecutionConfiguration(
            era: .afterGenesis, flags: [.enableForkID], resourceLimits: .standard
        )
        for (index, input) in transaction.inputs.enumerated() {
            let previous = input.previousOutput
            guard let source = try beef.transaction(for: previous.transactionID, limits: txLimits),
                  source.outputs.indices.contains(Int(previous.outputIndex)) else {
                throw ColorError.custody("transaction input \(index) lacks its source or unlocking script")
            }
            let spent = source.outputs[Int(previous.outputIndex)]
            var withSource = transaction
            withSource.inputs[index].sourceOutput = spent
            do {
                _ = try ScriptInterpreter.execute(
                    unlockingScript: input.unlockingScript, lockingScript: spent.lockingScript,
                    configuration: configuration,
                    context: ScriptExecutionContext(
                        transaction: withSource, inputIndex: index, spentOutput: spent, transactionLimits: txLimits
                    )
                )
            } catch {
                throw ColorError.custody("transaction input \(index) does not unlock its source")
            }
        }
    }

    /// `verifyReceipt`: the custody, the output's asset, role, owner and basket, the asset's
    /// support, and overlay admission. Returns the custody.
    static func verifyReceipt(
        _ ctx: OneColorContext, overlay: any ColorOverlayProvider, transaction: Transaction, txid: String,
        outputIndex: UInt32, basket: String, customInstructions: String
    ) async throws -> ColorCustody {
        guard let target = try ColorIdentifiers.parseBasket(basket) else {
            throw ColorError.custody("a receipt must name a per-asset value or authority basket")
        }
        let custody = try ColorCustody.parse(
            customInstructions, maxBytes: ColorCustody.maximumReceiptBytes, label: "receipt customInstructions"
        )
        guard transaction.outputs.indices.contains(Int(outputIndex)) else {
            throw ColorError.custody("the receipt names a missing output")
        }
        let source = transaction.outputs[Int(outputIndex)]
        guard let token = try ColorTokenOutput.read(source.lockingScript, txid: txid, vout: outputIndex) else {
            throw ColorError.custody("the received output is not a BRC-162 token output")
        }
        guard token.isSelected(by: custody.asset) else {
            throw ColorError.custody("the receipt instructions name a different asset than the output")
        }
        guard target.assetID == token.assetID, target.role == token.role else {
            throw ColorError.custody("the receipt basket does not match the received output")
        }
        try ColorKeys.assertOwned(token, custody: custody, identity: ctx.identity)
        try await assertSupportedAsset(overlay, token.assetID)
        let outpoint = "\(txid).\(outputIndex)"
        let admitted = try await spendable(overlay, assetID: token.assetID, outputs: [
            SourceOutput(outpoint: outpoint, lockingScript: source.lockingScript, satoshis: source.satoshis),
        ])
        guard admitted.contains(outpoint) else {
            throw ColorError.custody("the received output is not admitted and unspent in its asset overlay")
        }
        return custody
    }

    /// The assets a transaction's token inputs and outputs involve, in order.
    static func involvedAssets(_ transaction: Transaction, txid: String, in beef: BEEF) throws -> [ColorAssetID] {
        var assets: [ColorAssetID] = []
        func add(_ id: ColorAssetID) { if !assets.contains(id) { assets.append(id) } }
        for input in transaction.inputs {
            let previous = input.previousOutput
            guard let source = try beef.transaction(for: previous.transactionID, limits: txLimits),
                  source.outputs.indices.contains(Int(previous.outputIndex)),
                  let token = try ColorTokenOutput.read(
                    source.outputs[Int(previous.outputIndex)].lockingScript,
                    txid: previous.transactionID.displayHex, vout: previous.outputIndex
                  ) else { continue }
            add(token.assetID)
        }
        for (vout, output) in transaction.outputs.enumerated() {
            if let token = try ColorTokenOutput.read(output.lockingScript, txid: txid, vout: UInt32(vout)), !token.deploy {
                add(token.assetID)
            }
        }
        return assets
    }

    /// `withSuffixTag`: the caller's tags plus the custody's suffix tag, each once.
    static func withSuffixTag(_ tags: [String]?, _ custody: ColorCustody) -> [String] {
        var result: [String] = []
        for tag in (tags ?? []) + [custody.suffixTag] where !result.contains(tag) { result.append(tag) }
        return result
    }
}
