import Foundation
import BSVWallet

/// BRC-147 ordinal remittance. Port of `packages/actions/src/utils/ordinalRemittance.ts`.
public enum OrdinalRemittance {
    public static let maxNameLength = 64

    public struct Fields: Equatable, Sendable {
        public var origin: String?
        public var content: String?
        public var app: String?
        public var collection: String?
        public var name: String?

        public init(
            origin: String? = nil,
            content: String? = nil,
            app: String? = nil,
            collection: String? = nil,
            name: String? = nil
        ) {
            self.origin = origin
            self.content = content
            self.app = app
            self.collection = collection
            self.name = name
        }
    }

    public static func displayName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return String(trimmed.prefix(maxNameLength))
    }

    /// Load-bearing remittance fields mirrored from filter tags. Outpoints become `_`.
    public static func fromTags(_ tags: [String]?) -> Fields {
        guard let tags, !tags.isEmpty else { return Fields() }
        var origin: String?
        var content: String?
        var app: String?
        var collection: String?
        for tag in tags {
            let n = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.hasPrefix("origin:"), origin == nil {
                origin = Bsv21Remittance.formatOrdinalOutpoint(String(n.dropFirst(7)))
            } else if n.hasPrefix("content:"), content == nil {
                content = Bsv21Remittance.formatOrdinalOutpoint(String(n.dropFirst(8)))
            } else if n.hasPrefix("app:"), app == nil {
                app = String(n.dropFirst(4))
            } else if n.hasPrefix("collection:"), collection == nil {
                collection = Bsv21Remittance.formatOrdinalOutpoint(String(n.dropFirst(11)))
            }
        }
        return Fields(origin: origin, content: content, app: app, collection: collection)
    }

    /// Spend-derivation CI plus BRC-147 remittance dual-stamped from tags.
    public static func buildCustomInstructions(
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: String? = nil,
        tags: [String]? = nil,
        name: String? = nil
    ) -> String {
        var pairs: [(String, String)] = [
            ("protocolID", RemittanceJSON.protocolID(protocolID)),
            ("keyID", RemittanceJSON.string(keyID)),
        ]
        if let counterparty {
            pairs.append(("counterparty", RemittanceJSON.string(counterparty)))
        }
        let remittance = fromTags(tags)
        if let origin = remittance.origin {
            pairs.append(("origin", RemittanceJSON.string(origin)))
        }
        if let content = remittance.content {
            pairs.append(("content", RemittanceJSON.string(content)))
        }
        if let app = remittance.app {
            pairs.append(("app", RemittanceJSON.string(app)))
        }
        if let collection = remittance.collection {
            pairs.append(("collection", RemittanceJSON.string(collection)))
        }
        if let name = displayName(name) {
            pairs.append(("name", RemittanceJSON.string(name)))
        }
        return RemittanceJSON.object(pairs)
    }
}
