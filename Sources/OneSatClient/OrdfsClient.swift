import Foundation
import ToolboxCore

/// `OrdfsMetadata` from `@1sat/types`: what `/1sat/ordfs/metadata` returns for one inscription.
///
/// Only `outpoint` is required. TS reads the rest without checking, so a member the server leaves
/// out decodes as `nil` instead of failing a whole bulk response.
public struct OrdfsMetadata: Equatable, Sendable, Decodable {
    public let outpoint: String
    public let origin: String?
    public let sequence: Int?
    public let contentType: String?
    public let contentLength: Int?
    public let parent: String?
    public let map: [String: JSONValue]?

    public init(
        outpoint: String,
        origin: String? = nil,
        sequence: Int? = nil,
        contentType: String? = nil,
        contentLength: Int? = nil,
        parent: String? = nil,
        map: [String: JSONValue]? = nil
    ) {
        self.outpoint = outpoint
        self.origin = origin
        self.sequence = sequence
        self.contentType = contentType
        self.contentLength = contentLength
        self.parent = parent
        self.map = map
    }
}

/// `OrdfsContentOptions` from `@1sat/types`. A `false` flag is left out of the query, as in TS.
public struct OrdfsContentOptions: Equatable, Sendable {
    /// Sequence number: -1 for latest, 0 or more for a specific one.
    public var seq: Int?
    /// Include MAP data in the `X-Map` header.
    public var map: Bool
    /// Include the parent outpoint in the `X-Parent` header.
    public var parent: Bool
    /// Return raw directory JSON instead of resolving it.
    public var raw: Bool

    public init(seq: Int? = nil, map: Bool = false, parent: Bool = false, raw: Bool = false) {
        self.seq = seq
        self.map = map
        self.parent = parent
        self.raw = raw
    }
}

/// `OrdfsClient` from `@1sat/client`: inscription metadata and content URLs.
///
/// API routes live under `/1sat/ordfs`; content is served from the root `/content`. Outpoints are
/// passed through as given, so callers use the `txid_vout` form (see `OrdinalOutpoint.format`).
public struct OrdfsClient: Sendable {
    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `getMetadata(outpoint, seq?)`: `GET /1sat/ordfs/metadata/<outpoint>[:seq]`.
    public func metadata(outpoint: String, seq: Int? = nil) async throws -> OrdfsMetadata {
        try decode(
            try await transport.send(
                method: "GET",
                url: Self.metadataURL(outpoint: outpoint, seq: seq, baseURL: baseURL),
                headers: [:],
                body: nil
            ),
            as: OrdfsMetadata.self
        )
    }

    /// `bulkMetadata(outpoints)`: one `POST /1sat/ordfs/metadata` with `{"outpoints": [...]}`.
    ///
    /// Keys come back as provided, including any `:seq` suffix; a missing inscription is `nil`.
    /// No batching here, as in TS: the API takes at most 100 per request, so callers chunk.
    public func bulkMetadata(_ outpoints: [String]) async throws -> [String: OrdfsMetadata?] {
        let body = Array(try JSONEncoder().encode(["outpoints": outpoints]))
        return try decode(
            try await transport.send(
                method: "POST",
                url: Self.bulkMetadataURL(baseURL: baseURL),
                headers: ["Content-Type": "application/json"],
                body: body
            ),
            as: [String: OrdfsMetadata?].self
        )
    }

    /// `getContentUrl(outpoint, options)`: a URL to put in an image or video view.
    public func contentURL(outpoint: String, options: OrdfsContentOptions = OrdfsContentOptions()) -> URL {
        Self.contentURL(outpoint: outpoint, options: options, baseURL: baseURL)
    }

    public static func metadataURL(outpoint: String, seq: Int? = nil, baseURL: URL) -> URL {
        let path = seq.map { "\(outpoint):\($0)" } ?? outpoint
        return url("\(trimmedBase(baseURL))/1sat/ordfs/metadata/\(path)")
    }

    public static func bulkMetadataURL(baseURL: URL) -> URL {
        url("\(trimmedBase(baseURL))/1sat/ordfs/metadata")
    }

    public static func contentURL(
        outpoint: String,
        options: OrdfsContentOptions = OrdfsContentOptions(),
        baseURL: URL
    ) -> URL {
        let path = options.seq.map { "\(outpoint):\($0)" } ?? outpoint
        // `buildQueryString` order: map, parent, raw; only `true` flags are written.
        let query = [("map", options.map), ("parent", options.parent), ("raw", options.raw)]
            .filter(\.1)
            .map { "\($0.0)=true" }
        let suffix = query.isEmpty ? "" : "?" + query.joined(separator: "&")
        return url("\(trimmedBase(baseURL))/content/\(path)\(suffix)")
    }

    private func decode<T: Decodable>(
        _ response: (status: Int, body: [UInt8]),
        as type: T.Type
    ) throws -> T {
        guard (200..<300).contains(response.status) else {
            throw OneSatClientError.httpFailure(statusCode: response.status)
        }
        guard let value = try? JSONDecoder().decode(type, from: Data(response.body)) else {
            throw OneSatClientError.unreadableResponse
        }
        return value
    }

    private static func trimmedBase(_ baseURL: URL) -> String {
        let absolute = baseURL.absoluteString
        return absolute.hasSuffix("/") ? String(absolute.dropLast()) : absolute
    }

    private static func url(_ string: String) -> URL {
        URL(string: string)!
    }
}
