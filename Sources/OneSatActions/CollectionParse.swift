import Foundation
import OneSatClient
import OneSatTemplates
import BSVCore
import BSVWallet
import ToolboxCore

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

/// What a collection item's MAP says about it, for display (`CollectionParse.itemDetails`).
public struct CollectionItemDetails: Equatable, Sendable {
    public let traits: [CollectionItemTrait]
    public let mintNumber: Int?
    /// 1 is the rarest.
    public let rank: Int?
    public let rarityLabel: String?

    public init(
        traits: [CollectionItemTrait] = [],
        mintNumber: Int? = nil,
        rank: Int? = nil,
        rarityLabel: String? = nil
    ) {
        self.traits = traits
        self.mintNumber = mintNumber
        self.rank = rank
        self.rarityLabel = rarityLabel
    }

    /// Nothing to show.
    public var isEmpty: Bool { traits.isEmpty && mintNumber == nil && rank == nil && rarityLabel == nil }
}

/// What a collection parent's MAP says about the collection, for display
/// (`CollectionParse.collectionDetails`).
public struct CollectionDetails: Equatable, Sendable {
    public let description: String?
    /// `quantity` when it reads as a whole number.
    public let quantity: Int?
    /// `quantity` as sent ("Number in collection"), whether or not it is a whole number.
    public let quantityText: String?
    /// Label to percentage, in the order given.
    public let rarityLabels: [RarityLabelEntry]
    /// The traits table, in the order given: each trait's values with their occurrence.
    public let traits: [CollectionTraitEntry]

