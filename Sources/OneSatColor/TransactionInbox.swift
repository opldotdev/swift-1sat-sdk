import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVTransaction
import BSVWallet
import ToolboxActions
import OneSatCBOR
import OneSatMetanet

/// A message internalized and acknowledged.
public struct TransactionInboxReceipt: Equatable, Sendable {
    public let messageID: String
    public let txid: String
    /// Sender identity key, hex.
    public let sender: String
    /// `payment.satoshis` as the envelope states it (handle payments only).
    public let satoshis: UInt64?
    /// The `text/plain` content (handle payments only).
    public let memo: String?
    /// 1Color assets received, BRC-232 deliveries only.
    public let assetIDs: [String]
    /// BRC-232 deliveries only: per asset received, the indexes of the delivered outputs of
    /// `txid` that were filed for it, in delivery order. Other outputs of the same transaction,
    /// such as the sender's change, are not listed. Keys are the entries of `assetIDs`.
    public let deliveredOutputs: [String: [UInt32]]
}

/// A message left in the box, and why.
public struct TransactionInboxSkip: Equatable, Sendable {
    public let messageID: String
    public let reason: String
}

public struct SyncTransactionInboxResult: Equatable, Sendable {
    public var received: [TransactionInboxReceipt] = []
    public var skipped: [TransactionInboxSkip] = []
    public var error: String?
}

/// `syncTransactionInbox` of `@1sat/actions` `metanet/receive.ts`: collect the
/// `transaction-delivery` box. Each envelope is decoded, verified, decrypted and hash-checked; a
/// `payment` is internalized as a BRC-29 wallet payment, a BRC-232 delivery is mapped, its 1Color
/// receipts are submitted to their asset topics and must be admitted, the module's receipt checks
/// run, and the delivery is internalized whole. Only handled messages are acknowledged.
public enum TransactionInbox {
    public static let paymentLabel = "metanet payment"
    static let brc29Protocol = "3241645161d8"
    static let beefLimits = WalletBEEFLimits.standard

    /// Resolves the BRC-22 overlay a 1Color asset's receipt is submitted to. Nil leaves the
    /// message in the box with `overlay-required`.
    public typealias OverlayFor = @Sendable (ColorAssetID) async throws -> (any ColorOverlayProvider)?

    struct Skip: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    public static func sync(
        _ ctx: OneColorContext, messagebox: URL? = nil, overlayFor: OverlayFor? = nil
    ) async -> SyncTransactionInboxResult {
        var result = SyncTransactionInboxResult()
        var base = (messagebox ?? CborRelay.defaultHost).absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        let host = URL(string: base) ?? CborRelay.defaultHost

        let messages: [CborRelay.Message]
        do {
            messages = try await ctx.relay.list(host: host, messageBox: OneColorConstants.transactionDeliveryBox)
        } catch {
            result.error = error.localizedDescription
            return result
        }
        var acknowledged: [String] = []
        for message in messages {
            do {
                result.received.append(try await handle(ctx, message: message, overlayFor: overlayFor))
                acknowledged.append(message.messageID)
            } catch {
                result.skipped.append(TransactionInboxSkip(messageID: message.messageID, reason: error.localizedDescription))
            }
        }
        if !acknowledged.isEmpty {
            do {
                try await ctx.relay.acknowledge(host: host, messageIDs: acknowledged)
            } catch {
                result.error = "acknowledge-failed: \(error.localizedDescription)"
            }
        }
        return result
    }

