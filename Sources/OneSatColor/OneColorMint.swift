import Foundation
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates

public struct Mint1ColorResult: Equatable, Sendable {
    public var txid: String?
    /// Atomic BEEF of the mint.
    public var tx: [UInt8]?
    public var assetID: String?
    /// `<txid>.<vout>` of the continuing authority; nil when minting was ended.
    public var authorityOutpoint: String?
    /// True once `tm_color_<assetId>` accepted the transaction.
    public var submitted: Bool = false
    public var error: String?
}

/// Minting from an authority this wallet holds. `@1sat/actions` has no mint action; the
/// transaction is the one the BRC-207 module (`@bopen-io/color-permission-module` 0.2.3) builds
/// for a plan of `mint` plus an authority operation (`ColorPermissionModule.operations.test.ts`,
/// "mints with a selected authority and keeps a replacement authority").
extension OneColorActions {
    /// Mints `amount` units of an asset this wallet holds an authority for, to this wallet. The
    /// authority continues in a new output unless `endMinting` is set, which ends minting from this
    /// authority for good.
    ///
    /// When the overlay does not accept the broadcast mint, the result carries `txid`, `tx` and
    /// the error with `submitted` false; `resubmitMint` finishes it. Without the BEEF, the next send
    /// or mint that selects the minted outputs resubmits the wallet's own copy first.
    public static func mint(
        _ ctx: OneColorContext, assetID: String, amount: UInt64, endMinting: Bool = false
    ) async -> Mint1ColorResult {
        await mint(ctx, assetID: assetID, amount: amount, endMinting: endMinting, valueCustody: nil, authorityCustody: nil)
    }

