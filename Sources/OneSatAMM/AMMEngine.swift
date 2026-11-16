import BigInt

// A port of `@dcasegr/amm-engine` 0.55.1 (skein-amm cc146be, web/engine/src): the pool
// contract's exact swap arithmetic (pricing.ts), the split of an order across pools
// (allocation.ts), and the price (price.ts). Every amount is a `BigInt` where the TS has a
// `bigint`; the split's heuristic is `Double` where the TS has a `number`, with the same
// operations in the same order, so a split is the one TS plans.

/// `Direction` (types.ts): which asset is sold; the taker receives the other.
public enum AMMDirection: String, Sendable, Equatable {
    case bsvToToken
    case tokenToBsv
}

/// `PoolState` (types.ts): one pool UTXO as the exchange lists it.
public struct AMMPoolState: Equatable, Sendable {
    /// The pool UTXO's outpoint, as the pools route writes it.
    public var outpoint: String
    public var bsvReserve: BigInt
    public var tokenReserve: BigInt
    /// LP fee rate, basis points of amountIn (ceil).
    public var liquidityFeeBps: BigInt
    /// Validator fee rate, basis points of amountIn (ceil).
    public var validationFeeBps: BigInt
    /// The contract's CommissionBps, basis points of amountIn (ceil), paid to the relay.
    public var commissionBps: BigInt
    /// The pool's validator identity key; opaque to the engine.
    public var validatorIdentityKey: String
    /// When the validator was last seen live, ms.
    public var lastSeen: Double?
    /// The validator's minimum leg in sats, on the leg's sats side; nil or 0 is none.
    public var minLegSats: BigInt?

    public init(
        outpoint: String, bsvReserve: BigInt, tokenReserve: BigInt, liquidityFeeBps: BigInt,
        validationFeeBps: BigInt, commissionBps: BigInt, validatorIdentityKey: String,
        lastSeen: Double? = nil, minLegSats: BigInt? = nil
    ) {
        self.outpoint = outpoint
        self.bsvReserve = bsvReserve
        self.tokenReserve = tokenReserve
        self.liquidityFeeBps = liquidityFeeBps
        self.validationFeeBps = validationFeeBps
        self.commissionBps = commissionBps
        self.validatorIdentityKey = validatorIdentityKey
        self.lastSeen = lastSeen
        self.minLegSats = minLegSats
    }
}

/// `FixedCost` (types.ts): what one more leg costs the taker, sats.
public struct AMMFixedCost: Equatable, Sendable {
    public var minerFeeSats: BigInt
    public init(minerFeeSats: BigInt) { self.minerFeeSats = minerFeeSats }
}

/// `Leg` (types.ts): one pool's share of an order, with the pool's state after it.
public struct AMMLeg: Equatable, Sendable {
    public let outpoint: String
    public let amountIn: BigInt
    public let liquidityFee: BigInt
    public let validationFee: BigInt
    /// In the input asset.
    public let commission: BigInt
    public let amountOut: BigInt
    public let newBsvReserve: BigInt
    public let newTokenReserve: BigInt
}

/// `SwapResult` (pricing.ts): one swap as the contract computes it.
public struct AMMSwapResult: Equatable, Sendable {
    public let liquidityFee: BigInt
    public let validationFee: BigInt
    public let commission: BigInt
    public let net: BigInt
    public let amountOut: BigInt
    public let newBsvReserve: BigInt
    public let newTokenReserve: BigInt
}

/// Where JS would throw on an engine input: a division by zero (`RangeError: Division by zero`,
/// reserves that cancel the net) or a split share that is not a number (`RangeError` of
/// `BigInt(NaN)`, every pool with no price).
public struct AMMEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
}

/// pricing.ts: the contract's Swap arithmetic, bit for bit (pool/Pool.runar.go).
public enum AMMPricing {
    /// `feeAmount`: ceil(amountIn × bps / 10000).
    public static func feeAmount(_ amountIn: BigInt, _ bps: BigInt) -> BigInt {
        (amountIn * bps + 9999) / 10000
    }

