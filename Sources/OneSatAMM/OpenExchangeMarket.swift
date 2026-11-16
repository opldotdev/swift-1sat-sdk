import Foundation
import BigInt

// The exchange's public market reads (skein-amm cc146be web/ui/src/lib/overlay.ts, the 0.55.1
// client): a token's pools (P2), its stats (H3) and every enabled token's (H4); and discovery's
// token search (`?q=`, as 1sat-amm src/data/openex/api.ts reads it). Plain GETs.

/// `PoolRow` (lib/overlay.ts): a pool of the pools routes, the engine's `PoolState` with its id,
/// LP key, swap count and validator's peer ID.
public struct OpenExchangePoolRow: Equatable, Sendable {
    /// The engine's view of the pool (`minLegSats` set by `OpenExchangePrices.poolsWithMinimums`).
    public var pool: AMMPoolState
    /// The pool's id: its deploy outpoint, `<txid>_<vout>`, lowercase ("" when the row has none).
    public let poolId: String
    /// Lowercase ("" when the row has none).
    public let lpPubKey: String
    /// The pool's swaps so far: `Number(raw.swaps ?? 0)`, NaN for a value that is not a number.
    public let swaps: Double
    /// The validator's libp2p peer ID (P2).
    public let validatorPeerId: String?
    /// The token (P1).
    public let tokenId: String?

    /// `toPoolRow`: one wire row, nil when it is not one; throws where TS's `BigInt(...)` of a
    /// reserve or fee does.
    static func read(_ raw: JSONValue) throws -> OpenExchangePoolRow? {
        guard case .object = raw, case .string(let outpoint)? = raw["outpoint"],
              case .string(let validator)? = raw["validatorIdentityKey"],
              let bsv = raw["bsvReserve"], let tokens = raw["tokenReserve"] else { return nil }
        func required(_ key: String) throws -> BigInt {
            guard let value = raw[key] else { throw JS.ConversionError(description: "TypeError: Cannot convert undefined to a BigInt") }
            return try JS.bigInt(value)
        }
        let commission: BigInt = switch raw["commissionBps"] {
        case nil, .null?: 0
        case let value?: try JS.bigInt(value)
        }
        let pool = AMMPoolState(
            outpoint: outpoint,
            bsvReserve: try JS.bigInt(bsv),
            tokenReserve: try JS.bigInt(tokens),
            liquidityFeeBps: try required("liquidityFeeBps"),
            validationFeeBps: try required("validationFeeBps"),
            commissionBps: commission,
            validatorIdentityKey: validator
        )
        let swaps: Double = switch raw["swaps"] {
        case nil, .null?: 0
        case let value?: JS.number(value)
        }
        return OpenExchangePoolRow(
            pool: pool,
            poolId: raw["poolId"]?.string?.lowercased() ?? "",
            lpPubKey: raw["lpPubKey"]?.string?.lowercased() ?? "",
            swaps: swaps,
            validatorPeerId: raw["validatorPeerId"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            tokenId: raw["tokenId"]?.string
        )
    }
}

/// `PoolsAnswer` (lib/overlay.ts): a token's pools route (P2), the pools a swap may use now.
public struct OpenExchangePools: Equatable, Sendable {
    /// `Market`: the exchange instance's identity key (lowercase compressed hex) and its
    /// minimum commission.
    public struct Market: Equatable, Sendable {
        public let identityKey: String?
        public let minCommissionBps: Int
    }

    /// `BeatingValidator`: a validator beating on the token's topic now, and the minimum leg its
    /// terms announce (sats; nil for none).
    public struct Validator: Equatable, Sendable {
        public let identity: String
        public let peerId: String
        public let minLegSats: BigInt?
    }

    public let market: Market
    public let pools: [OpenExchangePoolRow]
    public let validators: [Validator]

    public static let empty = OpenExchangePools(market: Market(identityKey: nil, minCommissionBps: 0), pools: [], validators: [])

