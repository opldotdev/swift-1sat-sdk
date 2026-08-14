import BSVCore
import BSVScript

/// MAP SET suffix from `@1sat/templates` `bitcom/map.ts` + `utils/buildMapSuffix.ts`.
///
/// Field order is the script. Callers pass pairs in the same order `Object.entries` would.
public enum MapSuffix {
    private static let maximumByteCount = 1_100_000

    public static func set(_ fields: [(String, String)]) throws -> Script {
        var script = try Script(bytes: [], maximumByteCount: maximumByteCount)
        try script.append(.return, maximumScriptByteCount: maximumByteCount)
        try script.appendPushData(
            Array(OneSatConstants.mapPrefix.utf8),
            maximumScriptByteCount: maximumByteCount
        )
        try script.appendPushData(Array("SET".utf8), maximumScriptByteCount: maximumByteCount)
        for (key, value) in fields {
            try script.appendPushData(Array(clean(key).utf8), maximumScriptByteCount: maximumByteCount)
            try script.appendPushData(Array(clean(value).utf8), maximumScriptByteCount: maximumByteCount)
        }
        return script
    }

    /// `appendMapSuffix` from `packages/actions/src/utils/buildMapSuffix.ts`.
    public static func appending(_ map: [(String, String)]?, to lockingScript: Script) throws -> Script {
        guard let map, !map.isEmpty else { return lockingScript }
        return try Script(
            bytes: lockingScript.bytes + set(map).bytes,
            maximumByteCount: maximumByteCount
        )
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\0", with: " ")
            .replacingOccurrences(of: "\\u0000", with: " ")
    }
}