    /// `computeSwap`: the swap as the contract computes it, or nil where its assertions
    /// (`net > 0`, `out > 0`) fail.
    public static func computeSwap(_ pool: AMMPoolState, _ direction: AMMDirection, _ amountIn: BigInt) throws -> AMMSwapResult? {
        if amountIn <= 0 { return nil }
        let liquidityFee = feeAmount(amountIn, pool.liquidityFeeBps)
        let validationFee = feeAmount(amountIn, pool.validationFeeBps)
        let commission = feeAmount(amountIn, pool.commissionBps)
        let net = amountIn - liquidityFee - validationFee - commission
        if net <= 0 { return nil }

        let amountOut: BigInt
        let newBsvReserve: BigInt
        let newTokenReserve: BigInt
        switch direction {
        case .tokenToBsv:
            amountOut = try divide(net * pool.bsvReserve, pool.tokenReserve + net)
            newBsvReserve = pool.bsvReserve - amountOut
            newTokenReserve = pool.tokenReserve + net
        case .bsvToToken:
            amountOut = try divide(net * pool.tokenReserve, pool.bsvReserve + net)
            newBsvReserve = pool.bsvReserve + net
            newTokenReserve = pool.tokenReserve - amountOut
        }
        if amountOut <= 0 { return nil }
        return AMMSwapResult(
            liquidityFee: liquidityFee, validationFee: validationFee, commission: commission, net: net,
            amountOut: amountOut, newBsvReserve: newBsvReserve, newTokenReserve: newTokenReserve
        )
    }

    /// `legSats`: a leg's sats side, amountIn on a buy, amountOut on a sell.
    public static func legSats(_ direction: AMMDirection, _ amountIn: BigInt, _ amountOut: BigInt) -> BigInt {
        direction == .bsvToToken ? amountIn : amountOut
    }

    /// `underMinimum`: a leg's sats side under its pool's minimum (nil or 0 is none).
    public static func underMinimum(_ pool: AMMPoolState, _ direction: AMMDirection, _ amountIn: BigInt, _ amountOut: BigInt) -> Bool {
        legSats(direction, amountIn, amountOut) < (pool.minLegSats ?? 0)
    }

    /// `acceptedSwap`: `computeSwap`, or nil where the contract refuses it or it is under the
    /// pool's minimum.
    public static func acceptedSwap(_ pool: AMMPoolState, _ direction: AMMDirection, _ amountIn: BigInt) throws -> AMMSwapResult? {
        guard let result = try computeSwap(pool, direction, amountIn),
              !underMinimum(pool, direction, amountIn, result.amountOut) else { return nil }
        return result
    }

    /// `smallestAccepted`: the smallest amountIn the pool accepts, by doubling then bisection;
    /// nil when none up to 2^128.
    public static func smallestAccepted(_ pool: AMMPoolState, _ direction: AMMDirection) throws -> BigInt? {
        let cap = BigInt(1) << 128
        var hi = BigInt(1)
        while try acceptedSwap(pool, direction, hi) == nil {
            if hi >= cap { return nil }
            hi *= 2
        }
        var lo = hi / 2
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if try acceptedSwap(pool, direction, mid) == nil { lo = mid } else { hi = mid }
        }
        return hi
    }

    /// JS bigint `/`: truncation toward zero, a `RangeError` by zero.
    static func divide(_ a: BigInt, _ b: BigInt) throws -> BigInt {
        guard b != 0 else { throw AMMEngineError(description: "RangeError: Division by zero") }
        return a / b
    }
}

/// allocation.ts: the water-filling split of an order across constant-product pools.
public enum AMMAllocation {
    /// `planSplit`: `amountIn` split across `pools` (one token's, live, distinct outpoints),
    /// adding pools by spot price while the next one's gain beats its fixed cost, the marginal
    /// price equalised, rounded to exact contract-valid legs; no leg under its pool's minimum
    /// (such pools set aside and the split planned again). Legs sorted by outpoint.
    public static func planSplit(
        _ pools: [AMMPoolState], _ direction: AMMDirection, _ amountIn: BigInt, _ fixedCost: AMMFixedCost,
        maxSources: Int? = nil
    ) throws -> [AMMLeg] {
        var candidates = pools
        while true {
            let (legs, underMin) = try splitOnce(candidates, direction, amountIn, fixedCost, maxSources)
            if underMin.isEmpty { return legs }
            candidates = candidates.filter { !underMin.contains($0.outpoint) }
        }
    }

