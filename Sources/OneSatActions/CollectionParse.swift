import Foundation
import BSVCore
import BSVWallet

public enum RoyaltyType: String, Equatable, Sendable {
    case paymail
    case address
    case script
}

public struct Royalty: Equatable, Sendable {
    public let type: RoyaltyType
    public let destination: String
    public let percentage: String

    public init(type: RoyaltyType, destination: String, percentage: String) {
        self.type = type
        self.destination = destination
        self.percentage = percentage
    }
}

/// One TS `Rarity` object, kept as ordered entries because JSON.stringify order is the script.
public struct RarityLabelEntry: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public typealias RarityLabel = [RarityLabelEntry]

public struct CollectionTrait: Equatable, Sendable {
    public let values: [String]
    public let occurancePercentages: [String]

    public init(values: [String], occurancePercentages: [String]) {
        self.values = values
        self.occurancePercentages = occurancePercentages
    }
}

/// One TS `CollectionTraits` entry, ordered.
public struct CollectionTraitEntry: Equatable, Sendable {
    public let name: String
    public let trait: CollectionTrait

    public init(name: String, trait: CollectionTrait) {
        self.name = name
        self.trait = trait
    }
}

public struct CollectionSubTypeData: Equatable, Sendable {
    public let description: String
    public let quantity: Int
    public let rarityLabels: [RarityLabel]
    public let traits: [CollectionTraitEntry]

    public init(
        description: String,
        quantity: Int,
        rarityLabels: [RarityLabel] = [],
        traits: [CollectionTraitEntry] = []
    ) {
        self.description = description
        self.quantity = quantity
        self.rarityLabels = rarityLabels
        self.traits = traits
    }
}

public struct CollectionItemTrait: Equatable, Sendable {
    public let name: String
    public let value: String
    public let rarityLabel: String?
    public let occurancePercentrage: String?

    public init(
        name: String,
        value: String,
        rarityLabel: String? = nil,
        occurancePercentrage: String? = nil
    ) {
        self.name = name
        self.value = value
        self.rarityLabel = rarityLabel
        self.occurancePercentrage = occurancePercentrage
    }
}

public struct CollectionItemAttachment: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let contentType: String
    public let url: String

    public init(name: String, description: String? = nil, contentType: String, url: String) {
        self.name = name
        self.description = description
        self.contentType = contentType
        self.url = url
    }
}

public struct CollectionItemSubTypeData: Equatable, Sendable {
    public let collectionId: String
    public let mintNumber: Int?
    public let rank: Int?
    public let rarityLabel: String?
    public let traits: [CollectionItemTrait]
    public let attachments: [CollectionItemAttachment]

    public init(
        collectionId: String,
        mintNumber: Int? = nil,
        rank: Int? = nil,
        rarityLabel: String? = nil,
        traits: [CollectionItemTrait] = [],
        attachments: [CollectionItemAttachment] = []
    ) {
        self.collectionId = collectionId
        self.mintNumber = mintNumber
        self.rank = rank
        self.rarityLabel = rarityLabel
        self.traits = traits
        self.attachments = attachments
    }
}

public enum CollectionParseError: Error, Equatable, Sendable {
    case invalidCollectionId(String)
}

/// Collection MAP types, collectionId parse, 36-byte parent layout, and tag grouping.
public enum CollectionParse {
    /// Wallet tag strings mint writes (`collections/index.ts:451-456, 645-651`).
    public static let parentTag = "subType:collection"
    public static let itemTag = "subType:collectionItem"
    public static let collectionTagPrefix = "collection:"
    public static let collectionIdTagPrefix = "collectionId:"

    /// `collectionIdToParentBytes`: 32-byte txid reversed to internal order + 4-byte vout LE.
    public static func parentBytes(collectionId: String) throws -> [UInt8] {
        guard let id = absoluteCollectionId(collectionId),
              let separator = id.firstIndex(of: "_")
        else {
            throw CollectionParseError.invalidCollectionId(collectionId)
        }
        let txidHex = String(id[..<separator])
        let voutText = String(id[id.index(after: separator)...])
        guard let vout = UInt32(voutText) else {
            throw CollectionParseError.invalidCollectionId(collectionId)
        }
        let txidBytes = try Hex.decode(txidHex, maximumDecodedByteCount: 32)
        return Array(txidBytes.reversed()) + [
            UInt8(truncatingIfNeeded: vout),
            UInt8(truncatingIfNeeded: vout >> 8),
            UInt8(truncatingIfNeeded: vout >> 16),
            UInt8(truncatingIfNeeded: vout >> 24),
        ]
    }

