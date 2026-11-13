import Foundation
import BSVScript
import OneSatCBOR
import OneSatTemplates

/// One BRC-162 output read the way `@bopen-io/color-permission-module` 0.2.2 `readTokenOutput`
/// reads it: the asset, role, amount, whether it is the deploy, and the public key hash when the
/// rest of the script is plain P2PKH.
public struct ColorTokenOutput: Equatable, Sendable {
    public let assetID: ColorAssetID
    public let role: ColorTokenRole
    public let amount: UInt64
    /// The asset's deploy output, whose key uses the `ISSUE` selector.
    public let deploy: Bool
    /// Set when the remainder after the prefix is exactly P2PKH.
    public let pubKeyHash: [UInt8]?

    /// Nil for a script without the token layout. Throws for a deploy at a vout other than 0 and
    /// for a payload that requires processing profiles, which this wallet does not support.
    public static func read(_ script: Script, txid: String, vout: UInt32) throws -> ColorTokenOutput? {
        guard let token = OneColor.decode(script) else { return nil }
        try assertNoRequiredProfiles(token)
        let deploy = token.role == .deploy
        let assetID: ColorAssetID
        if deploy {
            guard vout == 0 else { throw ColorError.invalid("deploy: a BRC-162 deploy must be output 0") }
            assetID = try ColorAssetID(txid: txid, vout: 0)
        } else {
            guard let id = token.tokenID else { return nil }
            assetID = try ColorAssetID(id)
        }
        return ColorTokenOutput(
            assetID: assetID,
            role: token.amount == 0 ? .authority : .value,
            amount: token.amount,
            deploy: deploy,
            pubKeyHash: payToPublicKeyHash(token.lock.bytes)
        )
    }

    /// Whether a custody selector names this output: `ISSUE` names the deploy, an asset ID any
    /// other output of that asset.
    public func isSelected(by selector: ColorAssetSelector) -> Bool {
        switch selector {
        case .issue: deploy
        case .asset(let id): !deploy && id == assetID
        }
    }

    /// `OP_DUP OP_HASH160 <20> OP_EQUALVERIFY OP_CHECKSIG`.
    static func payToPublicKeyHash(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count == 25, bytes[0] == 0x76, bytes[1] == 0xa9, bytes[2] == 0x14,
              bytes[23] == 0x88, bytes[24] == 0xac else { return nil }
        return Array(bytes[3..<23])
    }

    /// The module supports no processing profiles: a payload map whose `req` has entries fails,
    /// and a malformed `req` or `ext`, or an invalid profile identifier, fails too.
    static func assertNoRequiredProfiles(_ token: OneColorToken) throws {
        guard let map = token.payloadMap else { return }
        let req = map["req"], ext = map["ext"]
        if let req, req.mapValue == nil { throw ColorError.invalid("req in a BRC-162 payload") }
        if let ext, ext.mapValue == nil { throw ColorError.invalid("ext in a BRC-162 payload") }
        let names = (req?.mapValue?.entries ?? []).map(\.key) + (ext?.mapValue?.entries ?? []).map(\.key)
        for name in names where !isProfileID(name) {
            throw ColorError.invalid("processing-profile identifier in a BRC-162 payload")
        }
        if let entries = req?.mapValue?.entries, !entries.isEmpty {
            throw ColorError.unsupportedProfiles
        }
    }

    /// `^[a-z][a-z0-9+.-]*:[\x21-\x7e]+$`, at most 200 characters.
    static func isProfileID(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        guard bytes.count <= 200, let colon = bytes.firstIndex(of: UInt8(ascii: ":")), colon > 0,
              colon < bytes.count - 1, (97...122).contains(bytes[0]) else { return false }
        let scheme = bytes[1..<colon].allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || $0 == 43 || $0 == 46 || $0 == 45
        }
        return scheme && bytes[(colon + 1)...].allSatisfy { (0x21...0x7e).contains($0) }
    }
}
