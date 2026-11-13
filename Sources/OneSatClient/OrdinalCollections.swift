import Foundation
import ToolboxCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Outpoint string handling for the two separator forms the ecosystem uses interchangeably.
///
/// The owner stream and `collectionId` values arrive as both `txid.vout` and `txid_vout`
/// (`OriginIndexer` writes dots, `collections` mints underscores). One canonical form — the
/// dot — is used everywhere inside this module, and the underscore form is produced only at
/// the URL boundary, where the content endpoints document it.
public enum Outpoint {
    /// Canonicalises either separator form to `txid.vout`.
    public static func normalize(_ outpoint: String) -> String {
        outpoint.replacingOccurrences(of: "_", with: ".")
    }

    /// The `txid_vout` form the ORDFS content and image endpoints take in their path.
    public static func urlForm(_ outpoint: String) -> String {
        normalize(outpoint).replacingOccurrences(of: ".", with: "_")
    }

    static func join(txid: String, vout: UInt32) -> String {
        "\(txid).\(vout)"
    }
}

/// The one non-GET call this module makes, kept injectable the same way `HTTPGet` is so the
/// metadata read is deterministic in tests.
public protocol HTTPPost: Sendable {
    func post(_ url: URL, body: [UInt8], contentType: String) async throws
        -> (status: Int, body: [UInt8])
}

/// The real POST over `URLSession`.
public struct URLSessionHTTPPost: HTTPPost {
    public init() {}

    public func post(_ url: URL, body: [UInt8], contentType: String) async throws
        -> (status: Int, body: [UInt8]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, [UInt8](data))
    }
}

/// What ORDFS knows about one inscription origin: its content shape and the MAP metadata that
/// names it and places it in a collection.
///
/// `subTypeData` arrives as a JSON string inside the MAP JSON — the double encoding is an
/// on-chain convention, decoded here once so no caller re-learns it.
public struct OrdinalMetadata: Equatable, Sendable {
    /// The origin outpoint this record describes, in canonical `txid.vout` form.
    public let outpoint: String
    public let contentType: String?
    /// The untruncated MAP `name` (the owner stream's `name:` event caps at 64 characters).
    public let name: String?
    /// `"collection"` for a collection's own inscription, `"collectionItem"` for a member.
    public let subType: String?
    /// The parent collection's origin outpoint, canonical form. Present only on members.
    public let collectionID: String?
    public let mintNumber: Int?
    public let rarityLabel: String?
    /// A collection inscription's own description, from its `subTypeData`.
    public let description: String?

    public init(
        outpoint: String, contentType: String?, name: String?, subType: String?,
        collectionID: String?, mintNumber: Int?, rarityLabel: String?, description: String?
    ) {
        self.outpoint = outpoint
        self.contentType = contentType
        self.name = name
        self.subType = subType
        self.collectionID = collectionID
        self.mintNumber = mintNumber
        self.rarityLabel = rarityLabel
        self.description = description
    }
}

/// One owned ordinal joined with its origin metadata, ready for display.
public struct OwnedOrdinal: Equatable, Sendable {
    public let output: OrdinalOutput
    public let metadata: OrdinalMetadata?

    /// The name a wallet shows: the untruncated ORDFS name when known, else the stream's.
    public var displayName: String? { metadata?.name ?? output.name }

    public init(output: OrdinalOutput, metadata: OrdinalMetadata?) {
        self.output = output
        self.metadata = metadata
    }
}

/// A collection the address holds members of, grouped for one wallet card.
public struct OrdinalCollection: Equatable, Sendable {
    /// The collection inscription's origin outpoint — the ecosystem's collection id.
    public let id: String
    /// The collection's MAP name, when its origin inscription could be read.
    public let name: String?
    public let description: String?
    /// The outpoint whose content is the collection's cover art: the collection inscription
    /// itself when it is an image, else the first held member.
    public let coverOutpoint: String
    /// Held members, in the order the owner stream reported them.
    public let items: [OwnedOrdinal]

    public init(
        id: String, name: String?, description: String?, coverOutpoint: String,
        items: [OwnedOrdinal]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.coverOutpoint = coverOutpoint
        self.items = items
    }
}

/// Everything an address holds, shaped the way a wallet stacks it: one entry per collection,
/// then the ordinals that belong to none.
public struct OrdinalHoldings: Equatable, Sendable {
    public let collections: [OrdinalCollection]
    public let singles: [OwnedOrdinal]

    public init(collections: [OrdinalCollection], singles: [OwnedOrdinal]) {
        self.collections = collections
        self.singles = singles
    }
}

extension OneSatClient {
    /// The most origins one bulk metadata request may carry, per the endpoint's contract.
    static let metadataBatchLimit = 100

    /// Reads ORDFS metadata for a set of outpoints, batched under the endpoint's limit.
    ///
    /// The result is keyed by canonical outpoint and omits outpoints ORDFS does not know —
    /// a null record is an answer ("no metadata"), not an error, because an inscription with
    /// no MAP data is a perfectly valid ordinal.
    public func metadata(
        forOutpoints outpoints: [String],
        http: any HTTPPost = URLSessionHTTPPost()
    ) async throws -> [String: OrdinalMetadata] {
        let canonical = outpoints.map(Outpoint.normalize)
        var results: [String: OrdinalMetadata] = [:]

        for batchStart in stride(from: 0, to: canonical.count, by: Self.metadataBatchLimit) {
            let batch = Array(
                canonical[batchStart..<min(batchStart + Self.metadataBatchLimit, canonical.count)]
            )
            let url = baseURL
                .appendingPathComponent("1sat")
                .appendingPathComponent("ordfs")
                .appendingPathComponent("metadata")
            let body = try JSONEncoder().encode(["outpoints": batch])
            let (status, responseBody) = try await http.post(
                url, body: [UInt8](body), contentType: "application/json"
            )
            guard (200..<300).contains(status) else {
                throw OneSatClientError.httpFailure(statusCode: status)
            }
            guard let json = try? JSONDecoder().decode(
                JSONValue.self, from: Data(responseBody)
            ), let object = json.objectValue else {
                throw OneSatClientError.unreadableResponse
            }

            for (key, value) in object {
                guard let record = Self.parseMetadata(
                    outpoint: Outpoint.normalize(key), json: value
                ) else { continue }
                results[record.outpoint] = record
            }
        }

        return results
    }