    /// `parsePools`.
    static func read(_ x: JSONValue?) throws -> OpenExchangePools {
        let validators = try (x?["validators"]?.array ?? []).compactMap { v -> Validator? in
            guard case .object = v, case .string(let identity)? = v["identity"] else { return nil }
            let min: BigInt = switch v["minLegSats"] {
            case .number?, .string?: try JS.bigInt(v["minLegSats"]!)
            default: 0
            }
            return Validator(identity: identity.lowercased(), peerId: v["peerId"]?.string ?? "", minLegSats: min > 0 ? min : nil)
        }
        let rows = try (x?["pools"]?.array ?? []).compactMap(OpenExchangePoolRow.read)
        return OpenExchangePools(market: market(x?["market"]), pools: rows, validators: validators)
    }

    /// `toMarket`.
    static func market(_ m: JSONValue?) -> Market {
        var identity: String?
        if case .string(let key)? = m?["identityKey"], OpenExchange.isIdentityKey(key.lowercased()), key.utf8.count == 66 {
            identity = key.lowercased()
        }
        return Market(identityKey: identity, minCommissionBps: m?["minCommissionBps"]?.int ?? 0)
    }
}

/// `TokenStats` (lib/overlay.ts): a token at the read's time (H3, H4). Counts and times are
/// JS numbers, as TS reads them; the changes are basis points.
public struct OpenExchangeTokenStats: Equatable, Sendable {
    public let tokenId: String
    /// The midpoint of what a buy and a sell of 1% of the pooled reserves would pay now (the
    /// engine's `priceOf(listed pools).mid`), nil with no pool.
    public let price: AMMPricePair?
    public let buyPrice: AMMPricePair?
    public let sellPrice: AMMPricePair?
    /// The last trade's price, nil without one.
    public let lastTradePrice: AMMPricePair?
    /// Bps; nil without a trade at or before the window's start.
    public let change1h: Double?
    public let change24h: Double?
    public let volume24hSats: BigInt
    public let volume24hTokens: BigInt
    public let buys24h: Double
    public let sells24h: Double
    /// Ms; nil without a trade.
    public let lastTradeAt: Double?
    public let tvlSats: BigInt
    public let tvlTokens: BigInt
    public let pools: Double
    /// The token's lifetime counters.
    public let volumeSats: BigInt
    public let volumeTokens: BigInt
    public let trades: Double

    /// `toStats`: a stats record, nil when it is not one; throws where `wireBig` does.
    static func read(_ r: JSONValue) throws -> OpenExchangeTokenStats? {
        guard case .object = r, case .string(let tokenId)? = r["tokenId"] else { return nil }
        return OpenExchangeTokenStats(
            tokenId: tokenId,
            price: try price(r["price"]),
            buyPrice: try price(r["buyPrice"]),
            sellPrice: try price(r["sellPrice"]),
            lastTradePrice: try price(r["lastTradePrice"]),
            change1h: finite(r["change1h"]),
            change24h: finite(r["change24h"]),
            volume24hSats: try wireBig(r["volume24hSats"]),
            volume24hTokens: try wireBig(r["volume24hTokens"]),
            buys24h: finite(r["buys24h"]) ?? 0,
            sells24h: finite(r["sells24h"]) ?? 0,
            lastTradeAt: finite(r["lastTradeAt"]),
            tvlSats: try wireBig(r["tvlSats"]),
            tvlTokens: try wireBig(r["tvlTokens"]),
            pools: finite(r["pools"]) ?? 0,
            volumeSats: try wireBig(r["volumeSats"]),
            volumeTokens: try wireBig(r["volumeTokens"]),
            trades: finite(r["trades"]) ?? 0
        )
    }

