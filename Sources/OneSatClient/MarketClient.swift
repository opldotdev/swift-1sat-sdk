import Foundation
import OneSatSweep

/// One OrdLock v2 listing as the market (`/1sat/market`) serves it: an `IndexedOutput` whose
/// `data.ordlock` holds the listing. A row without `data.ordlock` is not a listing and fails to
/// decode.
public struct MarketListing: Equatable, Sendable, Decodable {
    /// How the listing was spent (`spend_type`): the unlock's branch selector, as 1sat-stack
    /// `classifySpend` reads it.
    public enum SpendType: Equatable, Sendable {
        case sale
        case cancel
        /// Any other value, as served (the stack writes `unknown` for an unlock it cannot read).
        case unknown(String)

        init(_ value: String) {
            switch value {
            case "sale": self = .sale
            case "cancel": self = .cancel
            default: self = .unknown(value)
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// Unspent: still for sale.
        case active
        /// Bought.
        case sold
        /// Cancelled by the seller.
        case cancelled
        /// Spent some way the market could not classify.
        case spent
    }

    /// The listing output, as served (`txid.vout`).
    public let outpoint: String
    /// When the listing was indexed; the sort and cursor key of active listings.
    public let score: Double
    /// The spending transaction's id, once the listing is spent.
    public let spend: String?
    /// The ordinal's origin outpoint (`txid.vout`).
    public let origin: String?
    public let name: String?
    public let contentType: String?
    /// Satoshis the listing demands, from its payout output.
    public let price: UInt64
    /// The seller's cancel address.
    public let seller: String
    public let spendType: SpendType?
    /// When the spend was indexed; the sort and cursor key of sold and cancelled listings.
    public let spendScore: Double?

    public init(
        outpoint: String,
        score: Double,
        spend: String? = nil,
        origin: String? = nil,
        name: String? = nil,
        contentType: String? = nil,
        price: UInt64,
        seller: String,
        spendType: SpendType? = nil,
        spendScore: Double? = nil
    ) {
        self.outpoint = outpoint
        self.score = score
        self.spend = spend
        self.origin = origin
        self.name = name
        self.contentType = contentType
        self.price = price
        self.seller = seller
        self.spendType = spendType
        self.spendScore = spendScore
    }

    public var status: Status {
        switch spendType {
        case .sale: .sold
        case .cancel: .cancelled
        case .unknown: .spent
        case nil: spend == nil ? .active : .spent
        }
    }

    private enum Keys: String, CodingKey {
        case outpoint, score, spend, data
    }

    private enum DataKeys: String, CodingKey {
        case ordlock
    }

    private enum ListingKeys: String, CodingKey {
        case origin, name, price, seller
        case contentType = "content_type"
        case spendType = "spend_type"
        case spendScore = "spend_score"
    }

    public init(from decoder: any Decoder) throws {
        let row = try decoder.container(keyedBy: Keys.self)
        let listing = try row
            .nestedContainer(keyedBy: DataKeys.self, forKey: .data)
            .nestedContainer(keyedBy: ListingKeys.self, forKey: .ordlock)
        outpoint = try row.decode(String.self, forKey: .outpoint)
        score = try row.decode(Double.self, forKey: .score)
        spend = try row.decodeIfPresent(String.self, forKey: .spend)
        origin = try listing.decodeIfPresent(String.self, forKey: .origin)
        name = try listing.decodeIfPresent(String.self, forKey: .name)
        contentType = try listing.decodeIfPresent(String.self, forKey: .contentType)
        price = try listing.decode(UInt64.self, forKey: .price)
        seller = try listing.decode(String.self, forKey: .seller)
        spendType = try listing.decodeIfPresent(String.self, forKey: .spendType).map(SpendType.init)
        spendScore = try listing.decodeIfPresent(Double.self, forKey: .spendScore)
    }
}

/// One page of a market search, and the cursor for the next.
public struct MarketPage: Equatable, Sendable {
    public let rows: [MarketListing]
    /// Pass as `from` for the next page: the last row's `score` for active listings, its
    /// `spendScore` for sold and cancelled ones. Nil when this page came back short, so there is
    /// no next page.
    public let nextFrom: Double?

    public init(rows: [MarketListing], nextFrom: Double?) {
        self.rows = rows
        self.nextFrom = nextFrom
    }
}

/// `@1sat/client` `MarketClient`: the `/1sat/market` listing reads.
///
/// - GET `/listings`: search
/// - GET `/listing/:outpoint`: one listing, spent or not
/// - GET `/origin/:origin`: the active listing of an origin
/// - POST `/origins`: the active listings of many origins
///
/// Only mainnet runs a market (`OneSatAPI.marketURL(for:)`). A status outside 2xx is logged with
/// the server's message and thrown as `OneSatClientError.httpFailure`; the single lookups answer
/// nil for a 404, which means there is no such listing.
public struct MarketClient: Sendable {
    /// `status` of `searchListings`.
    public enum SearchStatus: String, Equatable, Sendable {
        /// Unspent listings, newest first by `score`.
        case active
        /// Sold listings, by `spend_score`.
        case sale
        /// Cancelled listings, by `spend_score`.
        case cancel
    }

