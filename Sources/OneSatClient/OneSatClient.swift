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
            guard output.isInscribed, output.tokenID == nil, !output.isLocked else { return nil }
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
            guard let tokenAmount = output.tokenAmount else {
                throw OneSatClientError.unreadableResponse
            }

            if balances[tokenID] == nil {
                balances[tokenID] = TokenAccumulator(amount: 0, symbol: nil)
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
            return TokenBalance(tokenID: tokenID, amount: balance.amount, symbol: balance.symbol)
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
            URLQueryItem(name: "tags", value: "insc,bsv21"),
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

/// Represents the aggregate a wallet displays instead of individual fungible token outputs.
public struct TokenBalance: Equatable, Sendable {
    public let tokenID: String
    /// Preserves the protocol's integer base-unit amount without applying display decimals.
    public let amount: UInt64
    /// Gives the ticker only when the owner stream itself reported one.
    public let symbol: String?

    /// Allows callers to preserve a balance value across their own read models.
    public init(tokenID: String, amount: UInt64, symbol: String?) {
        self.tokenID = tokenID
        self.amount = amount
        self.symbol = symbol
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

    var tokenID: String? {
        events.first(where: { $0.hasPrefix("bsv21:") }).map {
            String($0.dropFirst("bsv21:".count))
        }.flatMap { $0.isEmpty ? nil : $0 }
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

    var tokenAmount: UInt64? {
        data["bsv21"]?["amt"]?.stringValue.flatMap(UInt64.init)
    }

    var tokenSymbol: String? {
        nonempty(data["bsv21"]?["sym"]?.stringValue)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct TokenAccumulator {
    var amount: UInt64
    var symbol: String?
}
