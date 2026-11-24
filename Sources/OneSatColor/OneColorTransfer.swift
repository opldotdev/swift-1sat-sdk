import Foundation
import BSVScript
import BSVWallet
import ToolboxActions
import OneSatTemplates
import OneSatSweep

/// The result of `OneColorActions.transfer`.
package struct Transfer1ColorResult: Equatable, Sendable {
    package var txid: String?
    /// Atomic BEEF of the transfer.
    package var tx: [UInt8]?
    /// `<txid>.<vout>` of the token change kept in the asset's value basket; nil when the selected
    /// inputs covered the outputs exactly.
    package var changeOutpoint: String?
    /// True once `tm_color_<assetId>` admitted every token output of the transfer (its STEAK lists
    /// each of them). A 2xx answer that admits less leaves it false, with `error` set and `tx` kept.
    package var submitted: Bool = false
    package var error: String?

    package init() {}
}

/// A transfer whose token outputs the caller builds: the module's `createAction` for a
/// `p color plan` that declares one `transfer` and names no owned outputs, as skein-amm's pool
/// deploy sends it (`lp/poolDeploy.ts`: the pool output alone; "the module selects the token
/// inputs and adds their change").
extension OneColorActions {
    /// Transfers units of one asset to locking scripts the caller built, such as an Open Exchange
    /// pool: value inputs are selected to cover the token outputs, any excess comes back as token
    /// change after the requested outputs, and the broadcast transaction is submitted to the
    /// asset's topic.
    ///
    /// `outputs` are passed as given, in order. A BRC-162 value output of the asset is a
    /// destination and may not name a basket; any other non-token output passes through but may
    /// not enter a `p color` basket. `labels` are added after the plan labels and may not carry
    /// `p color` or BRC-177 labels: a handoff goes through `send`. `acceptDelayedBroadcast` is the
    /// caller's option, kept as the module keeps the caller's options (`...args`).
    ///
    /// Not in the TS, each defaulting to its behaviour: `inputOrder` `.confirmedFirst` selects
    /// token inputs proven first, then by least unproven ancestry; `funding` has the wallet's
    /// change chosen by the caller and the action sent in a second call (`ColorExecutor`).
    package static func transfer(
        _ ctx: OneColorContext, assetID: ColorAssetID, outputs: [WalletCreateActionOutput],
        description: String, labels: [String] = [], acceptDelayedBroadcast: Bool? = nil,
        inputOrder: ColorInputOrder = .largestFirst, funding: ColorFunding? = nil
    ) async -> Transfer1ColorResult {
        await transfer(
            ctx, assetID: assetID, outputs: outputs, description: description, labels: labels, changeCustody: nil,
            acceptDelayedBroadcast: acceptDelayedBroadcast, inputOrder: inputOrder, funding: funding
        )
    }