    /// `^[0-9a-fA-F]{64}_[0-9]+$` → the id, else nil.
    public static func absoluteCollectionId(_ text: String) -> String? {
        guard let separator = text.firstIndex(of: "_") else { return nil }
        let txid = String(text[..<separator])
        let vout = String(text[text.index(after: separator)...])
        guard txid.utf8.count == 64, isHex(txid), isDigits(vout) else { return nil }
        return text
    }

    /// Go `NormalizeRelativeOutpoint`. `"_N"` resolves against the item txid.
    public static func normalizeRelativeCollectionId(_ id: String, itemOutpoint: String?) -> String {
        guard let itemOutpoint, id.hasPrefix("_") else { return id }
        let suffix = String(id.dropFirst())
        guard isDigits(suffix), let index = UInt32(suffix) else { return id }
        guard let dot = itemOutpoint.firstIndex(of: ".") else { return id }
        let txid = String(itemOutpoint[..<dot])
        guard !txid.isEmpty else { return id }
        return "\(txid)_\(index)"
    }

    /// Go `ParseCollection`: only `subType == collectionItem` and `subTypeData.collectionId`.
    public static func collectionId(mapData: [String: String], itemOutpoint: String?) -> String? {
        guard mapData["subType"] == "collectionItem" else { return nil }
        guard let raw = mapData["subTypeData"], !raw.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let collectionId = object["collectionId"] as? String,
              !collectionId.isEmpty
        else {
            return nil
        }
        let normalized = normalizeRelativeCollectionId(collectionId, itemOutpoint: itemOutpoint)
        return normalized.isEmpty ? nil : normalized
    }

    /// Period origin `"<txid>.<vout>"` → underscore `"<txid>_<vout>"`.
    public static func collectionId(fromOrigin origin: String) -> String? {
        let parts = origin.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let txid = String(parts[0])
        let vout = String(parts[1])
        guard txid.utf8.count == 64, isHex(txid), isDigits(vout) else { return nil }
        return "\(txid)_\(vout)"
    }

    /// `validateSubTypeData` for a collection parent. Nil when valid.
    public static func validate(_ data: CollectionSubTypeData) -> String? {
        if data.description.isEmpty {
            return "Collection description is required"
        }
        if data.quantity == 0 {
            return "Collection quantity is required"
        }
        return nil
    }

    /// `validateSubTypeData` for a collection item. Nil when valid.
    public static func validate(_ data: CollectionItemSubTypeData) -> String? {
        if data.collectionId.isEmpty {
            return "Collection id is required"
        }
        if !data.collectionId.contains("_") {
            return "Collection id must be a valid outpoint"
        }
        let parts = data.collectionId.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        if parts[0].count != 64 {
            return "Collection id must contain a valid txid"
        }
        if parts.count < 2 || Int(parts[1]) == nil {
            return "Collection id must contain a valid vout"
        }
        return nil
    }

    public struct Grouping: Equatable, Sendable {
        /// Outputs tagged `subType:collection`, input order preserved.
        public let parents: [WalletOutput]
        /// Outputs tagged `subType:collectionItem` + canonical `collection:{id}` or historical
        /// `collectionId:{id}`, keyed by the id.
        public let itemsByCollectionId: [String: [WalletOutput]]
        /// Everything else — a lone inscription is not a collection.
        public let standalone: [WalletOutput]
    }

    /// Tag-only grouping. No MAP decode, no normalization, no network.
    public static func group(ordinalOutputs: [WalletOutput]) -> Grouping {
        var parents: [WalletOutput] = []
        var itemsByCollectionId: [String: [WalletOutput]] = [:]
        var standalone: [WalletOutput] = []
        for output in ordinalOutputs {
            let tags = output.tags ?? []
            if tags.contains(parentTag) {
                parents.append(output)
            } else if tags.contains(itemTag), let (idTag, prefix) = [
                collectionTagPrefix,
                collectionIdTagPrefix,
            ].compactMap({ prefix in
                tags.first(where: { $0.hasPrefix(prefix) }).map { ($0, prefix) }
            }).first {
                let id = String(idTag.dropFirst(prefix.count))
                itemsByCollectionId[id, default: []].append(output)
            } else {
                standalone.append(output)
            }
        }
        return Grouping(
            parents: parents,
            itemsByCollectionId: itemsByCollectionId,
            standalone: standalone
        )
    }

    private static func isHex(_ text: String) -> Bool {
        text.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (48...57).contains($0) }
    }
}

