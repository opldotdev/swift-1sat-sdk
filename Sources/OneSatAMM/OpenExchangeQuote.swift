import Foundation
import BigInt

// The quote of a swap, as `@dcasegr/amm-client` 0.55.1 (skein-amm cc146be) makes it: the swap
// form into the engine's request and the plan into what the page shows (web/ui/src/market/plan.ts,
// market/view.ts), the liveness the pools route implies (lib/overlay.ts `liveOfPools`), and the
// client's `quoteSwap`, `legCarrySats` and `legMinerFeeSats` (client.ts:525, 1038). Pure: no
// request is made, nothing is built, signed or sent.

// MARK: - Liveness (lib/overlay.ts, market/view.ts)

/// `LiveAnswer` (lib/overlay.ts): the validators known live on a token.
public struct OpenExchangeLiveness: Equatable, Sendable {
    /// `LiveValidator`.
    public struct Validator: Equatable, Sendable {
        /// Lowercase.
        public let identityKey: String
        /// The libp2p peer ID the relay dials.
        public let peerId: String
        /// The beat's time, ms (0: not told).
        public let at: Double
        public let ageMs: Double
        public let live: Bool

        public init(identityKey: String, peerId: String, at: Double, ageMs: Double, live: Bool) {
            self.identityKey = identityKey
            self.peerId = peerId
            self.at = at
            self.ageMs = ageMs
            self.live = live
        }
    }

    public let now: Double
    public let validators: [Validator]
    /// False when nothing about liveness is known.
    public let kept: Bool

    public init(now: Double, validators: [Validator], kept: Bool) {
        self.now = now
        self.validators = validators
        self.kept = kept
    }

    /// `liveOfPools`: the validators of the pools route's rows, each live (the host lists only
    /// pools whose validator beats), keyed by lowercase identity, first row first; a row with
    /// no peer ID names none.
    public static func of(_ rows: [OpenExchangePoolRow], now: Double = Date().timeIntervalSince1970 * 1000) -> OpenExchangeLiveness {
        var validators: [Validator] = []
        var seen: Set<String> = []
        for r in rows {
            let key = r.pool.validatorIdentityKey.lowercased()
            guard let peerId = r.validatorPeerId, !peerId.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            validators.append(Validator(identityKey: key, peerId: peerId, at: 0, ageMs: 0, live: true))
        }
        return OpenExchangeLiveness(now: now, validators: validators, kept: true)
    }
}

/// `ValidatorStatus` (market/view.ts): a pool's validator as the liveness read sees it.
public struct OpenExchangeValidatorStatus: Equatable, Sendable {
    public let identityKey: String
    /// The liveness read has a beat from it.
    public let live: Bool
    /// It is in the liveness read at all.
    public let seen: Bool
    public let peerId: String?
    public let at: Double?
    public let ageMs: Double?

    /// `validatorStatus`.
    public static func of(_ identityKey: String, _ live: OpenExchangeLiveness?) -> OpenExchangeValidatorStatus {
        let key = identityKey.lowercased()
        guard let v = live?.validators.first(where: { $0.identityKey == key }) else {
            return OpenExchangeValidatorStatus(identityKey: identityKey, live: false, seen: false, peerId: nil, at: nil, ageMs: nil)
        }
        return OpenExchangeValidatorStatus(identityKey: identityKey, live: v.live, seen: true, peerId: v.peerId, at: v.at, ageMs: v.ageMs)
    }
}

// MARK: - The plan (market/plan.ts)

/// `SwapForm` (market/plan.ts): the swap form as typed.
public struct OpenExchangeSwapForm: Equatable, Sendable {
    public var direction: AMMDirection
    /// Sats on a buy, tokens in display units on a sell.
    public var amount: String
    public var slippageBps: String
    /// The most pools the order may draw on.
    public var maxSources: Int

    public init(direction: AMMDirection, amount: String, slippageBps: String, maxSources: Int) {
        self.direction = direction
        self.amount = amount
        self.slippageBps = slippageBps
        self.maxSources = maxSources
    }
}

