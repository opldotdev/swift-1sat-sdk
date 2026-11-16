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

/// The Open Exchange buy swap as the app runs it (`OpenExchange.executeSwap`), against the
/// exchange the backend's chain uses: on testnet, `https://testnet.openex.dev`, with real
/// broadcast through testnet storage. A buys the most active hosted token with live pools for
/// the smallest leg its validators take.
///
/// - `testA…`: a swap cancelled before any leg is sent stages the sats and moves them back.
/// - `testB…`: quote, then buy; done, tokens in A's 1Color basket, sats spent within the quote.
/// - `testC…`: the recovery pass afterwards (`settleSwaps`, `resolveSwaps`) leaves the swap
///   basket empty.
///
/// A local run skips: the local stack serves no exchange.
final class SwapFlowTests: LiveTestCase {
    static let exchangeOrigin = "https://testnet.openex.dev"
    /// The slippage a buy allows, basis points.
    static let slippageBps = 300
    /// What the staging and move-back actions may cost in miner fees between them.
    static let actionFees: Int64 = 2_000

    /// Every exchange read through a session the host guard is named on, so the guard sees these
    /// requests on every platform.
    static let exchangeTransport: any HTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.protocolClasses = [HostGuard.self] + (configuration.protocolClasses ?? [])
        return URLSessionHTTPTransport(session: URLSession(configuration: configuration))
    }()

    func exchange() throws -> OpenExchange {
        guard backend.kind == .testnet else {
            throw XCTSkip("the swap flow runs on testnet only; the local stack serves no Open Exchange")
        }
        return try OpenExchange(origin: Self.exchangeOrigin, http: Self.exchangeTransport)
    }

    /// The context the app's swap runs with: the wallet, and the chain's 1Color overlay.
    func colorContext(_ wallet: LiveWallet) -> OneColorContext {
        OneColorContext(wallet.context, overlay: LiveColorOverlay.testnet)
    }

    /// The hosted token to buy: the one with the most live pools that each hold reserves, and
    /// those pools. Fails, naming what the host lists, when no token has one.
    func market(_ ox: OpenExchange) async throws -> (token: OpenExchangeHostedToken, pools: OpenExchangePools) {
        let hosted = try await ox.hostedTokens()
        var best: (OpenExchangeHostedToken, OpenExchangePools, Int)?
        var seen: [String] = []
        for token in hosted where token.pools > 0 {
            let pools = try await ox.tokenPools(token.tokenId)
            let live = OpenExchangeLiveness.of(pools.pools)
            let open = pools.pools.filter {
                $0.pool.bsvReserve > 0 && $0.pool.tokenReserve > 0
                    && OpenExchangeValidatorStatus.of($0.pool.validatorIdentityKey, live).live
            }.count
            seen.append("\(token.sym) \(token.tokenId): \(pools.pools.count) pools, \(open) open")
            if open > (best?.2 ?? 0) { best = (token, pools, open) }
        }
        guard let best else {
            XCTFail("no hosted token at \(Self.exchangeOrigin) has a live pool with liquidity: \(seen)")
            throw LiveSetupError("no pool with liquidity")
        }
        print("MARKET \(seen.joined(separator: "; "))")
        return (best.0, best.1)
    }

    /// A buy quote for the smallest leg the token's validators take, over one pool.
    func smallestBuyQuote(_ token: OpenExchangeHostedToken, pools: OpenExchangePools) throws -> OpenExchangeQuote {
        let minLeg = pools.validators.compactMap(\.minLegSats).max() ?? 0
        let amount = Swift.max(minLeg, BigInt(1_000))
        let quote = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: token.tokenId, side: .buy, amountIn: amount, maxSlippageBps: Self.slippageBps, maxSources: 1),
            held: pools, sym: token.sym, dec: token.dec
        )
        print("QUOTE buy \(quote.request.amountIn) sats of \(token.sym) \(token.tokenId): out \(quote.amountOut) "
            + "(min \(quote.minAmountOut)), stage \(quote.stage.amount) + \(quote.stage.feeSats) fee sats, "
            + "price \(quote.effectivePrice) sats/token (marginal \(quote.marginalPrice), impact \(quote.impactBps) bps), "
            + "legs \(quote.legs.map { "\($0.poolOutpoint) in \($0.amountIn) out \($0.amountOut) lp \($0.lpFee) val \($0.validatorFee) com \($0.commission)" })")
        return quote
    }

    /// What a swap of `quote` can take out of A: the staged amount and fee sats, and the
    /// actions' miner fees.
    static func most(_ quote: OpenExchangeQuote) -> Int64 {
        Int64(quote.stage.amount + quote.stage.feeSats) + actionFees
    }

    /// Makes sure A holds `need` sats, paying the shortfall (and a margin) from T. A testnet run
    /// with T too low fails and names T's address.
    func ensureSwapFunds(_ need: Int64) async throws -> LiveWallet {
        let a = try await qa(.A)
        let t = try await qa(.T)
        let balanceA = try await held(a)
        print("BALANCE \(a.name) \(balanceA) with its swap basket (swap needs \(need))")
        guard balanceA < need else { return a }
        let topUp = need - balanceA + 5_000
        // A faucet deposit sits at T's address until deposit sync takes it in, as the app's does.
        let synced = try await Funding.sync(t)
        if !synced.failures.isEmpty || synced.sweepError != nil {
            XCTFail("\(t.name) deposit sync: failures \(synced.failures), sweep \(String(describing: synced.sweepError))")
            throw LiveSetupError("treasury deposit sync failed")
        }
        let balanceT = try await t.balance()
        print("BALANCE \(t.name) \(balanceT)")
        guard balanceT >= topUp + 1_000 else {
            XCTFail("treasury \(t.name) holds \(balanceT) sats; the swap needs \(topUp) more in \(a.name). "
                + "Fund \(try t.receiveAddress()) from the testnet faucet and run again.")
            throw LiveSetupError("treasury too low")
        }
        let txid = try await Funding.pay(from: t, to: try a.receiveAddress(), satoshis: UInt64(topUp), description: "QA swap top-up")
        try await Funding.receive(a, txid: txid)
        print("TOPPED UP \(a.name) to \(try await a.balance()) (\(txid))")
        return a
    }

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

    /// Read only: the market and a quote.
    func testQuoteSmallestBuy() async throws {
        let ox = try exchange()
        let (token, pools) = try await market(ox)
        let quote = try smallestBuyQuote(token, pools: pools)
        XCTAssertEqual(quote.legs.count, 1)
        XCTAssertGreaterThan(quote.amountOut, 0)
        XCTAssertLessThanOrEqual(quote.minAmountOut, quote.amountOut)
    }

    /// Prints A, B and T (identity, deposit address, balance) without spending: what to fund.
    func testQAWalletAddresses() async throws {
        for role in QAWallets.Role.allCases {
            let wallet = try await qa(role)
            print("QA \(wallet.name) balance \(try await wallet.balance())")
        }
    }

    /// (c) A swap cancelled before its first leg: the sats are staged, nothing is relayed, and
    /// `moveBackSats` takes them back into the wallet's balance.
    func testA_CancelledBeforeSendMovesSatsBack() async throws {
        let ox = try exchange()
        let (token, pools) = try await market(ox)
        let quote = try smallestBuyQuote(token, pools: pools)
        let a = try await ensureSwapFunds(Self.most(quote))
        let ctx = colorContext(a)
        let settled = await ox.settleSwaps(ctx)
        print("SETTLED before cancel: \(settled)")
        // Sats an interrupted run left in the basket count toward the stage.
        let inBasket = BigInt(try await OpenExchangeSwapLeg.swapBasketTotals(ctx).sats)
        let lack = quote.stage.amount + quote.stage.feeSats - inBasket
        let before = try await held(a)
        let events = EventLog()
        let result = try await ox.executeSwap(
            ctx, quote: quote, sym: token.sym, isCancelled: { true },
            onEvent: { events.append($0) }
        )
        print("CANCELLED \(result) events \(events.all)")
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .cancelled)
        XCTAssertTrue(result.legs.isEmpty)
        let staged = events.all.compactMap { if case .staged(let txid, let sats, _, _, _) = $0 { (txid, sats) } else { nil } }
        if lack > 0 {
            XCTAssertEqual(staged.count, 1, "one staging action: \(events.all)")
            XCTAssertEqual(staged.first.map { BigInt($0.1) }, lack)
            assertTxid(staged.first?.0, "staging")
        } else {
            XCTAssertTrue(staged.isEmpty, "the basket covered the swap, yet it staged: \(events.all)")
        }
        XCTAssertFalse(events.all.contains { if case .relayed = $0 { true } else { false } }, "a cancelled swap relayed a leg")
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

    /// (a) Quote, then buy with A: done, the tokens in A's 1Color basket, the sats spent within
    /// the quote and fees, each leg's txid recorded.
    func testB_BuySwap() async throws {
        let ox = try exchange()
        let (token, pools) = try await market(ox)
        let quote = try smallestBuyQuote(token, pools: pools)
        let a = try await ensureSwapFunds(Self.most(quote))
        let ctx = colorContext(a)
        _ = await ox.settleSwaps(ctx)
        let asset = try ColorAssetID(token.tokenId)
        let tokensBefore = try await OneColorActions.balance(ctx, assetID: asset)
        let satsBefore = try await held(a)

        let events = EventLog()
        let progress = ProgressLog()
        let result = try await ox.executeSwap(
            ctx, quote: quote, sym: token.sym,
            onProgress: { progress.append($0) }, onEvent: { events.append($0) }
        )
        print("SWAP \(result)")
        for event in events.all { print("SWAP EVENT \(event)") }
        XCTAssertEqual(result.status, .filled, "events: \(events.all)")
        XCTAssertEqual(result.stop, .filled)
        guard case .done? = progress.all.last else {
            return XCTFail("the swap did not end done: \(String(describing: progress.all.last))")
        }
        XCTAssertFalse(result.legs.isEmpty)
        for leg in result.legs { assertTxid(leg.txid, "leg \(leg.poolOutpoint)") }
        XCTAssertEqual(result.totalIn, quote.request.amountIn)
        XCTAssertGreaterThanOrEqual(result.totalOut, quote.minAmountOut)
        XCTAssertNil(result.stuck)

        let tokensAfter = try await OneColorActions.balance(ctx, assetID: asset)
        XCTAssertEqual(BigInt(tokensAfter) - BigInt(tokensBefore), result.totalOut, "A's \(token.sym) went \(tokensBefore) -> \(tokensAfter)")
        let satsAfter = try await held(a)
        let spent = satsBefore - satsAfter
        XCTAssertGreaterThanOrEqual(spent, Int64(quote.request.amountIn), "A spent \(spent) sats on a \(quote.request.amountIn) sat buy")
        XCTAssertLessThanOrEqual(spent, Self.most(quote), "A spent \(spent) sats; the quote allows \(Self.most(quote))")
        let staged = events.all.compactMap { if case .staged(let txid, _, _, _, _) = $0 { txid } else { nil } }
        print("BUY \(token.sym) \(token.tokenId): staged \(staged), legs \(result.legs.map(\.txid)), "
            + "\(result.totalIn) sats in, \(result.totalOut) out (quoted \(quote.amountOut), min \(quote.minAmountOut)); "
            + "A sats \(satsBefore) -> \(satsAfter) (\(spent) spent), \(token.sym) \(tokensBefore) -> \(tokensAfter)")
    }

    /// (b) The recovery pass after the buy: nothing left to take in, the swap basket empty.
    func testC_RecoveryLeavesBasketEmpty() async throws {
        let ox = try exchange()
        let a = try await qa(.A)
        let ctx = colorContext(a)
        let settled = await ox.settleSwaps(ctx)
        let resolved = await ox.resolveSwaps(ctx)
        print("RECOVERY settled \(settled), resolved taken \(resolved.taken.map(\.txid)) stuck \(resolved.stuck)")
        XCTAssertTrue(resolved.stuck.isEmpty, "rows the pass cannot take in: \(resolved.stuck)")
        XCTAssertTrue(resolved.taken.isEmpty, "a second pass still took in \(resolved.taken.map(\.txid))")
        try await assertBasketEmpty(ctx, "after the recovery pass")
        let rows = try await a.outputs(in: OpenExchangeSwapNames.basket)
        XCTAssertTrue(rows.isEmpty, "the amm-swap basket lists \(rows.map { "\($0.outpoint)" })")
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
