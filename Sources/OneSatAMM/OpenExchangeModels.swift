import Foundation

/// `Defaults` (lib/skein.ts:159): what a new token instance is created with, each part absent
/// when unset. Read by `GET <swap>/defaults`.
public struct OpenExchangeDefaults: Equatable, Sendable {
    public struct Terms: Equatable, Sendable {
        public let lpFeeBps: Int
        public let validatorFeeBps: Int
        public let commissionBps: Int
        /// Present when the defaults set one above zero.
        public let minLegSats: Int?
    }

    public struct Market: Equatable, Sendable {
        public let minCommissionBps: Int
    }

    public let terms: Terms?
    public let market: Market?
    /// The price in sats to enable a token on `POST /amm/enable`; nil when paid enable is off.
    public let enablePriceSats: UInt64?

    /// `readDefaults` (lib/skein.ts:199).
    static func read(_ value: JSONValue?) -> OpenExchangeDefaults {
        var terms: Terms?
        if let t = value?["terms"], let lp = t["lpFeeBps"]?.int, let validator = t["validatorFeeBps"]?.int,
           let commission = t["commissionBps"]?.int {
            let min = t["minLegSats"]?.int.flatMap { $0 > 0 ? $0 : nil }
            terms = Terms(lpFeeBps: lp, validatorFeeBps: validator, commissionBps: commission, minLegSats: min)
        }
        let market = value?["market"]?["minCommissionBps"]?.int.map(Market.init(minCommissionBps:))
        let price = value?["enablePriceSats"]?.number.flatMap { $0 > 0 ? UInt64(exactly: $0) : nil }
        return OpenExchangeDefaults(terms: terms, market: market, enablePriceSats: price)
    }
}

/// `EnabledToken` (lib/skein.ts:124): a token on the swap instance's list, `GET <swap>/tokens`.
public struct OpenExchangeToken: Equatable, Sendable {
    public enum Status: String, Sendable { case enabled, disabled }

    public let tokenId: String
    public let topic: String
    public let sym: String
    public let dec: Int
    public let icon: String?
    public let status: Status
    /// When root last enabled or disabled it, ms.
    public let since: Double

    /// One row as `readTokens` (lib/skein.ts:142) maps it; nil for a row it filters out. A row's
    /// icon: its `icon`, else its `iconUrl` made absolute against `listURL`.
    static func read(_ row: JSONValue, listURL: String) -> OpenExchangeToken? {
        guard let tokenId = row["tokenId"]?.string, let status = row["status"]?.string.flatMap(Status.init) else {
            return nil
        }
        var icon = row["icon"]?.string
        if icon == nil, let iconUrl = row["iconUrl"]?.string, !iconUrl.isEmpty {
            icon = URL(string: iconUrl, relativeTo: URL(string: listURL))?.absoluteString
        }
        return OpenExchangeToken(
            tokenId: tokenId,
            topic: row["topic"]?.string ?? "tm_color_\(tokenId)",
            sym: row["sym"]?.string ?? "",
            dec: row["dec"]?.int ?? 0,
            icon: icon,
            status: status,
            since: row["since"]?.number ?? 0
        )
    }

    /// The same row with its token id written `<txid>_<vout>` (`enabledList`, client.ts:783).
    func canonical() -> OpenExchangeToken {
        guard let id = AMMTokenID.parseOutpoint(Self.firstUnderscoreAsDot(tokenId)) else { return self }
        return OpenExchangeToken(
            tokenId: id.description, topic: topic, sym: sym, dec: dec, icon: icon, status: status, since: since
        )
    }

    /// `text.replace("_", ".")`: the first underscore only.
    static func firstUnderscoreAsDot(_ text: String) -> String {
        guard let index = text.firstIndex(of: "_") else { return text }
        var out = text
        out.replaceSubrange(index...index, with: ".")
        return out
    }
}

/// The row a paid enable answers (`{fn: "enable", result}`, open-exchange config main.zig
/// `enablePaid`): the enabled token with the payment kept on it.
public struct OpenExchangeListing: Equatable, Sendable {
    /// The row as the token list shows it; nil when the answer's row lacks a token id or status.
    public let token: OpenExchangeToken?
    /// The payer's identity key, hex.
    public let paidBy: String?
    public let paymentTxid: String?
    public let satoshisPaid: UInt64?

    static func read(_ result: JSONValue?, listURL: String) -> OpenExchangeListing {
        OpenExchangeListing(
            token: result.flatMap { OpenExchangeToken.read($0, listURL: listURL) },
            paidBy: result?["paidBy"]?.string,
            paymentTxid: result?["paymentTxid"]?.string,
            satoshisPaid: result?["satoshisPaid"]?.number.flatMap { UInt64(exactly: $0) }
        )
    }
}

/// A parsed JSON value with JavaScript's types: `typeof` number, string, boolean, object.
enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    /// `res.json()`; nil when the bytes are not JSON (`.catch(() => ({}))`).
    static func parse(_ bytes: [UInt8]) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(bytes))
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var int: Int? { number.flatMap { Int(exactly: $0) } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }

    /// `String(v)` of a JSON value, as the client writes a code it did not check the type of.
    var text: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value): value == value.rounded() && abs(value) <= 9_007_199_254_740_991 ? String(Int64(value)) : String(value)
        case .string(let value): value
        case .array(let items): items.map(\.text).joined(separator: ",")
        case .object: "[object Object]"
        }
    }
}
