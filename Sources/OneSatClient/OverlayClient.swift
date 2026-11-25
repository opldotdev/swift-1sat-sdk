import Foundation

/// `@1sat/client` `OverlayClient`'s submits: the transaction's BEEF as `application/octet-stream`
/// and its topic in `X-Topics`, to `POST {base}/1sat/bsv21/overlay/submit` for BSV-21 and
/// `POST {base}/1sat/market/overlay/submit` for OrdLock v2 listings.
public struct OverlayClient: Sendable {
    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `submitBsv21(beef, tokenId)`: a transfer or mint, to the token's own topic `tm_<tokenId>`.
    public func submitBsv21(tx: [UInt8], tokenID: String) async throws {
        try await submit(
            tx: tx, topics: ["tm_\(tokenID)"], url: Self.bsv21SubmitURL(baseURL: baseURL),
            service: Self.bsv21Service, operation: "OverlayClient.submitBsv21"
        )
    }

    /// `submitBsv21Discovery(beef)`: a deploy, to the discovery topic `tm_bsv21`, so the indexer
    /// starts the new token's own topic.
    public func submitBsv21Discovery(tx: [UInt8]) async throws {
        try await submit(
            tx: tx, topics: ["tm_bsv21"], url: Self.bsv21SubmitURL(baseURL: baseURL),
            service: Self.bsv21Service, operation: "OverlayClient.submitBsv21Discovery"
        )
    }

    /// An OrdLock v2 listing, cancel or purchase, to the market topic `tm_ordlock_v2`, so the
    /// market indexes it. `tx` is the action's BEEF: the topic manager reads the transaction and
    /// the listings it spends from it, and refuses a raw transaction.
    public func submitListing(tx: [UInt8]) async throws {
        try await submit(
            tx: tx, topics: [Self.marketTopic], url: Self.marketSubmitURL(baseURL: baseURL),
            service: Self.marketService, operation: "OverlayClient.submitListing"
        )
    }

    /// The OrdLock v2 market topic (`TopicNameV2` in 1sat-stack `pkg/ordlock`).
    public static let marketTopic = "tm_ordlock_v2"

    private static let bsv21Service = "the BSV-21 token overlay"
    private static let marketService = "the market overlay"

    /// `POST {base}/1sat/bsv21/overlay/submit`.
    public static func bsv21SubmitURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("bsv21")
            .appendingPathComponent("overlay")
            .appendingPathComponent("submit")
    }

    /// `POST {base}/1sat/market/overlay/submit`.
    public static func marketSubmitURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("market")
            .appendingPathComponent("overlay")
            .appendingPathComponent("submit")
    }

    /// Topics go comma-separated, as TS sends them (the stack rejects a JSON array). The STEAK in a
    /// 2xx body is not read: no caller uses it, and an answer this client cannot parse must not
    /// turn an accepted submit into a failure. A status outside 2xx is logged and thrown as
    /// `OneSatClientError.httpFailure`.
    private func submit(
        tx: [UInt8], topics: [String], url: URL, service: String, operation: String
    ) async throws {
        let response = try await transport.send(
            method: "POST",
            url: url,
            headers: [
                "Content-Type": "application/octet-stream",
                "X-Topics": topics.joined(separator: ","),
            ],
            body: tx
        )
        try OneSatClientHTTP.check(
            response, service: service, operation: operation, method: "POST", url: url
        )
    }
}