/// `PlanInput` (market/plan.ts): the engine's request, or why the form makes none.
public enum OpenExchangePlanInput: Equatable, Sendable {
    case ok(AMMPlanRequest)
    case error(String)
}

/// `LegView` (market/plan.ts): one leg as the page shows it.
public struct OpenExchangeLegView: Equatable, Sendable {
    public let outpoint: String
    public let pool: AMMPoolState
    public let amountIn: BigInt
    public let amountOut: BigInt
    public let lpFee: BigInt
    public let validatorFee: BigInt
    /// In the input asset; 0 for a pool with none.
    public let commission: BigInt
    public let validator: OpenExchangeValidatorStatus
}

/// `PlanView` (market/plan.ts): a plan as the page shows it.
public struct OpenExchangePlanView: Equatable, Sendable {
    public let direction: AMMDirection
    public let legs: [OpenExchangeLegView]
    public let totalIn: BigInt
    public let totalOut: BigInt
    /// In the input asset (the fees and the commission come out of amountIn).
    public let lpFees: BigInt
    public let validatorFees: BigInt
    public let commissions: BigInt
    /// Sats per display token paid (buy) or received (sell), 8 places; "—" for none.
    public let effectivePrice: String
    /// The best pool's marginal price, the same unit.
    public let midPrice: String
    /// What the order would get at the mid price less what the plan gets, in bps of the former.
    public let slippageVsMidBps: BigInt
    /// The engine's absolute bound.
    public let minAmountOut: BigInt
    public let meetsSlippageBound: Bool
    public let filledCompletely: Bool
    /// amountIn the plan leaves unfilled.
    public let unfilled: BigInt
}

/// market/plan.ts and the client's quote (client.ts:499-528, 1038).
public enum OpenExchangeQuotes {
    /// `DEFAULT_FEE_RATE_SATS_PER_KB` (lib/config.ts:48).
    public static let defaultFeeRateSatsPerKb: Double = 100

    /// `legMinerFeeSats`: one leg's miner fee estimate, a swap of ~13 kB at `satsPerKb`, rounded
    /// up.
    public static func legMinerFeeSats(_ satsPerKb: Double) throws -> BigInt {
        try JS.bigInt((13 * satsPerKb).rounded(.up))
    }

    /// `livePools`: the pools whose validator is live in `live`; none without a read.
    public static func livePools(_ pools: [AMMPoolState], _ live: OpenExchangeLiveness?) -> [AMMPoolState] {
        guard let live else { return [] }
        return pools.filter { OpenExchangeValidatorStatus.of($0.validatorIdentityKey, live).live }
    }

    /// `withLastSeen` (market/view.ts): each pool with its validator's beat time as `lastSeen`;
    /// a pool whose validator is not in the read keeps its own.
    public static func withLastSeen(_ pools: [AMMPoolState], _ live: OpenExchangeLiveness?) -> [AMMPoolState] {
        pools.map { p in
            let key = p.validatorIdentityKey.lowercased()
            guard let v = live?.validators.first(where: { $0.identityKey == key }) else { return p }
            var out = p
            out.lastSeen = v.at
            return out
        }
    }

    /// `parseAmount` (lp/amounts.ts): a decimal in display units into base units: trimmed,
    /// underscores dropped, digits with at most `dec` places.
    public static func parseAmount(_ text: String, dec: Int = 0) throws -> BigInt {
        guard (0...18).contains(dec) else { throw OpenExchangeError.failed("decimals must be an integer 0-18") }
        let s = AMMTokenID.jsTrim(text).replacingOccurrences(of: "_", with: "")
        let bytes = Array(s.utf8)
        let isDigit = { (b: UInt8) in (0x30...0x39).contains(b) }
        let point = bytes.firstIndex(of: UInt8(ascii: "."))
        let wholeBytes = point.map { bytes[..<$0] } ?? bytes[...]
        let fracBytes = point.map { bytes[($0 + 1)...] } ?? []
        guard wholeBytes.allSatisfy(isDigit), fracBytes.allSatisfy(isDigit), !(wholeBytes.isEmpty && fracBytes.isEmpty) else {
            throw OpenExchangeError.failed("not an amount: \"\(text)\"")
        }
        if fracBytes.count > dec { throw OpenExchangeError.failed("at most \(dec) decimal place(s)") }
        let whole = wholeBytes.isEmpty ? "0" : String(decoding: wholeBytes, as: UTF8.self)
        let frac = String(decoding: fracBytes, as: UTF8.self)
        return try JS.bigInt(whole + frac + String(repeating: "0", count: dec - fracBytes.count))
    }

