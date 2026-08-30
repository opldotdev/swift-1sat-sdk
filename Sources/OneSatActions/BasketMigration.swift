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

        public init(
            from: String,
            to: String,
            moved: Int,
            skipped: Int,
            outpoints: [String],
            errors: [MoveError]
        ) {
            self.from = from
            self.to = to
            self.moved = moved
            self.skipped = skipped
            self.outpoints = outpoints
            self.errors = errors
        }
    }

    public struct MigrateResult: Equatable, Sendable {
        public let results: [MoveResult]
        public let totalMoved: Int

        public init(results: [MoveResult], totalMoved: Int) {
            self.results = results
            self.totalMoved = totalMoved
        }
    }

    /// `LEGACY_P1SAT_BASKET_MIGRATIONS` plus Swift's own `p 1sat bsv20` filing.
    public static var legacyMigrations: [(from: String, to: String)] {
        OneSatConstants.legacyP1SatBasketMigrations
    }

    /// Move every known legacy `p 1sat …` basket into its preferred plain name.
    public static func migrateLegacyP1SatBaskets(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        limit: Int = 1_000
    ) async throws -> MigrateResult {
        var results: [MoveResult] = []
        var totalMoved = 0
        for pair in legacyMigrations {
            let result = try await moveBasketOutputs(
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
            return MoveResult(from: from, to: to, moved: 0, skipped: 0, outpoints: [], errors: [])
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
            return MoveResult(from: from, to: to, moved: 0, skipped: 0, outpoints: [], errors: [])
        }
        if listed.outputs.isEmpty {
            return MoveResult(from: from, to: to, moved: 0, skipped: 0, outpoints: [], errors: [])
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
            errors: errors
        )
    }
}
