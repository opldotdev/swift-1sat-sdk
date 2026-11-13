import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVWallet
import OneSatCBOR

/// The BRC-169 signed envelope, DAG-CBOR form, as `actions/src/metanet/envelope.ts` writes it.
///
/// The signature covers the canonical DAG-CBOR encoding of every member except `content` and
/// `signature`, signed under `[2, "metanet handles envelope"]`, key ID `send`, counterparty
/// `anyone`, so anyone holding the sender's identity key can check it.
public enum MetanetEnvelope {
    public static let version = "1.0"
    public static let keyID = "send"

    public static func signatureProtocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: "metanet handles envelope")
    }

    /// The members a sender writes. `payment` is `null` for a delivery that carries no BRC-29
    /// payment, which is every 1Color send.
    public struct Unsigned: Equatable, Sendable {
        public var recipient: Recipient
        public var senderIdentityKey: [UInt8]
        public var senderHandle: String?
        public var senderDomain: String?
        public var created: String
        public var quoteID: String?
        public var payment: DagCborValue
        public var contentHash: [UInt8]?

        public init(
            recipient: Recipient, senderIdentityKey: [UInt8], senderHandle: String? = nil,
            senderDomain: String? = nil, created: String, quoteID: String? = nil,
            payment: DagCborValue = .null, contentHash: [UInt8]? = nil
        ) {
            self.recipient = recipient
            self.senderIdentityKey = senderIdentityKey
            self.senderHandle = senderHandle
            self.senderDomain = senderDomain
            self.created = created
            self.quoteID = quoteID
            self.payment = payment
            self.contentHash = contentHash
        }

        /// The map without `content` and `signature`. Absent optional members are left out, as
        /// the reference drops `undefined` ones.
        public func map() throws -> DagCborMap {
            var recipientEntries: [(key: String, value: DagCborValue)] = [
                ("handle", .text(recipient.handle)), ("domain", .text(recipient.domain)),
            ]
            if let tag = recipient.tag { recipientEntries.append(("tag", .text(tag))) }
            var senderEntries: [(key: String, value: DagCborValue)] = [
                ("identityKey", .bytes(senderIdentityKey)),
            ]
            if let senderHandle { senderEntries.append(("handle", .text(senderHandle))) }
            if let senderDomain { senderEntries.append(("domain", .text(senderDomain))) }
            var entries: [(key: String, value: DagCborValue)] = [
                ("metanetHandles", .text(MetanetEnvelope.version)),
                ("recipient", .map(try DagCborMap(recipientEntries))),
                ("sender", .map(try DagCborMap(senderEntries))),
                ("created", .text(created)),
                ("payment", payment),
            ]
            if let quoteID { entries.append(("quoteId", .text(quoteID))) }
            if let contentHash { entries.append(("contentHash", .bytes(contentHash))) }
            return try DagCborMap(entries)
        }

        public func signingPreimage() throws -> [UInt8] {
            try DagCbor.encode(.map(try map()))
        }
    }

    public struct Recipient: Equatable, Sendable {
        public var handle: String
        public var tag: String?
        public var domain: String

        public init(handle: String, tag: String? = nil, domain: String) {
            self.handle = handle
            self.tag = tag
            self.domain = domain
        }
    }

    /// An envelope as received: the whole decoded map, plus the members a receiver reads.
    public struct Received: Equatable, Sendable {
        public let map: DagCborMap
        public let senderIdentityKey: [UInt8]
        public let content: [UInt8]
        public let signature: [UInt8]

        public var payment: DagCborValue { map["payment"] ?? .null }
        public var contentHash: [UInt8]? { map["contentHash"]?.bytesValue }

        /// The preimage a verifier re-encodes: every received member but `content` and
        /// `signature`, unknown ones included, exactly as the reference does.
        public func signingPreimage() throws -> [UInt8] {
            try DagCbor.encode(.map(try DagCborMap(map.entries.filter {
                $0.key != "content" && $0.key != "signature"
            })))
        }
    }

    /// Signs and encodes. Returns the envelope bytes and the DER signature.
    public static func sign(
        _ unsigned: Unsigned, content: [UInt8], wallet: ProtoWallet
    ) async throws -> (envelope: [UInt8], signature: [UInt8]) {
        let result = try await wallet.createSignature(WalletCreateSignatureRequest(
            protocolID: try signatureProtocol(), keyID: try WalletKeyID(keyID),
            counterparty: .anyone, payload: .data(try unsigned.signingPreimage())
        ))
        let signature = result.signature.derBytes
        var entries = try unsigned.map().entries
        entries.append(("content", .bytes(content)))
        entries.append(("signature", .bytes(signature)))
        return (try DagCbor.encode(.map(try DagCborMap(entries))), signature)
    }

    public static func decode(_ bytes: [UInt8]) throws -> Received {
        guard case .map(let map) = try DagCbor.decode(bytes, options: .init(strictUTF8: true)),
              let sender = map["sender"]?.mapValue,
              let identityKey = sender["identityKey"]?.bytesValue,
              let content = map["content"]?.bytesValue,
              let signature = map["signature"]?.bytesValue else {
            throw MetanetError.envelope("not a BRC-169 DAG-CBOR envelope")
        }
        return Received(
            map: map, senderIdentityKey: identityKey, content: content, signature: signature
        )
    }

    /// Whether the signature verifies under the sender's identity key. Never throws: any failure
    /// to read the key or the signature is a failure to verify.
    public static func verify(_ received: Received) async -> Bool {
        do {
            let sender = try PublicKey(received.senderIdentityKey)
            let result = try await ProtoWallet.anyone().verifySignature(WalletVerifySignatureRequest(
                protocolID: try signatureProtocol(), keyID: try WalletKeyID(keyID),
                counterparty: .publicKey(sender), payload: .data(try received.signingPreimage()),
                signature: try ECDSASignature(derBytes: received.signature)
            ))
            return result.valid
        } catch {
            return false
        }
    }

    /// The reference's `created`: ISO 8601 in UTC with whole seconds.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

public enum MetanetError: Error, Equatable, Sendable, LocalizedError {
    case envelope(String)
    case delivery(String)
    case brc78(String)
    case handle(String)
    case relay(String)

    public var errorDescription: String? {
        switch self {
        case .envelope(let reason), .delivery(let reason), .brc78(let reason),
             .handle(let reason), .relay(let reason):
            reason
        }
    }
}
