import BigInt
import BSVWallet
import Foundation
import OneSatAMM
import OneSatColor
import ToolboxAuth
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Open Exchange swap as the app runs it (`OpenExchange.executeSwap`), against the exchange
/// the backend's chain uses: on testnet, `https://testnet.openex.dev`, with real broadcast through
/// testnet storage. One ordered test, so nothing depends on the order tests run in and `--parallel`
/// cannot interleave its steps:
///
/// 1. The exchange preflight (once per process): a hosted token with a live pool, and the
///    smallest round trip its validators take, under `maxLegSats`. Nothing is spent before it.
/// 2. A funded through the shared top-up (`fundedA`, `TopUpBudget`); anything an interrupted run
///    left in A's swap basket moved back.
/// 3. A swap cancelled before any leg is sent: the sats are staged and moved back.
/// 4. A buy of the round trip's size, quoted after funding.
/// 5. A sell of every unit of the token A holds, so the bought tokens do not pile up and the sats
///    come back.
/// 6. The recovery pass (`settleSwaps`, `resolveSwaps`) leaves the swap basket empty.
///
/// Each real swap is quoted fresh and runs again once, on a fresh quote, when it stops `floor`,
/// `min` or `no_pool` (a pool refusing a leg as pending is excluded and stops `no_pool`) with
/// nothing filled and everything moved back. A second clean stop is accepted for that side, but at
/// least one of the buy and the sell must fill in every run. Each run has a soft deadline (the swap
/// cancels before its next leg) and a hard one; a test that fails after staging moves the swap
/// basket back in teardown.
///
/// A local run skips: the local stack serves no exchange.
final class SwapFlowTests: LiveTestCase {
    /// The slippage a swap allows, basis points.
    static let slippageBps = 300
    /// What the staging and move-back actions may cost in miner fees between them.
    static let actionFees: Int64 = 2_000
    /// The most sats one leg may put in: the run fails, before spending, when the exchange's
    /// smallest round trip needs more. Testnet validators take legs of 100,000 sats or more, so
    /// the cap sits above that; the sell back returns most of it, leaving a few thousand in fees.
    /// It stays under `Funding.floor` so one top-up covers the round trip.
    static let maxLegSats = BigInt(150_000)
    /// A swap run is cancelled before its next leg after this long.
    static let softDeadline: TimeInterval = 150
    /// A swap run that has not returned by now is cancelled outright and fails.
    static let hardDeadline: TimeInterval = 240
    /// The stops a swap is run again for, on a fresh quote, when nothing filled.
    static let retryStops: Set<OpenExchangeSwapStop> = [.floor, .min, .noPool]

    /// Every exchange request through a session the host guard is named on, so the guard sees
    /// these requests on every platform; 30 s a request, 90 s in all.
    static let exchangeTransport: any HTTPTransport = URLSessionHTTPTransport(
        session: guardedSession(requestTimeout: 30, resourceTimeout: 90, fresh: true)
    )

    /// The exchange and wallet whose swap basket teardown empties when the test fails.
    private var cleanup: (ox: OpenExchange, ctx: OneColorContext)?

    override func tearDown() async throws {
        if let cleanup, testRun?.hasSucceeded != true {
            do {
                let done = try await Self.moveBackLeftovers(cleanup.ox, cleanup.ctx)
                print("TEARDOWN swap basket: \(done)")
            } catch {
                XCTFail("teardown could not move A's swap basket back: \(String(describing: error))")
            }
        }
        try await super.tearDown()
    }

    func exchange() throws -> (OpenExchange, origin: String) {
        guard backend.kind == .testnet, let origin = backend.exchange?.absoluteString else {
            throw XCTSkip("the swap flow runs on testnet only; the local stack serves no Open Exchange")
        }
        return (try OpenExchange(origin: origin, http: Self.exchangeTransport), origin)
    }

    /// The context the app's swap runs with: the wallet, and the chain's 1Color overlay.
    func colorContext(_ wallet: LiveWallet) -> OneColorContext {
        OneColorContext(wallet.context, overlay: LiveColorOverlay.testnet)
    }

    /// Prints A, B and T (identity, deposit address, balance) without spending: what to fund.
    func testQAWalletAddresses() async throws {
        for role in QAWallets.Role.allCases {
            let wallet = try await qa(role)
            print("QA \(wallet.name) balance \(try await wallet.balance())")
        }
    }

    // MARK: - The round trip

