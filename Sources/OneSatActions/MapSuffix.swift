import BSVScript
import OneSatTemplates

/// MAP SET suffix from `@1sat/templates` `bitcom/map.ts` + `utils/buildMapSuffix.ts`.
///
/// Field order is the script. Callers pass pairs in the same order `Object.entries` would.
public enum MapSuffix {
    private static let maximumByteCount = 1_100_000

    public static func set(_ fields: [(String, String)]) throws -> Script {
        try MAPTemplate.set(fields)
    }

    /// `appendMapSuffix` from `packages/actions/src/utils/buildMapSuffix.ts`.
    public static func appending(_ map: [(String, String)]?, to lockingScript: Script) throws -> Script {
        guard let map, !map.isEmpty else { return lockingScript }
        return try Script(
            bytes: lockingScript.bytes + set(map).bytes,
            maximumByteCount: maximumByteCount
        )
    }

}
