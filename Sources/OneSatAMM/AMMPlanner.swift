import BigInt

// A port of `@dcasegr/amm-engine` 0.55.1 (skein-amm cc146be, web/engine/src): the planner
// (planner.ts), the next leg of an order run one leg at a time (nextLeg.ts) and the replan of a
// remainder after a round (replanner.ts), over the split and the pricing of AMMEngine.swift.
// Pure and deterministic: the engine never reads the clock (the caller gives `now`), ties are
// broken by outpoint (JS string order).

/// `SlippageBound` (types.ts): a bound on the order's total amountOut. With both, the stricter
/// (larger) wins.
public struct AMMSlippageBound: Equatable, Sendable {
    /// The least total amountOut, in the output asset's base units.
    public var minAmountOut: BigInt?
    /// Basis points under the plan's own total amountOut (the split with the per-leg cost).
    public var toleranceBps: BigInt?

    public init(minAmountOut: BigInt? = nil, toleranceBps: BigInt? = nil) {
        self.minAmountOut = minAmountOut
        self.toleranceBps = toleranceBps
    }
}

/// `PlanRequest` (types.ts): an order against one token's pools.
public struct AMMPlanRequest: Equatable, Sendable {
    public var tokenId: String
    public var direction: AMMDirection
    public var amountIn: BigInt
    public var slippage: AMMSlippageBound
    /// The most pools the order may draw on; 1 is the best single pool for the whole amount.
    public var maxSources: Int
    public var fixedCost: AMMFixedCost
    /// The token's pools.
    public var inventory: [AMMPoolState]
    /// Pools whose validator was last seen more than this many ms before `now` are left out.
    public var livenessThreshold: Double?
    /// The caller's clock, ms; the filter applies only with both.
    public var now: Double?

    public init(
        tokenId: String, direction: AMMDirection, amountIn: BigInt, slippage: AMMSlippageBound, maxSources: Int,
        fixedCost: AMMFixedCost, inventory: [AMMPoolState], livenessThreshold: Double? = nil, now: Double? = nil
    ) {
        self.tokenId = tokenId
        self.direction = direction
        self.amountIn = amountIn
        self.slippage = slippage
        self.maxSources = maxSources
        self.fixedCost = fixedCost
        self.inventory = inventory
        self.livenessThreshold = livenessThreshold
        self.now = now
    }
}

/// `Plan.unfillable` (types.ts): why a plan has no leg.
public enum AMMUnfillable: String, Equatable, Sendable {
    /// The pools' minimum leg sizes leave no leg; without them there would be one.
    case min
}

/// `Plan` (types.ts): one round of legs, with the bookkeeping `replan` carries across rounds.
public struct AMMPlan: Equatable, Sendable {
    /// The legs of this round.
    public var legs: [AMMLeg]
    /// This round's legs' amountIn summed.
    public var totalAmountIn: BigInt
    /// This round's legs' amountOut summed (expected).
    public var totalAmountOut: BigInt
    /// What has filled plus this round's amountOut meets `resolvedMinAmountOut`.
    public var meetsSlippageBound: Bool
    /// This round covers the whole order still open.
    public var filledCompletely: Bool
    /// Set when the minimums leave no leg; `minAmountIn` is then the smallest amountIn one pool
    /// accepts, when one accepts any.
    public var unfillable: AMMUnfillable?
    public var minAmountIn: BigInt?

    public var direction: AMMDirection
    public var maxSources: Int
    public var fixedCost: AMMFixedCost
    public var livenessThreshold: Double?
    public var now: Double?
    /// The whole order, the same in every round.
    public var originalAmountIn: BigInt
    /// The order's absolute bound, resolved once by `plan`.
    public var resolvedMinAmountOut: BigInt
    /// amountIn filled in earlier rounds.
    public var cumulativeFilledAmountIn: BigInt
    /// amountOut received in earlier rounds.
    public var cumulativeFilledAmountOut: BigInt
    /// The candidates this round's legs do not use.
    public var remainingInventory: [AMMPoolState]