    /// `quoteMid`: the total amountOut of the split with no per-leg cost; 0 with no pool.
    public static func quoteMid(_ pools: [AMMPoolState], _ direction: AMMDirection, _ amountIn: BigInt) throws -> BigInt {
        if pools.isEmpty || amountIn <= 0 { return 0 }
        let legs = try planSplit(pools, direction, amountIn, AMMFixedCost(minerFeeSats: 0))
        return legs.reduce(BigInt(0)) { $0 + $1.amountOut }
    }

    struct PoolMath {
        let pool: AMMPoolState
        let inputReserve: Double
        let outputReserve: Double
        let k: Double
        let m: Double
        let spotPrice: Double
    }

    static func poolMath(_ pool: AMMPoolState, _ direction: AMMDirection) -> PoolMath {
        let bsv = JS.number(pool.bsvReserve)
        let tok = JS.number(pool.tokenReserve)
        let inputReserve = direction == .tokenToBsv ? tok : bsv
        let outputReserve = direction == .tokenToBsv ? bsv : tok
        let feeBps = JS.number(pool.liquidityFeeBps) + JS.number(pool.validationFeeBps) + JS.number(pool.commissionBps)
        let m = jsMax(0, (10000 - feeBps) / 10000)
        let k = inputReserve * outputReserve
        let spotPrice = inputReserve > 0 ? (m * outputReserve) / inputReserve : 0
        return PoolMath(pool: pool, inputReserve: inputReserve, outputReserve: outputReserve, k: k, m: m, spotPrice: spotPrice)
    }

    static func netAt(_ pm: PoolMath, _ shadowPrice: Double) -> Double {
        if shadowPrice <= 0 || pm.k <= 0 || pm.m <= 0 || !shadowPrice.isFinite { return .infinity }
        let net = ((pm.m * pm.k) / shadowPrice).squareRoot() - pm.inputReserve
        return net > 0 ? net : 0
    }

    static func amountInAt(_ pm: PoolMath, _ shadowPrice: Double) -> Double {
        if pm.m <= 0 { return 0 }
        return netAt(pm, shadowPrice) / pm.m
    }

    static func totalAmountInAt(_ pms: [PoolMath], _ shadowPrice: Double) -> Double {
        var sum = 0.0
        for pm in pms { sum += amountInAt(pm, shadowPrice) }
        return sum
    }

    static func outputAt(_ pm: PoolMath, _ net: Double) -> Double {
        if net <= 0 { return 0 }
        return (net * pm.outputReserve) / (pm.inputReserve + net)
    }