    func testSwapRoundTrip() async throws {
        let (ox, origin) = try exchange()
        let market = try await ExchangePreflight.shared.check(ox, origin: origin)
        let token = market.token

        let a = try await fundedA()
        let ctx = colorContext(a)
        cleanup = (ox, ctx)
        print("LEFTOVERS before the round trip: \(try await Self.moveBackLeftovers(ox, ctx))")

        // Quoted after funding, which can wait minutes for a deposit.
        let plan = try await roundTrip(ox, token, origin: origin)
        let need = Self.most(plan.buy) + Self.mostFees(plan.sell) + Self.actionFees
        let have = try await held(a)
        print("BALANCE \(a.name) \(have) with its swap basket (the round trip needs at most \(need))")
        guard have >= need else {
            throw LiveSetupError("\(a.name) holds \(have) sats after funding; the swap round trip needs \(need)")
        }

        try await cancelledBeforeSend(ox, ctx, a, token, origin: origin)
        let bought = try await buy(ox, ctx, a, token, origin: origin)
        let sold = try await sellBack(ox, ctx, a, token, after: bought)
        XCTAssertTrue(
            bought != nil || sold,
            "neither the buy nor the sell of \(token.sym) filled; each stopped cleanly twice with everything moved back. "
                + "See the SWAP lines: the exchange's pools at \(origin) took no leg this run."
        )
        try await recovery(ox, ctx, a)
    }