    public init(
        legs: [AMMLeg], totalAmountIn: BigInt, totalAmountOut: BigInt, meetsSlippageBound: Bool, filledCompletely: Bool,
        unfillable: AMMUnfillable? = nil, minAmountIn: BigInt? = nil, direction: AMMDirection, maxSources: Int,
        fixedCost: AMMFixedCost, livenessThreshold: Double? = nil, now: Double? = nil, originalAmountIn: BigInt,
        resolvedMinAmountOut: BigInt, cumulativeFilledAmountIn: BigInt, cumulativeFilledAmountOut: BigInt,
        remainingInventory: [AMMPoolState]
    ) {
        self.legs = legs
        self.totalAmountIn = totalAmountIn
        self.totalAmountOut = totalAmountOut
        self.meetsSlippageBound = meetsSlippageBound
        self.filledCompletely = filledCompletely
        self.unfillable = unfillable
        self.minAmountIn = minAmountIn
        self.direction = direction
        self.maxSources = maxSources
        self.fixedCost = fixedCost
        self.livenessThreshold = livenessThreshold
        self.now = now
        self.originalAmountIn = originalAmountIn
        self.resolvedMinAmountOut = resolvedMinAmountOut
        self.cumulativeFilledAmountIn = cumulativeFilledAmountIn
        self.cumulativeFilledAmountOut = cumulativeFilledAmountOut
        self.remainingInventory = remainingInventory
    }
}

/// `LegResult` (types.ts): what became of one leg of a round.
public enum AMMLegResult: Equatable, Sendable {
    /// Filled: counted, its pool spent.
    case filled(outpoint: String)
    /// Refused; with the pool's new state it stays a candidate, re-priced.
    case rejected(outpoint: String, newPoolState: AMMPoolState?)
    /// No answer: the pool's state is not known.
    case unknown(outpoint: String)

    public var outpoint: String {
        switch self {
        case .filled(let outpoint), .rejected(let outpoint, _), .unknown(let outpoint): outpoint
        }
    }
}

/// `NextLegRequest` (nextLeg.ts).
public struct AMMNextLegRequest: Equatable, Sendable {
    public var pools: [AMMPoolState]
    public var direction: AMMDirection
    /// The order's amountIn not yet filled.
    public var remaining: BigInt
    public var fixedCost: AMMFixedCost
    /// The least total amountOut the remainder must still bring.
    public var minOut: BigInt
    /// The legs the order may still fill; 1: one leg takes all of `remaining`.
    public var maxSources: Int

    public init(pools: [AMMPoolState], direction: AMMDirection, remaining: BigInt, fixedCost: AMMFixedCost, minOut: BigInt, maxSources: Int) {
        self.pools = pools
        self.direction = direction
        self.remaining = remaining
        self.fixedCost = fixedCost
        self.minOut = minOut
        self.maxSources = maxSources
    }
}

/// `NextLegResult` (nextLeg.ts).
public enum AMMNextLegResult: Equatable, Sendable {
    /// The leg to run, and the plan's total amountOut.
    case leg(AMMLeg, projectedOut: BigInt)
    case stop(AMMNextLegStop)
}

/// Why `nextLeg` stops.
public enum AMMNextLegStop: String, Equatable, Sendable {
    /// Nothing remains.
    case filled
    /// The plan's total amountOut is under `minOut`.
    case floor
    /// Only the pools' minimums leave no leg.
    case min
    /// No pool takes any of it.
    case noPool = "no_pool"
}

/// planner.ts, nextLeg.ts and replanner.ts.
public enum AMMPlanner {
    /// `filterLivePools`: the pools whose validator was seen within `livenessThreshold` of
    /// `now`; every pool when either is nil, none without a `lastSeen` otherwise.
    public static func filterLivePools(_ inventory: [AMMPoolState], livenessThreshold: Double?, now: Double?) -> [AMMPoolState] {
        guard let livenessThreshold, let now else { return inventory }
        return inventory.filter { p in
            guard let lastSeen = p.lastSeen else { return false }
            return now - lastSeen <= livenessThreshold
        }
    }

    /// `resolveMinAmountOut`: the absolute bound, the larger of `minAmountOut` and
    /// `totalAmountOut × (10000 − toleranceBps) / 10000`; 0 for none.
    public static func resolveMinAmountOut(_ totalAmountOut: BigInt, _ slippage: AMMSlippageBound) -> BigInt {
        var bound = BigInt(0)
        if let min = slippage.minAmountOut, min > bound { bound = min }
        if let tolerance = slippage.toleranceBps {
            let tolerant = (totalAmountOut * (10000 - tolerance)) / 10000
            if tolerant > bound { bound = tolerant }
        }
        return bound
    }

