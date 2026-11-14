import Foundation

/// An outpoint as the validated `createAction` arguments carry it to storage, `{txid, vout}`
/// (`@bsv/sdk` `parseWalletOutpoint`), read back as `"<txid>.<vout>"`. Nil for any other shape,
/// because storage reads only that one.
func storageOutpoint(_ value: Any?) -> String? {
    guard let object = value as? [String: Any],
          let txid = object["txid"] as? String,
          let vout = (object["vout"] as? NSNumber)?.intValue
    else { return nil }
    return "\(txid).\(vout)"
}

/// A tag as the validated arguments carry it to storage: trimmed and lowercased, as `@bsv/sdk`
/// `validateTag` leaves it (`validateIdentifier`), so the reference wallet stores the same text.
func storageTag(_ tag: String) -> String {
    tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// `storageTag` of each tag, in order.
func storageTags(_ tags: [String]) -> [String] { tags.map(storageTag) }