    /// (c) A swap cancelled before its first leg: the sats are staged, nothing is relayed, and
    /// `moveBackSats` takes them back into the wallet's balance.
    func cancelledBeforeSend(_ ox: OpenExchange, _ ctx: OneColorContext, _ a: LiveWallet, _ token: OpenExchangeHostedToken, origin: String) async throws {
        let quote = try await roundTrip(ox, token, origin: origin).buy
        // Sats an interrupted run left in the basket count toward the stage.
        let inBasket = BigInt(try await OpenExchangeSwapLeg.swapBasketTotals(ctx).sats)
        let lack = quote.stage.amount + quote.stage.feeSats - inBasket
        let before = try await a.balance()
        let run = try await Self.run(ox, ctx, quote: quote, sym: token.sym, what: "the cancelled swap", cancelled: true)
        let result = run.result
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .cancelled)
        XCTAssertTrue(result.legs.isEmpty)
        let staged = run.events.compactMap { if case .staged(let txid, let sats, _, _, _) = $0 { (txid, sats) } else { nil } }
        if lack > 0 {
            XCTAssertEqual(staged.count, 1, "one staging action: \(run.events)")
            XCTAssertEqual(staged.first.map { BigInt($0.1) }, lack)
            assertTxid(staged.first?.0, "staging")
        } else {
            XCTAssertTrue(staged.isEmpty, "the basket covered the swap, yet it staged: \(run.events)")
        }
        XCTAssertFalse(run.events.contains { if case .relayed = $0 { true } else { false } }, "a cancelled swap relayed a leg")
        guard case .moved(let back, _)? = result.returned else {
            return XCTFail("the staged sats did not go back: \(String(describing: result.returned))")
        }
        assertTxid(back, "move back")
        try await assertBasketEmpty(ctx, "after the move back")
        let after = try await a.balance()
        let cost = before - after
        print("CANCEL staged \(staged.first?.0 ?? "-") moved back \(back); A \(before) -> \(after) (\(cost) sats in fees)")
        XCTAssertTrue((1...Self.actionFees).contains(cost), "the cancelled swap cost \(cost) sats")
    }

    /// (a) Buy with A, quoted fresh: done, the tokens in A's 1Color basket, the sats spent within
    /// the quote and fees, each leg's txid recorded. Its result, or nil when it stopped cleanly twice.
    func buy(_ ox: OpenExchange, _ ctx: OneColorContext, _ a: LiveWallet, _ token: OpenExchangeHostedToken, origin: String) async throws -> OpenExchangeSwapResult? {
        guard let filled = try await swapWithRetry("buy", ox, ctx, a, token, quote: {
            try await self.roundTrip(ox, token, origin: origin).buy
        }) else { return nil }
        let (run, before, after) = filled
        let quote = run.quote
        let result = run.result
        XCTAssertEqual(result.status, .filled, "events: \(run.events)")
        XCTAssertEqual(result.stop, .filled)
        XCTAssertEqual(result.totalIn, quote.request.amountIn)
        XCTAssertGreaterThanOrEqual(result.totalOut, quote.minAmountOut)
        XCTAssertEqual(BigInt(after.tokens) - BigInt(before.tokens), result.totalOut, "A's \(token.sym) went \(before.tokens) -> \(after.tokens)")
        let spent = before.sats - after.sats
        XCTAssertGreaterThanOrEqual(spent, Int64(quote.request.amountIn), "A spent \(spent) sats on a \(quote.request.amountIn) sat buy")
        XCTAssertLessThanOrEqual(spent, Self.most(quote), "A spent \(spent) sats; the quote allows \(Self.most(quote))")
        print("BUY \(token.sym) \(token.tokenId): legs \(result.legs.map(\.txid)), \(result.totalIn) sats in, \(result.totalOut) out "
            + "(quoted \(quote.amountOut), min \(quote.minAmountOut)); A sats \(before.sats) -> \(after.sats) (\(spent) spent), "
            + "\(token.sym) \(before.tokens) -> \(after.tokens)")
        return result
    }

    /// Sells every unit of the token A holds (this run's buy and any an earlier run left), quoted
    /// fresh: done, the tokens gone from A's 1Color basket, the payout in A's sats. False when it
    /// stopped cleanly twice, or A holds none to sell. After a buy that filled, it first checks the
    /// pool math: selling the bought tokens back into the buy's own pool must return less than the
    /// buy paid in (`assertSamePoolLoses`). The best-priced sell can still pay more, when another of
    /// the token's pools prices it higher; that is the pools' price gap, and the log says so.
    func sellBack(_ ox: OpenExchange, _ ctx: OneColorContext, _ a: LiveWallet, _ token: OpenExchangeHostedToken, after buy: OpenExchangeSwapResult?) async throws -> Bool {
        if let buy { try await assertSamePoolLoses(ox, token, buy) }
        let asset = try ColorAssetID(token.tokenId)
        guard try await OneColorActions.balance(ctx, assetID: asset) > 0 else {
            print("SELL nothing: \(a.name) holds no \(token.sym)")
            return false
        }
        guard let filled = try await swapWithRetry("sell", ox, ctx, a, token, quote: {
            let held = try await OneColorActions.balance(ctx, assetID: asset)
            let pools = try await ox.tokenPools(token.tokenId)
            do {
                return try Self.quote(.sell, BigInt(held), token, pools)
            } catch let error as OpenExchangeError {
                if case .belowMinimum = error {
                    throw LiveSetupError("selling \(held) \(token.sym) back is under the validators' minimum leg: \(error.message)")
                }
                throw error
            }
        }) else { return false }
        let (run, before, after) = filled
        let quote = run.quote
        let result = run.result
        XCTAssertEqual(result.status, .filled, "events: \(run.events)")
        XCTAssertEqual(result.stop, .filled)
        XCTAssertEqual(result.totalIn, quote.request.amountIn)
        XCTAssertGreaterThan(result.totalOut, 0, "the sell paid out no sats")
        XCTAssertGreaterThanOrEqual(result.totalOut, quote.minAmountOut)
        XCTAssertEqual(BigInt(before.tokens) - BigInt(after.tokens), result.totalIn, "A's \(token.sym) went \(before.tokens) -> \(after.tokens)")
        // The payout came back into A's sats, less at most the sell's own fees.
        let gained = after.sats - before.sats
        let payout = Int64(result.totalOut)
        XCTAssertLessThanOrEqual(gained, payout, "A gained \(gained) sats on a sell that paid out \(payout)")
        XCTAssertGreaterThanOrEqual(gained, payout - Self.mostFees(quote),
            "A gained \(gained) sats on a sell that paid out \(payout); its fees may take at most \(Self.mostFees(quote))")
        print("SELL \(token.sym) \(token.tokenId): legs \(result.legs.map(\.txid)), \(result.totalIn) \(token.sym) in, \(result.totalOut) sats out "
            + "(quoted \(quote.amountOut), min \(quote.minAmountOut)); A sats \(before.sats) -> \(after.sats) (\(gained) gained), "
            + "\(token.sym) \(before.tokens) -> \(after.tokens)")
        if let buy {
            let samePool = Set(result.legs.map(\.poolId)) == Set(buy.legs.map(\.poolId))
            if samePool {
                XCTAssertLessThan(result.totalOut, buy.totalIn,
                    "the sell back through the buy's own pool paid \(result.totalOut) sats for a \(buy.totalIn) sat buy")
            }
            print("ROUND TRIP \(buy.totalIn) sats -> \(buy.totalOut) \(token.sym) -> \(result.totalOut) sats; buy pools \(buy.legs.map(\.poolId)), "
                + "sell pools \(result.legs.map(\.poolId))" + (samePool ? " (same pool)" : " (a different pool: the gain is the gap between the pools' prices)"))
        }
        return true
    }

    /// Selling what `buy` got back into the buy's own pool, read now, pays less than the buy paid
    /// in: one pool's round trip loses its fees and price impact. Computed with the contract's own
    /// math (`AMMPricing.computeSwap`, the TS engine's `computeSwap`) on the pool's current
    /// reserves, so it runs even when that sell is under the validators' minimum leg.
    func assertSamePoolLoses(_ ox: OpenExchange, _ token: OpenExchangeHostedToken, _ buy: OpenExchangeSwapResult) async throws {
        XCTAssertEqual(buy.legs.count, 1, "the round trip's buy is quoted for one leg")
        guard let leg = buy.legs.first else { return }
        let all = try await ox.tokenPools(token.tokenId)
        guard let row = all.pools.first(where: { $0.poolId == leg.poolId }) else {
            XCTFail("the buy's pool \(leg.poolId) is not listed now")
            return
        }
        guard let back = try AMMPricing.computeSwap(row.pool, .tokenToBsv, leg.amountOut) else {
            XCTFail("selling \(leg.amountOut) \(token.sym) back into \(leg.poolId) computes no swap")
            return
        }
        print("SAME POOL sell \(leg.amountOut) \(token.sym) back into \(leg.poolId): \(back.amountOut) sats "
            + "(fees lp \(back.liquidityFee) val \(back.validationFee) com \(back.commission)) for a \(leg.amountIn) sat buy")
        XCTAssertLessThan(back.amountOut, leg.amountIn,
            "selling \(leg.amountOut) \(token.sym) back into the buy's own pool pays \(back.amountOut) sats, more than the \(leg.amountIn) the buy paid")
    }

    /// (b) The recovery pass after the swaps: nothing left to take in, the swap basket empty.
    func recovery(_ ox: OpenExchange, _ ctx: OneColorContext, _ a: LiveWallet) async throws {
        let settled = await ox.settleSwaps(ctx)
        let resolved = await ox.resolveSwaps(ctx)
        print("RECOVERY settled \(settled), resolved taken \(resolved.taken.map(\.txid)) stuck \(resolved.stuck)")
        XCTAssertTrue(resolved.stuck.isEmpty, "rows the pass cannot take in: \(resolved.stuck)")
        XCTAssertTrue(resolved.taken.isEmpty, "a second pass still took in \(resolved.taken.map(\.txid))")
        try await assertBasketEmpty(ctx, "after the recovery pass")
        let rows = try await a.outputs(in: OpenExchangeSwapNames.basket)
        XCTAssertTrue(rows.isEmpty, "the amm-swap basket lists \(rows.map { "\($0.outpoint)" })")
    }

    // MARK: - Running a swap

    /// A's sats (with its swap basket) and its units of the swapped token.
    struct Holdings: Sendable {
        let sats: Int64
        let tokens: UInt64
    }

    func holdings(_ a: LiveWallet, _ ctx: OneColorContext, _ token: OpenExchangeHostedToken) async throws -> Holdings {
        Holdings(sats: try await held(a), tokens: try await OneColorActions.balance(ctx, assetID: try ColorAssetID(token.tokenId)))
    }

    /// Runs a swap on `quote()`, and once more on a fresh quote when the first stops in
    /// `retryStops` with nothing filled and everything moved back. The run that filled, with A's
    /// holdings around it; nil when the last run stopped cleanly with nothing filled (accepted).
    /// Fails on anything else: a deadline, a stop that left rows, a move back that failed.
    func swapWithRetry(
        _ side: String, _ ox: OpenExchange, _ ctx: OneColorContext, _ a: LiveWallet, _ token: OpenExchangeHostedToken,
        quote: () async throws -> OpenExchangeQuote
    ) async throws -> (run: SwapRun, before: Holdings, after: Holdings)? {
        for attempt in 1...2 {
            let q = try await quote()
            try assertQuote(q, side)
            let before = try await holdings(a, ctx, token)
            let run = try await Self.run(ox, ctx, quote: q, sym: token.sym, what: "the \(side) of \(token.sym) (attempt \(attempt))")
            let after = try await holdings(a, ctx, token)
            let result = run.result
            if !result.legs.isEmpty {
                guard case .done? = run.progress.last else {
                    XCTFail("the \(side) did not end done: \(String(describing: run.progress.last))")
                    throw LiveSetupError("the \(side) did not end done")
                }
                for leg in result.legs { assertTxid(leg.txid, "\(side) leg \(leg.poolOutpoint)") }
                XCTAssertNil(result.stuck, "the \(side) left rows the pass could not take in")
                return (run, before, after)
            }
            // Nothing filled: it must have stopped cleanly, everything back in A.
            if result.stop == .cancelled {
                XCTFail("the \(side) of \(token.sym) reached its \(Int(Self.softDeadline)) s deadline before a leg filled; events: \(run.events)")
                throw LiveSetupError("the \(side) ran out of time")
            }
            if case .error(let why)? = result.returned {
                XCTFail("the \(side) stopped \(result.stop.rawValue) and its move back failed: \(why)")
                throw LiveSetupError("the \(side)'s move back failed")
            }
            guard result.stuck == nil else {
                XCTFail("the \(side) stopped \(result.stop.rawValue) leaving rows the pass could not take in: \(String(describing: result.stuck))")
                throw LiveSetupError("the \(side) left stuck rows")
            }
            try await assertBasketEmpty(ctx, "after the \(side) stopped \(result.stop.rawValue)")
            XCTAssertEqual(after.tokens, before.tokens, "a \(side) that filled nothing moved A's \(token.sym)")
            XCTAssertTrue((0...Self.actionFees).contains(before.sats - after.sats),
                "a \(side) that filled nothing cost \(before.sats - after.sats) sats")
            guard Self.retryStops.contains(result.stop) else {
                XCTFail("the \(side) of \(token.sym) stopped \(result.stop.rawValue) with nothing filled; events: \(run.events)")
                throw LiveSetupError("the \(side) stopped \(result.stop.rawValue)")
            }
            if attempt == 1 {
                print("RETRY the \(side) of \(token.sym) stopped \(result.stop.rawValue) with nothing filled and everything moved back; quoting again")
                continue
            }
            print("ACCEPTED the \(side) of \(token.sym) stopped \(result.stop.rawValue) twice with nothing filled and everything moved back")
        }
        return nil
    }

    func assertQuote(_ quote: OpenExchangeQuote, _ side: String) throws {
        print("QUOTE \(side) \(quote.request.amountIn) of \(quote.request.tokenId): out \(quote.amountOut) "
            + "(min \(quote.minAmountOut)), stage \(quote.stage.amount) + \(quote.stage.feeSats) fee sats, "
            + "price \(quote.effectivePrice) sats/token (marginal \(quote.marginalPrice), impact \(quote.impactBps) bps), "
            + "legs \(quote.legs.map { "\($0.poolOutpoint) in \($0.amountIn) out \($0.amountOut) lp \($0.lpFee) val \($0.validatorFee) com \($0.commission)" })")
        XCTAssertEqual(quote.legs.count, 1, "the \(side) quote")
        XCTAssertGreaterThan(quote.amountOut, 0, "the \(side) quote")
        XCTAssertLessThanOrEqual(quote.minAmountOut, quote.amountOut, "the \(side) quote")
        if quote.request.side == .buy {
            XCTAssertLessThanOrEqual(quote.request.amountIn, Self.maxLegSats, "the buy quote")
        }
    }

    /// One swap and what it reported, under the soft and hard deadlines.
    struct SwapRun: Sendable {
        let quote: OpenExchangeQuote
        let result: OpenExchangeSwapResult
        let events: [OpenExchangeSwapEvent]
        let progress: [OpenExchangeSwapProgress]
    }

    static func run(
        _ ox: OpenExchange, _ ctx: OneColorContext, quote: OpenExchangeQuote, sym: String, what: String, cancelled: Bool = false
    ) async throws -> SwapRun {
        let events = EventLog()
        let progress = ProgressLog()
        let soft = Date().addingTimeInterval(softDeadline)
        let result: OpenExchangeSwapResult
        do {
            result = try await withDeadline(hardDeadline, what) {
                try await ox.executeSwap(
                    ctx, quote: quote, sym: sym,
                    isCancelled: { cancelled || Date() >= soft },
                    onProgress: { progress.append($0) }, onEvent: { events.append($0) }
                )
            }
        } catch {
            for event in events.all { print("SWAP EVENT \(event)") }
            print("SWAP \(what) threw: \(String(describing: error))")
            throw error
        }
        print("SWAP \(what): \(result)")
        for event in events.all { print("SWAP EVENT \(event)") }
        return SwapRun(quote: quote, result: result, events: events.all, progress: progress.all)
    }

    // MARK: - Quotes and sizes

    /// What a buy of `quote` can take out of A: the staged amount and fee sats, one leg's miner
    /// fee top-up (`OpenExchangeQuote.stage`), and the actions' miner fees.
    static func most(_ quote: OpenExchangeQuote) -> Int64 {
        Int64(quote.stage.amount + quote.stage.feeSats + quote.legMinerFeeSats) + actionFees
    }

    /// What a swap of `quote` can spend in fees alone: its fee sats, one leg's miner fee top-up and
    /// the actions' miner fees.
    static func mostFees(_ quote: OpenExchangeQuote) -> Int64 {
        Int64(quote.stage.feeSats + quote.legMinerFeeSats) + actionFees
    }

    static func quote(_ side: OpenExchangeQuoteRequest.Side, _ amount: BigInt, _ token: OpenExchangeHostedToken, _ pools: OpenExchangePools) throws -> OpenExchangeQuote {
        try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: token.tokenId, side: side, amountIn: amount, maxSlippageBps: slippageBps, maxSources: 1),
            held: pools, sym: token.sym, dec: token.dec
        )
    }

    /// The round trip on the token's pools read now (see `RoundTrip.size`).
    func roundTrip(_ ox: OpenExchange, _ token: OpenExchangeHostedToken, origin: String) async throws -> RoundTrip {
        try RoundTrip.size(token, pools: try await ox.tokenPools(token.tokenId), origin: origin)
    }

    // MARK: - The swap basket

    /// A's balance and what its swap basket holds: the sats a swap can draw on.
    func held(_ wallet: LiveWallet) async throws -> Int64 {
        let basket = try await OpenExchangeSwapLeg.swapBasketTotals(colorContext(wallet))
        return try await wallet.balance() + Int64(basket.sats)
    }

    func assertBasketEmpty(_ ctx: OneColorContext, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        let totals = try await OpenExchangeSwapLeg.swapBasketTotals(ctx)
        XCTAssertEqual(totals.sats, 0, "\(what): the swap basket holds \(totals.sats) sats in \(totals.satsOutputs) rows", file: file, line: line)
        XCTAssertTrue(totals.tokens.isEmpty, "\(what): the swap basket holds tokens \(totals.tokens)", file: file, line: line)
    }

    /// Takes in what landed (`settleSwaps`), then moves every token and sats row left in the swap
    /// basket back to the wallet: each token with the sats in one module plan, then any sats
    /// alone. Leaves rows a spender the pass could not take in holds, and says so. Returns what it
    /// did, in words.
    static func moveBackLeftovers(_ ox: OpenExchange, _ ctx: OneColorContext) async throws -> String {
        let settled = await ox.settleSwaps(ctx)
        var done: [String] = []
        if !settled.resolved.taken.isEmpty { done.append("took in \(settled.resolved.taken.map(\.txid))") }
        if !settled.resolved.stuck.isEmpty {
            throw LiveSetupError("the swap basket holds rows a transaction spends that the pass cannot take in, so they are not moved back: "
                + "\(settled.resolved.stuck)")
        }
        let totals = try await OpenExchangeSwapLeg.swapBasketTotals(ctx)
        for (tokenId, total) in totals.tokens.sorted(by: { $0.key < $1.key }) where total.amount > 0 {
            let moved = try await ox.moveBackTokens(ctx, tokenId: tokenId, sym: String(tokenId.prefix(8)))
            done.append("moved \(moved.amount) of \(tokenId) and the sats back in \(moved.txid) (\(moved.submitted)\(moved.errors.isEmpty ? "" : "; \(moved.errors)"))")
        }
        let sats = try await OpenExchangeSwapLeg.swapBasketTotals(ctx).sats
        if sats > 0 {
            let moved = try await OpenExchangeSwapLeg.moveBackSats(ctx)
            done.append("moved \(sats) sats back in \(moved.txid)")
        }
        return done.isEmpty ? "empty" : done.joined(separator: "; ")
    }
}

