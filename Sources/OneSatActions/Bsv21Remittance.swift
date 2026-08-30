import Foundation
import BSVTransaction
import BSVWallet

/// BRC-163 BSV-21 remittance. Port of `packages/actions/src/utils/bsv21Remittance.ts`.
///
/// CI holds load-bearing token fields plus derivation. Tags are listOutputs filters only.
public enum Bsv21Remittance {
    public static let deployTag = "bsv21:deploy"
    public static let authTag = "bsv21:auth"

    public struct Fields: Equatable, Sendable {
        public var id: String?
        public var amt: String
        public var op: String?
        public var symbol: String?
        public var decimals: String?
        public var icon: String?

        public init(
            id: String? = nil,
            amt: String,
            op: String? = nil,
            symbol: String? = nil,
            decimals: String? = nil,
            icon: String? = nil
        ) {
            self.id = id
            self.amt = amt
            self.op = op
            self.symbol = symbol
            self.decimals = decimals
            self.icon = icon
        }
    }

    public struct OutputFields: Equatable, Sendable {
        public var tokenId: String?
        public var amt: String?
        public var symbol: String?
        public var decimals: String?
        public var icon: String?
        public var isDeploy: Bool
        public var isAuth: Bool

        public init(
            tokenId: String? = nil,
            amt: String? = nil,
            symbol: String? = nil,
            decimals: String? = nil,
            icon: String? = nil,
            isDeploy: Bool = false,
            isAuth: Bool = false
        ) {
            self.tokenId = tokenId
            self.amt = amt
            self.symbol = symbol
            self.decimals = decimals
            self.icon = icon
            self.isDeploy = isDeploy
            self.isAuth = isAuth
        }
    }

    /// `formatOrdinalOutpoint` from `@1sat/types`. Underscore form.
    public static func formatOrdinalOutpoint(_ outpoint: String) -> String {
        let trimmed = outpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.utf8.count >= 66 {
            let bytes = Array(trimmed.utf8)
            if bytes.count > 64, bytes[64] == 0x2e || bytes[64] == 0x5f {
                return String(decoding: bytes[0..<64], as: UTF8.self)
                    + "_"
                    + String(decoding: bytes[65...], as: UTF8.self)
            }
        }
        if let dot = trimmed.firstIndex(of: "."),
           trimmed.distance(from: trimmed.startIndex, to: dot) == 64
        {
            return String(trimmed[..<dot]) + "_" + String(trimmed[trimmed.index(after: dot)...])
        }
        return trimmed.replacingOccurrences(of: ".", with: "_")
    }

