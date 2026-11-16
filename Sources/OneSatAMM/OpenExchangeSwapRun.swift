import BigInt
import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import OneSatColor
import OneSatTemplates

// A quoted swap run with the connected wallet (skein-amm 0.55.1 client.ts `executeSwap` /
// `runSwap`), the buy side: the overlay pass, the staging of what the swap basket lacks, then the
// legs ONE AT A TIME over the server's pool list read fresh before each, each leg's outcome
// handled as the TS client does, and at the end the move back of what an early stop left.

/// `LegResult`: a leg that filled.
public struct OpenExchangeLegResult: Equatable, Sendable {
    /// The pool output it spent, `<txid>.<vout>`.
    public let poolOutpoint: String
    public let poolId: String
    public let amountIn: BigInt
    public let amountOut: BigInt
    public let txid: String
}

/// `SwapStop`: why a swap stopped.
public enum OpenExchangeSwapStop: String, Equatable, Sendable {
    case filled
    case cancelled
    case floor
    case min
    case noPool = "no_pool"
    case fees
}

/// `SwapResult`.
public struct OpenExchangeSwapResult: Equatable, Sendable {
    /// "filled": every unit filled; "partial": some; "failed": none.
    public enum Status: String, Equatable, Sendable {
        case filled
        case partial
        case failed
    }

    /// What went back to the wallet when the swap stopped early, or why it did not.
    public enum Returned: Equatable, Sendable {
        case moved(txid: String, tokens: BigInt)
        case error(String)
    }

    public let status: Status
    public let stop: OpenExchangeSwapStop
    /// The legs that filled, in order.
    public let legs: [OpenExchangeLegResult]
    public let totalIn: BigInt
    public let totalOut: BigInt
    /// The swap amount not filled.
    public let unfilled: BigInt
    /// The swap-basket rows whose spender the last overlay pass could not take in; nil: none.
    public let stuck: [OpenExchangeStuckRow]?
    public let returned: Returned?
}

/// `SwapProgress`: where a swap is.
public enum OpenExchangeSwapProgress: Equatable, Sendable {
    case staging(sats: BigInt, tokens: BigInt)
    case relaying(leg: String, amountIn: BigInt, amountOut: BigInt, filled: [OpenExchangeLegResult])
    case repricing(leg: String, amountIn: BigInt, amountOut: BigInt, filled: [OpenExchangeLegResult])
    case returning(filled: [OpenExchangeLegResult])
    case stuck(rows: [OpenExchangeStuckRow])
    case done(OpenExchangeSwapResult)
    /// The swap's result when it ran to the end with nothing filled, or the error it threw.
    case failed(result: OpenExchangeSwapResult?, error: String?)
}

/// What happened inside a swap, in full, for the caller's log (not in the TS: its client keeps
/// these to itself). Never needed to drive a screen: `OpenExchangeSwapProgress` does that.
public enum OpenExchangeSwapEvent: Equatable, Sendable {
    /// What the basket lacked was staged: the staging transaction.
    case staged(txid: String, sats: UInt64)
    /// A leg's relay (attempt 1, or 2 when it is sent once more after no answer) and its outcome,
    /// the host's or validator's reason with it.
    case relayed(leg: String, attempt: Int, outcome: OpenExchangeLegOutcome)
    /// A pool left out for the rest of the swap, and why.
    case excluded(pool: String, reason: String)
    /// An overlay pass: the legs it took in and the rows it could not.
    case resolved(OpenExchangeResolved)
    /// The move back at an early stop: what went back, or why it did not.
    case returned(OpenExchangeSwapResult.Returned)
}