    static func handle(
        _ ctx: OneColorContext, message: CborRelay.Message, overlayFor: OverlayFor?
    ) async throws -> TransactionInboxReceipt {
        let envelope: MetanetEnvelope.Received
        do {
            envelope = try MetanetEnvelope.decode(message.body)
        } catch {
            throw Skip(reason: "not a DAG-CBOR BRC-169 envelope")
        }
        guard await MetanetEnvelope.verify(envelope) else {
            throw Skip(reason: "envelope signature does not verify")
        }
        guard envelope.senderIdentityKey.count == 33 else { throw Skip(reason: "sender must be 33 bytes") }
        let sender = Hex.encode(envelope.senderIdentityKey)
        let senderKey = try PublicKey(envelope.senderIdentityKey)
        let plaintext = try await BRC78.decrypt(envelope.content, from: senderKey, wallet: try BRC78.wallet(for: ctx.identity))
        if let hash = envelope.contentHash, BSVHashing.sha256(plaintext).bytes != hash {
            throw Skip(reason: "contentHash does not match the content")
        }
        let entity = try MimeEntity.parse(plaintext)
        let type = MimeEntity.mediaType(entity.contentType)

        if envelope.payment != .null {
            if type == TransactionDelivery.contentType {
                throw Skip(reason: "a payment with transaction-delivery content is not supported")
            }
            let memo = type == "text/plain" ? String(decoding: entity.body, as: UTF8.self) : nil
            let txid = try await internalizeEnvelopePayment(ctx, payment: envelope.payment, sender: senderKey, memo: memo)
            return TransactionInboxReceipt(
                messageID: message.messageID, txid: txid, sender: sender,
                satoshis: envelope.payment.mapValue?["satoshis"]?.unsignedValue, memo: memo, assetIDs: [],
                deliveredOutputs: [:]
            )
        }
        if type == TransactionDelivery.contentType {
            guard envelope.contentHash != nil else {
                throw Skip(reason: "a BRC-232 delivery requires the envelope contentHash")
            }
            let delivered = try await internalizeDelivery(
                ctx, body: try TransactionDelivery.body(ofEntity: plaintext), overlayFor: overlayFor
            )
            var outputs: [String: [UInt32]] = [:]
            for (assetID, indexes) in delivered.received { outputs[assetID.description] = indexes }
            return TransactionInboxReceipt(
                messageID: message.messageID, txid: delivered.txid, sender: sender,
                satoshis: nil, memo: nil, assetIDs: delivered.received.map(\.0.description),
                deliveredOutputs: outputs
            )
        }
        throw Skip(reason: "nothing to internalize: no payment, content type \(entity.contentType)")
    }

    /// A §7.3 `payment` as a BRC-29 wallet payment of output 0.
    static func internalizeEnvelopePayment(
        _ ctx: OneColorContext, payment: DagCborValue, sender: PublicKey, memo: String?
    ) async throws -> String {
        guard let map = payment.mapValue,
              let proto = map["protocol"]?.bytesValue, String(decoding: proto, as: UTF8.self) == brc29Protocol else {
            throw Skip(reason: "payment protocol is not BRC-29")
        }
        guard let prefix = map["derivationPrefix"]?.bytesValue, let suffix = map["derivationSuffix"]?.bytesValue,
              let beefBytes = map["beef"]?.bytesValue else {
            throw Skip(reason: "malformed payment")
        }
        let beef: BEEF
        let txid: TransactionID
        if let atomic = try? AtomicBEEF(bytes: beefBytes, limits: beefLimits) {
            beef = atomic.beef
            txid = atomic.subjectTransactionID
        } else {
            beef = try BEEF(bytes: beefBytes, limits: beefLimits)
            guard let last = beef.transactions.last else { throw Skip(reason: "payment beef has no transaction") }
            txid = try last.transactionID(limits: beefLimits.transactionLimits)
        }
        let description = memo.map { "Metanet payment: \($0)" } ?? "Metanet payment"
        _ = try await ctx.storage.colorInternalizeAction(ctx.auth, try WalletInternalizeActionRequest(
            transaction: try ColorBEEF.atomic(txid, in: beef),
            description: String(String.UnicodeScalarView(description.unicodeScalars.prefix(50))),
            labels: [paymentLabel],
            outputs: [try WalletInternalizeOutput(
                outputIndex: 0, protocol: .walletPayment,
                paymentRemittance: try WalletPaymentRemittance(
                    derivationPrefix: try WalletBase64Data(prefix), derivationSuffix: try WalletBase64Data(suffix),
                    senderIdentityKey: sender
                )
            )]
        ))
        return txid.displayHex
    }

    /// One BRC-232 delivery body, whole or not at all: map its entries, submit each 1Color asset's
    /// transaction to `tm_color_<assetId>` and require admission, run the module's receipt checks,
    /// then one internalize.
    public static func internalizeTransactionDelivery(
        _ ctx: OneColorContext, body: [UInt8], overlayFor: OverlayFor? = nil
    ) async throws -> (txid: String, assetIDs: [ColorAssetID]) {
        let delivered = try await internalizeDelivery(ctx, body: body, overlayFor: overlayFor)
        return (delivered.txid, delivered.received.map(\.0))
    }

