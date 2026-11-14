import Foundation
import BSVCore
import BSVCrypto
import BSVKeys

/// BRC-207 identifiers, byte-for-byte with `@bopen-io/color-permission-module` 0.2.2
/// `identifiers.ts`: asset IDs, wire tags, `p color` protocol IDs, baskets, suffix tags and
/// overlay topics. A Swift wallet and a TS wallet sharing one storage account file and find
/// the same outputs only because these strings match exactly.
public enum ColorIdentifiers {
    /// Asset selector for a deploy output's key derivation, before its asset ID exists.
    public static let issue = "ISSUE"
    /// Fixed BRC-43 key ID of every `p color` key.
    public static let keyID = "color"
    /// `listOutputs` selector for the inventory across every per-asset basket.
    public static let assetsSelector = "p color assets"
    /// Namespace of the per-asset value and authority baskets.
    public static let basketNamespace = "p color"
    /// Tag of a token whose overlay acceptance is still pending.
    public static let offlineTag = "color_offline"
    /// The shared deployment discovery topic.
    public static let discoveryTopic = "tm_color"
    /// BRC-43 caps protocol names at 280 characters.
    public static let maxProtocolNameLength = 280

    /// The topic of one asset, `tm_color_<txid>_<vout>`.
    public static func topic(_ assetID: ColorAssetID) -> String { "tm_color_\(assetID.description)" }

    /// The wire tag of an asset or `ISSUE`: `<txid>v<vout>`, or `issue`.
    public static func tag(_ selector: ColorAssetSelector) -> String {
        switch selector {
        case .issue: "issue"
        case .asset(let id): "\(id.txid)v\(id.vout)"
        }
    }

    /// `[2, "p color <assetTag> <prefix hex> <suffix hex>"]`, the hex being the UTF-8 bytes of
    /// the remittance strings.
    public static func protocolName(
        _ selector: ColorAssetSelector, derivationPrefix: String, derivationSuffix: String
    ) throws -> String {
        try validateRemittance(derivationPrefix)
        try validateRemittance(derivationSuffix)
        let name = "p color \(tag(selector)) \(Hex.encode(Array(derivationPrefix.utf8))) \(Hex.encode(Array(derivationSuffix.utf8)))"
        // TS compares `name.length`, UTF-16 units; the name is ASCII, so bytes and units agree.
        guard name.utf16.count <= maxProtocolNameLength else { throw ColorError.protocolNameTooLong }
        return name
    }

    /// Parses a `p color` protocol name back into its selector and remittance strings.
    public static func parseProtocolName(_ name: String) throws -> (selector: ColorAssetSelector, derivationPrefix: String, derivationSuffix: String) {
        let parts = name.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, parts[0] == "p", parts[1] == "color", name.utf16.count <= maxProtocolNameLength else {
            throw ColorError.invalid("p color protocol name")
        }
        guard isHexTag(parts[3]), isHexTag(parts[4]),
              let prefix = strictUTF8(try Hex.decode(parts[3], maximumDecodedByteCount: 280)),
              let suffix = strictUTF8(try Hex.decode(parts[4], maximumDecodedByteCount: 280)) else {
            throw ColorError.invalid("p color remittance tags")
        }
        try validateRemittance(prefix)
        try validateRemittance(suffix)
        return (try selector(fromTag: parts[2]), prefix, suffix)
    }

    /// The per-asset value basket `p color <tag>` or authority basket `p color <tag> authority`.
    public static func basket(_ assetID: ColorAssetID, role: ColorTokenRole) -> String {
        let basket = "\(basketNamespace) \(tag(.asset(assetID)))"
        return role == .authority ? "\(basket) authority" : basket
    }

    /// Parses a per-asset basket; nil for any other basket.
    public static func parseBasket(_ basket: String) throws -> (assetID: ColorAssetID, role: ColorTokenRole)? {
        let parts = basket.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2, parts[0] == "p", parts[1] == "color", parts[2] != "balance", parts[2] != "assets" else {
            return nil
        }
        return try parseTagged(Array(parts.dropFirst(2)))
    }

    /// Parses `p color balance <tag>` or `p color balance <tag> authority`; nil otherwise.
    public static func parseBalanceSelector(_ basket: String) throws -> (assetID: ColorAssetID, role: ColorTokenRole)? {
        let parts = basket.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 2, parts[0] == "p", parts[1] == "color", parts[2] == "balance" else { return nil }
        return try parseTagged(Array(parts.dropFirst(3)))
    }

    /// `p color ` and the hex SHA-256 of the UTF-8 derivation suffix: the tag filed on every
    /// managed output, so coin selection can find an output without storage keeping the suffix.
    public static func derivationSuffixTag(_ derivationSuffix: String) -> String {
        "\(basketNamespace) \(Hex.encode(BSVHashing.sha256(Array(derivationSuffix.utf8)).bytes))"
    }

    public static func isDerivationSuffixTag(_ tag: String) -> Bool {
        let prefix = "\(basketNamespace) "
        guard tag.hasPrefix(prefix) else { return false }
        let hex = tag.dropFirst(prefix.count)
        return hex.count == 64 && hex.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// A remittance string is nonempty strict UTF-8 without whitespace. Swift strings are always
    /// valid Unicode, so only the emptiness and whitespace checks can fail here.
    public static func validateRemittance(_ value: String) throws {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: isJSWhitespace) else {
            throw ColorError.invalid("remittance string")
        }
    }