    /// `pickBestSingleLeg`: the pool that gives the most for all of `amountIn` (tie: the smaller
    /// outpoint), at or above `minAmountOut` when that is above 0; nil when none.
    public static func pickBestSingleLeg(
        _ pools: [AMMPoolState], _ direction: AMMDirection, _ amountIn: BigInt, minAmountOut: BigInt
    ) throws -> AMMLeg? {
        var best: AMMLeg?
        for pool in pools {
            guard let result = try AMMPricing.acceptedSwap(pool, direction, amountIn) else { continue }
            if minAmountOut > 0 && result.amountOut < minAmountOut { continue }
            let leg = AMMLeg(
                outpoint: pool.outpoint, amountIn: amountIn, liquidityFee: result.liquidityFee,
                validationFee: result.validationFee, commission: result.commission, amountOut: result.amountOut,
                newBsvReserve: result.newBsvReserve, newTokenReserve: result.newTokenReserve
            )
            if let current = best {
                if leg.amountOut > current.amountOut || (leg.amountOut == current.amountOut && JS.less(leg.outpoint, current.outpoint)) {
                    best = leg
                }
            } else {
                best = leg
            }
        }
        return best
    }

    /// `planOrder`: `amountIn` against `pools`: with `maxSources` 1 the best single pool,
    /// otherwise the split (`planSplit`, at most `maxSources` pools). Empty for no amount or no
    /// pool.
    public static func planOrder(
        _ pools: [AMMPoolState], _ direction: AMMDirection, _ amountIn: BigInt, maxSources: Int,
        fixedCost: AMMFixedCost, minAmountOut: BigInt
    ) throws -> [AMMLeg] {
        if amountIn <= 0 || pools.isEmpty { return [] }
        if maxSources == 1 {
            return try pickBestSingleLeg(pools, direction, amountIn, minAmountOut: minAmountOut).map { [$0] } ?? []
        }
        return try AMMAllocation.planSplit(pools, direction, amountIn, fixedCost, maxSources: maxSources)
    }

    /// `minAmountInOf`: the smallest amountIn one of `pools` accepts, nil when none accepts any.
    public static func minAmountInOf(_ pools: [AMMPoolState], _ direction: AMMDirection) throws -> BigInt? {
        var min: BigInt?
        for pool in pools {
            if let a = try AMMPricing.smallestAccepted(pool, direction), min.map({ a < $0 }) ?? true { min = a }
        }
        return min
    }

    /// `plan`: a fresh order against its inventory (live pools only when the request filters).
    /// The bound is resolved here, against this plan's own total.
    public static func plan(_ request: AMMPlanRequest) throws -> AMMPlan {
        let eligible = filterLivePools(request.inventory, livenessThreshold: request.livenessThreshold, now: request.now)
        let explicitMin = request.slippage.minAmountOut ?? 0

        let legs = try planOrder(
            eligible, request.direction, request.amountIn, maxSources: request.maxSources,
            fixedCost: request.fixedCost, minAmountOut: explicitMin
        )
        let totalAmountIn = legs.reduce(BigInt(0)) { $0 + $1.amountIn }
        let totalAmountOut = legs.reduce(BigInt(0)) { $0 + $1.amountOut }
        let resolvedMinAmountOut = resolveMinAmountOut(totalAmountOut, request.slippage)
        let used = Set(legs.map(\.outpoint))

        var result = AMMPlan(
            legs: legs, totalAmountIn: totalAmountIn, totalAmountOut: totalAmountOut,
            meetsSlippageBound: totalAmountOut >= resolvedMinAmountOut,
            filledCompletely: totalAmountIn == request.amountIn,
            direction: request.direction, maxSources: request.maxSources, fixedCost: request.fixedCost,
            livenessThreshold: request.livenessThreshold, now: request.now, originalAmountIn: request.amountIn,
            resolvedMinAmountOut: resolvedMinAmountOut, cumulativeFilledAmountIn: 0, cumulativeFilledAmountOut: 0,
            remainingInventory: eligible.filter { !used.contains($0.outpoint) }
        )

        // No legs because of the minimums: the same order without them has legs.
        if legs.isEmpty, try !planOrder(
            AMMPrice.withoutMinimums(eligible), request.direction, request.amountIn, maxSources: request.maxSources,
            fixedCost: request.fixedCost, minAmountOut: explicitMin
        ).isEmpty {
            result.unfillable = .min
            result.minAmountIn = try minAmountInOf(eligible, request.direction)
        }
        return result
    }