    static func solveShadowPrice(_ pms: [PoolMath], _ target: Double) -> Double {
        if pms.isEmpty || target <= 0 { return .infinity }
        let maxSpot = pms.dropFirst().reduce(pms[0].spotPrice) { jsMax($0, $1.spotPrice) }
        if !maxSpot.isFinite || maxSpot <= 0 { return .infinity }
        var hi = maxSpot
        var lo = maxSpot / 2
        var guardCount = 0
        while totalAmountInAt(pms, lo) < target && guardCount < 400 {
            lo = lo / 2
            guardCount += 1
            if lo < Double.ulpOfOne { break }
        }
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if totalAmountInAt(pms, mid) > target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    static func totalOutputForTarget(_ pms: [PoolMath], _ target: Double) -> Double {
        if target <= 0 || pms.isEmpty { return 0 }
        let price = solveShadowPrice(pms, target)
        var out = 0.0
        for pm in pms { out += outputAt(pm, netAt(pm, price)) }
        return out
    }

    static func fixedCostInOutputUnits(_ pm: PoolMath, _ direction: AMMDirection, _ fixedCost: AMMFixedCost) -> Double {
        let sats = JS.number(fixedCost.minerFeeSats)
        if direction == .tokenToBsv { return sats }
        let bsv = JS.number(pm.pool.bsvReserve)
        let tok = JS.number(pm.pool.tokenReserve)
        if bsv <= 0 { return .infinity }
        return sats * (tok / bsv)
    }

    static func roundAllocation(_ pms: [PoolMath], _ floatShares: [Double], _ target: BigInt) throws -> [BigInt] {
        let totalFloat = floatShares.reduce(0, +)
        if totalFloat <= 0 || target <= 0 { return pms.map { _ in 0 } }
        let targetNum = JS.number(target)
        let scaled = floatShares.map { ($0 / totalFloat) * targetNum }
        let floors = try scaled.map { s -> BigInt in
            let value = jsMax(0, s.rounded(.down))
            guard !value.isNaN else {
                throw AMMEngineError(description: "RangeError: The number NaN cannot be converted to a BigInt because it is not an integer")
            }
            return try JS.bigInt(value)
        }
        let used = floors.reduce(BigInt(0), +)
        var remainder = target - used

        let order = scaled.enumerated()
            .map { (i: $0.offset, frac: $0.element - $0.element.rounded(.down), outpoint: pms[$0.offset].pool.outpoint) }
            .sorted { a, b in
                let byFrac = b.frac - a.frac
                if byFrac != 0 && !byFrac.isNaN { return byFrac < 0 }
                return JS.less(a.outpoint, b.outpoint)
            }

        var result = floors
        var idx = 0
        while remainder > 0 && idx < order.count {
            result[order[idx].i] += 1
            remainder -= 1
            idx += 1
        }
        if remainder > 0 && !result.isEmpty {
            result[0] += remainder
        }
        return result
    }

    static func splitOnce(
        _ pools: [AMMPoolState], _ direction: AMMDirection, _ amountIn: BigInt, _ fixedCost: AMMFixedCost, _ maxSources: Int?
    ) throws -> (legs: [AMMLeg], underMin: Set<String>) {
        var underMin: Set<String> = []
        if pools.isEmpty || amountIn <= 0 { return ([], underMin) }

        let sorted = pools.map { poolMath($0, direction) }.sorted { a, b in
            let bySpot = b.spotPrice - a.spotPrice
            if bySpot != 0 && !bySpot.isNaN { return bySpot < 0 }
            return JS.less(a.pool.outpoint, b.pool.outpoint)
        }

        let targetNum = JS.number(amountIn)
        var bestN = 1
        var prevOut = totalOutputForTarget(Array(sorted.prefix(1)), targetNum)
        let cap = maxSources.map { min(sorted.count, $0) } ?? sorted.count
        if cap >= 2 {
            for n in 2...cap {
                let out = totalOutputForTarget(Array(sorted.prefix(n)), targetNum)
                let gain = out - prevOut
                let cost = fixedCostInOutputUnits(sorted[n - 1], direction, fixedCost)
                if gain > cost {
                    bestN = n
                    prevOut = out
                } else {
                    break
                }
            }
        }

        let active = Array(sorted.prefix(bestN))
        let price = solveShadowPrice(active, targetNum)
        let shares = active.map { amountInAt($0, price) }
        var allocation = try roundAllocation(active, shares, amountIn)

        // Fold a share the contract refuses, or under its pool's minimum, into the largest other.
        for _ in 0..<active.count {
            var changed = false
            for i in 0..<active.count {
                let amt = allocation[i]
                if amt <= 0 { continue }
                if try AMMPricing.acceptedSwap(active[i].pool, direction, amt) == nil {
                    var bestJ = -1
                    for j in 0..<active.count where j != i {
                        if bestJ == -1 || allocation[j] > allocation[bestJ]
                            || (allocation[j] == allocation[bestJ] && JS.less(active[j].pool.outpoint, active[bestJ].pool.outpoint)) {
                            bestJ = j
                        }
                    }
                    if bestJ == -1 { break }
                    allocation[bestJ] += amt
                    allocation[i] = 0
                    changed = true
                }
            }
            if !changed { break }
        }

        var legs: [AMMLeg] = []
        for i in 0..<active.count {
            let amt = allocation[i]
            if amt <= 0 { continue }
            let pm = active[i]
            guard let result = try AMMPricing.acceptedSwap(pm.pool, direction, amt) else {
                if try AMMPricing.computeSwap(pm.pool, direction, amt) != nil { underMin.insert(pm.pool.outpoint) }
                continue
            }
            legs.append(AMMLeg(
                outpoint: pm.pool.outpoint, amountIn: amt, liquidityFee: result.liquidityFee,
                validationFee: result.validationFee, commission: result.commission, amountOut: result.amountOut,
                newBsvReserve: result.newBsvReserve, newTokenReserve: result.newTokenReserve
            ))
        }
        legs.sort { JS.less($0.outpoint, $1.outpoint) }
        return (legs, underMin)
    }

    /// `Math.max(a, b)`: NaN when either is.
    static func jsMax(_ a: Double, _ b: Double) -> Double {
        if a.isNaN || b.isNaN { return .nan }
        return a > b ? a : (b > a ? b : (a == 0 && b == 0 ? (a.sign == .plus ? a : b) : a))
    }
}

/// `PricePair` (price.ts) and the overlay's `Price` (lib/overlay.ts): an exact price, `sats`
/// satoshis per `tokens` token base units.
public struct AMMPricePair: Equatable, Sendable {
    public let sats: BigInt
    public let tokens: BigInt
    public init(sats: BigInt, tokens: BigInt) {
        self.sats = sats
        self.tokens = tokens
    }
}

/// `Price` (price.ts): what the next trade would pay.
public struct AMMPrice: Equatable, Sendable {
    /// What a buy of the reference sats would pay now.
    public let buy: AMMPricePair
    /// What a sell of the reference tokens would pay now.
    public let sell: AMMPricePair
    /// The exact midpoint of buy and sell.
    public let mid: AMMPricePair