    /// `toPrice`: an object with `sats` and `tokens` (either may be null), else nil.
    static func price(_ x: JSONValue?) throws -> AMMPricePair? {
        guard let x, case .object = x, let sats = x["sats"], let tokens = x["tokens"] else { return nil }
        return AMMPricePair(sats: try wireBig(sats), tokens: try wireBig(tokens))
    }

    /// `wireBig`: `BigInt(x)` of a number or string, else 0.
    static func wireBig(_ x: JSONValue?) throws -> BigInt {
        switch x {
        case .number?, .string?: try JS.bigInt(x!)
        default: 0
        }
    }

    /// `intOrNull`: a finite number, else nil.
    static func finite(_ x: JSONValue?) -> Double? {
        guard case .number(let n)? = x, n.isFinite else { return nil }
        return n
    }
}

/// A row of discovery's token search (1sat-amm `WireDiscoveryRow`): display fields, the icon as
/// an absolute URL, the deploy's supply and block height.
public struct OpenExchangeDiscoveryRow: Equatable, Sendable {
    public let tokenId: String
    public let sym: String?
    /// The row's `dec` when an integer.
    public let dec: Int?
    public let icon: String?
    /// Supply in base units; 0 for an authority-only deploy.
    public let amount: BigInt
    /// The row's `height` when an integer.
    public let height: Int?
}

extension OpenExchange {
    /// P2 (`tokenPools`, client.ts:958; `readPools`): a token's pools as the host lists them
    /// now, `GET <origin>/@<tokenId>/amm/pools`.
    public func tokenPools(_ tokenId: String) async throws -> OpenExchangePools {
        do {
            return try OpenExchangePools.read(try await getJSON("\(OpenExchangeURLs.trimTrailingSlashes(try tokenBase(tokenId)))/pools"))
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// H3 (`stats`, client.ts:1004; `readStats`): a token's stats, `GET <origin>/@<tokenId>/amm/stats`.
    public func stats(_ tokenId: String) async throws -> OpenExchangeTokenStats {
        do {
            let url = "\(OpenExchangeURLs.trimTrailingSlashes(try tokenBase(tokenId)))/stats"
            guard let value = try await getJSON(url), let stats = try OpenExchangeTokenStats.read(value) else {
                throw OpenExchangeError.failed("GET \(url): not a stats record")
            }
            return stats
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// H4 (`statsAll`, client.ts:1009; `readAllStats`): every enabled token's stats in one read,
    /// `GET <swap>/stats`; with `ids`, those tokens only, in that order (`?ids=a,b`).
    public func statsAll(ids: [String]? = nil) async throws -> [OpenExchangeTokenStats] {
        do {
            let query = ids.map { "?ids=" + $0.map(Self.uriComponent).joined(separator: ",") } ?? ""
            let rows = try await getJSON("\(OpenExchangeURLs.trimTrailingSlashes(base))/stats\(query)")?.array ?? []
            return try rows.compactMap(OpenExchangeTokenStats.read)
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `hostedTokens` (client.ts:952): the tokens this exchange hosts, priced from one read of
    /// the host-wide stats. A failed stats read leaves every token unpriced; a failed token list
    /// throws.
    public func hostedTokens() async throws -> [OpenExchangeHostedToken] {
        async let list = tokens()
        async let stats = statsOrNil()
        let (tokens, rows) = try await (list, stats)
        do {
            return try OpenExchangePrices.hostedFrom(tokens, stats: rows)
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `statsAll().catch(() => null)`.
    private func statsOrNil() async -> [OpenExchangeTokenStats]? {
        do { return try await statsAll() } catch { return nil }
    }

    /// Discovery's token search (1sat-amm `api.discoverySearch`): tokens whose symbol or id
    /// starts with `query` (ASCII case-insensitive), in discovery order, listed or not;
    /// `GET <origin>/@discovery/1color/tokens?q=&limit=&after=`. `limit` is held to 1–100;
    /// `after` is a cursor, the last row's token id.
    public func discoverySearch(_ query: String, limit: Int = 20, after: String? = nil) async throws -> [OpenExchangeDiscoveryRow] {
        do {
            let list = "\(try discoveryBase())/tokens"
            var params = "q=\(Self.formComponent(query))&limit=\(Swift.min(100, Swift.max(1, limit)))"
            if let after, !after.isEmpty { params += "&after=\(Self.formComponent(after))" }
            let rows = try await getJSON("\(list)?\(params)")?.array ?? []
            return try rows.compactMap { try Self.discoveryRow($0, listURL: list) }
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// One discovery row as 1sat-amm maps it; nil without a token id.
    static func discoveryRow(_ r: JSONValue, listURL: String) throws -> OpenExchangeDiscoveryRow? {
        guard case .string(let tokenId)? = r["tokenId"] else { return nil }
        var icon: String?
        if case .string(let iconUrl)? = r["iconUrl"], !iconUrl.isEmpty {
            guard let url = URL(string: iconUrl, relativeTo: URL(string: listURL)) else {
                throw OpenExchangeError.failed("Invalid URL: \(iconUrl)")
            }
            icon = url.absoluteString
        }
        // `big(x)`: `BigInt(String(x ?? 0))`, 0 for anything that is not an integer.
        let amount: BigInt = switch r["amount"] {
        case nil, .null?: 0
        case let value?: (try? JS.bigInt(JS.string(value))) ?? 0
        }
        return OpenExchangeDiscoveryRow(
            tokenId: tokenId, sym: r["sym"]?.string, dec: r["dec"]?.int, icon: icon, amount: amount,
            height: r["height"]?.int
        )
    }

    /// A search hit (1sat-amm `TokenSearchHit`): a hosted token, or a discovery row not listed
    /// here.
    public struct SearchHit: Equatable, Sendable {
        public let tokenId: String
        public let sym: String
        public let dec: Int
        public let icon: String?
        /// The token is hosted (enabled) here.
        public let listed: Bool
        /// The hosted token, when listed.
        public let hosted: OpenExchangeHostedToken?
    }

    /// 1sat-amm `searchTokens`: the hosted tokens the text filter keeps, then discovery's
    /// search hits not among them (a hosted token found there listed, any other not), at most
    /// `limit`. A failed discovery read leaves the local hits. Empty for an empty query.
    public func searchTokens(_ query: String, in hosted: [OpenExchangeHostedToken], limit: Int = 20) async -> [SearchHit] {
        let q = AMMTokenID.jsTrim(query)
        if q.isEmpty { return [] }
        async let remoteRows = discoveryHits(q, limit: Swift.min(100, limit))
        func hit(_ t: OpenExchangeHostedToken, icon: String? = nil) -> SearchHit {
            SearchHit(tokenId: t.tokenId, sym: t.sym, dec: t.dec, icon: t.icon ?? icon, listed: true, hosted: t)
        }
        var out = OpenExchangePrices.filter(hosted, query: q).map { hit($0) }
        var seen = Set(out.map(\.tokenId))
        for r in await remoteRows where !seen.contains(r.tokenId) {
            seen.insert(r.tokenId)
            if let row = hosted.first(where: { $0.tokenId == r.tokenId }) {
                out.append(hit(row, icon: r.icon))
            } else {
                out.append(SearchHit(
                    tokenId: r.tokenId, sym: r.sym ?? JS.prefix(r.tokenId, 8), dec: r.dec ?? 0, icon: r.icon,
                    listed: false, hosted: nil
                ))
            }
        }
        // `out.slice(0, limit)`: a negative limit counts back from the end.
        return Array(out.prefix(limit >= 0 ? limit : Swift.max(0, out.count + limit)))
    }

    /// `api.discoverySearch(...).catch(() => [])`.
    private func discoveryHits(_ query: String, limit: Int) async -> [OpenExchangeDiscoveryRow] {
        do { return try await discoverySearch(query, limit: limit) } catch { return [] }
    }
}
