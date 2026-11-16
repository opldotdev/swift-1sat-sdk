import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet

/// `internalizeAction` through the color module (`@bsv/color-permission-module` 0.2.3
/// `internalizeAction`), for a caller in this package that takes in a transaction it did not
/// receive as a delivery (an AMM swap's payout). A `p color` basket insertion must carry a
/// receipt for that output, which the module checks as it checks a delivered one: an unproven
/// transaction must unlock every input and involve only admitted assets, the output must be this
/// wallet's and admitted and unspent on the overlay; its receipt is then stored encrypted, with
/// the derivation-suffix tag. Any other insertion and every wallet payment pass as given.
package enum ColorInternalize {
    package enum Output: Equatable, Sendable {
        case walletPayment(outputIndex: UInt32, derivationPrefix: String, derivationSuffix: String, senderIdentityKey: String)
        case basketInsertion(outputIndex: UInt32, basket: String, customInstructions: String)

        package var outputIndex: UInt32 {
            switch self {
            case .walletPayment(let index, _, _, _), .basketInsertion(let index, _, _): index
            }
        }
    }

    /// Takes `atomicBEEF`'s outputs in; the wallet's `accepted`.
    package static func run(
        _ ctx: OneColorContext, atomicBEEF: [UInt8], outputs: [Output], description: String, labels: [String]
    ) async throws -> Bool {
        let (subjectID, beef, subject) = try ColorBEEF.open(atomicBEEF)
        let txid = subjectID.displayHex
        let colored = outputs.compactMap { output -> (UInt32, String, String)? in
            guard case let .basketInsertion(index, basket, instructions) = output, basket.hasPrefix("p color ") else { return nil }
            return (index, basket, instructions)
        }
        var remittances: [UInt32: WalletBasketInsertion] = [:]
        if !colored.isEmpty {
            let overlay = try ctx.requireOverlay()
            for (index, basket, instructions) in colored {
                _ = try ColorReceipt.check(subject: subject, outputIndex: Int(index), basket: basket, customInstructions: instructions)
            }
            if try beef.entry(for: subjectID, limits: ColorBEEF.limits.transactionLimits)?.merklePathIndex == nil {
                try ColorModule.assertUnlocks(subject, in: beef)
                for assetID in try ColorModule.involvedAssets(subject, txid: txid, in: beef) {
                    try await ColorModule.assertSupportedAsset(overlay, assetID)
                }
            }
            for (index, basket, instructions) in colored {
                _ = try await ColorModule.verifyReceipt(
                    ctx, overlay: overlay, transaction: subject, txid: txid, outputIndex: index,
                    basket: basket, customInstructions: instructions
                )
                remittances[index] = try WalletBasketInsertion(
                    basket: basket,
                    customInstructions: try await ColorMetadata.encrypt(instructions, identity: ctx.identity),
                    tags: ColorModule.withSuffixTag(nil)
                )
            }
        }
        let request = try WalletInternalizeActionRequest(
            transaction: try ColorBEEF.atomic(subjectID, in: beef),
            description: description,
            labels: labels,
            outputs: try outputs.map { output in
                switch output {
                case let .walletPayment(index, prefix, suffix, sender):
                    return WalletInternalizeOutput(outputIndex: index, remittance: .walletPayment(try WalletPaymentRemittance(
                        derivationPrefix: try WalletBase64Data(base64: prefix),
                        derivationSuffix: try WalletBase64Data(base64: suffix),
                        senderIdentityKey: try PublicKey(try Hex.decode(sender, maximumDecodedByteCount: 33))
                    )))
                case let .basketInsertion(index, basket, instructions):
                    let insertion = try remittances[index] ?? WalletBasketInsertion(basket: basket, customInstructions: instructions)
                    return WalletInternalizeOutput(outputIndex: index, remittance: .basketInsertion(insertion))
                }
            }
        )
        return try await ctx.storage.colorInternalizeAction(ctx.auth, request).accepted
    }
}

/// A plain `createAction` (no module plan), signed and processed as the module's own actions are,
/// for a caller in this package: `signCallerInputs` signs the caller's inputs over the assembled
/// transaction (input index → unlocking script); the storage's funding inputs are signed here.
package enum ColorPlainAction {
    package static func run(
        _ ctx: OneColorContext, request: WalletCreateActionRequest,
        signCallerInputs: (Transaction) throws -> [Int: Script]
    ) async throws -> (txid: String, atomicBEEF: [UInt8], transaction: Transaction) {
        let signed = try await ColorExecutor.execute(ctx, request: request, signCallerInputs: signCallerInputs)
        return (signed.transactionID.displayHex, try signed.atomicBEEF(), signed.transaction)
    }
}
