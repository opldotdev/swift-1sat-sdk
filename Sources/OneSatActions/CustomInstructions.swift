import Foundation
import BSVCore
import BSVKeys
import BSVWallet

/// `customInstructions` JSON written by `@1sat/actions`.
///
/// `JSON.stringify` insertion order is `protocolID`, `keyID`, optional `counterparty`, optional
/// extra fields such as `name` or `sym`.
public struct CustomInstructions: Equatable, Sendable {
    public let protocolID: WalletProtocolID
    public let keyID: String
    public let counterparty: WalletCounterparty
    public let name: String?
    public let symbol: String?

    public init(
        protocolID: WalletProtocolID? = nil,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        name: String? = nil,
        symbol: String? = nil
    ) throws {
        self.protocolID = try protocolID ?? OneSatConstants.p1satProtocolID
        self.keyID = keyID
        self.counterparty = counterparty
        self.name = name
        self.symbol = symbol
    }

    public func encoded(includeSelfCounterparty: Bool = false) -> String {
        var pairs: [(String, String)] = [
            (
                "protocolID",
                "[\(protocolID.securityLevel.rawValue),\(Self.jsonString(protocolID.name))]"
            ),
            ("keyID", Self.jsonString(keyID)),
        ]
        switch counterparty {
        case .self:
            if includeSelfCounterparty {
                pairs.append(("counterparty", Self.jsonString("self")))
            }
        case .anyone:
            pairs.append(("counterparty", Self.jsonString("anyone")))
        case .publicKey(let key):
            pairs.append(("counterparty", Self.jsonString(Hex.encode(key.compressedBytes))))
        }
        if let name {
            pairs.append(("name", Self.jsonString(name)))
        }
        if let symbol {
            pairs.append(("sym", Self.jsonString(symbol)))
        }
        let body = pairs.map { "\(Self.jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    public static func parse(_ text: String) throws -> CustomInstructions {
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else {
            throw OneSatActionError.invalidCustomInstructions
        }
        guard let protocolRaw = object["protocolID"] as? [Any],
              protocolRaw.count == 2,
              let levelNumber = protocolRaw[0] as? Int,
              let level = UInt8(exactly: levelNumber),
              let security = WalletSecurityLevel(rawValue: level),
              let protocolName = protocolRaw[1] as? String,
              let keyID = object["keyID"] as? String
        else {
            throw OneSatActionError.invalidCustomInstructions
        }
        let counterparty: WalletCounterparty
        if let raw = object["counterparty"] as? String {
            switch raw {
            case "self":
                counterparty = .self
            case "anyone":
                counterparty = .anyone
            default:
                let bytes = try Hex.decode(raw, maximumDecodedByteCount: 33)
                counterparty = .publicKey(try PublicKey(bytes))
            }
        } else {
            counterparty = .self
        }
        return try CustomInstructions(
            protocolID: WalletProtocolID(securityLevel: security, name: protocolName),
            keyID: keyID,
            counterparty: counterparty,
            name: object["name"] as? String,
            symbol: object["sym"] as? String
        )
    }

    private static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}