    /// `buildPlanRequest`: the form parsed against one token's pools, only the pools whose
    /// validator is live planned. `dec` scales a token amount (base units when nil).
    public static func buildPlanRequest(
        tokenId: String, form: OpenExchangeSwapForm, pools: [AMMPoolState], live: OpenExchangeLiveness?, dec: Int?,
        satsPerKb: Double = defaultFeeRateSatsPerKb
    ) throws -> OpenExchangePlanInput {
        if AMMTokenID.jsTrim(form.amount).isEmpty { return .error("enter an amount") }
        let amountIn: BigInt
        do {
            amountIn = try parseAmount(form.amount, dec: form.direction == .bsvToToken ? 0 : (dec ?? 0))
        } catch {
            return .error(OpenExchangeError.errorText(error))
        }
        if amountIn <= 0 { return .error("the amount must be positive") }
        let toleranceBps: BigInt
        do {
            let text = AMMTokenID.jsTrim(form.slippageBps)
            toleranceBps = try JS.bigInt(text.isEmpty ? "0" : text)
        } catch {
            return .error("slippage: whole basis points")
        }
        if toleranceBps < 0 || toleranceBps > 10000 { return .error("slippage: 0-10000 bps") }
        if pools.isEmpty { return .error("no pools for this token") }
        let usable = livePools(pools, live)
        if usable.isEmpty {
            guard let live else { return .error("no liveness read for this token: no pool can be planned") }
            return .error(live.kept
                ? "no pool's validator is live on this token"
                : "this instance keeps no liveness for this token (its market role is off for it): no validator is known live")
        }
        return .ok(AMMPlanRequest(
            tokenId: tokenId, direction: form.direction, amountIn: amountIn,
            slippage: AMMSlippageBound(toleranceBps: toleranceBps), maxSources: form.maxSources,
            fixedCost: AMMFixedCost(minerFeeSats: try legMinerFeeSats(satsPerKb)),
            inventory: withLastSeen(usable, live)
        ))
    }

    /// `planView`: the plan's legs with their pools and validators, the totals, the fees summed,
    /// the effective price and the best pool's marginal price, and the slippage against it.
    public static func planView(_ p: AMMPlan, inventory: [AMMPoolState], live: OpenExchangeLiveness?, dec: Int?) throws -> OpenExchangePlanView {
        var byOutpoint: [String: AMMPoolState] = [:]
        for x in inventory { byOutpoint[x.outpoint] = x }
        let legs = try p.legs.map { l -> OpenExchangeLegView in
            guard let pool = byOutpoint[l.outpoint] else {
                throw OpenExchangeError.failed("TypeError: the plan's pool \(l.outpoint) is not in the inventory")
            }
            return OpenExchangeLegView(
                outpoint: l.outpoint, pool: pool, amountIn: l.amountIn, amountOut: l.amountOut, lpFee: l.liquidityFee,
                validatorFee: l.validationFee, commission: l.commission,
                validator: .of(pool.validatorIdentityKey, live)
            )
        }
        func sum(_ f: (OpenExchangeLegView) -> BigInt) -> BigInt { legs.reduce(BigInt(0)) { $0 + f($1) } }
        let totalIn = sum(\.amountIn)
        let totalOut = sum(\.amountOut)
        let bsvToToken = p.direction == .bsvToToken

        // Mid: the best pool's marginal price (most output per unit in), before fees.
        var best: AMMPoolState?
        for x in inventory {
            guard let b = best else { best = x; continue }
            let better = bsvToToken
                ? x.tokenReserve * b.bsvReserve > b.tokenReserve * x.bsvReserve
                : x.bsvReserve * b.tokenReserve > b.bsvReserve * x.tokenReserve
            if better { best = x }
        }
        var midOut = BigInt(0)
        if let best, totalIn > 0 {
            midOut = bsvToToken
                ? try AMMPricing.divide(totalIn * best.tokenReserve, best.bsvReserve)
                : try AMMPricing.divide(totalIn * best.bsvReserve, best.tokenReserve)
        }
        let slippageVsMidBps = midOut > 0 ? ((midOut - totalOut) * 10000) / midOut : 0

        let lpFees = sum(\.lpFee)
        let validatorFees = sum(\.validatorFee)
        let commissions = sum(\.commission)
        let effectivePrice = bsvToToken
            ? try OpenExchangePrices.priceText(sats: totalIn, tokens: totalOut, dec: dec)
            : try OpenExchangePrices.priceText(sats: totalOut, tokens: totalIn, dec: dec)
        let midPrice = try best.map { try OpenExchangePrices.priceText(sats: $0.bsvReserve, tokens: $0.tokenReserve, dec: dec) } ?? "—"
        return OpenExchangePlanView(
            direction: p.direction, legs: legs, totalIn: totalIn, totalOut: totalOut, lpFees: lpFees,
            validatorFees: validatorFees, commissions: commissions, effectivePrice: effectivePrice, midPrice: midPrice,
            slippageVsMidBps: slippageVsMidBps, minAmountOut: p.resolvedMinAmountOut,
            meetsSlippageBound: p.meetsSlippageBound, filledCompletely: p.filledCompletely,
            unfilled: p.originalAmountIn - totalIn
        )
    }