// MARK: - The round trip's size

/// The smallest buy whose tokens sell back over the validators' minimum leg, and the sell it
/// expects, on one read of the token's pools.
struct RoundTrip: Sendable {
    let buy: OpenExchangeQuote
    let sell: OpenExchangeQuote
    /// The largest minimum leg of the validators of the token's open pools, sats.
    let minLegSats: BigInt

    /// Sizes the round trip: from the minimum leg up in 1% steps until a quote of selling the
    /// buy's least amount out clears the minimum by 1% (a sell's minimum is on its sats out). Fails,
    /// before anything is spent, when that buy would be over `SwapFlowTests.maxLegSats`.
    static func size(_ token: OpenExchangeHostedToken, pools: OpenExchangePools, origin: String) throws -> RoundTrip {
        let minLeg = minimumLeg(pools)
        let cap = SwapFlowTests.maxLegSats
        var amount = Swift.max(minLeg, BigInt(1_000))
        while amount <= cap {
            let buy: OpenExchangeQuote
            do {
                buy = try SwapFlowTests.quote(.buy, amount, token, pools)
            } catch {
                throw LiveSetupError("quoting a buy of \(amount) sats of \(token.sym) (\(token.tokenId)) at \(origin) failed: \(SwapMarket.text(error))")
            }
            if let sell = try? SwapFlowTests.quote(.sell, buy.minAmountOut, token, pools), sell.amountOut >= minLeg + minLeg / 100 {
                print("ROUND TRIP \(token.sym): buy \(amount) sats for at least \(buy.minAmountOut), which sell back for about \(sell.amountOut) sats "
                    + "(minimum leg \(minLeg) sats, cap \(cap))")
                return RoundTrip(buy: buy, sell: sell, minLegSats: minLeg)
            }
            amount += Swift.max(amount / 100, 1)
        }
        throw LiveSetupError(
            "the smallest swap round trip Open Exchange's validators take for \(token.sym) (\(token.tokenId)) at \(origin) "
                + (minLeg > cap
                    ? "is a leg of \(minLeg) sats (the validators' minLegSats)"
                    : "is a buy of more than \(cap) sats, to sell back over the validators' \(minLeg) sat minimum leg")
                + ", above this suite's cap of \(cap) sats a leg, so nothing was spent. That is the exchange's setting, not an SDK "
                + "fault: lower the validators' minLegSats at \(origin), or raise SwapFlowTests.maxLegSats on purpose.")
    }

