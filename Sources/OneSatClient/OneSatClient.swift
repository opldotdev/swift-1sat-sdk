import Foundation
import OneSatSweep
import ToolboxCore
import ToolboxServices

/// Gives wallet displays a truthful read-only view of an address's 1Sat assets.
public struct OneSatClient: Sendable {
    private static let outputLimit = 10_000

    /// Keeps the endpoint and transport injectable so reads are deterministic in tests and apps.
    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        http: any HTTPGet = URLSessionHTTPGet()
    ) {
        self.baseURL = baseURL
        self.http = http
    }

    /// Every ordinal is returned separately because its outpoint is its wallet identity.
    public func ordinals(forAddress address: String) async throws -> [OrdinalOutput] {
        try await outputs(forAddress: address).compactMap { output in
            guard output.isInscribed, !output.isToken, !output.isLocked else { return nil }
            return OrdinalOutput(
                txid: output.txid,
                vout: output.vout,
                satoshis: output.satoshis,
                contentType: output.inscriptionContentType
            )
        }
    }

    /// Token outputs are grouped so a wallet can render one balance per BSV-21 token id.
    public func tokenBalances(forAddress address: String) async throws -> [TokenBalance] {
        let outputs = try await outputs(forAddress: address)
        var balances: [String: TokenAccumulator] = [:]
        var tokenOrder: [String] = []

        for output in outputs {
            guard let tokenID = output.tokenID else { continue }
            let tokenAmount: UInt64
            if let parsed = output.tokenAmount {
                tokenAmount = parsed
            } else if output.hasBsv21Event {
                throw OneSatClientError.unreadableResponse
            } else {
                tokenAmount = 0
            }

            if balances[tokenID] == nil {
                balances[tokenID] = TokenAccumulator(
                    amount: 0,
                    symbol: nil,
                    decimals: output.tokenDecimals,
                    kind: output.tokenKind
                )
                tokenOrder.append(tokenID)
            }
            guard var balance = balances[tokenID] else {
                throw OneSatClientError.unreadableResponse
            }
            let (amount, overflow) = balance.amount.addingReportingOverflow(tokenAmount)
            guard !overflow else { throw OneSatClientError.unreadableResponse }
            balance.amount = amount
            if balance.symbol == nil {
                balance.symbol = output.tokenSymbol
            }
            balances[tokenID] = balance
        }

        return try tokenOrder.map { tokenID in
            guard let balance = balances[tokenID] else {
                throw OneSatClientError.unreadableResponse
            }
            return TokenBalance(
                tokenID: tokenID,
                amount: balance.amount,
                symbol: balance.symbol,
                decimals: balance.decimals,
                kind: balance.kind
            )
        }
    }

    private let baseURL: URL
    private let http: any HTTPGet

    private func outputs(forAddress address: String) async throws -> [IndexedOutput] {
        let endpoint = baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("owner")
            .appendingPathComponent(address)
            .appendingPathComponent("txos")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OneSatClientError.unreadableResponse
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(Self.outputLimit)),
            URLQueryItem(name: "tags", value: "insc,bsv20,bsv21"),
        ]
        guard let url = components.url else { throw OneSatClientError.unreadableResponse }

        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw OneSatClientError.httpFailure(statusCode: status)
        }
        return try Self.parse(sse: body)
    }

    /// Refuses malformed TXO frames so a partial response cannot become a misleading asset view.
    private static func parse(sse body: [UInt8]) throws -> [IndexedOutput] {
        let text = String(decoding: body, as: UTF8.self)
        var outputs: [IndexedOutput] = []

        for frame in text.components(separatedBy: "\n\n") {
            var event = "message"
            var data = ""
            for line in frame.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("event:") {
                    event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    data = String(line.dropFirst("data:".count).drop(while: { $0 == " " }))
                }
            }
            guard event == "txo", !data.isEmpty else { continue }

            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)),
                  let outpoint = json["outpoint"]?.stringValue,
                  let (txid, vout) = OneSatScanner.splitOutpoint(outpoint),
                  let satoshisValue = json["satoshis"]?.intValue,
                  let satoshis = UInt64(exactly: satoshisValue) else {
                throw OneSatClientError.unreadableResponse
            }
            if let spend = json["spend"]?.stringValue, !spend.isEmpty { continue }

            outputs.append(
                IndexedOutput(
                    txid: txid,
                    vout: vout,
                    satoshis: satoshis,
                    events: json["events"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    data: json["data"]?.objectValue ?? [:]
                )
            )
        }
        return outputs
    }
}

/// Carries the outpoint and display metadata needed to identify one owned inscription.
public struct OrdinalOutput: Equatable, Sendable {
    public let txid: String
    public let vout: UInt32
    public let satoshis: UInt64
    /// Explains how a wallet may render the content without fetching it first.
    public let contentType: String?

