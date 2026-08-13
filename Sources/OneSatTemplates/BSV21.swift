import Foundation
import BSVScript

/// A BSV-21 token inscription (`application/bsv-20` JSON inside an inscription envelope).
///
/// Matches `@1sat/templates` `BSV21`. The JSON field order is part of the locking script.
public struct BSV21: Equatable, Sendable {
    public enum Operation: String, Equatable, Sendable {
        case deployMint = "deploy+mint"
        case deployAuth = "deploy+auth"
        case mint
        case auth
        case transfer
        case burn
    }

    public struct TokenData: Equatable, Sendable {
        public let operation: Operation
        public let symbol: String?
        public let decimals: Int?
        public let icon: String?
        public let tokenID: String?
        public let amount: String?
    }

    public let tokenData: TokenData
    public let inscription: Inscription

    public static func deployMint(
        symbol: String,
        amount: String,
        decimals: Int = 0,
        icon: String? = nil
    ) throws -> BSV21 {
        try validateSymbol(symbol)
        try validateAmount(amount)
        try validateDecimals(decimals)
        let data = TokenData(
            operation: .deployMint,
            symbol: symbol,
            decimals: decimals > 0 ? decimals : nil,
            icon: nonempty(icon),
            tokenID: nil,
            amount: amount
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public static func deployAuth(
        symbol: String,
        decimals: Int = 0,
        icon: String? = nil
    ) throws -> BSV21 {
        try validateSymbol(symbol)
        try validateDecimals(decimals)
        let data = TokenData(
            operation: .deployAuth,
            symbol: symbol,
            decimals: decimals > 0 ? decimals : nil,
            icon: nonempty(icon),
            tokenID: nil,
            amount: nil
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public static func mint(tokenID: String, amount: String) throws -> BSV21 {
        try validateTokenID(tokenID)
        try validateAmount(amount)
        let data = TokenData(
            operation: .mint,
            symbol: nil,
            decimals: nil,
            icon: nil,
            tokenID: tokenID,
            amount: amount
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public static func auth(tokenID: String) throws -> BSV21 {
        try validateTokenID(tokenID)
        let data = TokenData(
            operation: .auth,
            symbol: nil,
            decimals: nil,
            icon: nil,
            tokenID: tokenID,
            amount: nil
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public static func transfer(tokenID: String, amount: String) throws -> BSV21 {
        try validateTokenID(tokenID)
        try validateAmount(amount)
        let data = TokenData(
            operation: .transfer,
            symbol: nil,
            decimals: nil,
            icon: nil,
            tokenID: tokenID,
            amount: amount
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public static func burn(tokenID: String, amount: String) throws -> BSV21 {
        try validateTokenID(tokenID)
        try validateAmount(amount)
        let data = TokenData(
            operation: .burn,
            symbol: nil,
            decimals: nil,
            icon: nil,
            tokenID: tokenID,
            amount: amount
        )
        return BSV21(tokenData: data, inscription: try inscription(for: data))
    }

    public func lock(lockingScript: Script? = nil) throws -> Script {
        guard let lockingScript else { return try inscription.lock() }
        let wrapped = try Inscription.fromText(
            Self.wireJSON(tokenData),
            contentType: "application/bsv-20",
            scriptSuffix: lockingScript
        )
        return try wrapped.lock()
    }

    public static func decode(_ script: Script) -> BSV21? {
        guard let inscription = Inscription.decode(script),
              inscription.contentType == "application/bsv-20",
              let text = String(bytes: inscription.content, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let json = object as? [String: Any],
              json["p"] as? String == "bsv-20",
              let opRaw = json["op"] as? String,
              let operation = Operation(rawValue: opRaw.lowercased())
        else { return nil }

        let isAuth = operation == .deployAuth || operation == .auth
        if isAuth {
            guard json["amt"] == nil else { return nil }
        } else {
            guard let amt = json["amt"] as? String, (try? validateAmount(amt)) != nil
            else { return nil }
        }

        switch operation {
        case .deployMint, .deployAuth:
            guard let symbol = json["sym"] as? String else { return nil }
            guard (try? validateSymbol(symbol)) != nil else { return nil }
            var decimals: Int?
            if let dec = json["dec"] {
                guard let decString = dec as? String, let parsed = Int(decString) else { return nil }
                guard (try? validateDecimals(parsed)) != nil else { return nil }
                decimals = parsed
            }
            let amount = json["amt"] as? String
            let data = TokenData(
                operation: operation,
                symbol: symbol,
                decimals: decimals,
                icon: nonempty(json["icon"] as? String),
                tokenID: nil,
                amount: amount
            )
            return BSV21(tokenData: data, inscription: inscription)

        case .mint, .auth, .transfer, .burn:
            guard let tokenID = json["id"] as? String else { return nil }
            guard (try? validateTokenID(tokenID)) != nil else { return nil }
            let data = TokenData(
                operation: operation,
                symbol: nil,
                decimals: nil,
                icon: nil,
                tokenID: tokenID,
                amount: json["amt"] as? String
            )
            return BSV21(tokenData: data, inscription: inscription)
        }
    }

    private static func inscription(for data: TokenData) throws -> Inscription {
        try Inscription.fromText(wireJSON(data), contentType: "application/bsv-20")
    }

    /// Field order is part of the script. Do not alphabetize.
    private static func wireJSON(_ data: TokenData) -> String {
        var pairs: [(String, String)] = [
            ("p", "bsv-20"),
            ("op", data.operation.rawValue),
        ]
        switch data.operation {
        case .deployMint, .deployAuth:
            if let symbol = data.symbol { pairs.append(("sym", symbol)) }
            if let amount = data.amount { pairs.append(("amt", amount)) }
            if let decimals = data.decimals { pairs.append(("dec", String(decimals))) }
            if let icon = data.icon { pairs.append(("icon", icon)) }
        case .mint, .transfer, .burn:
            if let tokenID = data.tokenID { pairs.append(("id", tokenID)) }
            if let amount = data.amount { pairs.append(("amt", amount)) }
        case .auth:
            if let tokenID = data.tokenID { pairs.append(("id", tokenID)) }
        }
        let body = pairs.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",")
        return "{\(body)}"
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

    private static func validateSymbol(_ symbol: String) throws {
        guard !symbol.isEmpty, symbol.count <= 32 else {
            throw BSV21Error.invalidSymbol
        }
    }

    private static func validateDecimals(_ decimals: Int) throws {
        guard (0...18).contains(decimals) else { throw BSV21Error.invalidDecimals }
    }

    private static func validateAmount(_ amount: String) throws {
        guard let value = UInt64(amount), value > 0 else { throw BSV21Error.invalidAmount }
    }

    private static func validateTokenID(_ tokenID: String) throws {
        let parts = tokenID.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 64, parts[1].allSatisfy(\.isNumber) else {
            throw BSV21Error.invalidTokenID
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

public enum BSV21Error: Error, Equatable, Sendable {
    case invalidSymbol
    case invalidDecimals
    case invalidAmount
    case invalidTokenID
}