    /// `quote` (market/plan.ts): the engine's plan and its view.
    public static func quote(_ request: AMMPlanRequest, live: OpenExchangeLiveness?, dec: Int?) throws -> (plan: AMMPlan, view: OpenExchangePlanView) {
        let p = try AMMPlanner.plan(request)
        return (p, try planView(p, inventory: request.inventory, live: live, dec: dec))
    }

    /// `goneFromLookup`: the plan's pools a fresh read no longer lists (spent since the plan).
    public static func goneFromLookup(_ planned: [AMMLeg], fresh: [AMMPoolState]) -> [String] {
        let listed = Set(fresh.map(\.outpoint))
        return planned.map(\.outpoint).filter { !listed.contains($0) }
    }

    /// `legCarrySats` (client.ts:525): a leg's sats beyond its amount in, the miner fee estimate
    /// plus its 1-sat carriers: on a buy the token payout; on a sell the token fee and commission
    /// outputs that are not zero, and the token change.
    public static func legCarrySats(_ leg: AMMLeg, buy: Bool, minerFeeSats: BigInt) -> BigInt {
        legCarrySats(liquidityFee: leg.liquidityFee, validationFee: leg.validationFee, commission: leg.commission, buy: buy, minerFeeSats: minerFeeSats)
    }

    /// `legCarrySats` of a leg's three fees.
    public static func legCarrySats(liquidityFee: BigInt, validationFee: BigInt, commission: BigInt, buy: Bool, minerFeeSats: BigInt) -> BigInt {
        let carriers = buy ? BigInt(1) : BigInt([liquidityFee, validationFee, commission].filter { $0 > 0 }.count + 1)
        return minerFeeSats + carriers
    }