    /// `replan`: the remainder of an order after a round. A filled leg counts and its pool is
    /// gone; a refusal with the pool's new state keeps that pool, re-priced; any other result
    /// (or none) drops the pool. The bound stays the whole order's: each round covers what the
    /// filled legs have not delivered. No legs once the order is filled or nothing is left.
    public static func replan(_ plan: AMMPlan, _ results: [AMMLegResult]) throws -> AMMPlan {
        var resultByOutpoint: [String: AMMLegResult] = [:]
        for r in results { resultByOutpoint[r.outpoint] = r }

        var filledIn = BigInt(0)
        var filledOut = BigInt(0)
        var repriced: [AMMPoolState] = []
        for leg in plan.legs {
            switch resultByOutpoint[leg.outpoint] {
            case .filled?:
                filledIn += leg.amountIn
                filledOut += leg.amountOut
            case .rejected(_, let state?)?:
                repriced.append(state)
            default:
                break
            }
        }

        let nextInventory = plan.remainingInventory + repriced
        let cumulativeFilledAmountIn = plan.cumulativeFilledAmountIn + filledIn
        let cumulativeFilledAmountOut = plan.cumulativeFilledAmountOut + filledOut
        let remainder = plan.originalAmountIn - cumulativeFilledAmountIn
        let remainingMinAmountOut = plan.resolvedMinAmountOut > cumulativeFilledAmountOut
            ? plan.resolvedMinAmountOut - cumulativeFilledAmountOut
            : 0

        func round(_ legs: [AMMLeg], _ totalIn: BigInt, _ totalOut: BigInt, meets: Bool, filled: Bool, inventory: [AMMPoolState]) -> AMMPlan {
            AMMPlan(
                legs: legs, totalAmountIn: totalIn, totalAmountOut: totalOut, meetsSlippageBound: meets,
                filledCompletely: filled, direction: plan.direction, maxSources: plan.maxSources,
                fixedCost: plan.fixedCost, livenessThreshold: plan.livenessThreshold, now: plan.now,
                originalAmountIn: plan.originalAmountIn, resolvedMinAmountOut: plan.resolvedMinAmountOut,
                cumulativeFilledAmountIn: cumulativeFilledAmountIn, cumulativeFilledAmountOut: cumulativeFilledAmountOut,
                remainingInventory: inventory
            )
        }

        if remainder <= 0 {
            return round(
                [], 0, 0, meets: cumulativeFilledAmountOut >= plan.resolvedMinAmountOut, filled: true,
                inventory: nextInventory
            )
        }

        let newLegs = try planOrder(
            nextInventory, plan.direction, remainder, maxSources: plan.maxSources, fixedCost: plan.fixedCost,
            minAmountOut: remainingMinAmountOut
        )
        let totalAmountIn = newLegs.reduce(BigInt(0)) { $0 + $1.amountIn }
        let totalAmountOut = newLegs.reduce(BigInt(0)) { $0 + $1.amountOut }
        let used = Set(newLegs.map(\.outpoint))
        return round(
            newLegs, totalAmountIn, totalAmountOut,
            meets: cumulativeFilledAmountOut + totalAmountOut >= plan.resolvedMinAmountOut,
            filled: cumulativeFilledAmountIn + totalAmountIn == plan.originalAmountIn,
            inventory: nextInventory.filter { !used.contains($0.outpoint) }
        )
    }

    /// `nextLeg`: the next leg of an order run one leg at a time. Plans `remaining` against
    /// `pools` (minimums applied, at most `maxSources` pools) and takes that plan's leg with the
    /// largest amountIn (tie: the smaller outpoint), `projectedOut` the plan's total. With
    /// `maxSources` 1 the leg takes all of `remaining` in the best single pool.
    public static func nextLeg(_ request: AMMNextLegRequest) throws -> AMMNextLegResult {
        let pools = request.pools
        let direction = request.direction
        let remaining = request.remaining
        if remaining <= 0 { return .stop(.filled) }

        if request.maxSources == 1 {
            guard let leg = try pickBestSingleLeg(pools, direction, remaining, minAmountOut: 0) else {
                let free = try pickBestSingleLeg(AMMPrice.withoutMinimums(pools), direction, remaining, minAmountOut: 0)
                return .stop(free != nil ? .min : .noPool)
            }
            if leg.amountOut < request.minOut { return .stop(.floor) }
            return .leg(leg, projectedOut: leg.amountOut)
        }

        let legs = try AMMAllocation.planSplit(pools, direction, remaining, request.fixedCost, maxSources: request.maxSources)
        if legs.isEmpty {
            let free = try AMMAllocation.planSplit(
                AMMPrice.withoutMinimums(pools), direction, remaining, request.fixedCost, maxSources: request.maxSources
            )
            return .stop(free.isEmpty ? .noPool : .min)
        }

        let projectedOut = legs.reduce(BigInt(0)) { $0 + $1.amountOut }
        if projectedOut < request.minOut { return .stop(.floor) }

        var leg = legs[0]
        for l in legs where l.amountIn > leg.amountIn || (l.amountIn == leg.amountIn && JS.less(l.outpoint, leg.outpoint)) {
            leg = l
        }
        return .leg(leg, projectedOut: projectedOut)
    }
}