    /// The largest `minLegSats` of the validators whose pools are open (reserves on both sides,
    /// a live validator); 0 for none.
    static func minimumLeg(_ pools: OpenExchangePools) -> BigInt {
        let open = Set(SwapMarket.openPools(pools).map { $0.pool.validatorIdentityKey.lowercased() })
        return pools.validators.filter { open.contains($0.identity.lowercased()) }.compactMap(\.minLegSats).max() ?? 0
    }
}

// MARK: - The exchange preflight

/// The token the swap test trades, chosen from what the host lists.
enum SwapMarket {
    /// The pools that hold reserves on both sides and whose validator is live.
    static func openPools(_ pools: OpenExchangePools) -> [OpenExchangePoolRow] {
        let live = OpenExchangeLiveness.of(pools.pools)
        return pools.pools.filter {
            $0.pool.bsvReserve > 0 && $0.pool.tokenReserve > 0
                && OpenExchangeValidatorStatus.of($0.pool.validatorIdentityKey, live).live
        }
    }

    /// The hosted token with an open pool and the smallest minimum leg (more open pools first on
    /// a tie). Fails, naming what the host lists, when no token has one.
    static func pick(_ ox: OpenExchange, origin: String) async throws -> (token: OpenExchangeHostedToken, pools: OpenExchangePools) {
        let hosted: [OpenExchangeHostedToken]
        do {
            hosted = try await ox.hostedTokens()
        } catch {
            throw unreachable(origin, "its token list", error)
        }
        // The stats give each token's open pools; without them, read every listed token.
        let listed = hosted.contains { $0.pools > 0 } ? hosted.filter { $0.pools > 0 } : hosted
        var best: (token: OpenExchangeHostedToken, pools: OpenExchangePools, open: Int, minLeg: BigInt)?
        var seen: [String] = []
        for token in listed {
            let pools: OpenExchangePools
            do {
                pools = try await ox.tokenPools(token.tokenId)
            } catch {
                seen.append("\(token.sym) \(token.tokenId): pools unread (\(text(error)))")
                continue
            }
            let open = openPools(pools).count
            let minLeg = RoundTrip.minimumLeg(pools)
            seen.append("\(token.sym) \(token.tokenId): \(pools.pools.count) pools, \(open) open, minimum leg \(minLeg) sats")
            guard open > 0 else { continue }
            if let b = best, b.minLeg < minLeg || (b.minLeg == minLeg && b.open >= open) { continue }
            best = (token, pools, open, minLeg)
        }
        print("MARKET \(seen.joined(separator: "; "))")
        guard let best else {
            throw LiveSetupError(
                "Open Exchange at \(origin) lists no token with a live pool holding liquidity (\(hosted.count) tokens listed: "
                    + "\(seen.isEmpty ? "none" : seen.joined(separator: "; "))). The swap flow cannot run until the exchange has one; "
                    + "this is the exchange's state, not an SDK fault.")
        }
        return (best.token, best.pools)
    }