/// MAP pair builders. Field order is the script.
public enum CollectionMap {
    /// `buildCollectionMap`. Pair order: app, type, name, subType, subTypeData[, royalties].
    public static func collection(
        app: String = "1sat-wallet",
        name: String,
        data: CollectionSubTypeData,
        royalties: [Royalty] = []
    ) -> [(String, String)] {
        var pairs: [(String, String)] = [
            ("app", app),
            ("type", "ord"),
            ("name", name),
            ("subType", "collection"),
            ("subTypeData", encode(data)),
        ]
        if !royalties.isEmpty {
            pairs.append(("royalties", encode(royalties)))
        }
        return pairs
    }

    /// `buildCollectionItemMap`. Pair order: app, type, name, subType, subTypeData.
    public static func collectionItem(
        app: String = "1sat-wallet",
        name: String,
        data: CollectionItemSubTypeData
    ) -> [(String, String)] {
        [
            ("app", app),
            ("type", "ord"),
            ("name", name),
            ("subType", "collectionItem"),
            ("subTypeData", encode(data)),
        ]
    }

    public static func encode(_ data: CollectionSubTypeData) -> String {
        let labels = "[" + data.rarityLabels.map(encodeLabel).joined(separator: ",") + "]"
        let traitsBody = data.traits
            .map { "\(jsonString($0.name)):\(encode($0.trait))" }
            .joined(separator: ",")
        return jsonObject([
            ("description", jsonString(data.description)),
            ("quantity", "\(data.quantity)"),
            ("rarityLabels", labels),
            ("traits", "{\(traitsBody)}"),
        ])
    }

    public static func encode(_ data: CollectionItemSubTypeData) -> String {
        var pairs: [(String, String)] = [
            ("collectionId", jsonString(data.collectionId)),
        ]
        if let mintNumber = data.mintNumber {
            pairs.append(("mintNumber", "\(mintNumber)"))
        }
        if let rank = data.rank {
            pairs.append(("rank", "\(rank)"))
        }
        if let rarityLabel = data.rarityLabel {
            pairs.append(("rarityLabel", jsonString(rarityLabel)))
        }
        if !data.traits.isEmpty {
            pairs.append(("traits", "[\(data.traits.map(encode).joined(separator: ","))]"))
        }
        if !data.attachments.isEmpty {
            pairs.append(("attachments", "[\(data.attachments.map(encode).joined(separator: ","))]"))
        }
        return jsonObject(pairs)
    }

    public static func encode(_ royalties: [Royalty]) -> String {
        "[" + royalties.map { royalty in
            jsonObject([
                ("type", jsonString(royalty.type.rawValue)),
                ("destination", jsonString(royalty.destination)),
                ("percentage", jsonString(royalty.percentage)),
            ])
        }.joined(separator: ",") + "]"
    }

    private static func encode(_ trait: CollectionTrait) -> String {
        jsonObject([
            ("values", jsonStringArray(trait.values)),
            ("occurancePercentages", jsonStringArray(trait.occurancePercentages)),
        ])
    }

    private static func encode(_ trait: CollectionItemTrait) -> String {
        var pairs: [(String, String)] = [
            ("name", jsonString(trait.name)),
            ("value", jsonString(trait.value)),
        ]
        if let rarityLabel = trait.rarityLabel {
            pairs.append(("rarityLabel", jsonString(rarityLabel)))
        }
        if let occurancePercentrage = trait.occurancePercentrage {
            pairs.append(("occurancePercentrage", jsonString(occurancePercentrage)))
        }
        return jsonObject(pairs)
    }

    private static func encode(_ attachment: CollectionItemAttachment) -> String {
        var pairs: [(String, String)] = [
            ("name", jsonString(attachment.name)),
        ]
        if let description = attachment.description {
            pairs.append(("description", jsonString(description)))
        }
        pairs.append(("content-type", jsonString(attachment.contentType)))
        pairs.append(("url", jsonString(attachment.url)))
        return jsonObject(pairs)
    }

    private static func encodeLabel(_ label: RarityLabel) -> String {
        jsonObject(label.map { ($0.key, jsonString($0.value)) })
    }

    private static func jsonObject(_ pairs: [(String, String)]) -> String {
        let body = pairs.map { "\(jsonString($0.0)):\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    private static func jsonStringArray(_ values: [String]) -> String {
        "[\(values.map(jsonString).joined(separator: ","))]"
    }

    /// Mirrors `CustomInstructions.jsonString` so MAP bytes match `JSON.stringify`.
    private static func jsonString(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        escaped += "\""
        return escaped
    }
}