    /// `mint` with the new outputs' custodies given, so tests can pin their keys to TS vectors.
    static func mint(
        _ ctx: OneColorContext, assetID assetText: String, amount: UInt64, endMinting: Bool,
        valueCustody: ColorCustody?, authorityCustody: ColorCustody?
    ) async -> Mint1ColorResult {
        var result = Mint1ColorResult()
        do {
            guard assetText != ColorIdentifiers.issue, let assetID = try? ColorAssetID(assetText) else {
                return Mint1ColorResult(error: "invalid-asset-id: expected <txid>_<vout>")
            }
            guard amount > 0 else { return Mint1ColorResult(error: "amount-must-be-positive") }
            let overlay = try ctx.requireOverlay()
            // TS `fund` checks the asset's support before funding it.
            try await ColorModule.assertSupportedAsset(overlay, assetID)

            let authorityOutputs = endMinting ? 0 : 1
            let operation = ColorOperations.authorityOperation(inputs: 1, outputs: authorityOutputs)
            let selected = try await ColorModule.selectInputs(
                ctx, overlay: overlay, assetID: assetID, role: .authority,
                target: UInt64(ColorOperations.authorityInputs(for: operation, outputs: authorityOutputs))
            )
            let built = try await mintRequest(
                ctx, assetID: assetID, amount: amount, endMinting: endMinting, authorities: selected,
                valueCustody: valueCustody, authorityCustody: authorityCustody
            )

            // signBound: every authority input must still be admitted and unspent.
            let admitted = try await ColorModule.spendable(overlay, assetID: assetID, outputs: selected.map(ColorModule.source))
            guard selected.allSatisfy({ admitted.contains($0.outpoint) }) else {
                throw ColorError.custody("a \(assetID) input is no longer spendable")
            }
            let signed = try await ColorExecutor.execute(ctx, request: built.request, tokenInputs: selected)
            let txid = signed.transactionID.displayHex
            let atomic = try signed.atomicBEEF()
            result.txid = txid
            result.tx = atomic
            result.assetID = assetID.description
            result.authorityOutpoint = built.authorityIndex.map { "\(txid).\($0)" }

            try await ColorModule.submit(overlay, topics: [ColorIdentifiers.topic(assetID)], beef: atomic)
            result.submitted = true
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
    }

    /// The mint request: the authority inputs, a value output of `amount` and, unless
    /// `endMinting`, a continuing authority, each a new `p color` output of this wallet; plan
    /// labels of `mint` and the authority operation, checked as the module checks them.
    static func mintRequest(
        _ ctx: OneColorContext, assetID: ColorAssetID, amount: UInt64, endMinting: Bool,
        authorities: [ColorManagedInput], valueCustody: ColorCustody?, authorityCustody: ColorCustody?
    ) async throws -> (request: WalletCreateActionRequest, authorityIndex: UInt32?) {
        var outputs = [try await ColorModule.newManagedOutput(
            ctx, assetID: assetID, amount: amount, custody: valueCustody, outputDescription: "Minted 1Color tokens"
        )]
        if !endMinting {
            outputs.append(try await ColorModule.newManagedOutput(
                ctx, assetID: assetID, amount: 0, role: .authority, custody: authorityCustody,
                outputDescription: "1Color mint authority"
            ))
        }
        let authorityOutputs = endMinting ? 0 : 1
        let required = try ColorOperations.required(
            inputs: ColorHolding(value: 0, authority: authorities.count),
            outputs: ColorHolding(value: amount, authority: authorityOutputs)
        )
        let plan = ColorPlan(
            assets: [.asset(assetID)],
            ownedOutputs: outputs.enumerated().map { index, output in
                ColorPlan.Remittance(
                    outputIndex: UInt32(index), asset: output.custody.asset,
                    derivationPrefix: output.custody.derivationPrefix,
                    derivationSuffix: output.custody.derivationSuffix,
                    senderIdentityKey: output.custody.senderIdentityKey
                )
            },
            operations: [
                .init(asset: .asset(assetID), operation: .mint),
                .init(asset: .asset(assetID), operation: ColorOperations.authorityOperation(
                    inputs: authorities.count, outputs: authorityOutputs
                )),
            ]
        )
        try ColorOperations.assertOperations(plan, assetID: assetID, required: required)
        let request = try WalletCreateActionRequest(
            description: endMinting
                ? "Mint \(amount) 1Color tokens and end minting" : "Mint \(amount) 1Color tokens",
            inputBEEF: try await ColorModule.inputBEEF(ctx, inputs: authorities),
            inputs: try ColorExecutor.tokenInputs(authorities),
            outputs: outputs.map { $0.output },
            labels: try plan.labels(),
            options: try ColorExecutor.options()
        )
        return (request, endMinting ? nil : 1)
    }

    /// Submits a mint that was broadcast but not accepted by the overlay. `tx` is the mint's
    /// Atomic BEEF from `Mint1ColorResult`: it must spend an authority of exactly one asset and
    /// carry no deploy.
    public static func resubmitMint(_ ctx: OneColorContext, tx: [UInt8]) async -> Mint1ColorResult {
        var result = Mint1ColorResult()
        do {
            let overlay = try ctx.requireOverlay()
            let atomic = try AtomicBEEF(bytes: tx, limits: beefLimits)
            guard let transaction = try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: ColorModule.txLimits) else {
                throw ColorError.invalid("mint transaction")
            }
            let topics = try ColorModule.topics(of: transaction, in: atomic.beef)
            guard topics.count == 1, let topic = topics.first, topic != ColorIdentifiers.discoveryTopic else {
                throw ColorError.invalid("mint transaction")
            }
            let spendsAuthority = try transaction.inputs.contains { input in
                let previous = input.previousOutput
                guard let source = try atomic.beef.transaction(for: previous.transactionID, limits: ColorModule.txLimits),
                      source.outputs.indices.contains(Int(previous.outputIndex)),
                      let token = ColorModule.read(source.outputs[Int(previous.outputIndex)].lockingScript, outpoint: previous)
                else { return false }
                return token.role == .authority && ColorIdentifiers.topic(token.assetID) == topic
            }
            guard spendsAuthority else { throw ColorError.invalid("mint transaction") }
            let txid = atomic.subjectTransactionID.displayHex
            result.txid = txid
            result.tx = tx
            result.assetID = String(topic.dropFirst("tm_color_".count))
            for (vout, output) in transaction.outputs.enumerated() {
                if let token = try? ColorTokenOutput.read(output.lockingScript, txid: txid, vout: UInt32(vout)),
                   token.role == .authority, ColorIdentifiers.topic(token.assetID) == topic {
                    result.authorityOutpoint = "\(txid).\(vout)"
                    break
                }
            }
            try await ColorModule.submit(overlay, topics: topics, beef: tx)
            result.submitted = true
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
    }

    /// Whether the wallet holds an authority output for the asset, from wallet state alone (no
    /// overlay call): a listed, spendable authority-basket output with custody and a suffix tag.
    public static func holdsAuthority(_ ctx: OneColorContext, assetID: ColorAssetID) async throws -> Bool {
        try await !ColorModule.candidates(ctx, assetID: assetID, role: .authority).isEmpty
    }
}
