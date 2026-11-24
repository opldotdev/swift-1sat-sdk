import Foundation

/// `@1sat/client` `BeefClient.getBeef`: the BEEF of one transaction, `GET {base}/1sat/beef/{txid}`.
///
/// The indexer answers Atomic BEEF (BRC-95) for a known transaction; `OneSatBEEF` in
/// `OneSatActions` reads it, and that module makes this client a `ListingBeefSource`.
public struct BeefClient: Sendable {
    public let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// The BEEF bytes as the indexer sent them. A status outside 2xx is logged with the service's
    /// answer and thrown as `OneSatClientError.httpFailure`; TS throws its `HttpError` there too.
    public func beef(forTxid txid: String) async throws -> [UInt8] {
        let url = Self.url(forTxid: txid, baseURL: baseURL)
        let response = try await transport.send(method: "GET", url: url, headers: [:], body: nil)
        try OneSatClientHTTP.check(
            response, service: "the 1Sat indexer", operation: "BeefClient.beef(forTxid:)", method: "GET", url: url
        )
        return response.body
    }

    /// `GET {base}/1sat/beef/{txid}`.
    public static func url(forTxid txid: String, baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("beef")
            .appendingPathComponent(txid)
    }
}
