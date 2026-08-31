import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxStorage
import ToolboxStorageClient

/// Re-file spendable outputs from one basket into another via `internalizeAction`
/// basket insertion. Port of `packages/actions/src/utils/moveBasket.ts`.
///
/// Tags and customInstructions are preserved. No chain spend. Idempotent when
/// the source basket is empty.
public enum BasketMigration {
    public struct MoveError: Equatable, Sendable {
        public let outpoint: String
        public let error: String

        public init(outpoint: String, error: String) {
            self.outpoint = outpoint
            self.error = error
        }
    }

    public struct MoveResult: Equatable, Sendable {
        public let from: String
        public let to: String
        public let moved: Int
        public let skipped: Int
        public let outpoints: [String]
        public let errors: [MoveError]
        /// True only when the source listed empty (or from == to). Partial
        /// moves and skipped rows are never complete.
        public let complete: Bool

        public init(
            from: String,
            to: String,
            moved: Int,
            skipped: Int,
            outpoints: [String],
            errors: [MoveError],
            complete: Bool
        ) {
            self.from = from
            self.to = to
            self.moved = moved
            self.skipped = skipped
            self.outpoints = outpoints
            self.errors = errors
            self.complete = complete
        }
    }

    public struct MigrateResult: Equatable, Sendable {
        public let results: [MoveResult]
        public let totalMoved: Int
        /// True only when every source basket listed empty.
        public let complete: Bool

        public init(results: [MoveResult], totalMoved: Int) {
            self.results = results
            self.totalMoved = totalMoved
            self.complete = results.allSatisfy(\.complete)
        }
    }

    /// `LEGACY_P1SAT_BASKET_MIGRATIONS` plus leftover `ordinals` / `p 1sat bsv20`.
    public static var legacyMigrations: [(from: String, to: String)] {
        OneSatConstants.legacyP1SatBasketMigrations
    }

    /// Move every known leftover inventory basket into its preferred name.
    /// Drains each source (offset 0 after each successful page) until empty.
    /// `complete` is true only when every source listed empty. Errors stop
    /// that pair; remaining pairs still run.
    public static func migrateLegacyP1SatBaskets(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        limit: Int = 1_000
    ) async throws -> MigrateResult {
        var results: [MoveResult] = []
        var totalMoved = 0
        for pair in legacyMigrations {
            let result = try await drainBasket(
                ctx,
                internalizer: internalizer,
                from: pair.from,
                to: pair.to,
                limit: limit
            )
            results.append(result)
            totalMoved += result.moved
        }
        return MigrateResult(results: results, totalMoved: totalMoved)
    }

    /// Re-list from offset 0 until the source is empty or a page skips.
    private static func drainBasket(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        from: String,
        to: String,
        limit: Int
    ) async throws -> MoveResult {
        var moved = 0
        var skipped = 0
        var outpoints: [String] = []
        var errors: [MoveError] = []
        var complete = false
        var seen = Set<String>()
        while true {
            let page = try await moveBasketOutputs(
                ctx,
                internalizer: internalizer,
                from: from,
                to: to,
                limit: limit
            )
            moved += page.moved
            skipped += page.skipped
            outpoints.append(contentsOf: page.outpoints)
            errors.append(contentsOf: page.errors)
            if page.complete {
                complete = errors.isEmpty && skipped == 0
                break
            }
            if !page.errors.isEmpty || page.skipped > 0 {
                complete = false
                break
            }
            let fresh = Set(page.outpoints)
            if fresh.isEmpty || !fresh.isDisjoint(with: seen) {
                complete = false
                break
            }
            seen.formUnion(fresh)
        }
        return MoveResult(
            from: from,
            to: to,
            moved: moved,
            skipped: skipped,
            outpoints: outpoints,
            errors: errors,
            complete: complete
        )
    }

    public static func moveBasketOutputs(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        from fromBasket: String,
        to toBasket: String,
        limit: Int = 1_000,
        offset: Int = 0
    ) async throws -> MoveResult {
        let from = fromBasket.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = toBasket.trimmingCharacters(in: .whitespacesAndNewlines)
        if from.isEmpty || to.isEmpty {
            throw OneSatActionError.moveBasketBasketsRequired
        }
        if from == to {
            return MoveResult(
                from: from,
                to: to,
                moved: 0,
                skipped: 0,
                outpoints: [],
                errors: [],
                complete: true
            )
        }

        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: from,
                include: .entireTransactions,
                includeCustomInstructions: true,
                includeTags: true,
                pagination: try WalletPagination(limit: UInt32(limit), offset: UInt32(offset))
            )
        )
        return try await moveBasketOutputs(
            from: from,
            to: to,
            listed: listed,
            internalizer: internalizer
        )
    }

    /// Pure re-file against an already-listed basket. Tests use this directly.
    public static func moveBasketOutputs(
        from: String,
        to: String,
        listed: WalletListOutputsResult,
        internalizer: any ActionInternalizer
    ) async throws -> MoveResult {
        if from == to {
            return MoveResult(
                from: from,
                to: to,
                moved: 0,
                skipped: 0,
                outpoints: [],
                errors: [],
                complete: true
            )
        }
        if listed.outputs.isEmpty {
            return MoveResult(
                from: from,
                to: to,
                moved: 0,
                skipped: 0,
                outpoints: [],
                errors: [],
                complete: true
            )
        }
        guard let beef = listed.beef else {
            throw OneSatActionError.moveBasketMissingBEEF(basket: from)
        }

        var errors: [MoveError] = []
        var outpoints: [String] = []
        var moved = 0
        var skipped = 0

        for output in listed.outputs {
            let outpoint = output.outpoint.description
            let atomic: AtomicBEEF
            do {
                atomic = try AtomicBEEF(
                    subjectTransactionID: output.outpoint.transactionID,
                    beef: beef,
                    limits: WalletBEEFLimits.standard
                )
            } catch {
                skipped += 1
                errors.append(
                    MoveError(
                        outpoint: outpoint,
                        error: "beef-missing-txid:\(String(output.outpoint.transactionID.displayHex.prefix(12)))"
                    )
                )
                continue
            }

            do {
                let insertion = try WalletBasketInsertion(
                    basket: to,
                    customInstructions: output.customInstructions,
                    tags: output.tags ?? []
                )
                let request = try WalletInternalizeActionRequest(
                    transaction: atomic,
                    description: "move basket \(from) → \(to)",
                    outputs: [
                        WalletInternalizeOutput(
                            outputIndex: output.outpoint.outputIndex,
                            remittance: .basketInsertion(insertion)
                        ),
                    ]
                )
                _ = try await internalizer.internalizeAction(request)
                moved += 1
                outpoints.append(outpoint)
            } catch {
                skipped += 1
                errors.append(
                    MoveError(outpoint: outpoint, error: error.localizedDescription)
                )
            }
        }

        return MoveResult(
            from: from,
            to: to,
            moved: moved,
            skipped: skipped,
            outpoints: outpoints,
            errors: errors,
            complete: false
        )
    }
}