    /// Reads an address's ordinals and shapes them into collection groups plus loose singles.
    ///
    /// Three reads compose: the owner stream, bulk metadata for every held origin, then bulk
    /// metadata for the collections those origins name. A member whose collection record cannot
    /// be read still groups — the collection just shows without a name until ORDFS can serve it.
    public func ordinalHoldings(
        forAddress address: String,
        http: any HTTPPost = URLSessionHTTPPost()
    ) async throws -> OrdinalHoldings {
        let outputs = try await ordinals(forAddress: address)
        return try await holdings(for: outputs, http: http)
    }

    /// The composition above, from already-fetched outputs — the entry point for a wallet that
    /// reads several addresses and wants one grouped result.
    public func holdings(
        for outputs: [OrdinalOutput],
        http: any HTTPPost = URLSessionHTTPPost()
    ) async throws -> OrdinalHoldings {
        guard !outputs.isEmpty else { return OrdinalHoldings(collections: [], singles: []) }

        let origins = Array(Set(outputs.map(\.origin)))
        let originMetadata = try await metadata(forOutpoints: origins, http: http)

        let owned = outputs.map {
            OwnedOrdinal(output: $0, metadata: originMetadata[$0.origin])
        }

        var members: [String: [OwnedOrdinal]] = [:]
        var collectionOrder: [String] = []
        var singles: [OwnedOrdinal] = []
        for ordinal in owned {
            guard let collectionID = ordinal.metadata?.collectionID else {
                singles.append(ordinal)
                continue
            }
            if members[collectionID] == nil { collectionOrder.append(collectionID) }
            members[collectionID, default: []].append(ordinal)
        }

        let collectionMetadata = collectionOrder.isEmpty
            ? [:]
            : try await metadata(forOutpoints: collectionOrder, http: http)

        let collections = collectionOrder.map { id in
            let items = members[id] ?? []
            let record = collectionMetadata[id]
            // The collection inscription doubles as cover art when it is an image; a
            // collection minted with non-image content falls back to its first held member.
            let cover = record?.contentType?.hasPrefix("image/") == true
                ? id
                : (items.first?.output.origin ?? id)
            return OrdinalCollection(
                id: id,
                name: record?.name,
                description: record?.description,
                coverOutpoint: cover,
                items: items
            )
        }
        .sorted { left, right in
            if left.items.count != right.items.count {
                return left.items.count > right.items.count
            }
            return (left.name ?? left.id) < (right.name ?? right.id)
        }

        return OrdinalHoldings(collections: collections, singles: singles)
    }

    /// The URL serving an inscription's full content.
    public func contentURL(forOutpoint outpoint: String) -> URL {
        baseURL
            .appendingPathComponent("content")
            .appendingPathComponent(Outpoint.urlForm(outpoint))
    }

    /// The URL serving an inscription resized server-side, for card thumbnails.
    ///
    /// `fill` crops to cover the box, matching how a card frames square art; webp keeps the
    /// payload small. A caller that needs the untouched bytes uses `contentURL` instead.
    public func imageURL(forOutpoint outpoint: String, width: Int, height: Int) -> URL {
        let endpoint = baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("ordfs")
            .appendingPathComponent("image")
            .appendingPathComponent(Outpoint.urlForm(outpoint))
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "w", value: String(width)),
            URLQueryItem(name: "h", value: String(height)),
            URLQueryItem(name: "fit", value: "fill"),
            URLQueryItem(name: "f", value: "webp"),
        ]
        return components?.url ?? endpoint
    }

    /// One metadata record, or nil for a null/unreadable entry — ORDFS answers null for
    /// outpoints it has no record of, and that absence is data, not a failure.
    private static func parseMetadata(outpoint: String, json: JSONValue) -> OrdinalMetadata? {
        guard let object = json.objectValue else { return nil }
        let map = object["map"]?.objectValue

        // The double-encoded layer: MAP's `subTypeData` is a JSON string inside the JSON.
        var collectionID: String?
        var mintNumber: Int?
        var rarityLabel: String?
        var description: String?
        if let raw = map?["subTypeData"]?.stringValue,
           let inner = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)),
           let fields = inner.objectValue {
            collectionID = fields["collectionId"]?.stringValue.map(Outpoint.normalize)
            mintNumber = fields["mintNumber"]?.intValue
                ?? fields["mintNumber"]?.stringValue.flatMap(Int.init)
            rarityLabel = fields["rarityLabel"]?.stringValue
            description = fields["description"]?.stringValue
        }

        return OrdinalMetadata(
            outpoint: outpoint,
            contentType: object["contentType"]?.stringValue,
            name: map?["name"]?.stringValue,
            subType: map?["subType"]?.stringValue,
            collectionID: collectionID,
            mintNumber: mintNumber,
            rarityLabel: rarityLabel,
            description: description
        )
    }
}
