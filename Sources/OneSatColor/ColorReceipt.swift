import Foundation
import BSVScript
import BSVTransaction
import OneSatTemplates

/// BRC-207 receipt instructions: the `customInstructions` of a `basket insertion` into
/// `p color <assetTag>` (or `… authority`), as BRC-232 carries them and `internalizeAction` takes
/// them. Port of `@1sat/actions` `1color/receipt.ts`.
///
/// The string is exactly `{"version":1,"assetId":…,"derivationPrefix":…,"derivationSuffix":…,
/// "senderIdentityKey":…}`: these members, this order, no whitespace.
public struct ColorReceipt: Equatable, Sendable {
    public let assetID: ColorAssetID
    public let derivationPrefix: String
    public let derivationSuffix: String
    /// Compressed public key, 66 lowercase hex.
    public let senderIdentityKey: String

    public init(assetID: ColorAssetID, derivationPrefix: String, derivationSuffix: String, senderIdentityKey: String) throws {
        _ = try ColorIdentifiers.protocolName(.asset(assetID), derivationPrefix: derivationPrefix, derivationSuffix: derivationSuffix)
        try ColorIdentifiers.validateIdentityKey(senderIdentityKey, name: "senderIdentityKey")
        self.init(checked: assetID, derivationPrefix, derivationSuffix, senderIdentityKey)
    }

    private init(checked assetID: ColorAssetID, _ derivationPrefix: String, _ derivationSuffix: String, _ senderIdentityKey: String) {
        self.assetID = assetID
        self.derivationPrefix = derivationPrefix
        self.derivationSuffix = derivationSuffix
        self.senderIdentityKey = senderIdentityKey
    }

    /// The exact receipt JSON.
    public var customInstructions: String {
        StrictJSON.object([
            ("version", .number(1)),
            ("assetId", .string(assetID.description)),
            ("derivationPrefix", .string(derivationPrefix)),
            ("derivationSuffix", .string(derivationSuffix)),
            ("senderIdentityKey", .string(senderIdentityKey)),
        ]).serialized
    }

    /// Accepts only the exact string ``customInstructions`` produces.
    public init(customInstructions: String) throws {
        // `JSON.parse` in TS; any valid JSON is read, then the round trip must match exactly.
        guard let value = try? StrictJSON.parse(customInstructions, label: "receipt") else {
            throw ColorError.message("receipt customInstructions are not JSON")
        }
        guard case .object(let members) = value,
              members[member: "version"] == .number(1),
              case .string(let asset)? = members[member: "assetId"], asset != ColorIdentifiers.issue,
              case .string(let prefix)? = members[member: "derivationPrefix"],
              case .string(let suffix)? = members[member: "derivationSuffix"],
              case .string(let sender)? = members[member: "senderIdentityKey"],
              ColorIdentifiers.isIdentityKeyHex(sender) else {
            throw ColorError.message("malformed receipt customInstructions")
        }
        // TS `colorProtocolID(assetId, derivationPrefix, derivationSuffix)`: the remittance strings,
        // then the asset ID, then the name's length. TS checks the sender key's form only, not that
        // it is on the curve; the module's custody parse checks that when it takes the receipt in.
        try ColorIdentifiers.validateRemittance(prefix, name: "derivationPrefix")
        try ColorIdentifiers.validateRemittance(suffix, name: "derivationSuffix")
        let assetID = try ColorAssetID(asset)
        _ = try ColorIdentifiers.protocolName(.asset(assetID), derivationPrefix: prefix, derivationSuffix: suffix)
        self.init(checked: assetID, prefix, suffix, sender)
        guard self.customInstructions == customInstructions else {
            throw ColorError.message("receipt customInstructions must be exactly {version, assetId, derivationPrefix, derivationSuffix, senderIdentityKey}")
        }
    }

    /// Checks one received `basket insertion` against its subject transaction: the basket names
    /// the receipt's asset and the output's role, and the output is a 1Color output of that asset.
    public static func check(
        subject: Transaction, outputIndex: Int, basket: String, customInstructions: String
    ) throws -> (assetID: ColorAssetID, role: ColorTokenRole, receipt: ColorReceipt) {
        guard let target = try ColorIdentifiers.parseBasket(basket) else {
            throw ColorError.message("\(basket) is not a per-asset p color basket")
        }
        let receipt = try ColorReceipt(customInstructions: customInstructions)
        guard receipt.assetID == target.assetID else {
            throw ColorError.message("the receipt names \(receipt.assetID), the basket \(target.assetID)")
        }
        guard ColorIdentifiers.basket(target.assetID, role: target.role) == basket else {
            throw ColorError.message("\(basket) is not a canonical basket name")
        }
        guard outputIndex >= 0, outputIndex < subject.outputs.count,
              let token = OneColor.decode(subject.outputs[outputIndex].lockingScript),
              token.role != .deploy, token.tokenID == target.assetID.description,
              (token.role == .authority ? ColorTokenRole.authority : .value) == target.role else {
            // TS throws this one without the `BRC-207: ` prefix.
            throw ColorError.plain("output \(outputIndex): not a 1Color \(target.role.rawValue) output of \(target.assetID)")
        }
        return (target.assetID, target.role, receipt)
    }
}
