import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVWallet

/// The custody tuple of a managed `p color` output, stored as its custom instructions: the
/// receipt-format JSON `{"version":1,"assetId":…,"derivationPrefix":…,"derivationSuffix":…,
/// "senderIdentityKey":…}`. A deploy keeps `ISSUE` as its asset for good.
public struct ColorCustody: Equatable, Sendable {
    public static let maximumReceiptBytes = 1000

    public let asset: ColorAssetSelector
    public let derivationPrefix: String
    public let derivationSuffix: String
    /// Compressed public key, 66 lowercase hex: the counterparty of the output's key.
    public let senderIdentityKey: String

    public init(asset: ColorAssetSelector, derivationPrefix: String, derivationSuffix: String, senderIdentityKey: String) throws {
        _ = try ColorIdentifiers.protocolName(asset, derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix)
        try ColorIdentifiers.validateIdentityKey(senderIdentityKey)
        self.asset = asset
        self.derivationPrefix = derivationPrefix
        self.derivationSuffix = derivationSuffix
        self.senderIdentityKey = senderIdentityKey
    }

    /// `JSON.stringify({ version: 1, ...custody })`.
    public var json: String {
        StrictJSON.object([
            ("version", .number(1)),
            ("assetId", .string(asset.description)),
            ("derivationPrefix", .string(derivationPrefix)),
            ("derivationSuffix", .string(derivationSuffix)),
            ("senderIdentityKey", .string(senderIdentityKey)),
        ]).serialized
    }

    /// The tag filed on the output, by which its transaction is listed.
    public var suffixTag: String { ColorIdentifiers.derivationSuffixTag(derivationSuffix) }

    /// Parses stored or received custody: exactly the five members, plus an optional empty
    /// `profileData`. `maxBytes` bounds a receipt.
    public static func parse(_ text: String, maxBytes: Int? = nil, label: String = "custody") throws -> ColorCustody {
        if let maxBytes, text.utf8.count > maxBytes {
            throw ColorError.custody("\(label) exceeds \(maxBytes) bytes")
        }
        let value = try StrictJSON.parse(text, label: label)
        guard case .object(let members) = value else { throw ColorError.custody("\(label) is not an object") }
        try StrictJSON.exactMembers(
            members,
            required: ["version", "assetId", "derivationPrefix", "derivationSuffix", "senderIdentityKey"],
            optional: ["profileData"], label: label
        )
        guard members[member: "version"] == .number(1) else { throw ColorError.custody("\(label) version must be 1") }
        if let profileData = members[member: "profileData"] {
            guard case .object(let entries) = profileData else {
                throw ColorError.custody("\(label).profileData must be an object")
            }
            guard entries.isEmpty else {
                throw ColorError.custody("\(label).profileData names a profile the asset does not require")
            }
        }
        guard case .string(let asset)? = members[member: "assetId"],
              case .string(let prefix)? = members[member: "derivationPrefix"],
              case .string(let suffix)? = members[member: "derivationSuffix"],
              case .string(let sender)? = members[member: "senderIdentityKey"] else {
            throw ColorError.custody("\(label) members must be strings")
        }
        return try ColorCustody(asset: try ColorAssetSelector(asset), derivationPrefix: prefix,
                                derivationSuffix: suffix, senderIdentityKey: sender)
    }
}

/// `p color` keys: protocol `[2, "p color <tag> <prefix hex> <suffix hex>"]`, key ID `color`.
public enum ColorKeys {
    public static func protocolID(_ selector: ColorAssetSelector, derivationPrefix: String, derivationSuffix: String) throws -> WalletProtocolID {
        try WalletProtocolID(
            securityLevel: .everyAppAndCounterparty,
            name: try ColorIdentifiers.protocolName(selector, derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix)
        )
    }

    /// The key a sender locks a recipient's output to: counterparty the recipient, not for self.
    public static func recipientPublicKey(
        identity: PrivateKey, asset: ColorAssetSelector, derivationPrefix: String,
        derivationSuffix: String, recipient: PublicKey
    ) throws -> PublicKey {
        try WalletKeyDeriver(rootKey: identity).derivePublicKey(
            protocolID: try protocolID(asset, derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix),
            keyID: try WalletKeyID(ColorIdentifiers.keyID),
            counterparty: .publicKey(recipient), forSelf: false
        )
    }

    /// This wallet's key for a custody tuple: counterparty the custody's sender, for self.
    public static func ownPublicKey(identity: PrivateKey, custody: ColorCustody) throws -> PublicKey {
        try WalletKeyDeriver(rootKey: identity).derivePublicKey(
            protocolID: try protocolID(custody.asset, derivationPrefix: custody.derivationPrefix, derivationSuffix: custody.derivationSuffix),
            keyID: try WalletKeyID(ColorIdentifiers.keyID),
            counterparty: .publicKey(try sender(custody)), forSelf: true
        )
    }

    /// The spending key of a managed output.
    public static func privateKey(identity: PrivateKey, custody: ColorCustody) throws -> PrivateKey {
        try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try protocolID(custody.asset, derivationPrefix: custody.derivationPrefix, derivationSuffix: custody.derivationSuffix),
            keyID: try WalletKeyID(ColorIdentifiers.keyID),
            counterparty: .publicKey(try sender(custody))
        )
    }

    /// Fails unless the output is a P2PKH remainder locked to this wallet's key for the custody.
    public static func assertOwned(_ token: ColorTokenOutput, custody: ColorCustody, identity: PrivateKey) throws {
        guard let hash = token.pubKeyHash else {
            throw ColorError.custody("a managed token output must have a P2PKH remainder")
        }
        let key = try ownPublicKey(identity: identity, custody: custody)
        guard BSVHashing.hash160(key.compressedBytes).bytes == hash else {
            throw ColorError.custody("the token output is not locked to this wallet's p color key")
        }
    }

    public static func hash160(_ key: PublicKey) -> [UInt8] {
        BSVHashing.hash160(key.compressedBytes).bytes
    }

    static func sender(_ custody: ColorCustody) throws -> PublicKey {
        try PublicKey(Hex.decode(custody.senderIdentityKey, maximumDecodedByteCount: 33))
    }
}

/// Custody at rest is encrypted as the TypeScript wallet's permissions manager stores it:
/// BRC-2 under `[2, "admin metadata encryption"]`, key ID `1`, counterparty self, base64.
/// Plaintext custody written by an earlier Swift build still reads.
public enum ColorMetadata {
    public static func encrypt(_ plaintext: String, identity: PrivateKey) async throws -> String {
        let result = try await ProtoWallet(rootKey: identity).encrypt(WalletEncryptRequest(
            protocolID: .walletMetadataEncryption, keyID: try WalletKeyID("1"),
            counterparty: .self, plaintext: Array(plaintext.utf8)
        ))
        return Data(result.ciphertext).base64EncodedString()
    }

    /// Plaintext JSON passes through; ciphertext is decrypted. Nil when it cannot be read.
    public static func decrypt(_ stored: String, identity: PrivateKey) async -> String? {
        if stored.hasPrefix("{") { return stored }
        guard let data = Data(base64Encoded: stored) else { return nil }
        guard let result = try? await ProtoWallet(rootKey: identity).decrypt(WalletDecryptRequest(
            protocolID: .walletMetadataEncryption, keyID: try WalletKeyID("1"),
            counterparty: .self, ciphertext: Array(data)
        )) else { return nil }
        return String(bytes: result.plaintext, encoding: .utf8)
    }
}