    /// `quoteSwap` (client.ts:1038): an exact-in quote for one token over the pools the page
    /// holds (`held`, the token's pools route answer), each pool with its validator's minimum
    /// leg; no request. The price and the impact from the engine's price over the same pools
    /// (the buy side on a buy, the sell side on a sell); each leg's own fees; what a swap would
    /// stage (the amount, and the fee sats of exactly `maxSources` legs). `feeRateSatsPerKb` is
    /// the client's `feeRateSatsPerKb` (default 100).
    public static func quoteSwap(
        _ req: OpenExchangeQuoteRequest, held: OpenExchangePools?, sym: String, dec: Int,
        feeRateSatsPerKb: Double = defaultFeeRateSatsPerKb
    ) throws -> OpenExchangeQuote {
        if req.amountIn <= 0 { throw OpenExchangeError.failed("Enter an amount") }
        guard let held, !held.pools.isEmpty else { throw OpenExchangeError.failed("No pool to swap against") }
        let rows = OpenExchangePrices.poolsWithMinimums(held)
        let pools = rows.map(\.pool)
        let live = OpenExchangeLiveness.of(rows)
        let buy = req.side == .buy
        // `formatAmount(req.amountIn, buy ? 0 : dec)`, parsed back by the form: the same amount.
        let amountDec = buy ? 0 : dec
        guard (0...18).contains(amountDec) else { throw OpenExchangeError.failed("decimals must be an integer 0-18") }
        let form = OpenExchangeSwapForm(
            direction: buy ? .bsvToToken : .tokenToBsv,
            amount: try OpenExchangePrices.formatAmount(req.amountIn, dec: amountDec),
            slippageBps: String(req.maxSlippageBps), maxSources: req.maxSources
        )
        let request: AMMPlanRequest
        switch try buildPlanRequest(tokenId: req.tokenId, form: form, pools: pools, live: live, dec: dec, satsPerKb: feeRateSatsPerKb) {
        case .ok(let r): request = r
        case .error(let message): throw OpenExchangeError.failed(message)
        }
        let (plan, view) = try quote(request, live: live, dec: dec)
        if plan.unfillable == .min {
            let least = try OpenExchangePrices.formatAmount(plan.minAmountIn ?? 0, dec: amountDec)
            throw OpenExchangeError.belowMinimum("No pool here takes a swap this small: at least \(least) \(buy ? "sats" : sym).")
        }
        let used = view.legs.filter { $0.amountIn > 0 }
        if used.isEmpty || view.totalOut == 0 { throw OpenExchangeError.failed("The amount is too small to receive anything") }

        let price = try AMMPrice.of(pools)
        let marginal = price.map { OpenExchangePrices.pairPrice(buy ? $0.buy : $0.sell, dec: dec) } ?? 0
        let totalIn = used.reduce(BigInt(0)) { $0 + $1.amountIn }
        let sats = buy ? totalIn : view.totalOut
        let tokens = buy ? view.totalOut : totalIn
        let effective = JS.number(sats) / (JS.number(tokens) / JS.pow10(dec))
        let minerFee = try legMinerFeeSats(feeRateSatsPerKb)
        let carry = plan.legs.map { legCarrySats($0, buy: buy, minerFeeSats: minerFee) }
        // The fee sats for exactly maxSources legs: the planned legs' own, each further leg at the largest of theirs.
        let (spare, overflow) = req.maxSources.subtractingReportingOverflow(carry.count)
        let more = BigInt(overflow ? 0 : Swift.max(0, spare))
        let feeSats = carry.reduce(BigInt(0), +) + more * carry.reduce(BigInt(0)) { $1 > $0 ? $1 : $0 }

        // TS reads `poolId` off the planned leg's pool, which comes from the live pools only.
        var poolIds: [String: String] = [:]
        for row in rows where OpenExchangeValidatorStatus.of(row.pool.validatorIdentityKey, live).live {
            poolIds[row.pool.outpoint] = row.poolId
        }
        let legs = used.map { l in
            OpenExchangeQuoteLeg(
                poolOutpoint: OpenExchangePrices.outpointText(l.outpoint),
                poolId: poolIds[l.outpoint] ?? "",
                amountIn: l.amountIn,
                amountOut: l.amountOut,
                shareBps: Int((l.amountIn * 10_000) / req.amountIn),
                reserves: OpenExchangeReserves(sats: l.pool.bsvReserve, tokens: l.pool.tokenReserve),
                validator: .init(identityKey: l.pool.validatorIdentityKey, live: l.validator.live),
                fees: OpenExchangePrices.poolFees(l.pool),
                lpFee: l.lpFee,
                validatorFee: l.validatorFee,
                commission: l.commission
            )
        }
        let impact = marginal != 0 && !marginal.isNaN ? JS.round((abs(effective - marginal) / marginal) * 10_000) : 0
        return OpenExchangeQuote(
            request: req, legs: legs, amountOut: view.totalOut, minAmountOut: view.minAmountOut,
            effectivePrice: effective, marginalPrice: marginal, impactBps: impact,
            stage: OpenExchangeQuoteStage(amount: req.amountIn, feeSats: feeSats), legMinerFeeSats: minerFee,
            plan: plan, view: view
        )
    }
}