    /// `internalizeTransactionDelivery`, with the output indexes received for each asset.
    static func internalizeDelivery(
        _ ctx: OneColorContext, body: [UInt8], overlayFor: OverlayFor? = nil
    ) async throws -> (txid: String, received: [(ColorAssetID, [UInt32])]) {
        let delivery = try TransactionDelivery.decode(body)
        let txidHex = Hex.encode(delivery.txid)
        let beef = try BEEF(bytes: delivery.beef, limits: beefLimits)
        let txLimits = beefLimits.transactionLimits
        guard let subjectID = try? TransactionID(displayHex: txidHex),
              let entry = try beef.entry(for: subjectID, limits: txLimits),
              let subject = entry.transaction else {
            throw Skip(reason: "beef does not contain \(txidHex)")
        }

        struct Insertion { let index: UInt32; let basket: String; let instructions: String; let tags: [String]? }
        var outputs: [(UInt32, WalletInternalizeRemittance?)] = []
        var insertions: [Insertion] = []
        var received: [(ColorAssetID, [UInt32])] = []
        for output in delivery.outputs {
            let index = output.outputIndex
            guard subject.outputs.indices.contains(Int(index)) else {
                throw Skip(reason: "output \(index) is not in \(txidHex)")
            }
            switch output {
            case let .walletPayment(_, prefix, suffix, senderKey):
                let hex = Hex.encode(senderKey)
                guard senderKey.count == 33, senderKey[0] == 2 || senderKey[0] == 3 else {
                    throw Skip(reason: "output \(index): senderIdentityKey is not a compressed key")
                }
                outputs.append((index, .walletPayment(try WalletPaymentRemittance(
                    derivationPrefix: try WalletBase64Data(base64: prefix),
                    derivationSuffix: try WalletBase64Data(base64: suffix),
                    senderIdentityKey: try PublicKey(try Hex.decode(hex, maximumDecodedByteCount: 33))
                ))))
            case let .basketInsertion(_, basket, instructions, tags):
                guard basket.hasPrefix("p color ") else {
                    throw Skip(reason: "output \(index): unsupported basket \(basket)")
                }
                let checked = try ColorReceipt.check(
                    subject: subject, outputIndex: Int(index), basket: basket, customInstructions: instructions
                )
                if let at = received.firstIndex(where: { $0.0 == checked.assetID }) {
                    received[at].1.append(index)
                } else {
                    received.append((checked.assetID, [index]))
                }
                insertions.append(Insertion(index: index, basket: basket, instructions: instructions, tags: tags))
                outputs.append((index, nil))
            }
        }

        if !received.isEmpty {
            // Every asset's overlay is resolved before any submit.
            var targets: [(ColorAssetID, any ColorOverlayProvider, [UInt32])] = []
            for (assetID, indexes) in received {
                let resolved: (any ColorOverlayProvider)?
                do {
                    // A supplied resolver decides, even when it answers nil; the context's
                    // overlay is only the default when no resolver was given.
                    if let overlayFor {
                        resolved = try await overlayFor(assetID)
                    } else {
                        resolved = ctx.overlay
                    }
                } catch {
                    throw Skip(reason: error.localizedDescription)
                }
                guard let resolved else { throw Skip(reason: "overlay-required") }
                targets.append((assetID, resolved, indexes))
            }
            for (assetID, provider, indexes) in targets {
                let topic = ColorIdentifiers.topic(assetID)
                let steak = try await provider.submit(topics: [topic], beef: delivery.beef)
                let admitted = steak[topic]?.outputsToAdmit ?? []
                for index in indexes where !admitted.contains(index) {
                    throw Skip(reason: "\(topic) did not admit \(txidHex).\(index)")
                }
            }
        }

        // The module's internalize checks: the received output must be ours, its asset supported,
        // and admitted and unspent; an unproven transaction must unlock every input.
        var remittances: [UInt32: WalletBasketInsertion] = [:]
        if !insertions.isEmpty {
            guard let overlay = ctx.overlay else { throw Skip(reason: "overlay-required") }
            if entry.merklePathIndex == nil {
                try ColorModule.assertUnlocks(subject, in: beef)
                for assetID in try ColorModule.involvedAssets(subject, txid: txidHex, in: beef) {
                    try await ColorModule.assertSupportedAsset(overlay, assetID)
                }
            }
            for insertion in insertions {
                let custody = try await ColorModule.verifyReceipt(
                    ctx, overlay: overlay, transaction: subject, txid: txidHex, outputIndex: insertion.index,
                    basket: insertion.basket, customInstructions: insertion.instructions
                )
                // Custody is stored as the wallet's permissions manager stores it: encrypted.
                remittances[insertion.index] = try WalletBasketInsertion(
                    basket: insertion.basket,
                    customInstructions: try await ColorMetadata.encrypt(insertion.instructions, identity: ctx.identity),
                    tags: ColorModule.withSuffixTag(insertion.tags, custody)
                )
            }
        }

        _ = try await ctx.storage.colorInternalizeAction(ctx.auth, try WalletInternalizeActionRequest(
            transaction: try ColorBEEF.atomic(subjectID, in: beef),
            description: received.isEmpty ? "Receive delivered outputs" : "Receive 1Color tokens",
            outputs: outputs.map { index, remittance in
                if let remittance { return WalletInternalizeOutput(outputIndex: index, remittance: remittance) }
                return WalletInternalizeOutput(outputIndex: index, remittance: .basketInsertion(remittances[index]!))
            }
        ))
        return (txidHex, received)
    }
}