    /// `PRICE_SHARE_BPS`: the reference size, this share of the pooled reserves, bps.
    public static let shareBps: BigInt = 100

    /// `priceOf`: the price a buy of `shareBps` of the pooled sats and a sell of `shareBps` of
    /// the pooled tokens would pay, split across `pools` with no per-leg cost and no minimums.
    /// Nil with no pool, or when a side has no leg. The host's stats `price` is this over the
    /// listed pools.
    public static func of(_ pools: [AMMPoolState], shareBps: BigInt = AMMPrice.shareBps) throws -> AMMPrice? {
        if pools.isEmpty { return nil }
        let free = withoutMinimums(pools)
        let bsv = free.reduce(BigInt(0)) { $0 + $1.bsvReserve }
        let tok = free.reduce(BigInt(0)) { $0 + $1.tokenReserve }
        let refSats = Swift.max(BigInt(1), (bsv * shareBps) / 10000)
        let refTokens = Swift.max(BigInt(1), (tok * shareBps) / 10000)

        let noCost = AMMFixedCost(minerFeeSats: 0)
        let buyLegs = try AMMAllocation.planSplit(free, .bsvToToken, refSats, noCost)
        let sellLegs = try AMMAllocation.planSplit(free, .tokenToBsv, refTokens, noCost)
        if buyLegs.isEmpty || sellLegs.isEmpty { return nil }

        let buy = AMMPricePair(
            sats: buyLegs.reduce(BigInt(0)) { $0 + $1.amountIn },
            tokens: buyLegs.reduce(BigInt(0)) { $0 + $1.amountOut }
        )
        let sell = AMMPricePair(
            sats: sellLegs.reduce(BigInt(0)) { $0 + $1.amountOut },
            tokens: sellLegs.reduce(BigInt(0)) { $0 + $1.amountIn }
        )
        let mid = AMMPricePair(
            sats: buy.sats * sell.tokens + sell.sats * buy.tokens,
            tokens: 2 * buy.tokens * sell.tokens
        )
        return AMMPrice(buy: buy, sell: sell, mid: mid)
    }

    /// `withoutMinimums` (planner.ts): the pools with their minimum leg sizes removed.
    public static func withoutMinimums(_ pools: [AMMPoolState]) -> [AMMPoolState] {
        pools.map { var p = $0; p.minLegSats = nil; return p }
    }
}
