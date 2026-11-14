import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxStorage
import OneSatTemplates
import OneSatMetanet

public struct Deploy1ColorResult: Equatable, Sendable {
    public var txid: String?
    /// Atomic BEEF of the deploy.
    public var tx: [UInt8]?
    /// `<txid>_0`.
    public var assetID: String?
    /// The deploy output's custody as filed (encrypted). Keep it with `tx` until the deploy is filed
    /// and admitted: `resubmitDeploy` needs it to file a deploy whose filing failed.
    public var customInstructions: String?
    public var error: String?
}

public struct Send1ColorResult: Equatable, Sendable {
    public var txid: String?
    /// Atomic BEEF of the send.
    public var tx: [UInt8]?
    /// True when the BRC-169 envelope reached the handle's messagebox (`delivered: 'envelope'`).
    public var delivered: Bool = false
    public var messageID: String?
    public var error: String?
}

/// `deploy1Color`, `send1Color` and the value balance, ported from `@1sat/actions` `1color/*`
/// with the BRC-207 module's part done here (a Swift wallet has no permissions manager).
public enum OneColorActions {
    static let beefLimits = WalletBEEFLimits.standard

    // MARK: - Deploy

    /// Deploys a 1Color token: `amount > 0` is fixed supply, `0` an authority deploy. The deploy is
    /// output 0, keyed to this wallet under `ISSUE`; once broadcast it is filed into its asset
    /// basket and submitted to `tm_color`. The asset ID is `<txid>_0`.
    ///
    /// When submission fails after the broadcast, the result carries the txid, the transaction and
    /// the asset ID with the error, so the caller can resubmit.
    public static func deploy(
        _ ctx: OneColorContext, amount: UInt64, decimals: Int? = nil, symbol: String? = nil,
        icon: OneColorIcon? = nil
    ) async -> Deploy1ColorResult {
        var result = Deploy1ColorResult()
        do {
            let overlay = try ctx.requireOverlay()
            let authority = amount == 0
            let custody = try ColorCustody(
                asset: .issue, derivationPrefix: ColorExecutor.randomBase64(),
                derivationSuffix: ColorExecutor.randomBase64(), senderIdentityKey: ctx.identityKey
            )
            let key = try ColorKeys.ownPublicKey(identity: ctx.identity, custody: custody)
            let lock = OneColorLock.publicKeyHash(ColorKeys.hash160(key))
            let payload = OneColorPayload.metadata(OneColorMetadata(symbol: symbol, decimals: decimals, icon: icon))
            let deploy = authority
                ? try OneColor.deployAuthority(lock: lock, payload: payload)
                : try OneColor.deployValue(amount: amount, lock: lock, payload: payload)
            let script = try deploy.lock()
            guard let token = try ColorTokenOutput.read(script, txid: String(repeating: "0", count: 64), vout: 0) else {
                throw ColorError.invalid("deploy output")
            }
            try ColorKeys.assertOwned(token, custody: custody, identity: ctx.identity)

            let plan = ColorPlan(
                assets: [.issue],
                ownedOutputs: [ColorPlan.Remittance(
                    outputIndex: 0, asset: .issue, derivationPrefix: custody.derivationPrefix,
                    derivationSuffix: custody.derivationSuffix, senderIdentityKey: custody.senderIdentityKey
                )],
                operations: [.init(asset: .issue, operation: authority ? .deployAuthority : .deployFixed)]
            )
            // A deploy output has no basket until it is signed, so its custody is encrypted here.
            let instructions = try await ColorMetadata.encrypt(custody.json, identity: ctx.identity)
            result.customInstructions = instructions
            let request = try WalletCreateActionRequest(
                description: authority ? "Deploy 1Color token (authority)" : "Deploy 1Color token (fixed supply)",
                outputs: [try WalletCreateActionOutput(
                    lockingScript: script.bytes, satoshis: OneColorConstants.carrierSatoshis,
                    outputDescription: "1Color deploy", customInstructions: instructions,
                    tags: [custody.suffixTag]
                )],
                labels: try plan.labels(),
                options: try ColorExecutor.options()
            )
            let signed = try await ColorExecutor.execute(ctx, request: request, tokenInputs: [])
            let txid = signed.transactionID.displayHex
            let atomic = try signed.atomicBEEF()
            let assetID = try ColorAssetID(txid: txid, vout: 0)
            result.txid = txid
            result.tx = atomic
            result.assetID = assetID.description

            // File the deploy into its asset basket; storage merges the insertion into its own action.
            _ = try await ctx.storage.colorInternalizeAction(ctx.auth, try WalletInternalizeActionRequest(
                transaction: try AtomicBEEF(bytes: atomic, limits: beefLimits),
                description: "File the deployed asset",
                outputs: [try WalletInternalizeOutput(
                    outputIndex: 0, protocol: .basketInsertion,
                    insertionRemittance: try WalletBasketInsertion(
                        basket: ColorIdentifiers.basket(assetID, role: token.role), customInstructions: instructions
                    )
                )]
            ))
            try await ColorModule.submit(overlay, topics: [ColorIdentifiers.discoveryTopic], beef: atomic)
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
    }

    /// Finishes a deploy that `deploy` broadcast but could not file or submit: files output 0 into
    /// its asset basket unless storage already lists it there, then submits the deploy to `tm_color`.
    ///
    /// `tx` is the deploy's Atomic BEEF and `customInstructions` the custody `deploy` returned. The
    /// custody is only needed when the deploy is not filed yet; it is checked against the output's
    /// key before anything is filed. `@1sat/actions` has no counterpart: in TS the BRC-207 module
    /// files the deploy inside the wallet's own action.
    public static func resubmitDeploy(
        _ ctx: OneColorContext, tx: [UInt8], customInstructions: String? = nil
    ) async -> Deploy1ColorResult {
        var result = Deploy1ColorResult()
        do {
            let overlay = try ctx.requireOverlay()
            let atomic = try AtomicBEEF(bytes: tx, limits: beefLimits)
            guard let deployTx = try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: ColorModule.txLimits),
                  let first = deployTx.outputs.first else {
                throw ColorError.invalid("deploy transaction")
            }
            let txid = atomic.subjectTransactionID.displayHex
            guard let token = try ColorTokenOutput.read(first.lockingScript, txid: txid, vout: 0), token.deploy else {
                throw ColorError.invalid("deploy output")
            }
            let assetID = try ColorAssetID(txid: txid, vout: 0)
            result.txid = txid
            result.tx = tx
            result.assetID = assetID.description
            result.customInstructions = customInstructions

            let basket = ColorIdentifiers.basket(assetID, role: token.role)
            let outpoint = "\(txid).0"
            let filed = try await ColorModule.listBasket(ctx, basket: basket)
                .contains { $0.outpoint.description == outpoint }
            if !filed {
                guard let customInstructions else {
                    throw ColorError.custody("the deploy is not filed and no custody was given to file it")
                }
                guard let plaintext = await ColorMetadata.decrypt(customInstructions, identity: ctx.identity) else {
                    throw ColorError.custody("the deploy custody cannot be read")
                }
                let custody = try ColorCustody.parse(plaintext)
                guard custody.asset == .issue else { throw ColorError.custody("a deploy's custody asset must be ISSUE") }
                try ColorKeys.assertOwned(token, custody: custody, identity: ctx.identity)
                _ = try await ctx.storage.colorInternalizeAction(ctx.auth, try WalletInternalizeActionRequest(
                    transaction: atomic,
                    description: "File the deployed asset",
                    outputs: [try WalletInternalizeOutput(
                        outputIndex: 0, protocol: .basketInsertion,
                        insertionRemittance: try WalletBasketInsertion(basket: basket, customInstructions: customInstructions)
                    )]
                ))
            }
            try await ColorModule.submit(overlay, topics: [ColorIdentifiers.discoveryTopic], beef: tx)
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
    }

    // MARK: - Send

    /// Sends `amount` units to a BRC-169 handle: a BRC-177 handoff the recipient submits,
    /// delivered (BRC-232) in a signed envelope to the handle's `transaction-delivery` box.
    ///
    /// When delivery fails the result carries the error with `txid` and `tx`, so the caller can
    /// retry delivery or abort the send.
    public static func send(
        _ ctx: OneColorContext, assetID assetText: String, amount: UInt64, to handle: String,
        expirySeconds: Int = OneColorConstants.sendExpirySeconds, memo: String? = nil
    ) async -> Send1ColorResult {
        var result = Send1ColorResult()
        do {
            guard assetText != ColorIdentifiers.issue, let assetID = try? ColorAssetID(assetText) else {
                return Send1ColorResult(error: "invalid-asset-id: expected <txid>_<vout>")
            }
            guard amount > 0 else { return Send1ColorResult(error: "amount-must-be-positive") }

            // 1. The handle; the recipient key is derived from it.
            let resolution = try await ctx.handles.resolve(handle)
            let recipient = "@\(resolution.handle)\(resolution.tag.map { "+\($0)" } ?? "")@\(resolution.domain)"
            let recipientKey = try PublicKey(try Hex.decode(resolution.identityKey, maximumDecodedByteCount: 33))

            // 2. The recipient's output.
            let derivationPrefix = ColorExecutor.randomBase64()
            let derivationSuffix = ColorExecutor.randomBase64()
            let key = try ColorKeys.recipientPublicKey(
                identity: ctx.identity, asset: .asset(assetID), derivationPrefix: derivationPrefix,
                derivationSuffix: derivationSuffix, recipient: recipientKey
            )
            let lockingScript = try OneColor.value(
                tokenID: assetID.description, amount: amount, lock: .publicKeyHash(ColorKeys.hash160(key))
            ).lock()

            // The delivery body, checked before the handoff exists.
            let receipt = try ColorReceipt(
                assetID: assetID, derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix,
                senderIdentityKey: ctx.identityKey
            )
            let delivery = { (txid: [UInt8], beef: [UInt8]) throws -> [UInt8] in
                try TransactionDelivery(
                    txid: txid, beef: beef,
                    outputs: [.basketInsertion(
                        outputIndex: 0, basket: ColorIdentifiers.basket(assetID, role: .value),
                        customInstructions: receipt.customInstructions, tags: nil
                    )],
                    lifecycles: [], memo: memo
                ).mime()
            }
            _ = try delivery([UInt8](repeating: 0, count: 32), [])

            // BRC-177 preflight: an invalid expiry or storage without noSend expiry fails here,
            // before a split could spend fees and change token outputs.
            let expiryLabel = "p nosend expiry seconds \(expirySeconds)"
            _ = try NoSendExpiry.parse(labels: [expiryLabel])
            guard try await ctx.storage.supportsNoSendExpiry() else { throw NoSendExpiryError.unsupported }

            // 3. The handoff: select, split to the exact amount when needed, and sign as BRC-177.
            let overlay = try ctx.requireOverlay()
            var selected = try await ColorModule.selectInputs(ctx, overlay: overlay, assetID: assetID, target: amount)
            if selected.reduce(0, { $0 + $1.amount }) > amount {
                selected = [try await ColorModule.split(ctx, overlay: overlay, assetID: assetID, selected: selected, amount: amount)]
            }
            let plan = ColorPlan(assets: [.asset(assetID)], operations: [.init(asset: .asset(assetID), operation: .transfer)])
            let request = try WalletCreateActionRequest(
                description: "Send \(amount) 1Color tokens to \(recipient)",
                inputBEEF: try await ColorModule.inputBEEF(ctx, inputs: selected),
                inputs: try ColorExecutor.tokenInputs(selected),
                outputs: [try WalletCreateActionOutput(
                    lockingScript: lockingScript.bytes, satoshis: OneColorConstants.carrierSatoshis,
                    outputDescription: "1Color tokens"
                )],
                labels: try plan.labels() + [
                    "\(OneColorConstants.sendLabelPrefix)\(base64Hex(derivationPrefix)) \(base64Hex(derivationSuffix))",
                    expiryLabel,
                ],
                options: try ColorExecutor.options(noSend: true)
            )
            // signBound: every token input must still be admitted and unspent.
            let admitted = try await ColorModule.spendable(overlay, assetID: assetID, outputs: selected.map(ColorModule.source))
            guard selected.allSatisfy({ admitted.contains($0.outpoint) }) else {
                throw ColorError.custody("a \(assetID) input is no longer spendable")
            }
            let identity = ctx.identity
            let inputs = selected
            let handoff = try await NoSendExpiryAction.run(
                storage: ctx.storage, auth: ctx.auth, identity: identity, request: request,
                maximumFee: ctx.maximumFee,
                signCallerInputs: { transaction, _ in
                    try ColorExecutor.unlocks(transaction, inputs: inputs, identity: identity)
                }
            )
            let txid = handoff.signed.transactionID.displayHex
            let atomic = try handoff.signed.atomicBEEF()
            result.txid = txid
            result.tx = atomic

            // 4. Deliver.
            do {
                let plain = try AtomicBEEF(bytes: atomic, limits: beefLimits).beef.serialized(limits: beefLimits)
                let plaintext = try delivery(try Hex.decode(txid, maximumDecodedByteCount: 32), plain)
                let sent = try await Delivery.sendEnvelope(
                    ctx, resolution: resolution, recipientKey: recipientKey, plaintext: plaintext,
                    messageBox: OneColorConstants.transactionDeliveryBox
                )
                result.delivered = true
                result.messageID = sent.messageID
            } catch {
                result.error = "delivery-failed: \(error.localizedDescription)"
            }
            return result
        } catch {
            result.error = error.localizedDescription
            return result
        }
    }

    static func base64Hex(_ value: String) -> String {
        Hex.encode(Array(Data(base64Encoded: value) ?? Data()))
    }

    // MARK: - Balance

    /// The units of an asset's value basket (or the count of its authority outputs), from wallet
    /// state alone, as the module's balance read reports it.
    public static func balance(_ ctx: OneColorContext, assetID: ColorAssetID, role: ColorTokenRole = .value) async throws -> UInt64 {
        let outputs = try await ColorModule.listBasket(ctx, basket: ColorIdentifiers.basket(assetID, role: role))
        var total: UInt64 = 0
        for output in outputs {
            guard let script = try? ColorModule.script(output),
                  let token = ColorModule.read(script, outpoint: output.outpoint),
                  token.assetID == assetID, token.role == role else { continue }
            total += role == .value ? token.amount : 1
        }
        return total
    }
}

/// `sendEnvelope`: a signed BRC-169 envelope whose content is BRC-78 encrypted to the recipient.
enum Delivery {
    static func sendEnvelope(
        _ ctx: OneColorContext, resolution: HandleResolver.Resolution, recipientKey: PublicKey,
        plaintext: [UInt8], messageBox: String
    ) async throws -> (status: String, messageID: String) {
        let content = try await BRC78.encrypt(plaintext, to: recipientKey, wallet: try BRC78.wallet(for: ctx.identity))
        let unsigned = MetanetEnvelope.Unsigned(
            recipient: .init(handle: resolution.handle, tag: resolution.tag, domain: resolution.domain),
            senderIdentityKey: ctx.identity.publicKey.compressedBytes,
            created: MetanetEnvelope.timestamp(),
            payment: .null,
            contentHash: BSVHashing.sha256(plaintext).bytes
        )
        let (envelope, _) = try await MetanetEnvelope.sign(unsigned, content: content, wallet: ProtoWallet(rootKey: ctx.identity))
        guard let host = URL(string: resolution.messagebox) else {
            throw MetanetError.relay("invalid messagebox URL")
        }
        return try await ctx.relay.send(
            host: host, recipient: recipientKey.compressedBytes, messageBox: messageBox, body: envelope
        )
    }
}