    /// The preflight's error for a read that failed: unreachable (not an SDK fault), or an answer
    /// the SDK could not read.
    static func unreachable(_ origin: String, _ what: String, _ error: Error) -> LiveSetupError {
        let network: Bool
        if case .network? = error as? OpenExchangeError { network = true } else { network = error is URLError }
        if network {
            return LiveSetupError("Open Exchange at \(origin) is unreachable (reading \(what)): \(text(error)). "
                + "The exchange is down or this machine cannot reach it; this is not an SDK fault.")
        }
        return LiveSetupError("Open Exchange at \(origin) answered \(what) with something the SDK could not read: \(text(error)). "
            + "Check the exchange is up first; if it is, look at the SDK's market reads.")
    }

    /// An error in words: an exchange error's message, else the error itself.
    static func text(_ error: Error) -> String {
        (error as? OpenExchangeError)?.message ?? String(describing: error)
    }
}

/// Checks, once per process, that Open Exchange is there with a live pool, and that its smallest
/// round trip fits `SwapFlowTests.maxLegSats`, so a down exchange or an empty market fails every
/// swap test at once with one clear message, before any sats move.
actor ExchangePreflight {
    static let shared = ExchangePreflight()

    struct Report: Sendable {
        let token: OpenExchangeHostedToken
        let openPools: Int
        let roundTrip: RoundTrip
    }

    private var outcome: Result<Report, LiveSetupError>?

    func check(_ ox: OpenExchange, origin: String) async throws -> Report {
        if let outcome { return try outcome.get() }
        let result: Result<Report, LiveSetupError>
        do {
            let (token, pools) = try await SwapMarket.pick(ox, origin: origin)
            let trip = try RoundTrip.size(token, pools: pools, origin: origin)
            result = .success(Report(token: token, openPools: SwapMarket.openPools(pools).count, roundTrip: trip))
        } catch let error as LiveSetupError {
            result = .failure(error)
        } catch {
            result = .failure(LiveSetupError("Open Exchange preflight at \(origin) failed: \(String(describing: error))"))
        }
        outcome = result
        if case .success(let report) = result {
            print("EXCHANGE PREFLIGHT ok: \(origin) \(report.token.sym) \(report.token.tokenId), \(report.openPools) open pools, "
                + "minimum leg \(report.roundTrip.minLegSats) sats, round trip buy \(report.roundTrip.buy.request.amountIn) sats")
        }
        return try result.get()
    }
}

// MARK: - Deadlines and logs

/// Runs `operation`, cancelling it and failing when it has not returned within `seconds`. Returns
/// only once the operation has ended, so nothing it started is still running afterwards.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval, _ what: String, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LiveSetupError("\(what) did not finish within \(Int(seconds)) s; it was cancelled")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw LiveSetupError("\(what) returned nothing")
        }
        return first
    }
}

/// A thread-safe record of what a swap reported.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [OpenExchangeSwapEvent] = []
    func append(_ event: OpenExchangeSwapEvent) { lock.lock(); events.append(event); lock.unlock() }
    var all: [OpenExchangeSwapEvent] { lock.lock(); defer { lock.unlock() }; return events }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [OpenExchangeSwapProgress] = []
    func append(_ step: OpenExchangeSwapProgress) { lock.lock(); steps.append(step); lock.unlock() }
    var all: [OpenExchangeSwapProgress] { lock.lock(); defer { lock.unlock() }; return steps }
}