    /// `transfer` with the change custody given, so tests can pin its key to a TS vector.
    static func transfer(
        _ ctx: OneColorContext, assetID: ColorAssetID, outputs requested: [WalletCreateActionOutput],
        description: String, labels: [String], changeCustody: ColorCustody?, acceptDelayedBroadcast: Bool? = nil,
        inputOrder: ColorInputOrder = .largestFirst, funding: ColorFunding? = nil
    ) async -> Transfer1ColorResult {
        var result = Transfer1ColorResult()
        do {
            for label in labels where label.utf8.starts(with: "\(ColorIdentifiers.basketNamespace) ".utf8) {
                throw ColorError.custody("unknown p color label")
            }
            for label in labels where label.utf8.starts(with: "p nosend expiry ".utf8) {
                throw ColorError.custody("a transfer is not a handoff; send hands tokens over")
            }
            let plan = ColorPlan(assets: [.asset(assetID)], operations: [.init(asset: .asset(assetID), operation: .transfer)])
            let outputs = try ColorModule.planOutputs(requested, assetID: assetID)
            let overlay = try ctx.requireOverlay()
            // TS `fund`: the asset's support, then `fundAsset`.
            try await ColorModule.assertSupportedAsset(overlay, assetID)
            let selected = outputs.value > 0
                ? try await ColorModule.selectInputs(ctx, overlay: overlay, assetID: assetID, target: outputs.value, order: inputOrder)
                : []
            let selectedValue = try ColorModule.sumAmounts(selected)
            // Change returns what selection adds beyond the need.
            let change = selectedValue > 0 ? selectedValue - outputs.value : 0
            try ColorOperations.assertOperations(plan, assetID: assetID, required: try ColorOperations.required(
                inputs: ColorHolding(value: selectedValue),
                outputs: ColorHolding(value: outputs.value + change, authority: outputs.authority)
            ))

            var all = requested
            if change > 0 {
                all.append(try await ColorModule.newManagedOutput(ctx, assetID: assetID, amount: change, custody: changeCustody).output)
            }
            let request = try WalletCreateActionRequest(
                description: description,
                inputBEEF: try await ColorModule.inputBEEF(ctx, inputs: selected),
                inputs: try ColorExecutor.tokenInputs(selected),
                outputs: all,
                labels: try plan.labels() + labels,
                options: acceptDelayedBroadcast == nil
                    ? try ColorExecutor.options()
                    : try WalletCreateActionOptions(signAndProcess: false, acceptDelayedBroadcast: acceptDelayedBroadcast, randomizeOutputs: false)
            )

            // signBound: every token input must still be admitted and unspent.
            let admitted = try await ColorModule.spendable(overlay, assetID: assetID, outputs: selected.map(ColorModule.source))
            guard selected.allSatisfy({ admitted.contains($0.outpoint) }) else {
                throw ColorError.custody("a \(assetID) input is no longer spendable")
            }
            let signed = try await ColorExecutor.execute(ctx, request: request, tokenInputs: selected, funding: funding)
            // Broadcast: the txid is reported even if a later step throws.
            let txid = signed.transactionID.displayHex
            result.txid = txid
            if change > 0 { result.changeOutpoint = "\(txid).\(requested.count)" }
            let atomic = try signed.atomicBEEF()
            result.tx = atomic

            try await ColorModule.submit(overlay, topics: [ColorIdentifiers.topic(assetID)], beef: atomic)
            result.submitted = true
            return result
        } catch {
            OneSatLog.error(error, "1Color transfer failed", category: "OneSatColor")
            result.error = OneSatLog.localizedMessage(error)
            return result
        }
    }
}

extension ColorModule {
    /// The units and authority outputs the requested outputs send of the asset.
    struct PlannedOutputs: Equatable {
        var value: UInt64 = 0
        var authority = 0
    }

    /// TS `planOutputs` for a plan of one existing asset with no owned outputs, in output order: a
    /// non-token output passes unless it names a `p color` basket; a token output must be of the
    /// plan's asset, is not a deploy, and names no basket. Units are summed; authority outputs are
    /// counted for the operation check. A BRC-161 JSON output is not read here and passes as a
    /// non-token output (this wallet builds none).
    static func planOutputs(_ outputs: [WalletCreateActionOutput], assetID: ColorAssetID) throws -> PlannedOutputs {
        var planned = PlannedOutputs()
        for (index, output) in outputs.enumerated() {
            let script: Script
            do {
                script = try Script(bytes: output.lockingScript, maximumByteCount: Int(txLimits.maximumScriptByteCount))
            } catch {
                throw ColorError.invalid("output \(index) locking script")
            }
            guard let token = try ColorTokenOutput.read(script, txid: String(repeating: "0", count: 64), vout: UInt32(index)) else {
                if output.basket?.utf8.starts(with: "\(ColorIdentifiers.basketNamespace) ".utf8) == true {
                    throw ColorError.custody("a p color basket can only receive BRC-162 token outputs")
                }
                continue
            }
            // A deploy is filed under ISSUE, an asset this plan does not name.
            guard !token.deploy else {
                throw ColorError.custody("plan.assets must name exactly the assets the action moves")
            }
            guard token.assetID == assetID else {
                throw ColorError.custody("an output asset is missing from plan.assets")
            }
            switch token.role {
            case .value:
                let (sum, overflow) = planned.value.addingReportingOverflow(token.amount)
                guard !overflow else { throw ColorError.invalid("token output total") }
                planned.value = sum
            case .authority:
                planned.authority += 1
            }
            if output.basket != nil {
                throw ColorError.custody("only outputs in plan.ownedOutputs may enter a p color basket")
            }
        }
        return planned
    }
}
