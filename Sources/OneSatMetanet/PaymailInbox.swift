import Foundation
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import ToolboxStorage
import ToolboxWallet

/// The wallet call a paymail payment is internalized through: the BRC-100 `internalizeAction`, as
/// `syncMessages` calls `ctx.wallet.internalizeAction`. `RemoteWallet` provides it and checks that
/// the claimed output is its own BRC-29 key before storage sees the request.
public protocol PaymailPaymentWallet: Sendable {
    func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult
}

extension RemoteWallet: PaymailPaymentWallet {}

/// A paymail message that cannot be internalized. The message stays in the box.
public struct PaymailInboxError: Error, Equatable, Sendable, LocalizedError {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

/// 1Sat paymail payments in the `payment_inbox` message box, as `@1sat/actions`
/// `sync/syncMessages.ts` handles them.
///
/// The paymail server (`wallet-server` `paymail/messagebox.ts`) posts each payment it receives as
/// `{beef, outputIndex, derivationPrefix, derivationSuffix, senderIdentityKey, satoshis, alias}`.
/// One message becomes one BRC-29 wallet payment, straight into the spendable balance:
///
/// - the body is JSON, parsed once more when it is itself a JSON string;
/// - `beef` is hex BEEF (plain or Atomic); the subject is the last entry that carries a
///   transaction, whatever an Atomic prefix names;
/// - the wallet gets Atomic BEEF of that subject, output `outputIndex` as a `wallet payment` with
///   the message's derivation and `senderIdentityKey` (the server's anyone key), and the
///   description `Paymail payment to <alias>` cut to 50 UTF-16 units.
///
/// The caller lists and opens the box, and acknowledges a message only after it was internalized.
public enum PaymailInbox {
    /// `syncMessages` default box.
    public static let messageBox = "payment_inbox"
    /// `syncMessages` default server.
    public static let defaultHost = URL(string: "https://messagebox.1sat.app")!
    /// `.slice(0, 50)` of the description.
    public static let descriptionLimit = 50

    static let beefLimits = StorageLimits.beef

    /// One decoded message body (`PaymailMessage`).
    public struct Message: Equatable, Sendable {
        /// `beef`, hex-decoded.
        public let beef: [UInt8]
        public let outputIndex: UInt32
        public let derivationPrefix: String
        public let derivationSuffix: String
        /// Hex public key the payment was derived against.
        public let senderIdentityKey: String
        /// As the server states it. Informational: the internalize request does not carry it.
        public let satoshis: UInt64?
        public let alias: String

        public init(
            beef: [UInt8], outputIndex: UInt32, derivationPrefix: String, derivationSuffix: String,
            senderIdentityKey: String, satoshis: UInt64?, alias: String
        ) {
            self.beef = beef
            self.outputIndex = outputIndex
            self.derivationPrefix = derivationPrefix
            self.derivationSuffix = derivationSuffix
            self.senderIdentityKey = senderIdentityKey
            self.satoshis = satoshis
            self.alias = alias
        }
    }

    /// A message the wallet internalized.
    public struct Receipt: Equatable, Sendable {
        /// The subject transaction, display hex.
        public let txid: String
        public let outputIndex: UInt32
        public let satoshis: UInt64?
        public let alias: String
        public let accepted: Bool

        public init(txid: String, outputIndex: UInt32, satoshis: UInt64?, alias: String, accepted: Bool) {
            self.txid = txid
            self.outputIndex = outputIndex
            self.satoshis = satoshis
            self.alias = alias
            self.accepted = accepted
        }
    }

    private struct Wire: Decodable {
        let beef: String
        let outputIndex: UInt32
        let derivationPrefix: String
        let derivationSuffix: String
        let senderIdentityKey: String
        let satoshis: UInt64?
        let alias: String

        enum CodingKeys: String, CodingKey {
            case beef, outputIndex, derivationPrefix, derivationSuffix, senderIdentityKey, satoshis, alias
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            beef = try container.decode(String.self, forKey: .beef)
            outputIndex = try container.decode(UInt32.self, forKey: .outputIndex)
            derivationPrefix = try container.decode(String.self, forKey: .derivationPrefix)
            derivationSuffix = try container.decode(String.self, forKey: .derivationSuffix)
            senderIdentityKey = try container.decode(String.self, forKey: .senderIdentityKey)
            // The reference never reads it, so an odd value does not refuse the message.
            satoshis = try? container.decodeIfPresent(UInt64.self, forKey: .satoshis)
            alias = try container.decode(String.self, forKey: .alias)
        }
    }

