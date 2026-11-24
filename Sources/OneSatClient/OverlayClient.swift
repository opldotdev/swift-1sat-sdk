import Foundation

/// `@1sat/client` `OverlayClient`'s BSV-21 submits: `POST {base}/1sat/bsv21/overlay/submit` with the
/// transaction as `application/octet-stream` and its topic in `X-Topics`.
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
        try await submit(tx: tx, topics: ["tm_\(tokenID)"], operation: "OverlayClient.submitBsv21")
    }

    /// `submitBsv21Discovery(beef)`: a deploy, to the discovery topic `tm_bsv21`, so the indexer
    /// starts the new token's own topic.
    public func submitBsv21Discovery(tx: [UInt8]) async throws {
        try await submit(tx: tx, topics: ["tm_bsv21"], operation: "OverlayClient.submitBsv21Discovery")
    }

    /// `POST {base}/1sat/bsv21/overlay/submit`.
    public static func bsv21SubmitURL(baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("bsv21")
            .appendingPathComponent("overlay")
            .appendingPathComponent("submit")
    }

    /// Topics go comma-separated, as TS sends them (the stack rejects a JSON array). The STEAK in a
    /// 2xx body is not read: no caller uses it, and an answer this client cannot parse must not
    /// turn an accepted submit into a failure. A status outside 2xx is logged and thrown as
    /// `OneSatClientError.httpFailure`.
    private func submit(tx: [UInt8], topics: [String], operation: String) async throws {
        let url = Self.bsv21SubmitURL(baseURL: baseURL)
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
            response, service: "the BSV-21 token overlay", operation: operation, method: "POST", url: url
        )
    }
}