    public init(
        description: String? = nil,
        quantity: Int? = nil,
        quantityText: String? = nil,
        rarityLabels: [RarityLabelEntry] = [],
        traits: [CollectionTraitEntry] = []
    ) {
        self.description = description
        self.quantity = quantity
        self.quantityText = quantityText
        self.rarityLabels = rarityLabels
        self.traits = traits
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

    /// What a collection item's MAP says about it (docs.1satordinals.com `collectionItem`
    /// subType; TS `CollectionItemSubTypeData`): its traits, mint number, rank and rarity label.
    /// For display only; sync tags never carry these, so this needs the item's metadata.
    ///
    /// `subTypeData` may be an object or JSON text (`OrdinalTags.parseMapSubTypeData`). Each trait
    /// must be an object with a non-empty string `name` and a `value`; a number or bool `value` is
    /// kept as its JSON text, any other value skips the entry. Order is kept. A trait's
    /// `rarityLabel` is kept when it is text, and its occurrence from `occurancePercentrage` (TS)
    /// or `occurrencePercent` (the spec), text or a number. `mintNumber` and `rank` are whole
    /// numbers, sent as numbers or digit text. `attachments` are not read.
    public static func itemDetails(fromMap map: [String: JSONValue]?) -> CollectionItemDetails {
        guard let data = subTypeDataObject(map) else { return CollectionItemDetails() }
        let traits = (data["traits"].map(nestedJSON)?.arrayValue ?? []).compactMap { entry -> CollectionItemTrait? in
            guard let trait = entry.objectValue,
                  let name = trait["name"]?.stringValue, !name.isEmpty,
                  let value = trait["value"].flatMap(scalarText)
            else {
                return nil
            }
            return CollectionItemTrait(
                name: name,
                value: value,
                rarityLabel: trait["rarityLabel"]?.stringValue,
                occurancePercentrage: (trait["occurancePercentrage"] ?? trait["occurrencePercent"])
                    .flatMap(scalarText)
            )
        }
        return CollectionItemDetails(
            traits: traits,
            mintNumber: data["mintNumber"].flatMap(wholeNumber),
            rank: data["rank"].flatMap(wholeNumber),
            rarityLabel: data["rarityLabel"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// `itemDetails(fromMap:).traits`.
    public static func itemTraits(fromMap map: [String: JSONValue]?) -> [CollectionItemTrait] {
        itemDetails(fromMap: map).traits
    }

    /// What a collection parent's MAP says about the collection (docs.1satordinals.com
    /// `collection` subType; TS `CollectionSubTypeData`): description, quantity, rarity labels
    /// and the traits table.
    ///
    /// `subTypeData` may be an object or JSON text, and so may `rarityLabels` and `traits` inside
    /// it. Members keep the order the JSON text gives; an object that reached here already decoded
    /// (`JSONValue` keeps no order) is read in key order. `rarityLabels` is an object of label to
    /// percentage (the spec) or an array of such objects (TS `RarityLabels`), read in order.
    /// `quantity` is a whole number when it reads as one; `quantityText` keeps it as sent.
    public static func collectionDetails(fromMap map: [String: JSONValue]?) -> CollectionDetails {
        guard let data = subTypeDataObject(map) else { return CollectionDetails() }
        let quantityText = data["quantity"].flatMap(scalarText)
        var rarityLabels: [RarityLabelEntry] = []
        let labelEntries: [CollectionMapJSON] = switch data["rarityLabels"].map(nestedJSON) {
        case .array(let entries)?: entries
        case let object?: [object]
        case nil: []
        }
        for entry in labelEntries {
            for (label, percentage) in entry.members ?? [] where !label.isEmpty {
                guard let percentage = scalarText(percentage) else { continue }
                rarityLabels.append(RarityLabelEntry(key: label, value: percentage))
            }
        }
        let traits = (data["traits"].map(nestedJSON)?.members ?? []).compactMap {
            name, table -> CollectionTraitEntry? in
            let table = nestedJSON(table)
            guard !name.isEmpty, let values = table["values"]?.arrayValue else { return nil }
            let texts = values.compactMap(scalarText)
            guard !texts.isEmpty else { return nil }
            let percentages = (table["occurancePercentages"]?.arrayValue ?? []).compactMap(scalarText)
            return CollectionTraitEntry(
                name: name,
                trait: CollectionTrait(values: texts, occurancePercentages: percentages)
            )
        }
        return CollectionDetails(
            description: data["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            quantity: data["quantity"].flatMap(wholeNumber),
            quantityText: quantityText.flatMap { $0.isEmpty ? nil : $0 },
            rarityLabels: rarityLabels,
            traits: traits
        )
    }

    /// MAP `subTypeData` as an ordered object: JSON text is read in order, an object as decoded.
    private static func subTypeDataObject(_ map: [String: JSONValue]?) -> CollectionMapJSON? {
        switch map?["subTypeData"] {
        case .object(let object):
            return CollectionMapJSON(object: object)
        case .string(let text):
            guard let value = CollectionMapJSON.parse(text), value.members != nil else { return nil }
            return value
        default:
            return nil
        }
    }

    /// A member that may itself be JSON text (`rarityLabels`, `traits`): the text read as JSON
    /// when it is an object or array, else the member as it is.
    private static func nestedJSON(_ value: CollectionMapJSON) -> CollectionMapJSON {
        guard case .string(let text) = value, let parsed = CollectionMapJSON.parse(text) else { return value }
        switch parsed {
        case .object, .array: return parsed
        default: return value
        }
    }

    /// A string as is, a number or bool as its JSON text, else nil.
    private static func scalarText(_ value: CollectionMapJSON) -> String? {
        switch value {
        case .string(let text):
            return text
        case .bool(let flag):
            return flag ? "true" : "false"
        case .number(let number):
            if let integer = Int64(exactly: number) { return String(integer) }
            guard number.isFinite else { return nil }
            return String(number)
        default:
            return nil
        }
    }

    /// A whole number sent as a number or as digit text.
    private static func wholeNumber(_ value: CollectionMapJSON) -> Int? {
        switch value {
        case .number(let number):
            return Int(exactly: number)
        case .string(let text):
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
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
        /// Collection parents, input order preserved: outputs tagged `subType:collection` (this
        /// wallet's own mint), and untagged outputs whose origin is the collection id an item in
        /// the same input names (a parent received or synced, which BRC-147 does not tag).
        public let parents: [WalletOutput]
        /// Outputs that name a collection (`memberCollectionId`), keyed by the id, each array in
        /// input order.
        public let itemsByCollectionId: [String: [WalletOutput]]
        /// The keys of `itemsByCollectionId` in order of first appearance, so callers that list
        /// collections get the same order every time.
        public let collectionIds: [String]
        /// Everything else — a lone inscription is not a collection.
        public let standalone: [WalletOutput]
    }

    /// The collection an ordinal output belongs to, read from its tags: the first canonical
    /// `collection:` value, else the first historical `collectionId:` value, matched in any case.
    ///
    /// BRC-147 `ordinalTagsFromMetadata` (TS `types/src/ordinalTags.ts`) writes `collection:` for
    /// every synced or received item and no `subType:` tag; only this wallet's mint adds
    /// `subType:collectionItem`. So the id tag alone is membership.
    ///
    /// A relative `_N` resolves against the txid of `origin`. The id comes back in lowercase
    /// `txid_vout` form, or nil when it is not an outpoint (MAP `collection` may hold any text,
    /// and such outputs stay standalone).
    public static func memberCollectionId(tags: [String], origin: String) -> String? {
        let raw = [collectionTagPrefix, collectionIdTagPrefix].lazy.compactMap { prefix in
            tags.lazy.compactMap { WalletTag.value($0, prefix: prefix) }.first
        }.first
        guard let raw else { return nil }
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("_"), let separator = origin.firstIndex(where: { $0 == "_" || $0 == "." }) {
            let suffix = String(id.dropFirst())
            if isDigits(suffix) { id = "\(origin[..<separator])_\(suffix)" }
        }
        id = Bsv21Remittance.formatOrdinalOutpoint(id).lowercased()
        return absoluteCollectionId(id)
    }

    /// The origin an ordinal output's tags record, in lowercase `txid_vout` form: the first
    /// `origin:<id>` tag, a bare `origin` tag meaning the output is its own origin, else the
    /// output's own outpoint.
    public static func origin(of output: WalletOutput) -> String {
        let outpoint = output.outpoint.description
        var resolved: String?
        for tag in output.tags ?? [] where resolved == nil {
            if WalletTag.matches(tag, "origin") {
                resolved = outpoint
            } else if let value = WalletTag.value(tag, prefix: "origin:"), !value.isEmpty {
                resolved = value
            }
        }
        return Bsv21Remittance.formatOrdinalOutpoint(resolved ?? outpoint).lowercased()
    }

    /// Tag-only grouping. No MAP decode, no normalization beyond the id form, no network. Tags
    /// match in any case: storage lowercases them (`subtype:collection`), older rows keep the
    /// camelCase.
    ///
    /// Each output is, in this order: a parent when tagged `subType:collection`; an item when it
    /// names a collection (`memberCollectionId`); a parent when its own origin is a collection id
    /// some item in the input names; else standalone.
    public static func group(ordinalOutputs: [WalletOutput]) -> Grouping {
        let members = ordinalOutputs.map { output in
            memberCollectionId(tags: output.tags ?? [], origin: origin(of: output))
        }
        let referenced = Set(members.compactMap { $0 })
        var parents: [WalletOutput] = []
        var itemsByCollectionId: [String: [WalletOutput]] = [:]
        var collectionIds: [String] = []
        var standalone: [WalletOutput] = []
        for (output, member) in zip(ordinalOutputs, members) {
            let tags = output.tags ?? []
            if WalletTag.contains(tags, parentTag) {
                parents.append(output)
            } else if let member {
                if itemsByCollectionId[member] == nil { collectionIds.append(member) }
                itemsByCollectionId[member, default: []].append(output)
            } else if referenced.contains(origin(of: output)) {
                parents.append(output)
            } else {
                standalone.append(output)
            }
        }
        return Grouping(
            parents: parents,
            itemsByCollectionId: itemsByCollectionId,
            collectionIds: collectionIds,
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
        JSONText.quote(value)
    }
}

/// JSON with object members in the order the text gives them, for the MAP fields a person reads
/// in order (rarity labels, the traits table). Lenient: any valid JSON reads; nesting stops at 64.
enum CollectionMapJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([CollectionMapJSON])
    case object([(String, CollectionMapJSON)])

    static let maximumDepth = 64

    static func == (lhs: CollectionMapJSON, rhs: CollectionMapJSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.number(a), .number(b)): a == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    /// A decoded `JSONValue`; its objects have no order left, so members go in key order.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let flag): self = .bool(flag)
        case .number(let number): self = .number(number)
        case .string(let text): self = .string(text)
        case .array(let items): self = .array(items.map(CollectionMapJSON.init))
        case .object(let object): self = CollectionMapJSON(object: object)
        }
    }

    init(object: [String: JSONValue]) {
        self = .object(object.keys.sorted().map { ($0, CollectionMapJSON(object[$0] ?? .null)) })
    }

    /// The first member named `key`.
    subscript(key: String) -> CollectionMapJSON? {
        members?.first { $0.0 == key }?.1
    }

    var members: [(String, CollectionMapJSON)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var arrayValue: [CollectionMapJSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    var objectValue: CollectionMapJSON? { members == nil ? nil : self }

    var stringValue: String? {
        if case .string(let text) = self { return text }
        return nil
    }

    /// The text as JSON, or nil when it is not JSON.
    static func parse(_ text: String) -> CollectionMapJSON? {
        var reader = Reader(bytes: Array(text.utf8))
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.index == reader.bytes.count ? value : nil
    }

    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> CollectionMapJSON? {
            guard depth <= CollectionMapJSON.maximumDepth else { return nil }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth + 1)
            case UInt8(ascii: "["): return array(depth: depth + 1)
            case UInt8(ascii: "\""): return string().map(CollectionMapJSON.string)
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        mutating func literal(_ word: String, _ value: CollectionMapJSON) -> CollectionMapJSON? {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected
            else { return nil }
            index += expected.count
            return value
        }

        mutating func object(depth: Int) -> CollectionMapJSON? {
            index += 1
            var members: [(String, CollectionMapJSON)] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = value(depth: depth) else { return nil }
                members.append((key, value))
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func array(depth: Int) -> CollectionMapJSON? {
            index += 1
            var items: [CollectionMapJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            }
            while true {
                guard let item = value(depth: depth) else { return nil }
                items.append(item)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        /// A string token, unescaped by `JSONDecoder` so escapes and surrogates read as JSON says.
        mutating func string() -> String? {
            let start = index
            var escaped = false
            index += 1
            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "\\"):
                    escaped = true
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    guard escaped else {
                        return String(decoding: bytes[start + 1..<index - 1], as: UTF8.self)
                    }
                    return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
                default: index += 1
                }
            }
            return nil
        }

        mutating func number() -> CollectionMapJSON? {
            let start = index
            while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
            guard index > start,
                  let number = try? JSONDecoder().decode(Double.self, from: Data(bytes[start..<index]))
            else { return nil }
            return .number(number)
        }
    }
}