extension OpenExchange {
    /// `executeSwap`: runs a quoted buy with the wallet of `ctx` (see `runSwap`). `onProgress` is
    /// told where the swap is; `isCancelled` is asked before each leg (`cancelled`). `floor` is
    /// the least total amount out the swap accepts (default: the quote's `minAmountOut`, as TS).
    /// `onEvent` is told each relay, exclusion, pass and move back, for a log. A sell throws:
    /// only the buy side is here.
    public func executeSwap(
        _ ctx: OneColorContext, quote: OpenExchangeQuote, sym: String = "token",
        floor: BigInt? = nil,
        feeRateSatsPerKb: Double = OpenExchangeQuotes.defaultFeeRateSatsPerKb,
        patienceMs: Int = OpenExchange.legPatienceMs,
        isCancelled: @Sendable () -> Bool = { false },
        onProgress: (@Sendable (OpenExchangeSwapProgress) -> Void)? = nil,
        onEvent: (@Sendable (OpenExchangeSwapEvent) -> Void)? = nil
    ) async throws -> OpenExchangeSwapResult {
        let progress: (OpenExchangeSwapProgress) -> Void = { onProgress?($0) }
        let result: OpenExchangeSwapResult
        do {
            result = try await runSwap(
                ctx, quote: quote, sym: sym, floor: floor ?? quote.minAmountOut, feeRate: feeRateSatsPerKb, patienceMs: patienceMs,
                isCancelled: isCancelled, progress: progress, event: { onEvent?($0) }
            )
        } catch {
            let err = OpenExchangeError.of(error)
            progress(.failed(result: nil, error: OpenExchangeError.errorText(err)))
            throw err
        }
        progress(result.status == .failed ? .failed(result: result, error: nil) : .done(result))
        return result
    }

    /// A leg sent with no answer yet: what it spends, to account a later take-in by the pass.
    private struct Pending {
        let prepared: OpenExchangePreparedLeg
        let leg: AMMLeg
        let poolId: String
    }