    public static func normalizeTokenId(_ id: String) -> String {
        formatOrdinalOutpoint(id.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Filter tags only (exact listOutputs match).
    public static func filterTags(
        tokenId: String? = nil,
        deploy: Bool = false,
        auth: Bool = false
    ) -> [String] {
        var tags: [String] = []
        if let tokenId { tags.append("bsv21:\(tokenId)") }
        if deploy { tags.append(deployTag) }
        if auth { tags.append(authTag) }
        return tags
    }

    /// CI: token fields + optional derivation. Key order matches TS `JSON.stringify`.
    public static func buildCustomInstructions(
        token: Fields,
        protocolID: WalletProtocolID? = nil,
        keyID: String? = nil,
        counterparty: String? = nil
    ) -> String {
        var pairs: [(String, String)] = []
        if let id = token.id, !id.isEmpty {
            pairs.append(("id", RemittanceJSON.string(id)))
        }
        pairs.append(("amt", RemittanceJSON.string(token.amt)))
        if let op = token.op { pairs.append(("op", RemittanceJSON.string(op))) }
        if let symbol = token.symbol { pairs.append(("sym", RemittanceJSON.string(symbol))) }
        if let decimals = token.decimals { pairs.append(("dec", RemittanceJSON.string(decimals))) }
        if let icon = token.icon { pairs.append(("icon", RemittanceJSON.string(icon))) }
        if let protocolID {
            pairs.append(("protocolID", RemittanceJSON.protocolID(protocolID)))
        }
        if let keyID { pairs.append(("keyID", RemittanceJSON.string(keyID))) }
        if let counterparty { pairs.append(("counterparty", RemittanceJSON.string(counterparty))) }
        return RemittanceJSON.object(pairs)
    }

    public static func parseCustomInstructions(_ text: String?) -> (
        fields: Fields?,
        keyID: String?,
        counterparty: String?
    ) {
        guard let text, let object = RemittanceJSON.dictionary(text) else {
            return (nil, nil, nil)
        }
        let amt = object["amt"] as? String
        let fields = Fields(
            id: object["id"] as? String,
            amt: amt ?? "",
            op: object["op"] as? String,
            symbol: object["sym"] as? String,
            decimals: object["dec"] as? String,
            icon: object["icon"] as? String
        )
        return (
            amt == nil && fields.id == nil && fields.symbol == nil ? nil : fields,
            object["keyID"] as? String,
            object["counterparty"] as? String
        )
    }

    /// CI → tags → deploy outpoint. Token id is never the BRC-164 `id:` list key.
    public static func fields(from output: WalletOutput) -> OutputFields {
        fields(
            tags: output.tags,
            customInstructions: output.customInstructions,
            outpoint: output.outpoint.ordinalDescription
        )
    }

    public static func fields(
        tags: [String]?,
        customInstructions: String?,
        outpoint: String?
    ) -> OutputFields {
        let parsed = parseCustomInstructions(customInstructions)
        let tags = tags ?? []
        let isDeploy = tags.contains { $0.lowercased() == deployTag }
        let isAuth = tags.contains { $0.lowercased() == authTag }

        var tokenId = parsed.fields?.id
        if tokenId == nil {
            if let tag = tags.first(where: { tag in
                let n = tag.lowercased()
                return n.hasPrefix("bsv21:") && n != deployTag && n != authTag
            }) {
                tokenId = String(tag.dropFirst(6))
            }
        }
        if tokenId == nil, isDeploy, let outpoint {
            tokenId = formatOrdinalOutpoint(outpoint)
        }

        var amt = parsed.fields?.amt
        if amt == nil || amt?.isEmpty == true {
            amt = tags.first { $0.hasPrefix("amt:") }.map { String($0.dropFirst(4)) }
        }
        if amt?.isEmpty == true { amt = nil }

        var symbol = parsed.fields?.symbol
        if symbol == nil {
            symbol = tags.first { $0.hasPrefix("sym:") }.map { String($0.dropFirst(4)) }
        }
        var decimals = parsed.fields?.decimals
        if decimals == nil {
            decimals = tags.first { $0.hasPrefix("dec:") }.map { String($0.dropFirst(4)) }
        }
        var icon = parsed.fields?.icon
        if icon == nil {
            icon = tags.first { $0.hasPrefix("icon:") }.map { String($0.dropFirst(5)) }
        }

        return OutputFields(
            tokenId: tokenId,
            amt: amt,
            symbol: symbol,
            decimals: decimals,
            icon: icon,
            isDeploy: isDeploy,
            isAuth: isAuth
        )
    }

    /// Value tips only — skip pure auth rows in balances.
    public static func isBalanceable(_ output: WalletOutput) -> Bool {
        let f = fields(from: output)
        if f.isAuth && !f.isDeploy { return false }
        if let op = parseOp(output.customInstructions), op == "auth" || op == "deploy+auth" {
            return false
        }
        guard let amt = f.amt, amt != "0", !amt.isEmpty else { return false }
        return true
    }

    public static func overwrite(
        _ existingJSON: String,
        id: String? = nil,
        amt: String? = nil,
        op: String? = nil,
        symbol: String? = nil,
        decimals: String? = nil,
        icon: String? = nil
    ) throws -> String {
        guard var object = RemittanceJSON.dictionary(existingJSON) else {
            throw OneSatActionError.invalidCustomInstructions
        }
        if let id { object["id"] = id }
        if let amt { object["amt"] = amt }
        if let op { object["op"] = op }
        if let symbol { object["sym"] = symbol }
        if let decimals { object["dec"] = decimals }
        if let icon { object["icon"] = icon }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw OneSatActionError.invalidCustomInstructions
        }
        return text
    }

    private static func parseOp(_ ci: String?) -> String? {
        guard let ci, let object = RemittanceJSON.dictionary(ci) else { return nil }
        return object["op"] as? String
    }
}

enum RemittanceJSON {
    static func string(_ value: String) -> String {
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

    static func protocolID(_ id: WalletProtocolID) -> String {
        "[\(id.securityLevel.rawValue),\(string(id.name))]"
    }

    static func object(_ pairs: [(String, String)]) -> String {
        let body = pairs.map { "\(string($0.0)):\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    static func dictionary(_ text: String) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return nil }
        return object
    }
}
