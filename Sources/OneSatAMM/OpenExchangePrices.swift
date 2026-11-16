import BigInt

/// `HostedToken` (client.ts:139): a token this exchange hosts, with its pools summed.
public struct OpenExchangeHostedToken: Equatable, Sendable {
    public let tokenId: String
    /// The token's symbol, else its id's first 8 characters.
    public let sym: String
    public let dec: Int
    /// An image URL.
    public let icon: String?
    /// Sats per whole token: the stats' `price` (the midpoint of what a buy and a sell of 1% of
    /// the pooled reserves would pay now) as a JS number. Nil with no open pool.
    public let marginalPrice: Double?
    public let depth: OpenExchangeDepth?
    /// Open pools: the stats' `pools`, 0 without stats.
    public let pools: Double
    /// All pools summed (the stats' TVL).
    public let reserves: OpenExchangeReserves
    /// The stats record the token was priced from (the 24h figures), nil without one. Not in
    /// the TS `HostedToken`, which keeps the record apart.
    public let stats: OpenExchangeTokenStats?
}

/// A token's pools summed: `{sats, tokens}`.
public struct OpenExchangeReserves: Equatable, Sendable {
    public let sats: BigInt
    public let tokens: BigInt
}

/// `Depth` (client.ts:133): the sats a buy needs to move the marginal price up by `bps`.
public struct OpenExchangeDepth: Equatable, Sendable {
    public let bps: Int
    public let sats: BigInt
}

/// `PoolView` (client.ts:160): one open pool of a token, as a quote routes over it.
public struct OpenExchangePoolView: Equatable, Sendable {
    /// `<txid>.<vout>`.
    public let outpoint: String
    /// The pool's id, its deploy outpoint `<txid>_<vout>`.
    public let poolId: String
    public let tokenId: String
    public let sats: BigInt
    public let tokens: BigInt
    public let validator: Validator

    /// `ValidatorRef`.
    public struct Validator: Equatable, Sendable {
        public let identityKey: String
        public let live: Bool
    }
}

/// `Fees` (client.ts:272): a pool's fees, basis points of the amount in.
public struct OpenExchangeFees: Equatable, Sendable {
    public let lpBps: Double
    public let validatorBps: Double
    /// The relay's commission; 0 for none.
    public let commissionBps: Double
}

/// A token's market figures in USD for a token page or a holdings row: 1sat-amm's
/// `OpenExProvider.computeStats` (src/data/openex/provider.ts) without its live-trade, holder
/// and supply parts.
public struct OpenExchangeTokenMarket: Equatable, Sendable {
    /// USD per whole token.
    public let priceUSD: Double
    /// BSV per whole token (0 without a BSV/USD rate).
    public let priceBSV: Double
    /// Percent; NaN when the exchange has no history for the window yet.
    public let change24h: Double
    public let change1h: Double
    /// The pools' sats and tokens, in USD.
    public let liquidityUSD: Double
    public let volume24hUSD: Double
    public let buys24h: Double
    public let sells24h: Double
    public let buyVolume24hUSD: Double
    public let sellVolume24hUSD: Double
}

/// The client's pure market functions (client.ts:462-530, market/prices.ts, market/view.ts,
/// lp/amounts.ts of the 0.55.1 client) and 1sat-amm's USD conversions.
public enum OpenExchangePrices {
    public static let satsPerBSV: Double = 100_000_000

    /// `hostedFrom` (client.ts:462): the enabled tokens at output 0 (a native topic), each with
    /// its record of the host-wide stats; `stats` nil (not read): no prices; a token the stats
    /// lack: no price, no pools.
    public static func hostedFrom(_ list: [OpenExchangeToken], stats: [OpenExchangeTokenStats]?) throws -> [OpenExchangeHostedToken] {
        var out: [OpenExchangeHostedToken] = []
        for t in list where t.status == .enabled && isNativeTopic(t.topic) {
            let st = (stats ?? []).first { AMMTokenID.parse($0.tokenId)?.description == t.tokenId }
            let sats = st?.tvlSats ?? 0
            let tokens = st?.tvlTokens ?? 0
            var marginalPrice: Double?
            if let price = st?.price, price.tokens > 0 {
                marginalPrice = JS.number(price.sats) / (JS.number(price.tokens) / JS.pow10(t.dec))
            }
            out.append(OpenExchangeHostedToken(
                tokenId: t.tokenId,
                sym: t.sym.isEmpty ? JS.prefix(t.tokenId, 8) : t.sym,
                dec: t.dec,
                icon: t.icon.flatMap { $0.isEmpty ? nil : $0 },
                marginalPrice: marginalPrice,
                depth: try depthOf(sats),
                pools: st?.pools ?? 0,
                reserves: OpenExchangeReserves(sats: sats, tokens: tokens),
                stats: st
            ))
        }
        return out
    }