    /// A compressed secp256k1 key in lowercase hex.
    public static func validateIdentityKey(_ value: String) throws {
        guard value.utf8.count == 66, value.hasPrefix("02") || value.hasPrefix("03"),
              value.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }),
              (try? PublicKey(Hex.decode(value, maximumDecodedByteCount: 33))) != nil else {
            throw ColorError.invalid("identity key")
        }
    }

    static func selector(fromTag tag: String) throws -> ColorAssetSelector {
        if tag == "issue" { return .issue }
        guard let v = tag.firstIndex(of: "v") else { throw ColorError.invalid("asset tag") }
        let txid = String(tag[..<v]), vout = String(tag[tag.index(after: v)...])
        return .asset(try ColorAssetID(txid: txid, voutText: vout))
    }

    private static func parseTagged(_ rest: [String]) throws -> (assetID: ColorAssetID, role: ColorTokenRole)? {
        guard !rest.isEmpty, rest.count <= 2, rest.count == 1 || rest[1] == "authority" else { return nil }
        guard case .asset(let id) = try selector(fromTag: rest[0]) else {
            throw ColorError.invalid("issue is not a stored basket")
        }
        return (id, rest.count == 2 ? .authority : .value)
    }

    private static func isHexTag(_ text: String) -> Bool {
        !text.isEmpty && text.count % 2 == 0 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// Decodes UTF-8 only when it round-trips: `TextDecoder('utf-8', { fatal: true })`.
    static func strictUTF8(_ bytes: [UInt8]) -> String? {
        let text = String(decoding: bytes, as: UTF8.self)
        return Array(text.utf8) == bytes ? text : nil
    }

    /// JavaScript `\s` with the `u` flag.
    static func isJSWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: true
        default: false
        }
    }
}

public enum ColorTokenRole: String, Sendable, Equatable, Codable {
    case value, authority
}

/// A canonical BRC-162 asset ID, `<64 lowercase hex>_<vout>`, vout a canonical uint32.
public struct ColorAssetID: Hashable, Sendable, CustomStringConvertible, Comparable {
    public let txid: String
    public let vout: UInt32

    public init(txid: String, vout: UInt32) throws {
        guard txid.utf8.count == 64, txid.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else {
            throw ColorError.invalid("asset ID")
        }
        self.txid = txid
        self.vout = vout
    }

    /// Parses `<txid>_<vout>`.
    public init(_ text: String) throws {
        guard let sep = text.firstIndex(of: "_") else { throw ColorError.invalid("asset ID") }
        try self.init(txid: String(text[..<sep]), voutText: String(text[text.index(after: sep)...]))
    }

    init(txid: String, voutText: String) throws {
        // `(0|[1-9]\d{0,9})` then <= 0xffffffff.
        guard !voutText.isEmpty, voutText.count <= 10, voutText.allSatisfy({ ("0"..."9").contains($0) }),
              voutText == "0" || !voutText.hasPrefix("0"),
              let value = UInt64(voutText), value <= UInt64(UInt32.max) else {
            throw ColorError.invalid("asset ID")
        }
        try self.init(txid: txid, vout: UInt32(value))
    }

    public var description: String { "\(txid)_\(vout)" }
    /// The BRC-36 outpoint form, `<txid>.<vout>`.
    public var outpoint: String { "\(txid).\(vout)" }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

/// An asset ID, or `ISSUE` where a deploy output's key is meant.
public enum ColorAssetSelector: Hashable, Sendable, CustomStringConvertible {
    case issue
    case asset(ColorAssetID)

    public init(_ text: String) throws {
        self = text == ColorIdentifiers.issue ? .issue : .asset(try ColorAssetID(text))
    }

    public var description: String {
        switch self {
        case .issue: ColorIdentifiers.issue
        case .asset(let id): id.description
        }
    }
}

public enum ColorError: Error, Equatable, Sendable, LocalizedError {
    case invalid(String)
    case protocolNameTooLong
    case planTooLarge
    case receiptTooLarge
    case overlay(String)
    /// The overlay answered the submission (2xx) but its STEAK for `topic` did not admit these
    /// outputs of the transaction (`<txid>.<vout>`).
    case notAdmitted(topic: String, outpoints: [String])
    case custody(String)
    case unsupportedProfiles

    public var errorDescription: String? {
        switch self {
        case .invalid(let what): "BRC-207: invalid \(what)"
        case .protocolNameTooLong: "BRC-207: protocol name exceeds 280 characters"
        case .planTooLarge: "BRC-207: plan exceeds 16 MiB"
        case .receiptTooLarge: "BRC-207: receipt exceeds 1000 bytes"
        case .overlay(let reason): "BRC-207: \(reason)"
        case .notAdmitted(let topic, let outpoints):
            "BRC-207: the overlay did not admit \(outpoints.joined(separator: ", ")) to \(topic)"
        case .custody(let reason): "BRC-207: \(reason)"
        case .unsupportedProfiles: "BRC-207: the asset requires processing profiles this wallet does not support"
        }
    }
}
