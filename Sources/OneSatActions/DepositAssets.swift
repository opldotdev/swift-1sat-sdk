import Foundation
import OneSatClient

/// What `syncAddresses` reads from `OneSatServices` beyond the BEEF itself, to classify what
/// arrived at a deposit address the way the `@1sat/wallet` indexers do.
///
/// - `rawTransaction`: `services.beef.getRawTx`, for an input whose source is not in the BEEF.
/// - `ordinalMetadata`: `services.ordfs.getMetadata(outpoint, seq)`, to find a transferred
///   ordinal's origin (`OriginIndexer`).
/// - `ordinalContent`: `services.ordfs.getContent(outpoint).data`, the origin's small text body
///   (an OpNS name).
/// - `tokenDetails`: `services.bsv21.getTokenDetails(id)`; `nil` where the overlay answers 404,
///   which `Bsv21Indexer` takes as "keep the inscription's own values".
public protocol DepositAssetSource: Sendable {
    func rawTransaction(txid: String) async throws -> [UInt8]
    func ordinalMetadata(outpoint: String, seq: Int) async throws -> OrdfsMetadata
    func ordinalContent(outpoint: String) async throws -> [UInt8]
    func tokenDetails(tokenID: String) async throws -> DepositTokenDetails?
}

/// The token facts `Bsv21Indexer` copies from the overlay: `sym`, `Number(dec) || 0`, `icon`.
public struct DepositTokenDetails: Equatable, Sendable {
    public let symbol: String?
    public let decimals: Int
    public let icon: String?

    public init(symbol: String?, decimals: Int, icon: String?) {
        self.symbol = symbol
        self.decimals = decimals
        self.icon = icon
    }
}

public enum DepositAssetError: Error, Equatable, Sendable {
    case httpFailure(statusCode: Int)
}

/// `OneSatServices` against one 1sat-stack host: `/1sat/beef`, `/1sat/ordfs`, `/content`,
/// `/1sat/bsv21`.
public struct OneSatDepositAssets: DepositAssetSource {
    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `BeefClient.getRawTx`: `GET /1sat/beef/<txid>/tx`.
    public func rawTransaction(txid: String) async throws -> [UInt8] {
        try await get(Self.rawTransactionURL(txid: txid, baseURL: baseURL))
    }

    public func ordinalMetadata(outpoint: String, seq: Int) async throws -> OrdfsMetadata {
        try await OrdfsClient(baseURL: baseURL, transport: transport).metadata(outpoint: outpoint, seq: seq)
    }

    /// `OrdfsClient.getContent`: `GET /content/<outpoint>`.
    public func ordinalContent(outpoint: String) async throws -> [UInt8] {
        try await get(OrdfsClient.contentURL(outpoint: outpoint, baseURL: baseURL))
    }

    public func tokenDetails(tokenID: String) async throws -> DepositTokenDetails? {
        do {
            let details = try await Bsv21Client(baseURL: baseURL, transport: transport)
                .tokenDetails(tokenID: tokenID)
            return DepositTokenDetails(
                symbol: details.token.symbol,
                decimals: details.token.decimals.flatMap { Int($0) } ?? 0,
                icon: details.token.icon
            )
        } catch OneSatClientError.httpFailure(statusCode: 404) {
            return nil
        }
    }

    public static func rawTransactionURL(txid: String, baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("beef")
            .appendingPathComponent(txid)
            .appendingPathComponent("tx")
    }

    private func get(_ url: URL) async throws -> [UInt8] {
        let response = try await transport.send(method: "GET", url: url, headers: [:], body: nil)
        guard (200..<300).contains(response.status) else {
            throw DepositAssetError.httpFailure(statusCode: response.status)
        }
        return response.body
    }
}