    func runSwap(
        _ ctx: OneColorContext, quote: OpenExchangeQuote, sym: String, floor: BigInt, feeRate: Double, patienceMs: Int,
        isCancelled: () -> Bool, progress: (OpenExchangeSwapProgress) -> Void, event: (OpenExchangeSwapEvent) -> Void
    ) async throws -> OpenExchangeSwapResult {
        guard quote.request.side == .buy else { throw OpenExchangeError.failed("only a buy swap is supported here") }
        let tokenId = quote.request.tokenId
        let minerFee = try OpenExchangeQuotes.legMinerFeeSats(feeRate)

        var excluded = Set<String>()
        var spentAt: String?
        var budget = quote.request.maxSources

        var legs: [OpenExchangeLegResult] = []
        var filledIn = BigInt(0)
        var filledOut = BigInt(0)
        var order: String?
        var pending: [Pending] = []
        var stuck: [OpenExchangeStuckRow] = []
        func accountResolved(_ r: OpenExchangeResolved) {
            event(.resolved(r))
            let before = stuck
            stuck = r.stuck
            if !stuck.isEmpty, stuck != before { progress(.stuck(rows: stuck)) }
            for t in r.taken {
                guard let i = pending.firstIndex(where: { $0.prepared.satsInputs.contains { t.inputs.contains($0.outpoint) } }) else { continue }
                let x = pending.remove(at: i)
                order = order ?? x.prepared.order
                budget -= 1
                filledIn += x.leg.amountIn
                filledOut += x.leg.amountOut
                legs.append(OpenExchangeLegResult(
                    poolOutpoint: OpenExchangePrices.outpointText(x.leg.outpoint), poolId: x.poolId,
                    amountIn: x.leg.amountIn, amountOut: x.leg.amountOut, txid: t.txid
                ))
            }
        }

        accountResolved(await resolveSwaps(ctx))
        // 1. Stage what the basket lacks.
        let needSats = quote.stage.amount + quote.stage.feeSats
        let haveSats = BigInt(try await OpenExchangeSwapLeg.swapBasketSats(ctx))
        let lackSats = needSats > haveSats ? needSats - haveSats : 0
        if lackSats > 0 {
            progress(.staging(sats: lackSats, tokens: 0))
            guard let sats = UInt64(exactly: lackSats) else { throw OpenExchangeError.failed("nothing to stage in the swap basket") }
            let staged = try await OpenExchangeSwapLeg.stageSats(ctx, sats: sats, sym: sym)
            event(.staged(txid: staged.txid, sats: sats))
        }

        // 2. The loop.
        var why = OpenExchangeSwapStop.filled
        while true {
            if isCancelled() {
                why = .cancelled
                break
            }
            let remaining = quote.request.amountIn - filledIn
            let answer = try await tokenPools(tokenId)
            if let at = spentAt, answer.pools.contains(where: { $0.pool.outpoint == at }) {
                excluded.insert(at)
                event(.excluded(pool: at, reason: "still listed at the outpoint refused pool_spent"))
            }
            spentAt = nil
            // Review note: a pool with an empty reserve takes no leg; it is not offered to the planner.
            let rows = OpenExchangePrices.poolsWithMinimums(answer).filter {
                !excluded.contains($0.pool.outpoint) && $0.pool.bsvReserve > 0 && $0.pool.tokenReserve > 0
            }
            let minOut = floor > filledOut ? floor - filledOut : 0
            let leg: AMMLeg
            switch try AMMPlanner.nextLeg(AMMNextLegRequest(
                pools: rows.map(\.pool), direction: .bsvToToken, remaining: remaining,
                fixedCost: AMMFixedCost(minerFeeSats: minerFee), minOut: minOut, maxSources: budget
            )) {
            case .stop(let stop):
                why = OpenExchangeSwapStop(rawValue: stop.rawValue) ?? .noPool
            case .leg(let next, _):
                leg = next
                guard let row = rows.first(where: { $0.pool.outpoint == leg.outpoint }) else { throw OpenExchangeError.failed("the planned pool is not listed") }
                let spends = AMMTokenID.parseOutpoint(row.pool.outpoint)
                let poolOutput = Self.poolOutputOf(try? await readTx(tokenId: tokenId, txid: spends?.txid ?? ""), leg.outpoint)
                let peerId = row.validatorPeerId ?? answer.validators.first { $0.identity == row.pool.validatorIdentityKey.lowercased() }?.peerId
                guard let poolOutput, let peerId else {
                    excluded.insert(row.pool.outpoint)
                    event(.excluded(pool: row.pool.outpoint, reason: poolOutput == nil ? "the host served no transaction for the pool" : "no peer ID for the pool's validator"))
                    continue
                }
                let commissionPkh = try answer.market.identityKey.flatMap { identity in
                    try spends.map { try OpenExchangeKeys.commissionPkh(marketIdentity: identity, txid: $0.txid, vout: Int($0.vout)) }
                }
                let input = OpenExchangeSwapLeg.LegInput(
                    tokenId: tokenId, leg: leg, pool: row.pool, poolBEEF: poolOutput.beef, poolOutputIndex: poolOutput.outputIndex,
                    commissionPkh: commissionPkh, satsPerKb: feeRate
                )
                guard let inputs = try OpenExchangeSwapLeg.selectInputs(input, sats: try await OpenExchangeSwapLeg.satsHoldings(ctx)) else {
                    why = .fees
                    break
                }
                let holding = try await OpenExchangeSwapLeg.basketBEEF(ctx)
                    ?? BEEF(version: .v2, merklePaths: [], transactions: [], limits: OpenExchangeSwapLeg.beefLimits)
                let prepared = try OpenExchangeSwapLeg.prepare(
                    ctx, input, inputs: inputs.sats, order: order, last: leg.amountIn == remaining, holdingBEEF: holding
                )
                let legText = OpenExchangePrices.outpointText(leg.outpoint)
                progress(.relaying(leg: legText, amountIn: leg.amountIn, amountOut: leg.amountOut, filled: legs))
                var outcome = await relayOnce(ctx, prepared, tokenId: tokenId, peerId: peerId, patienceMs: patienceMs)
                event(.relayed(leg: legText, attempt: 1, outcome: outcome))
                if case .unknown = outcome {
                    // (a) The overlay: what the leg spends.
                    let spent = (try? await readSpendsAll([legText] + inputs.sats.map(\.outpoint))) ?? []
                    if spent.contains(where: { $0.spentBy != nil && $0.outpoint != legText }) {
                        pending.append(Pending(prepared: prepared, leg: leg, poolId: row.poolId))
                        accountResolved(await resolveSwaps(ctx))
                        continue
                    }
                    if spent.contains(where: { $0.spentBy != nil && $0.outpoint == legText }) { continue }
                    // (b) Once more to the same validator.
                    outcome = await relayOnce(ctx, prepared, tokenId: tokenId, peerId: peerId, patienceMs: patienceMs)
                    event(.relayed(leg: legText, attempt: 2, outcome: outcome))
                    if case .unknown(_, let reason) = outcome {
                        // (c) Race: the next leg to another pool with the same rows.
                        pending.append(Pending(prepared: prepared, leg: leg, poolId: row.poolId))
                        excluded.insert(row.pool.outpoint)
                        event(.excluded(pool: row.pool.outpoint, reason: "no answer twice: \(reason)"))
                        continue
                    }
                }
                if case let .accepted(_, txid, completed) = outcome {
                    if !completed.internalized {
                        pending.append(Pending(prepared: prepared, leg: leg, poolId: row.poolId))
                        accountResolved(await resolveSwaps(ctx))
                        continue
                    }
                    order = order ?? prepared.order
                    budget -= 1
                    filledIn += leg.amountIn
                    filledOut += leg.amountOut
                    legs.append(OpenExchangeLegResult(poolOutpoint: legText, poolId: row.poolId, amountIn: leg.amountIn, amountOut: leg.amountOut, txid: txid))
                    continue
                }
                if case let .refused(_, reason, _) = outcome, reason.hasPrefix("pool_spent") {
                    progress(.repricing(leg: legText, amountIn: leg.amountIn, amountOut: leg.amountOut, filled: legs))
                    spentAt = row.pool.outpoint
                } else {
                    excluded.insert(row.pool.outpoint)
                    let reason: String = switch outcome {
                    case .refused(_, let reason, _): "refused: \(reason)"
                    case .failed(let reason): "failed: \(reason)"
                    case .accepted, .unknown: "no outcome"
                    }
                    event(.excluded(pool: row.pool.outpoint, reason: reason))
                }
                accountResolved(await resolveSwaps(ctx))
                continue
            }
            break
        }

        // 3. The end.
        let status: OpenExchangeSwapResult.Status = filledIn >= quote.request.amountIn ? .filled : legs.isEmpty ? .failed : .partial
        var returned: OpenExchangeSwapResult.Returned?
        if why != .filled, pending.isEmpty {
            let rows = try await OpenExchangeSwapLeg.basketRows(ctx)
            let left = OpenExchangeSwapLeg.satsRows(rows).count + (try OpenExchangeSwapLeg.tokenRowCount(rows, tokenId: tokenId))
            if left > 0 {
                progress(.returning(filled: legs))
                do {
                    let m = try await OpenExchangeSwapLeg.moveBack(ctx, tokenId: tokenId, sym: sym)
                    returned = .moved(txid: m.txid, tokens: 0)
                } catch {
                    returned = .error(OpenExchangeError.errorText(error))
                }
                if let returned { event(.returned(returned)) }
            }
        }
        return OpenExchangeSwapResult(
            status: status, stop: why, legs: legs, totalIn: filledIn, totalOut: filledOut,
            unfilled: quote.request.amountIn - filledIn, stuck: stuck.isEmpty ? nil : stuck, returned: returned
        )
    }

