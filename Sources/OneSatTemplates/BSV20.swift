import Foundation
import BSVScript

/// A tick-based BSV-20 inscription (`application/bsv-20` JSON inside an inscription envelope).
///
/// Matches `@1sat/templates` `BSV20`. Field order is part of the locking script.
public struct BSV20: Equatable, Sendable {
    public enum Operation: String, Equatable, Sendable {
        case deploy
        case mint
        case transfer
        case burn
    }

    public struct TokenData: Equatable, Sendable {
        public let operation: Operation
        public let tick: String
        public let amount: String?
    }

    public let tokenData: TokenData
    public let inscription: Inscription

    public static func transfer(tick: String, amount: String) throws -> BSV20 {
        try validateTick(tick)
        try validateAmount(amount)
        let data = TokenData(operation: .transfer, tick: tick, amount: amount)
        return BSV20(tokenData: data, inscription: try inscription(for: data))
    }

    public static func burn(tick: String, amount: String) throws -> BSV20 {
        try validateTick(tick)
        try validateAmount(amount)
        let data = TokenData(operation: .burn, tick: tick, amount: amount)
        return BSV20(tokenData: data, inscription: try inscription(for: data))
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

    public static func decode(_ script: Script) -> BSV20? {
        guard let inscription = Inscription.decode(script),
              inscription.contentType == "application/bsv-20",
              let text = String(bytes: inscription.content, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let json = object as? [String: Any],
              json["p"] as? String == "bsv-20",
              json["id"] == nil,
              let opRaw = json["op"] as? String,
              let operation = Operation(rawValue: opRaw.lowercased()),
              let tick = json["tick"] as? String,
              (try? validateTick(tick)) != nil
        else { return nil }

        let amount = json["amt"] as? String
        if operation == .transfer || operation == .burn {
            guard let amount, (try? validateAmount(amount)) != nil else { return nil }
        }
        return BSV20(
            tokenData: TokenData(operation: operation, tick: tick, amount: amount),
            inscription: inscription
        )
    }

    private static func inscription(for data: TokenData) throws -> Inscription {
        try Inscription.fromText(wireJSON(data), contentType: "application/bsv-20")
    }

    /// Field order is part of the script. Do not alphabetize.
    private static func wireJSON(_ data: TokenData) -> String {
        var pairs: [(String, String)] = [
            ("p", "bsv-20"),
            ("op", data.operation.rawValue),
            ("tick", data.tick),
        ]
        if let amount = data.amount {
            pairs.append(("amt", amount))
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

    private static func validateTick(_ tick: String) throws {
        guard !tick.isEmpty, tick.count <= 32 else { throw BSV20Error.invalidTick }
    }

    private static func validateAmount(_ amount: String) throws {
        guard let value = UInt64(amount), value > 0 else { throw BSV20Error.invalidAmount }
    }
}

public enum BSV20Error: Error, Equatable, Sendable {
    case invalidTick
    case invalidAmount
}
