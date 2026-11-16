import Foundation
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import OneSatSweep

/// A `p color plan` transfer whose token inputs the caller holds outside the module and signs
/// itself, its token outputs the wallet's own (plan `ownedOutputs`): `@bsv/color-permission-module`
/// 0.2.3 `createAction` with explicit foreign inputs, then `signAction` with the caller's spends,
/// as skein-amm's `moveBack` (market/activeSwap.ts) sends it through `runAppSignedAction`.
///
/// What the module does, in its order: each owned output must be a token output locked to this
/// wallet's key for its remittance, and is filed in the asset's basket with its custody (encrypted)
/// and a derivation-suffix tag; each explicit input whose source in `inputBEEF` is a token output
/// must be of a supported asset and admitted and unspent on its overlay ("a foreign token input is
/// not admitted and unspent in its overlay"), any other input passes through; the operations the
/// inputs and outputs imply must be the plan's. Before signing, the token inputs are asked again
/// ("a <asset> input is no longer spendable"); after the broadcast the transaction is submitted to
/// `tm_color_<asset>`. The module's `onResponse` throws a failure there; this port returns it as
/// `submitError` with the txid instead (deliberate: the tokens moved and were filed, so the
/// caller must still learn the transaction), and logs it.
///
/// This port selects no token inputs of the wallet's own: the explicit inputs must cover the token
/// outputs (a move back spends every row it moves). An explicit input that is one of the wallet's
/// own `p color` outputs is not classified as the module's managed input either: the swap basket's
/// rows never are.
package enum ColorAppSignedTransfer {
    /// A requested output the wallet keeps: its index and the custody it is locked to.
    package struct Owned: Sendable {
        package let outputIndex: Int
        package let custody: ColorCustody

        package init(outputIndex: Int, custody: ColorCustody) {
            self.outputIndex = outputIndex
            self.custody = custody
        }
    }

    static let txLimits = WalletTransactionLimits.standard

    package static func run(
        _ ctx: OneColorContext, assetID: ColorAssetID, description: String, inputBEEF: BEEF,
        inputs: [WalletCreateActionInput], outputs requested: [WalletCreateActionOutput], owned: [Owned],
        labels: [String], signCallerInputs: (Transaction) throws -> [Int: Script]
    ) async throws -> (txid: String, atomicBEEF: [UInt8], transaction: Transaction, submitError: String?) {
        for label in labels where label.utf8.starts(with: "\(ColorIdentifiers.basketNamespace) ".utf8) {
            throw ColorError.custody("unknown p color label")
        }
        for label in labels where label.utf8.starts(with: "p nosend expiry ".utf8) {
            throw ColorError.custody("a transfer is not a handoff; send hands tokens over")
        }
        let plan = ColorPlan(
            assets: [.asset(assetID)],
            ownedOutputs: try owned.map {
                guard $0.custody.asset == .asset(assetID) else {
                    throw ColorError.custody("an owned output remittance names another asset")
                }
                return ColorPlan.Remittance(
                    outputIndex: UInt32($0.outputIndex), asset: $0.custody.asset, derivationPrefix: $0.custody.derivationPrefix,
                    derivationSuffix: $0.custody.derivationSuffix, senderIdentityKey: $0.custody.senderIdentityKey
                )
            },
            operations: [.init(asset: .asset(assetID), operation: .transfer)]
        )
        for o in owned where o.outputIndex >= requested.count {
            throw ColorError.custody("plan.ownedOutputs names a missing output")
        }
        let overlay = try ctx.requireOverlay()

        // planOutputs: the owned outputs filed with their custody; the units each side carries.
        var planned = ColorHolding()
        var outputs: [WalletCreateActionOutput] = []
        for (index, output) in requested.enumerated() {
            let custody = owned.first { $0.outputIndex == index }?.custody
            let script: Script
            do {
                script = try Script(bytes: output.lockingScript, maximumByteCount: Int(txLimits.maximumScriptByteCount))
            } catch {
                throw ColorError.invalid("output \(index) locking script")
            }
            guard let token = try ColorTokenOutput.read(script, txid: String(repeating: "0", count: 64), vout: UInt32(index)) else {
                if custody != nil { throw ColorError.custody("plan.ownedOutputs names a non-token output") }
                if output.basket?.utf8.starts(with: "\(ColorIdentifiers.basketNamespace) ".utf8) == true {
                    throw ColorError.custody("a p color basket can only receive BRC-162 token outputs")
                }
                outputs.append(output)
                continue
            }
            guard !token.deploy else { throw ColorError.custody("plan.assets must name exactly the assets the action moves") }
            guard token.assetID == assetID else { throw ColorError.custody("an output asset is missing from plan.assets") }
            switch token.role {
            case .value:
                let (sum, overflow) = planned.value.addingReportingOverflow(token.amount)
                guard !overflow else { throw ColorError.invalid("token output total") }
                planned.value = sum
            case .authority:
                planned.authority += 1
            }
            guard let custody else {
                if output.basket != nil { throw ColorError.custody("only outputs in plan.ownedOutputs may enter a p color basket") }
                outputs.append(output)
                continue
            }
            try ColorKeys.assertOwned(token, custody: custody, identity: ctx.identity)
            let basket = ColorIdentifiers.basket(assetID, role: token.role)
            if let named = output.basket, named != basket {
                throw ColorError.custody("an owned output names the wrong p color basket")
            }
            outputs.append(try WalletCreateActionOutput(
                lockingScript: output.lockingScript, satoshis: output.satoshis, outputDescription: output.outputDescription,
                basket: basket, customInstructions: try await ColorMetadata.encrypt(custody.json, identity: ctx.identity),
                tags: ColorModule.withSuffixTag(output.tags)
            ))
        }

        // explicitInputs: a foreign token input counts once its overlay admits it.
        var seen = Set<String>()
        var explicit = ColorHolding()
        var foreign: [ColorModule.SourceOutput] = []
        for input in inputs {
            let outpoint = input.outpoint.description
            guard seen.insert(outpoint).inserted else { throw ColorError.custody("duplicate explicit input") }
            let previous = input.outpoint
            guard let source = try inputBEEF.transaction(for: previous.transactionID, limits: txLimits),
                  source.outputs.indices.contains(Int(previous.outputIndex)) else { continue }
            let spent = source.outputs[Int(previous.outputIndex)]
            guard let token = try ColorTokenOutput.read(spent.lockingScript, txid: previous.transactionID.displayHex, vout: previous.outputIndex) else {
                continue
            }
            try await ColorModule.assertSupportedAsset(overlay, token.assetID)
            let output = ColorModule.SourceOutput(outpoint: outpoint, lockingScript: spent.lockingScript, satoshis: spent.satoshis)
            guard try await ColorModule.spendable(overlay, assetID: token.assetID, outputs: [output]).contains(outpoint) else {
                throw ColorError.custody("a foreign token input is not admitted and unspent in its overlay")
            }
            guard token.assetID == assetID else { throw ColorError.custody("plan.assets must name exactly the assets the action moves") }
            switch token.role {
            case .value:
                let (sum, overflow) = explicit.value.addingReportingOverflow(token.amount)
                guard !overflow else { throw ColorError.invalid("token input total") }
                explicit.value = sum
            case .authority:
                explicit.authority += 1
            }
            foreign.append(output)
        }

        // fundAsset: nothing selected here; the operations the action implies are the plan's.
        try await ColorModule.assertSupportedAsset(overlay, assetID)
        guard planned.value <= explicit.value else {
            throw ColorError.custody("the explicit token inputs carry \(explicit.value) of \(assetID), the outputs \(planned.value): this action selects no inputs of its own")
        }
        try ColorOperations.assertOperations(plan, assetID: assetID, required: try ColorOperations.required(inputs: explicit, outputs: planned))

        let request = try WalletCreateActionRequest(
            description: description,
            inputBEEF: inputBEEF,
            inputs: inputs,
            outputs: outputs,
            labels: try plan.labels() + labels,
            options: try WalletCreateActionOptions(signAndProcess: false, acceptDelayedBroadcast: false, randomizeOutputs: false)
        )
        // signBound: every token input must still be admitted and unspent.
        if !foreign.isEmpty {
            let admitted = try await ColorModule.spendable(overlay, assetID: assetID, outputs: foreign)
            guard foreign.allSatisfy({ admitted.contains($0.outpoint) }) else {
                throw ColorError.custody("a \(assetID) input is no longer spendable")
            }
        }
        let signed = try await ColorExecutor.execute(ctx, request: request, signCallerInputs: signCallerInputs)
        // Broadcast, the owned outputs filed: from here the txid is reported whatever fails.
        let txid = signed.transactionID.displayHex
        let atomic: [UInt8]
        do {
            atomic = try signed.atomicBEEF()
        } catch {
            OneSatLog.error(error, "1Color app-signed transfer \(txid) was broadcast, then its Atomic BEEF could not be built", category: "OneSatColor")
            throw error
        }
        // The module's `onResponse` throws a failed submit to the page (skein-amm's `moveBack` then
        // reports no txid); here it is the result's `submitError`, the txid kept, because the
        // tokens already moved.
        var submitError: String?
        do {
            try await ColorModule.submit(overlay, topics: [ColorIdentifiers.topic(assetID)], beef: atomic)
        } catch {
            OneSatLog.error(error, "1Color app-signed transfer \(txid) was broadcast, then the overlay submit failed", category: "OneSatColor")
            submitError = (error as? LocalizedError)?.errorDescription ?? OneSatLog.message(error)
        }
        return (txid, atomic, signed.transaction, submitError)
    }
}