    /// The client's `relayLeg`: a thrown error is no answer.
    func relayOnce(_ ctx: OneColorContext, _ p: OpenExchangePreparedLeg, tokenId: String, peerId: String, patienceMs: Int) async -> OpenExchangeLegOutcome {
        do {
            return try await relayLeg(ctx, p, tokenId: tokenId, peerId: peerId, patienceMs: patienceMs)
        } catch {
            return .unknown(id: p.id, reason: OpenExchangeError.errorText(error))
        }
    }

    /// `poolOutputOf` (lib/overlay.ts): the `/tx` read's BEEF as the Atomic BEEF of the outpoint's
    /// transaction, and its output index; nil without bytes or without that transaction.
    static func poolOutputOf(_ bytes: [UInt8]?, _ outpoint: String) -> (beef: [UInt8], outputIndex: Int)? {
        guard let bytes, !bytes.isEmpty, let op = AMMTokenID.parseOutpoint(outpoint),
              let beef = try? readBEEF(bytes), let id = try? TransactionID(displayHex: op.txid),
              (try? beef.entry(for: id, limits: OpenExchangeSwapLeg.txLimits)) != nil,
              let atomic = try? ColorBEEF.atomic(id, in: beef).serialized(limits: beefLimits) else { return nil }
        return (atomic, Int(op.vout))
    }
}