// MARK: - The quote (client.ts:177-238)

/// `QuoteRequest` (client.ts:179): an exact-in swap of one token.
public struct OpenExchangeQuoteRequest: Equatable, Sendable {
    /// `Side`: a buy pays sats for the token; a sell pays the token for sats.
    public enum Side: String, Equatable, Sendable {
        case buy
        case sell
    }

    public var tokenId: String
    public var side: Side
    /// Base units of what is paid: sats on a buy, token base units on a sell.
    public var amountIn: BigInt
    /// The most the amount out may fall under the quoted one, basis points (0–10000).
    public var maxSlippageBps: Int
    /// The most pools the swap may draw on, filled legs counted; 1: one leg for the whole amount.
    public var maxSources: Int

    public init(tokenId: String, side: Side, amountIn: BigInt, maxSlippageBps: Int, maxSources: Int) {
        self.tokenId = tokenId
        self.side = side
        self.amountIn = amountIn
        self.maxSlippageBps = maxSlippageBps
        self.maxSources = maxSources
    }
}

/// `QuoteLeg` (client.ts:194): one pool's leg of a quote.
public struct OpenExchangeQuoteLeg: Equatable, Sendable {
    /// `<txid>.<vout>`.
    public let poolOutpoint: String
    /// The pool's id, its deploy outpoint.
    public let poolId: String
    public let amountIn: BigInt
    public let amountOut: BigInt
    /// The leg's share of the amount in, basis points.
    public let shareBps: Int
    /// The pool's reserves before the leg.
    public let reserves: OpenExchangeReserves
    public let validator: OpenExchangePoolView.Validator
    /// The pool's own fee rates (`poolFees`).
    public let fees: OpenExchangeFees
    /// The leg's LP fee, validator fee and commission, in the input asset (the plan view's;
    /// not on the TS `QuoteLeg`).
    public let lpFee: BigInt
    public let validatorFee: BigInt
    public let commission: BigInt
}

/// `QuoteStage` (client.ts:211): what a swap stages before its first leg.
public struct OpenExchangeQuoteStage: Equatable, Sendable {
    /// The swap amount: sats on a buy, token base units on a sell.
    public let amount: BigInt
    /// The sats for the carriers and miner fees of `maxSources` legs.
    public let feeSats: BigInt
}

/// `Quote` (client.ts:218): an exact-in quote.
public struct OpenExchangeQuote: Equatable, Sendable {
    public let request: OpenExchangeQuoteRequest
    public let legs: [OpenExchangeQuoteLeg]
    /// What the route gives.
    public let amountOut: BigInt
    /// The least amount out the swap accepts: the route's amount out less the max slippage.
    public let minAmountOut: BigInt
    /// Sats per whole token this swap pays or gets, fees included.
    public let effectivePrice: Double
    /// Sats per whole token now: the engine's price over the held pools, its buy side on a buy,
    /// its sell side on a sell; 0 when there is none.
    public let marginalPrice: Double
    /// |effective − marginal| / marginal, basis points, rounded; 0 without a marginal price.
    public let impactBps: Double
    /// What a swap would stage. Not a ceiling on what it spends: when a leg's own miner fee
    /// comes out above the ~13 kB estimate in `feeSats`, `executeSwap` stages the shortfall in
    /// sats, up to `legMinerFeeSats` for each leg it attempts, so a swap can spend up to that much
    /// more sats than it stages here (`amount + feeSats` on a buy, `feeSats` on a sell), plus
    /// each top-up's own miner fee (about 20 sats): each is its own wallet transaction. A top-up
    /// reports `.staging` again, which can then come after `.relaying` (not in the TS).
    public let stage: OpenExchangeQuoteStage
    /// One leg's miner fee estimate, sats.
    public let legMinerFeeSats: BigInt
    /// The engine's plan the quote was made from (the TS client keeps it beside the quote).
    public let plan: AMMPlan
    /// The plan as the page shows it: the fees summed, the effective and mid prices.
    public let view: OpenExchangePlanView
}