    /// `typeof msg.body === 'string' ? JSON.parse(msg.body) : msg.body` over the body text a
    /// message box client hands back (already decrypted): an object is the message; a JSON string
    /// is parsed once more.
    public static func decode(_ body: String) throws -> Message {
        let decoder = JSONDecoder()
        let wire: Wire
        do {
            if let inner = try? decoder.decode(String.self, from: Data(body.utf8)) {
                wire = try decoder.decode(Wire.self, from: Data(inner.utf8))
            } else {
                wire = try decoder.decode(Wire.self, from: Data(body.utf8))
            }
        } catch {
            throw PaymailInboxError("not a paymail payment message")
        }
        let beef: [UInt8]
        do {
            beef = try Hex.decode(wire.beef, maximumDecodedByteCount: beefLimits.maximumByteCount)
        } catch {
            throw PaymailInboxError("paymail beef is not hex")
        }
        return Message(
            beef: beef, outputIndex: wire.outputIndex, derivationPrefix: wire.derivationPrefix,
            derivationSuffix: wire.derivationSuffix, senderIdentityKey: wire.senderIdentityKey,
            satoshis: wire.satoshis, alias: wire.alias
        )
    }

    /// `Beef.fromBinary`: standard BEEF, or Atomic BEEF read past its prefix and subject id.
    public static func readBEEF(_ bytes: [UInt8]) throws -> BEEF {
        var nested = bytes
        if bytes.count >= 36, bytes.prefix(4).elementsEqual([0x01, 0x01, 0x01, 0x01]) {
            nested = Array(bytes.dropFirst(36))
        }
        do {
            return try BEEF(bytes: nested, limits: beefLimits)
        } catch {
            throw PaymailInboxError("paymail beef is not valid BEEF")
        }
    }

    /// The last entry that carries a transaction (`txs.filter(tx != null)`, last). A trailing
    /// transaction-ID-only entry is passed over.
    public static func subjectTransactionID(of beef: BEEF) throws -> TransactionID {
        guard let subject = beef.transactions.last(where: { $0.transaction != nil }) else {
            throw PaymailInboxError("paymail beef has no transaction")
        }
        return try subject.transactionID(limits: beefLimits.transactionLimits)
    }

    /// `` `Paymail payment to ${alias}`.slice(0, 50) ``: the first 50 UTF-16 code units. A cut
    /// through a surrogate pair drops its first half, which a Swift string cannot hold alone.
    public static func description(alias: String) -> String {
        let units = Array("Paymail payment to \(alias)".utf16.prefix(descriptionLimit))
        var cut = units[...]
        if let last = cut.last, UTF16.isLeadSurrogate(last) { cut = cut.dropLast() }
        return String(decoding: cut, as: UTF16.self)
    }

    /// The `internalizeAction` request `syncMessages` makes for one message.
    public static func internalizeRequest(for message: Message) throws -> WalletInternalizeActionRequest {
        let beef = try readBEEF(message.beef)
        let subject = try subjectTransactionID(of: beef)
        let remittance: WalletPaymentRemittance
        do {
            let sender = try PublicKey(try Hex.decode(message.senderIdentityKey, maximumDecodedByteCount: 33))
            remittance = try WalletPaymentRemittance(
                derivationPrefix: try WalletBase64Data(base64: message.derivationPrefix),
                derivationSuffix: try WalletBase64Data(base64: message.derivationSuffix),
                senderIdentityKey: sender
            )
        } catch {
            throw PaymailInboxError("malformed paymail payment remittance")
        }
        return try WalletInternalizeActionRequest(
            transaction: try MetanetBEEF.atomic(subject, in: beef),
            description: description(alias: message.alias),
            outputs: [WalletInternalizeOutput(outputIndex: message.outputIndex, remittance: .walletPayment(remittance))]
        )
    }

    /// Internalizes one message. A throw means nothing was internalized: leave the message in the
    /// box. Acknowledge it only after this returns.
    @discardableResult
    public static func internalize(_ message: Message, wallet: any PaymailPaymentWallet) async throws -> Receipt {
        let request = try internalizeRequest(for: message)
        let result = try await wallet.internalizeAction(request)
        return Receipt(
            txid: request.transaction.subjectTransactionID.displayHex, outputIndex: message.outputIndex,
            satoshis: message.satoshis, alias: message.alias, accepted: result.accepted
        )
    }

    /// Decodes a body and internalizes it.
    @discardableResult
    public static func internalize(body: String, wallet: any PaymailPaymentWallet) async throws -> Receipt {
        try await internalize(try decode(body), wallet: wallet)
    }
}
