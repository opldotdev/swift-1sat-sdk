import Foundation
import ToolboxCore

/// `formatOrdinalOutpoint` from `@1sat/types` `outpoint.ts`.
public enum OrdinalOutpoint {
    /// The ordinals and indexer id form, `txid_vout`, used for origin tags, CI origin, collection
    /// ids and OrdFS keys. Accepts the dotted BRC-100 form or the underscore form.
    public static func format(_ outpoint: String) -> String {
        let trimmed = outpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let units = Array(trimmed.utf16)
        if units.count >= 66, units[64] == 0x2E || units[64] == 0x5F {
            return String(decoding: units[0..<64], as: UTF16.self)
                + "_"
                + String(decoding: units[65...], as: UTF16.self)
        }
        // JS `String.replace` with a string pattern swaps the first match only.
        guard let dot = trimmed.firstIndex(of: ".") else { return trimmed }
        return trimmed.replacingCharacters(in: dot...dot, with: "_")
    }
}

/// The ordinal metadata helpers from `@1sat/types` `ordinalTags.ts` (BRC-147).
public enum OrdinalTags {
    /// Longest display name put in customInstructions (not tags).
    public static let maxNameTagLength = 64

    /// `ordinalTagsFromMetadata`. Emits `origin:`, `content:`, `collection:`, `app:` and `type:`
    /// filter tags in that order. Never emits `name:`, which belongs in CI `name`.
    public static func fromMetadata(_ metadata: OrdfsMetadata?, fallbackOrigin: String? = nil) -> [String] {
        fromMetadata(
            origin: metadata?.origin,
            contentType: metadata?.contentType,
            map: metadata?.map,
            parent: metadata?.parent,
            fallbackOrigin: fallbackOrigin
        )
    }

    /// The same, from the separate fields of a partial `OrdfsMetadata`.
    public static func fromMetadata(
        origin: String? = nil,
        contentType: String? = nil,
        map: [String: JSONValue]? = nil,
        parent: String? = nil,
        fallbackOrigin: String? = nil
    ) -> [String] {
        var tags: [String] = []

        if let origin = nonempty(origin) ?? nonempty(fallbackOrigin) {
            tags.append("origin:\(OrdinalOutpoint.format(origin))")
        }

        let subTypeData = parseMapSubTypeData(map)
        // The first string value wins, even an empty one, which then emits no tag (as in TS).
        let content = map?["content"]?.stringValue ?? parent
        if let content = nonempty(content) {
            tags.append("content:\(OrdinalOutpoint.format(content))")
        }

        let collectionID = map?["collectionId"]?.stringValue
            ?? map?["collection"]?.stringValue
            ?? subTypeData?["collectionId"]?.stringValue
            ?? subTypeData?["collection"]?.stringValue
        if let collectionID = nonempty(collectionID) {
            tags.append("collection:\(OrdinalOutpoint.format(collectionID))")
        }

        if let app = nonempty(map?["app"]?.stringValue) {
            tags.append("app:\(app)")
        }

        if let typeTag = contentTypeTag(contentType) {
            tags.append(typeTag)
        }
        return tags
    }

    /// `contentTypeTag`: one `type:<mime>` tag with `;` parameters stripped.
    public static func contentTypeTag(_ contentType: String?) -> String? {
        guard let contentType else { return nil }
        let base = String(contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : "type:\(base)"
    }

    /// `parseMapSubTypeData`: MAP `subTypeData` as an object, whether sent as one or as JSON text.
    public static func parseMapSubTypeData(_ map: [String: JSONValue]?) -> [String: JSONValue]? {
        switch map?["subTypeData"] {
        case .object(let object):
            return object
        case .string(let text) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.objectValue
        default:
            return nil
        }
    }

    /// `nameFromMap`: MAP `name`, falling back to `subTypeData.name`. For CI `name`, not tags.
    public static func nameFromMap(_ map: [String: JSONValue]?) -> String? {
        guard let map else { return nil }
        if let name = nonempty(map["name"]?.stringValue) { return name }
        return nonempty(parseMapSubTypeData(map)?["name"]?.stringValue)
    }

    /// `displayNameForCi`: trimmed, then cut to 64 UTF-16 units.
    ///
    /// JS `slice` can leave a lone surrogate at the cut; Swift keeps valid Unicode, so a non-BMP
    /// character that straddles the limit is dropped and the result is 63 units long.
    public static func displayNameForCi(_ name: String?) -> String? {
        guard let trimmed = nonempty(name?.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        var result = String.UnicodeScalarView()
        var units = 0
        for scalar in trimmed.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            guard units + width <= maxNameTagLength else { break }
            result.append(scalar)
            units += width
        }
        return String(result)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