    /// Allows callers to preserve an ordinal value across their own read models.
    public init(txid: String, vout: UInt32, satoshis: UInt64, contentType: String?) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.contentType = contentType
    }
}

/// Distinguishes tick-based BSV-20 from id-based BSV-21 in a token balance.
public enum TokenKind: String, Equatable, Sendable {
    case bsv20
    case bsv21
}

/// Represents the aggregate a wallet displays instead of individual fungible token outputs.
public struct TokenBalance: Equatable, Sendable {
    public let tokenID: String
    /// Preserves the protocol's integer base-unit amount without applying display decimals.
    public let amount: UInt64
    /// Gives the ticker only when the owner stream itself reported one.
    public let symbol: String?
    /// Display decimals from the indexer, or 0 when the stream omitted them.
    public let decimals: Int
    public let kind: TokenKind

    /// Allows callers to preserve a balance value across their own read models.
    public init(
        tokenID: String,
        amount: UInt64,
        symbol: String?,
        decimals: Int = 0,
        kind: TokenKind = .bsv21
    ) {
        self.tokenID = tokenID
        self.amount = amount
        self.symbol = symbol
        self.decimals = decimals
        self.kind = kind
    }
}

/// Distinguishes transport failures from data that cannot safely represent an asset balance.
public enum OneSatClientError: Error, Equatable, Sendable {
    case unreadableResponse
    case httpFailure(statusCode: Int)
}

private struct IndexedOutput: Sendable {
    let txid: String
    let vout: UInt32
    let satoshis: UInt64
    let events: [String]
    let data: [String: JSONValue]

    var hasBsv21Event: Bool {
        events.contains(where: { $0.hasPrefix("bsv21:") })
    }

    var isTokenInscription: Bool {
        inscriptionContentType == "application/bsv-20"
            || events.contains("type:application/bsv-20")
    }

    var isToken: Bool {
        hasBsv21Event || data["bsv21"] != nil || data["bsv20"] != nil || isTokenInscription
    }

    var tokenKind: TokenKind {
        if hasBsv21Event || data["bsv21"] != nil { return .bsv21 }
        if nonempty(inscriptionJSON?["id"]?.stringValue) != nil { return .bsv21 }
        return .bsv20
    }

    var tokenID: String? {
        if let id = events.first(where: { $0.hasPrefix("bsv21:") }).map({
            String($0.dropFirst("bsv21:".count))
        }).flatMap({ $0.isEmpty ? nil : $0 }) {
            return id
        }
        if let id = nonempty(data["bsv21"]?["id"]?.stringValue) { return id }
        if let tick = nonempty(data["bsv20"]?["tick"]?.stringValue) { return tick }
        if let id = nonempty(inscriptionJSON?["id"]?.stringValue) { return id }
        if let tick = nonempty(inscriptionJSON?["tick"]?.stringValue) { return tick }
        if isToken { return "\(txid)_\(vout)" }
        return nil
    }

    var isInscribed: Bool {
        events.contains(where: { $0 == "insc" || $0.hasPrefix("ord") })
    }

    var isLocked: Bool {
        events.contains(where: { $0 == "lock" || $0.hasPrefix("lock:") })
    }

    var inscriptionContentType: String? {
        nonempty(data["insc"]?["file"]?["type"]?.stringValue)
    }

    var inscriptionJSON: JSONValue? {
        data["insc"]?["json"]
    }

    var tokenAmount: UInt64? {
        integerAmount(data["bsv21"]?["amt"])
            ?? integerAmount(data["bsv20"]?["amt"])
            ?? integerAmount(inscriptionJSON?["amt"])
    }

    var tokenSymbol: String? {
        nonempty(data["bsv21"]?["sym"]?.stringValue)
            ?? nonempty(data["bsv20"]?["tick"]?.stringValue)
            ?? nonempty(data["bsv20"]?["sym"]?.stringValue)
            ?? nonempty(inscriptionJSON?["sym"]?.stringValue)
            ?? nonempty(inscriptionJSON?["tick"]?.stringValue)
    }

    var tokenDecimals: Int {
        integer(data["bsv21"]?["dec"])
            ?? integer(data["bsv20"]?["dec"])
            ?? integer(inscriptionJSON?["dec"])
            ?? 0
    }

    private func integerAmount(_ value: JSONValue?) -> UInt64? {
        if let text = value?.stringValue { return UInt64(text) }
        if let number = value?.intValue { return UInt64(exactly: number) }
        return nil
    }

    private func integer(_ value: JSONValue?) -> Int? {
        if let text = value?.stringValue { return Int(text) }
        return value?.intValue
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct TokenAccumulator {
    var amount: UInt64
    var symbol: String?
    var decimals: Int
    var kind: TokenKind
}