    /// `parseTokenTopic(name)?.kind === "native"`: `tm_color_<64 lowercase hex>_0`.
    static func isNativeTopic(_ topic: String) -> Bool {
        let bytes = Array(topic.utf8)
        let head = Array("tm_color_".utf8)
        guard bytes.count == head.count + 66, bytes.starts(with: head) else { return false }
        let hex = bytes[head.count..<(head.count + 64)]
        return hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
            && bytes[head.count + 64] == UInt8(ascii: "_") && bytes[head.count + 65] == UInt8(ascii: "0")
    }

    /// `poolViews` (client.ts:487): the pools route's rows, outpoints dotted, every validator
    /// live (the host lists no other).
    public static func poolViews(_ answer: OpenExchangePools?, tokenId: String) -> [OpenExchangePoolView] {
        (answer?.pools ?? []).map { p in
            OpenExchangePoolView(
                outpoint: outpointText(p.pool.outpoint),
                poolId: p.poolId,
                tokenId: tokenId,
                sats: p.pool.bsvReserve,
                tokens: p.pool.tokenReserve,
                validator: .init(identityKey: p.pool.validatorIdentityKey, live: true)
            )
        }
    }

    /// `outpointText` (lib/tokenId.ts): `<txid>.<vout>`; anything not an outpoint as given.
    static func outpointText(_ outpoint: String) -> String {
        guard let id = AMMTokenID.parseOutpoint(outpoint) else { return outpoint }
        return "\(id.txid).\(id.vout)"
    }

    /// `poolFees` (client.ts:499): the fees a pool's own record names.
    public static func poolFees(_ pool: AMMPoolState) -> OpenExchangeFees {
        OpenExchangeFees(
            lpBps: JS.number(pool.liquidityFeeBps),
            validatorBps: JS.number(pool.validationFeeBps),
            commissionBps: JS.number(pool.commissionBps)
        )
    }

    /// `poolsWithMinimums` (client.ts:507): each pool with its validator's minimum leg.
    public static func poolsWithMinimums(_ answer: OpenExchangePools) -> [OpenExchangePoolRow] {
        let min = Dictionary(answer.validators.map { ($0.identity, $0.minLegSats) }, uniquingKeysWith: { $1 })
        return answer.pools.map { row in
            guard let m = min[row.pool.validatorIdentityKey.lowercased()] ?? nil, m != 0 else { return row }
            var out = row
            out.pool.minLegSats = m
            return out
        }
    }

    /// `pairPrice` (client.ts:518): sats per whole token of an exact pair, 0 when `tokens` is 0
    /// or less. A JS number.
    public static func pairPrice(_ p: AMMPricePair, dec: Int) -> Double {
        p.tokens > 0 ? JS.number(p.sats) / (JS.number(p.tokens) / JS.pow10(dec)) : 0
    }

    /// `depthOf` (market/prices.ts): the sats a buy needs to move the marginal price up by
    /// `bps`, over `sats` summed reserves, x·(√(1 + bps/10000) − 1) rounded; nil with none.
    public static func depthOf(_ sats: BigInt, bps: Int = 200) throws -> OpenExchangeDepth? {
        if sats == 0 { return nil }
        let x = JS.number(sats) * ((1 + Double(bps) / 10_000).squareRoot() - 1)
        return OpenExchangeDepth(bps: bps, sats: try JS.bigInt(JS.round(x)))
    }

    /// `PRICE_DECIMALS` (market/view.ts).
    public static let priceDecimals = 8

    /// `marginalPrice` (market/view.ts): bsvReserve / tokenReserve in sats per display token
    /// (× 10^dec), exact, up to 8 places, trailing zeros trimmed; "—" with no tokens.
    public static func marginalPrice(bsvReserve: BigInt, tokenReserve: BigInt, dec: Int? = nil) throws -> String {
        if tokenReserve <= 0 { return "—" }
        guard (dec ?? 0) >= 0 else { throw AMMEngineError(description: "RangeError: Exponent must be non-negative") }
        let scale = BigInt(10).power(priceDecimals)
        let num = bsvReserve * BigInt(10).power(dec ?? 0) * scale
        return try formatAmount(num / tokenReserve, dec: priceDecimals)
    }

    /// `priceOf` (market/view.ts): sats ÷ tokens as sats per display token, 8 places; "—" when
    /// either is 0 or less.
    public static func priceText(sats: BigInt, tokens: BigInt, dec: Int? = nil) throws -> String {
        if sats <= 0 || tokens <= 0 { return "—" }
        return try marginalPrice(bsvReserve: sats, tokenReserve: tokens, dec: dec)
    }

