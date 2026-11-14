/// Case-insensitive reads of wallet tags.
///
/// Storage keeps tags as ts-sdk `validateTag` leaves them: trimmed and lowercased.
/// Rows written before that hold the tag as the writer spelled it (`subType:collection`,
/// `publishedAt:<ms>`), so readers match either spelling.
enum WalletTag {
    /// `tag` equals `expected`, ignoring case.
    static func matches(_ tag: String, _ expected: String) -> Bool {
        tag.lowercased() == expected.lowercased()
    }

    /// `tags` holds `expected` in any case.
    static func contains(_ tags: [String], _ expected: String) -> Bool {
        tags.contains { matches($0, expected) }
    }

    /// The text after `prefix` when `tag` starts with it in any case, else nil.
    static func value(_ tag: String, prefix: String) -> String? {
        guard tag.count >= prefix.count,
              tag.prefix(prefix.count).lowercased() == prefix.lowercased()
        else {
            return nil
        }
        return String(tag.dropFirst(prefix.count))
    }
}