    /// The most origins one POST `/origins` carries; ``listings(origins:)`` sends more in chunks.
    public static let originsChunkSize = 100

    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    /// `baseURL` is the API host (`OneSatAPI.marketURL(for:)`); the client adds `/1sat/market`.
    public init(
        baseURL: URL = OneSatAPI.mainnetURL,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `searchListings`: one page of listings. `type` is an exact content type, `query` a name
    /// prefix (case-insensitive on the hosted stack). `from` is exclusive: pass the previous page's
    /// `nextFrom`. `reverse` (default) is newest first.
    public func searchListings(
        status: SearchStatus = .active,
        type: String? = nil,
        query: String? = nil,
        limit: Int = 20,
        from: Double? = nil,
        reverse: Bool = true
    ) async throws -> MarketPage {
        let url = Self.searchURL(
            baseURL: baseURL, status: status, type: type, query: query, limit: limit, from: from, reverse: reverse
        )
        let rows = try OneSatClientHTTP.decode(
            [MarketListing].self,
            try await transport.send(method: "GET", url: url, headers: [:], body: nil),
            service: Self.service, operation: "MarketClient.searchListings", method: "GET", url: url
        )
        let nextFrom: Double?
        if rows.count < limit {
            nextFrom = nil
        } else {
            switch status {
            case .active: nextFrom = rows.last?.score
            case .sale, .cancel: nextFrom = rows.last?.spendScore
            }
        }
        return MarketPage(rows: rows, nextFrom: nextFrom)
    }

    /// `getListing`: the listing at `outpoint`, spent or not. Nil when the market has none.
    public func listing(outpoint: String) async throws -> MarketListing? {
        try await lookup(Self.listingURL(outpoint: outpoint, baseURL: baseURL), operation: "MarketClient.listing(outpoint:)")
    }

    /// `getListingByOrigin`: the active listing of `origin`. Nil when it is not listed.
    public func listing(origin: String) async throws -> MarketListing? {
        try await lookup(Self.originURL(origin: origin, baseURL: baseURL), operation: "MarketClient.listing(origin:)")
    }

    /// `getListingsByOrigins`: the active listings of `origins`, keyed by origin as the market
    /// writes it (`txid.vout`). An origin with no active listing has no entry. More than
    /// ``originsChunkSize`` origins go in several requests.
    public func listings(origins: [String]) async throws -> [String: MarketListing] {
        let url = Self.originsURL(baseURL: baseURL)
        var merged: [String: MarketListing] = [:]
        var start = origins.startIndex
        while start < origins.endIndex {
            let end = min(start + Self.originsChunkSize, origins.endIndex)
            let body = Array(try JSONEncoder().encode(Array(origins[start..<end])))
            // The stack answers `null` for an empty map.
            let page = try OneSatClientHTTP.decode(
                [String: MarketListing]?.self,
                try await transport.send(
                    method: "POST", url: url, headers: ["Content-Type": "application/json"], body: body
                ),
                service: Self.service, operation: "MarketClient.listings(origins:)", method: "POST", url: url
            )
            merged.merge(page ?? [:]) { _, new in new }
            start = end
        }
        return merged
    }

    // MARK: URLs

    /// `{base}/1sat/market/listings` with `status`, `limit` and `rev` always, and `type`, `q`
    /// and `from` when given.
    public static func searchURL(
        baseURL: URL,
        status: SearchStatus = .active,
        type: String? = nil,
        query: String? = nil,
        limit: Int = 20,
        from: Double? = nil,
        reverse: Bool = true
    ) -> URL {
        var items: [(String, String)] = [("status", status.rawValue)]
        if let type { items.append(("type", type)) }
        if let query { items.append(("q", query)) }
        items.append(("limit", String(limit)))
        if let from { items.append(("from", String(from))) }
        items.append(("rev", reverse ? "true" : "false"))
        let query = items.map { "\($0.0)=\(URIComponent.encode($0.1))" }.joined(separator: "&")
        return URL(string: "\(root(baseURL))/listings?\(query)")!
    }

    public static func listingURL(outpoint: String, baseURL: URL) -> URL {
        URL(string: "\(root(baseURL))/listing/\(URIComponent.encode(outpoint))")!
    }

    public static func originURL(origin: String, baseURL: URL) -> URL {
        URL(string: "\(root(baseURL))/origin/\(URIComponent.encode(origin))")!
    }

    public static func originsURL(baseURL: URL) -> URL {
        URL(string: "\(root(baseURL))/origins")!
    }

    // MARK: Private

    private static let service = "the market"

    private func lookup(_ url: URL, operation: String) async throws -> MarketListing? {
        let response = try await transport.send(method: "GET", url: url, headers: [:], body: nil)
        // No such listing: an answer, not a failure to log.
        if response.status == 404 { return nil }
        return try OneSatClientHTTP.decode(
            MarketListing.self, response, service: Self.service, operation: operation, method: "GET", url: url
        )
    }

    private static func root(_ baseURL: URL) -> String {
        var absolute = baseURL.absoluteString
        if absolute.hasSuffix("/") { absolute.removeLast() }
        return "\(absolute)/1sat/market"
    }
}

/// `encodeURIComponent`: every byte outside `A-Za-z0-9-_.!~*'()` percent-encoded, so `+` in
/// `image/svg+xml` and `/` stay data.
enum URIComponent {
    static func encode(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "!"),
                 UInt8(ascii: "~"), UInt8(ascii: "*"), UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded.append(String(format: "%%%02X", byte))
            }
        }
        return encoded
    }
}
