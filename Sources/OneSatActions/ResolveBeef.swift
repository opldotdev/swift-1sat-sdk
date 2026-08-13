import BSVTransaction
import BSVWallet
import ToolboxActions

/// `utils/resolveBeef.ts`. The frozen `StorageClient` does not return BEEF today.
public enum ResolveBeef {
    public static func extractIDTag(tags: [String]?) -> String? {
        tags?.first(where: { $0.hasPrefix("id:") })
    }

    public static func resolve(
        _ ctx: OneSatContext,
        basket: String,
        tags: [String]?
    ) async throws -> [UInt8] {
        guard let idTag = extractIDTag(tags: tags) else {
            throw OneSatActionError.noBeefAvailable
        }
        let result = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: basket,
                tags: [idTag],
                include: .entireTransactions,
                pagination: WalletPagination(limit: 1)
            )
        )
        guard let beef = result.beef else {
            throw OneSatActionError.noBeefAvailable
        }
        return try beef.serialized(limits: StorageBeefLimits.standard)
    }
}

/// BEEF encode bounds used when a future storage client returns graph bytes.
enum StorageBeefLimits {
    static let standard: BEEFLimits = WalletBEEFLimits.standard
}