extension OpenExchangeSwapLeg {
    /// `POOL_TAG` / `POOL_OP` (lp/poolRows.ts).
    static let poolTag = "amm-pool"

    /// `isPoolRow`.
    static func isPoolRow(_ row: WalletOutput) -> Bool {
        if row.tags?.contains(poolTag) == true { return true }
        return JSONValue.parse(Array((row.customInstructions ?? "{}").utf8))?["op"]?.string == poolTag
    }

    /// `tokenInputsOf(rows, tokenId).length`: the swap basket's token rows of `tokenId`.
    static func tokenRowCount(_ rows: [WalletOutput], tokenId: String) throws -> Int {
        let assetId = try OneColor.idFromString(try AMMTokenID.canonical(tokenId))
        return rows.filter { row in
            guard let script = row.lockingScript, !isPoolRow(row), let t = AMMPool.decodeOneColor(script),
                  t.role == .value, t.idBytes == assetId, keyOf(row.customInstructions) != nil else { return false }
            return true
        }.count
    }

    /// `moveBack` with only sats in the swap basket: `moveBackSats` over every sats row. The
    /// module's transfer plan that takes token rows back is not here: with a token row of
    /// `tokenId` it throws.
    static func moveBack(_ ctx: OneColorContext, tokenId: String, sym: String) async throws -> OpenExchangeMovedBack {
        let rows = try await basketRows(ctx)
        let tokens = try tokenRowCount(rows, tokenId: tokenId)
        let sats = satsRows(rows)
        if tokens == 0, !sats.isEmpty { return try await moveBackSats(ctx, sym: sym, rows: sats) }
        if tokens == 0 { throw fail("the swap basket holds no \(sym)") }
        throw fail("moving \(sym) back from the swap basket is not supported here")
    }
}

/// One token's rows in the swap basket.
public struct OpenExchangeSwapTokenTotal: Equatable, Sendable {
    public let amount: BigInt
    public let outputs: Int
}

/// What the swap basket (`amm-swap`) holds, outside the wallet's balance until a leg spends it,
/// the pass takes a payout in, or a move back returns it.
public struct OpenExchangeSwapBasketTotals: Equatable, Sendable {
    /// `swapSatsTotal`: the sats rows' sats, and how many rows.
    public let sats: UInt64
    public let satsOutputs: Int
    /// `swapTotals`: by token id (`<txid>_<vout>`).
    public let tokens: [String: OpenExchangeSwapTokenTotal]
}

extension OpenExchangeSwapLeg {
    /// `tokenIdOfWire` (lib/tokenId.ts): a BRC-162 wire id as `<txid>_<vout>`.
    static func tokenIdOfWire(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 32 || bytes.count == 36 else { throw fail("a token's wire id is 32 or 36 bytes, not \(bytes.count)") }
        let vout = bytes.count == 32 ? 0 : bytes[32..<36].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return "\(AMMPool.hex(bytes[0..<32].reversed()))_\(vout)"
    }

    /// `swapTotals` and `swapSatsTotal` (market/activeSwap.ts) in one read of the basket.
    public static func swapBasketTotals(_ ctx: OneColorContext) async throws -> OpenExchangeSwapBasketTotals {
        let rows = try await basketRows(ctx)
        var tokens: [String: OpenExchangeSwapTokenTotal] = [:]
        for row in rows {
            guard let script = row.lockingScript, let t = AMMPool.decodeOneColor(script), t.role == .value, let id = t.idBytes else { continue }
            let key = try tokenIdOfWire(id)
            let was = tokens[key]
            tokens[key] = OpenExchangeSwapTokenTotal(amount: (was?.amount ?? 0) + BigInt(t.amount), outputs: (was?.outputs ?? 0) + 1)
        }
        let sats = satsRows(rows)
        return OpenExchangeSwapBasketTotals(sats: sats.reduce(0) { $0 + $1.satoshis }, satsOutputs: sats.count, tokens: tokens)
    }
}