    /// `formatAmount` (lp/amounts.ts): base units as a decimal with `dec` places (0–18), trailing
    /// zeros trimmed.
    static func formatAmount(_ amount: BigInt, dec: Int = 0) throws -> String {
        guard (0...18).contains(dec) else { throw AMMEngineError(description: "decimals must be an integer 0-18") }
        let negative = amount < 0
        let digits = amount.magnitude.description
        if dec == 0 { return (negative ? "-" : "") + digits }
        let padded = String(repeating: "0", count: Swift.max(0, dec + 1 - digits.count)) + digits
        let whole = padded.prefix(padded.count - dec)
        var fraction = Substring(padded.suffix(dec))
        while fraction.hasSuffix("0") { fraction = fraction.dropLast() }
        return (negative ? "-" : "") + whole + (fraction.isEmpty ? "" : ".\(fraction)")
    }

    // MARK: - The discover list's text filter

    /// The discover list's text filter (1sat-amm `searchTokens`' local part): the tokens whose
    /// symbol contains `query` or whose id starts with it, lowercased, in list order. An empty
    /// query keeps every token.
    public static func filter(_ tokens: [OpenExchangeHostedToken], query: String) -> [OpenExchangeHostedToken] {
        let q = AMMTokenID.jsTrim(query)
        if q.isEmpty { return tokens }
        let lower = Array(q.lowercased().utf16)
        return tokens.filter { t in
            includes(Array(t.sym.lowercased().utf16), lower) || Array(t.tokenId.utf16).starts(with: lower)
        }
    }

    /// `haystack.includes(needle)` on UTF-16 code units.
    static func includes(_ haystack: [UInt16], _ needle: [UInt16]) -> Bool {
        if needle.isEmpty { return true }
        guard haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        return false
    }

    // MARK: - USD (1sat-amm src/data/openex/provider.ts)

    /// `priceUsdOf`: USD per whole token of an exact pair, at `usdPerBSV`.
    public static func priceUSD(_ p: AMMPricePair, dec: Int, usdPerBSV: Double) -> Double {
        (pairPrice(p, dec: dec) / satsPerBSV) * usdPerBSV
    }

    /// A holding's value: `amount` base units as whole tokens times the token's USD price
    /// (1sat-amm's `balance * stats.priceUsd`).
    public static func valueUSD(amount: BigInt, dec: Int, priceUSD: Double) -> Double {
        (JS.number(amount) / JS.pow10(dec)) * priceUSD
    }

    /// `spotSatsPerToken`: sats per whole token, the engine's mid over `pools` when given and
    /// priced, else the stats' price; 0 without either.
    public static func spotSatsPerToken(pools: [AMMPoolState]?, statsPrice: AMMPricePair?, dec: Int) throws -> Double {
        if let pools, let p = try AMMPrice.of(pools) { return pairPrice(p.mid, dec: dec) }
        return statsPrice.map { pairPrice($0, dec: dec) } ?? 0
    }

    /// `computeStats`, its market part: the USD price, the changes in percent, the liquidity
    /// (from `pools` when there are any, else the stats' TVL) and the 24h volume.
    public static func market(
        stats: OpenExchangeTokenStats?, pools: [AMMPoolState]?, dec: Int, usdPerBSV: Double
    ) throws -> OpenExchangeTokenMarket {
        let priceUSD = (try spotSatsPerToken(pools: pools, statsPrice: stats?.price, dec: dec) / satsPerBSV) * usdPerBSV
        var liquidityUSD = 0.0
        if let pools, !pools.isEmpty {
            let sats = pools.reduce(BigInt(0)) { $0 + $1.bsvReserve }
            let tokens = pools.reduce(BigInt(0)) { $0 + $1.tokenReserve }
            liquidityUSD = (JS.number(sats) / satsPerBSV) * usdPerBSV + (JS.number(tokens) / JS.pow10(dec)) * priceUSD
        } else if let stats {
            liquidityUSD = (JS.number(stats.tvlSats) / satsPerBSV) * usdPerBSV + (JS.number(stats.tvlTokens) / JS.pow10(dec)) * priceUSD
        }
        let volume = stats.map { (JS.number($0.volume24hSats) / satsPerBSV) * usdPerBSV } ?? 0
        let buys = stats?.buys24h ?? 0
        let sells = stats?.sells24h ?? 0
        let total = buys + sells
        let buyShare = total > 0 ? buys / total : 0.5
        return OpenExchangeTokenMarket(
            priceUSD: priceUSD,
            priceBSV: usdPerBSV > 0 ? priceUSD / usdPerBSV : 0,
            change24h: stats?.change24h.map { $0 / 100 } ?? .nan,
            change1h: stats?.change1h.map { $0 / 100 } ?? .nan,
            liquidityUSD: liquidityUSD,
            volume24hUSD: volume,
            buys24h: buys,
            sells24h: sells,
            buyVolume24hUSD: volume * buyShare,
            sellVolume24hUSD: volume * (1 - buyShare)
        )
    }
}
