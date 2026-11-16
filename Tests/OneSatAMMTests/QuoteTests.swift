import Foundation
import XCTest
import BigInt
import BSVCore
import BSVKeys
import ToolboxAuth
import OneSatTemplates
@testable import OneSatAMM

// Vectors of skein-amm 0.55.1 (cc146be) for the quote: web/engine/src (planner, nextLeg,
// replanner, over allocation and pricing), web/ui/src/market/plan.ts and view.ts, lib/overlay.ts
// (`parsePools`, `liveOfPools`), lp/amounts.ts (`parseAmount`), market/relay.ts (`callApp`,
// `parseSwapTerms`, `readBytes`, on @bsv/sdk 4.0.1) and the client's pure quote functions
// (client.ts `poolFees`, `legCarrySats`, `quoteSwap`, extracted verbatim). Fixtures/
// amm-quote-vectors.json holds each case's input and the TS output, written by running that
// TS under bun: Fixtures/amm-quote-vectors.gen.sh lays it out and runs amm-quote-vectors.gen.ts.
// Bigints are "n:<digits>", JS numbers "d:<String(n)>", strings "s:<text>", object keys sorted.

/// A canonical value, rendered as the generator renders TS values.
private indirect enum Canon {
    case big(BigInt)
    case num(Double)
    case str(String)
    case bool(Bool)
    case null
    case arr([Canon])
    case obj([String: Canon])


    var text: String {
        switch self {
        case .big(let b): JSONText.quote("n:\(b)")
        case .num(let d): JSONText.quote("d:" + JS.string(d))
        case .str(let s): JSONText.quote("s:" + s)
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        case .arr(let items): "[" + items.map(\.text).joined(separator: ",") + "]"
        case .obj(let members):
            "{" + members.keys.sorted(by: JS.less).map { JSONText.quote($0) + ":" + members[$0]!.text }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - Inputs

private struct Input {
    let raw: Any?
    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    subscript(_ key: String) -> Input { Input((raw as? [String: Any])?[key]) }
    var isNil: Bool { raw == nil }
    var items: [Input] { (raw as? [Any] ?? []).map(Input.init) }
    var bool: Bool { raw as? Bool ?? false }

    private func tagged(_ tag: String) -> String? {
        guard let s = raw as? String, s.hasPrefix(tag) else { return nil }
        return String(s.dropFirst(tag.count))
    }

    var big: BigInt? { tagged("n:").flatMap { BigInt($0) } }
    var num: Double? { tagged("d:").map { JS.number($0) } }
    var int: Int? { num.map { Int($0) } }
    var str: String? { tagged("s:") }

    var pool: AMMPoolState {
        AMMPoolState(
            outpoint: self["outpoint"].str!, bsvReserve: self["bsvReserve"].big!, tokenReserve: self["tokenReserve"].big!,
            liquidityFeeBps: self["liquidityFeeBps"].big!, validationFeeBps: self["validationFeeBps"].big!,
            commissionBps: self["commissionBps"].big!, validatorIdentityKey: self["validatorIdentityKey"].str!,
            lastSeen: self["lastSeen"].num, minLegSats: self["minLegSats"].big
        )
    }

    var pools: [AMMPoolState] { items.map(\.pool) }
    var direction: AMMDirection { AMMDirection(rawValue: str!)! }
    var fixedCost: AMMFixedCost { AMMFixedCost(minerFeeSats: self["minerFeeSats"].big!) }

    var planRequest: AMMPlanRequest {
        AMMPlanRequest(
            tokenId: self["tokenId"].str!, direction: self["direction"].direction, amountIn: self["amountIn"].big!,
            slippage: AMMSlippageBound(minAmountOut: self["slippage"]["minAmountOut"].big, toleranceBps: self["slippage"]["toleranceBps"].big),
            maxSources: self["maxSources"].int!, fixedCost: self["fixedCost"].fixedCost, inventory: self["inventory"].pools,
            livenessThreshold: self["livenessThreshold"].num, now: self["now"].num
        )
    }

    var legResult: AMMLegResult {
        let outpoint = self["outpoint"].str!
        switch self["status"].str! {
        case "filled": return .filled(outpoint: outpoint)
        case "rejected": return .rejected(outpoint: outpoint, newPoolState: self["newPoolState"].isNil ? nil : self["newPoolState"].pool)
        default: return .unknown(outpoint: outpoint)
        }
    }

    var live: OpenExchangeLiveness? {
        if isNil { return nil }
        return OpenExchangeLiveness(
            now: self["now"].num!,
            validators: self["validators"].items.map {
                .init(identityKey: $0["identityKey"].str!, peerId: $0["peerId"].str!, at: $0["at"].num!, ageMs: $0["ageMs"].num!, live: $0["live"].bool)
            },
            kept: self["kept"].bool
        )
    }
}

// MARK: - Outputs

/// An object, its nil members left out.
private struct Obj {
    private var members: [String: Canon] = [:]
    func with(_ key: String, _ value: Canon?) -> Obj {
        var o = self
        if let value { o.members[key] = value }
        return o
    }
    var canon: Canon { .obj(members) }
}

private func big(_ b: BigInt?) -> Canon? { b.map(Canon.big) }
private func num(_ d: Double?) -> Canon? { d.map(Canon.num) }
private func str(_ s: String?) -> Canon? { s.map(Canon.str) }

private func poolC(_ p: AMMPoolState) -> Canon {
    Obj().with("outpoint", .str(p.outpoint)).with("bsvReserve", .big(p.bsvReserve)).with("tokenReserve", .big(p.tokenReserve))
        .with("liquidityFeeBps", .big(p.liquidityFeeBps)).with("validationFeeBps", .big(p.validationFeeBps))
        .with("commissionBps", .big(p.commissionBps)).with("validatorIdentityKey", .str(p.validatorIdentityKey))
        .with("lastSeen", num(p.lastSeen)).with("minLegSats", big(p.minLegSats)).canon
}

private func legC(_ l: AMMLeg) -> Canon {
    Obj().with("outpoint", .str(l.outpoint)).with("amountIn", .big(l.amountIn)).with("liquidityFee", .big(l.liquidityFee))
        .with("validationFee", .big(l.validationFee)).with("commission", .big(l.commission)).with("amountOut", .big(l.amountOut))
        .with("newBsvReserve", .big(l.newBsvReserve)).with("newTokenReserve", .big(l.newTokenReserve)).canon
}

private func costC(_ f: AMMFixedCost) -> Canon { Obj().with("minerFeeSats", .big(f.minerFeeSats)).canon }

private func planC(_ p: AMMPlan) -> Canon {
    Obj().with("legs", .arr(p.legs.map(legC))).with("totalAmountIn", .big(p.totalAmountIn))
        .with("totalAmountOut", .big(p.totalAmountOut)).with("meetsSlippageBound", .bool(p.meetsSlippageBound))
        .with("filledCompletely", .bool(p.filledCompletely)).with("unfillable", str(p.unfillable?.rawValue))
        .with("minAmountIn", big(p.minAmountIn)).with("direction", .str(p.direction.rawValue))
        .with("maxSources", .num(Double(p.maxSources))).with("fixedCost", costC(p.fixedCost))
        .with("livenessThreshold", num(p.livenessThreshold)).with("now", num(p.now))
        .with("originalAmountIn", .big(p.originalAmountIn)).with("resolvedMinAmountOut", .big(p.resolvedMinAmountOut))
        .with("cumulativeFilledAmountIn", .big(p.cumulativeFilledAmountIn))
        .with("cumulativeFilledAmountOut", .big(p.cumulativeFilledAmountOut))
        .with("remainingInventory", .arr(p.remainingInventory.map(poolC))).canon
}

private func statusC(_ s: OpenExchangeValidatorStatus) -> Canon {
    Obj().with("identityKey", .str(s.identityKey)).with("live", .bool(s.live)).with("seen", .bool(s.seen))
        .with("peerId", str(s.peerId)).with("at", num(s.at)).with("ageMs", num(s.ageMs)).canon
}

private func requestC(_ r: AMMPlanRequest) -> Canon {
    let slippage = Obj().with("minAmountOut", big(r.slippage.minAmountOut)).with("toleranceBps", big(r.slippage.toleranceBps)).canon
    return Obj().with("tokenId", .str(r.tokenId)).with("direction", .str(r.direction.rawValue)).with("amountIn", .big(r.amountIn))
        .with("slippage", slippage).with("maxSources", .num(Double(r.maxSources))).with("fixedCost", costC(r.fixedCost))
        .with("inventory", .arr(r.inventory.map(poolC))).with("livenessThreshold", num(r.livenessThreshold))
        .with("now", num(r.now)).canon
}

private func viewLegC(_ l: OpenExchangeLegView) -> Canon {
    Obj().with("outpoint", .str(l.outpoint)).with("pool", poolC(l.pool)).with("amountIn", .big(l.amountIn))
        .with("amountOut", .big(l.amountOut)).with("lpFee", .big(l.lpFee)).with("validatorFee", .big(l.validatorFee))
        .with("commission", .big(l.commission)).with("validator", statusC(l.validator)).canon
}

private func viewC(_ v: OpenExchangePlanView) -> Canon {
    Obj().with("direction", .str(v.direction.rawValue)).with("legs", .arr(v.legs.map(viewLegC)))
        .with("totalIn", .big(v.totalIn)).with("totalOut", .big(v.totalOut)).with("lpFees", .big(v.lpFees))
        .with("validatorFees", .big(v.validatorFees)).with("commissions", .big(v.commissions))
        .with("effectivePrice", .str(v.effectivePrice)).with("midPrice", .str(v.midPrice))
        .with("slippageVsMidBps", .big(v.slippageVsMidBps)).with("minAmountOut", .big(v.minAmountOut))
        .with("meetsSlippageBound", .bool(v.meetsSlippageBound)).with("filledCompletely", .bool(v.filledCompletely))
        .with("unfilled", .big(v.unfilled)).canon
}

private func feesC(_ f: OpenExchangeFees) -> Canon {
    Obj().with("lpBps", .num(f.lpBps)).with("validatorBps", .num(f.validatorBps)).with("commissionBps", .num(f.commissionBps)).canon
}

private func quoteLegC(_ l: OpenExchangeQuoteLeg) -> Canon {
    let reserves = Obj().with("sats", .big(l.reserves.sats)).with("tokens", .big(l.reserves.tokens)).canon
    let validator = Obj().with("identityKey", .str(l.validator.identityKey)).with("live", .bool(l.validator.live)).canon
    return Obj().with("poolOutpoint", .str(l.poolOutpoint)).with("poolId", .str(l.poolId)).with("amountIn", .big(l.amountIn))
        .with("amountOut", .big(l.amountOut)).with("shareBps", .num(Double(l.shareBps))).with("reserves", reserves)
        .with("validator", validator).with("fees", feesC(l.fees)).canon
}

private func quoteC(_ q: OpenExchangeQuote) -> Canon {
    let r = q.request
    let request = Obj().with("tokenId", .str(r.tokenId)).with("side", .str(r.side.rawValue)).with("amountIn", .big(r.amountIn))
        .with("maxSlippageBps", .num(Double(r.maxSlippageBps))).with("maxSources", .num(Double(r.maxSources))).canon
    let stage = Obj().with("amount", .big(q.stage.amount)).with("feeSats", .big(q.stage.feeSats)).canon
    let quote = Obj().with("request", request).with("legs", .arr(q.legs.map(quoteLegC))).with("amountOut", .big(q.amountOut))
        .with("minAmountOut", .big(q.minAmountOut)).with("effectivePrice", .num(q.effectivePrice))
        .with("marginalPrice", .num(q.marginalPrice)).with("impactBps", .num(q.impactBps)).with("stage", stage)
        .with("legMinerFeeSats", .big(q.legMinerFeeSats)).canon
    return Obj().with("quote", quote).with("plan", planC(q.plan)).with("view", viewC(q.view)).canon
}

private func termsC(_ t: OpenExchangeSwapTerms) -> Canon {
    Obj().with("commissionPkh", str(t.commissionPkh) ?? .null).with("minCommissionBps", .num(Double(t.minCommissionBps))).canon
}

/// A thrown error as the generator writes a TS one: `"<name>: <message>"` and a ClientError's kind.
private func thrown(_ error: Error) -> Canon {
    let text: String
    var kind: String?
    switch error {
    case OpenExchangeError.belowMinimum(let m): text = "ClientError: \(m)"; kind = "below_minimum"
    case OpenExchangeError.failed(let m): text = "Error: \(m)"
    case OpenExchangeError.refused(_, let m): text = "RelayError: \(m)"
    case let e as AMMEngineError: text = e.description
    case let e as JS.ConversionError: text = e.description
    default: text = String(describing: error)
    }
    return Obj().with("throws", .str(text)).with("kind", str(kind)).canon
}

private func outcome(_ f: () throws -> Canon) -> Canon {
    do { return try f() } catch { return thrown(error) }
}

/// JavaScriptCore (bun) and V8 word an engine `RangeError` differently; the Swift errors carry
/// V8's words (as the earlier vectors did). The same three causes, matched by their JSC text.
private let rangeErrorWords: [(jsc: String, swift: String)] = [
    ("RangeError: Not an integer", "RangeError: The number "),
    ("RangeError: 0 is an invalid divisor value.", "RangeError: Division by zero"),
    ("RangeError: Negative exponent is not allowed", "RangeError: Exponent must be non-negative"),
]

private func VK(_ s: String) -> String { "02" + String(String(repeating: s, count: 64).prefix(64)) }

final class AMMQuoteVectorTests: XCTestCase {
    private struct Case {
        let kind: String
        let name: String
        let input: Input
        let expect: String
    }

    private func cases() throws -> [Case] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "amm-quote-vectors", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return (root["cases"] as? [[String: Any]] ?? []).map {
            Case(kind: $0["kind"] as! String, name: $0["name"] as! String, input: Input($0["input"]), expect: $0["expect"] as! String)
        }
    }

    private func check(_ k: Case, _ actual: Canon, file: StaticString = #filePath, line: UInt = #line) {
        let got = actual.text
        if got == k.expect { return }
        // An engine RangeError: the same cause in V8's words.
        if case .obj(let m) = actual, case .str(let swiftText)? = m["throws"] {
            for words in rangeErrorWords where k.expect == "{\"throws\":\(JSONText.quote("s:" + words.jsc))}" {
                if swiftText.hasPrefix(words.swift) { return }
            }
        }
        XCTFail("\(k.kind) \(k.name)\n  TS:    \(k.expect)\n  Swift: \(got)", file: file, line: line)
    }

    func testTheVectorsCoverEveryPart() throws {
        let kinds = Dictionary(grouping: try cases(), by: \.kind).mapValues(\.count)
        for kind in ["plan", "replan", "nextLeg", "quote", "build", "terms", "call", "carry", "fees", "minerFee", "parseAmount", "best", "minIn", "order"] {
            XCTAssertGreaterThan(kinds[kind] ?? 0, 0, kind)
        }
        XCTAssertGreaterThanOrEqual(kinds.values.reduce(0, +), 200)
    }

    func testPlannerMatchesTS() throws {
        for k in try cases() {
            let i = k.input
            switch k.kind {
            case "plan":
                check(k, outcome { planC(try AMMPlanner.plan(i.planRequest)) })
            case "replan":
                check(k, outcome {
                    var p = try AMMPlanner.plan(i["request"].planRequest)
                    var out = [planC(p)]
                    for results in i["rounds"].items {
                        p = try AMMPlanner.replan(p, results.items.map(\.legResult))
                        out.append(planC(p))
                    }
                    return .arr(out)
                })
            case "nextLeg":
                let r = AMMNextLegRequest(
                    pools: i["pools"].pools, direction: i["direction"].direction, remaining: i["remaining"].big!,
                    fixedCost: i["fixedCost"].fixedCost, minOut: i["minOut"].big!, maxSources: i["maxSources"].int!
                )
                check(k, outcome {
                    switch try AMMPlanner.nextLeg(r) {
                    case .leg(let leg, let projectedOut): Obj().with("leg", legC(leg)).with("projectedOut", .big(projectedOut)).canon
                    case .stop(let stop): Obj().with("stop", .str(stop.rawValue)).canon
                    }
                })
            case "resolveMin":
                check(k, .arr(i.items.map { pair in
                    let s = pair.items[1]
                    return Canon.big(AMMPlanner.resolveMinAmountOut(pair.items[0].big!, AMMSlippageBound(minAmountOut: s["minAmountOut"].big, toleranceBps: s["toleranceBps"].big)))
                }))
            case "best":
                check(k, outcome {
                    try AMMPlanner.pickBestSingleLeg(i["pools"].pools, i["direction"].direction, i["amountIn"].big!, minAmountOut: i["minAmountOut"].big!).map(legC) ?? .null
                })
            case "minIn":
                check(k, outcome { try AMMPlanner.minAmountInOf(i["pools"].pools, i["direction"].direction).map(Canon.big) ?? .null })
            case "order":
                check(k, outcome {
                    .arr(try AMMPlanner.planOrder(
                        i["pools"].pools, i["direction"].direction, i["amountIn"].big!, maxSources: i["maxSources"].int!,
                        fixedCost: i["fixedCost"].fixedCost, minAmountOut: i["minAmountOut"].big!
                    ).map(legC))
                })
            case "live":
                check(k, .arr(AMMPlanner.filterLivePools(i["pools"].pools, livenessThreshold: i["threshold"].num, now: i["now"].num).map { Canon.str($0.outpoint) }))
            default:
                continue
            }
        }
    }

    func testMarketPlanMatchesTS() throws {
        for k in try cases() {
            let i = k.input
            switch k.kind {
            case "minerFee":
                check(k, outcome { .big(try OpenExchangeQuotes.legMinerFeeSats(i.num!)) })
            case "carry":
                let l = i["leg"]
                check(k, .big(OpenExchangeQuotes.legCarrySats(
                    liquidityFee: l["liquidityFee"].big!, validationFee: l["validationFee"].big!, commission: l["commission"].big!,
                    buy: i["buy"].bool, minerFeeSats: i["fee"].big!
                )))
            case "fees":
                check(k, feesC(OpenExchangePrices.poolFees(i.pool)))
            case "parseAmount":
                check(k, outcome { .big(try OpenExchangeQuotes.parseAmount(i["text"].str!, dec: i["dec"].int!)) })
            case "build":
                let f = i["form"]
                let form = OpenExchangeSwapForm(
                    direction: f["direction"].direction, amount: f["amount"].str!, slippageBps: f["slippageBps"].str!,
                    maxSources: f["maxSources"].int!
                )
                check(k, outcome {
                    switch try OpenExchangeQuotes.buildPlanRequest(
                        tokenId: i["tokenId"].str!, form: form, pools: i["pools"].pools, live: i["live"].live, dec: i["dec"].int,
                        satsPerKb: i["rate"].num!
                    ) {
                    case .ok(let r): Obj().with("ok", .bool(true)).with("request", requestC(r)).canon
                    case .error(let e): Obj().with("ok", .bool(false)).with("error", .str(e)).canon
                    }
                })
            case "status":
                let live = i["live"].live
                check(k, .arr([
                    statusC(.of(VK("A"), live)), statusC(.of(VK("b"), live)), statusC(.of(VK("c"), live)), statusC(.of(VK("a"), nil)),
                ]))
            case "withLastSeen":
                let pools = i["pools"].pools
                let live = i["live"].live
                check(k, .arr([
                    .arr(OpenExchangeQuotes.withLastSeen(pools, live).map(poolC)),
                    .arr(OpenExchangeQuotes.withLastSeen(pools, nil).map(poolC)),
                    .arr(OpenExchangeQuotes.livePools(pools, live).map { Canon.str($0.outpoint) }),
                ]))
            case "gone":
                let legs = ["a:0", "b:0", "c:0"].map {
                    AMMLeg(outpoint: $0, amountIn: 0, liquidityFee: 0, validationFee: 0, commission: 0, amountOut: 0, newBsvReserve: 0, newTokenReserve: 0)
                }
                let b = AMMPoolState(outpoint: "b:0", bsvReserve: 1, tokenReserve: 1, liquidityFeeBps: 0, validationFeeBps: 0, commissionBps: 0, validatorIdentityKey: "")
                check(k, .arr(OpenExchangeQuotes.goneFromLookup(legs, fresh: [b]).map(Canon.str)))
            default:
                continue
            }
        }
    }

    func testQuoteSwapMatchesTS() throws {
        var quoted = 0
        for k in try cases() where k.kind == "quote" {
            let i = k.input
            let r = i["request"]
            let request = OpenExchangeQuoteRequest(
                tokenId: r["tokenId"].str!, side: OpenExchangeQuoteRequest.Side(rawValue: r["side"].str!)!,
                amountIn: r["amountIn"].big!, maxSlippageBps: r["maxSlippageBps"].int!, maxSources: r["maxSources"].int!
            )
            let held = try i["held"].str.map { try OpenExchangePools.read(JSONValue.parse(Array($0.utf8))) }
            check(k, outcome {
                let q = try OpenExchangeQuotes.quoteSwap(
                    request, held: held, sym: i["meta"]["sym"].str!, dec: i["meta"]["dec"].int!, feeRateSatsPerKb: i["rate"].num!
                )
                quoted += 1
                // The Swift-only per-leg fees are the view's.
                for (leg, view) in zip(q.legs, q.view.legs.filter { $0.amountIn > 0 }) {
                    XCTAssertEqual([leg.lpFee, leg.validatorFee, leg.commission], [view.lpFee, view.validatorFee, view.commission], k.name)
                }
                return quoteC(q)
            })
        }
        XCTAssertGreaterThan(quoted, 20)
    }

    func testSwapTermsMatchTS() async throws {
        for k in try cases() {
            switch k.kind {
            case "terms":
                let text = k.input.str!
                check(k, outcome { termsC(try OpenExchange.parseSwapTerms(try XCTUnwrap(JSONValue.parse(Array(text.utf8))))) })
            case "call":
                let session = StubSigned(.response(k.input["status"].int!, k.input["body"].str!))
                let exchange = try OpenExchange(origin: "https://x", http: StubHTTP(), session: { _, _ in session })
                let actual: Canon
                do {
                    actual = termsC(try await exchange.swapTerms(tokenId: "t", identity: PrivateKey(Array(repeating: 1, count: 32))))
                } catch {
                    actual = thrown(error)
                }
                check(k, actual)
            default:
                continue
            }
        }
    }
}

// MARK: - The swap terms request, and what the vectors cannot show

final class OpenExchangeSwapTermsTests: XCTestCase {
    private let tokenId = String(repeating: "ab", count: 32) + "_0"

    func testSwapTermsIsOneSignedCallToTheTokensInstance() async throws {
        let pkh = (0..<20).map { UInt8($0 * 3) }
        let body = #"{"fn":"amm.swap.terms","result":{"commissionPkh":"# + "\(pkh)".replacingOccurrences(of: " ", with: "") + #","minCommissionBps":12}}"#
        let session = StubSigned(.response(200, body))
        let log = SessionLog()
        let http = StubHTTP()
        let exchange = try OpenExchange(origin: "https://swap.example", http: http, session: { identity, instance in
            log.record(identity, instance)
            return session
        })
        let identity = try PrivateKey(Array(repeating: 7, count: 32))
        let terms = try await exchange.swapTerms(tokenId: tokenId, identity: identity)
        XCTAssertEqual(terms, OpenExchangeSwapTerms(commissionPkh: Hex.encode(pkh), minCommissionBps: 12))

        let sent = await session.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.method, "POST")
        XCTAssertEqual(sent.first?.path, "/@\(tokenId)/amm/call")
        XCTAssertNil(sent.first?.query)
        XCTAssertEqual(sent.first?.headers, ["content-type": "application/json"])
        XCTAssertEqual(sent.first?.body.map { String(decoding: $0, as: UTF8.self) }, #"{"fn":"amm.swap.terms","args":{}}"#)
        XCTAssertEqual(log.instances, ["https://swap.example/@\(tokenId)"])
        XCTAssertEqual(log.identities, [Hex.encode(identity.publicKey.compressedBytes)])
        // Nothing but the signed call: no plain request.
        let plain = await http.requests
        XCTAssertTrue(plain.isEmpty)
    }

    func testAnUnsignedRefusalIsReadAsTheAnswer() async throws {
        let session = StubSigned(.error(AuthTransportError.unauthenticatedReply(
            status: 401, body: Array(#"{"error":{"code":"ERR_UNAUTHORIZED","message":"who are you"}}"#.utf8)
        )))
        let exchange = try OpenExchange(origin: "https://swap.example", http: StubHTTP(), session: { _, _ in session })
        do {
            _ = try await exchange.swapTerms(tokenId: tokenId, identity: try PrivateKey(Array(repeating: 2, count: 32)))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? OpenExchangeError, .refused(code: "ERR_UNAUTHORIZED", message: "ERR_UNAUTHORIZED: who are you"))
        }
    }

    func testAPrimitiveAnswerIsNotTerms() async throws {
        // `"result" in answer` of a JSON string or number throws in JS (a TypeError, worded per engine).
        for body in [#""text""#, "5", "true"] {
            let exchange = try OpenExchange(origin: "https://swap.example", http: StubHTTP(), session: { _, _ in StubSigned(.response(200, body)) })
            do {
                _ = try await exchange.swapTerms(tokenId: tokenId, identity: try PrivateKey(Array(repeating: 3, count: 32)))
                XCTFail("expected a failure for \(body)")
            } catch {
                guard case .failed(let message)? = error as? OpenExchangeError else { return XCTFail("\(error)") }
                XCTAssertTrue(message.hasPrefix("TypeError"), message)
            }
        }
    }

    func testANetworkFailureIsNetwork() async throws {
        let exchange = try OpenExchange(origin: "https://swap.example", http: StubHTTP(), session: { _, _ in
            StubSigned(.error(URLError(.notConnectedToInternet)))
        })
        do {
            _ = try await exchange.swapTerms(tokenId: tokenId, identity: try PrivateKey(Array(repeating: 4, count: 32)))
            XCTFail("expected a network error")
        } catch {
            guard case .network? = error as? OpenExchangeError else { return XCTFail("\(error)") }
        }
    }
}

// MARK: - The quote sheet's numbers, by hand

final class OpenExchangeQuoteSheetTests: XCTestCase {
    private let T = String(repeating: "ab", count: 32) + "_0"

    private func held(_ pools: String, validators: String = #"[{"identity":"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peerId":"p"}]"#) throws -> OpenExchangePools {
        try OpenExchangePools.read(JSONValue.parse(Array(#"{"market":{},"pools":\#(pools),"validators":\#(validators)}"#.utf8)))
    }

    private func row(_ txid: Character, bsv: Int = 1_000_000, tokens: Int = 5_000_000, lp: Int = 30, val: Int = 5, comm: Int = 0) -> String {
        let outpoint = String(repeating: txid, count: 64) + "_0"
        return #"{"outpoint":"\#(outpoint)","poolId":"\#(outpoint)","bsvReserve":\#(bsv),"tokenReserve":\#(tokens),"liquidityFeeBps":\#(lp),"validationFeeBps":\#(val),"commissionBps":\#(comm),"validatorIdentityKey":"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","validatorPeerId":"p"}"#
    }

    func testABuyOfOnePool() throws {
        let q = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: T, side: .buy, amountIn: 100_000, maxSlippageBps: 50, maxSources: 3),
            held: try held("[\(row("1"))]"), sym: "TST", dec: 2
        )
        // The contract: lp ceil(100000·30/1e4) = 300, validator 50, net 99 650,
        // out floor(99650·5e6 / (1e6 + 99650)) = 453 098.
        XCTAssertEqual(q.amountOut, 453_098)
        XCTAssertEqual(q.minAmountOut, 453_098 * 9_950 / 10_000)
        XCTAssertEqual(q.legs.count, 1)
        XCTAssertEqual(q.legs[0].shareBps, 10_000)
        XCTAssertEqual(q.legs[0].poolOutpoint, String(repeating: "1", count: 64) + ".0")
        XCTAssertEqual(q.legs[0].fees, OpenExchangeFees(lpBps: 30, validatorBps: 5, commissionBps: 0))
        XCTAssertEqual([q.view.lpFees, q.view.validatorFees, q.view.commissions], [300, 50, 0])
        XCTAssertEqual(q.legMinerFeeSats, 1300)
        // A buy carries one sat per leg; three legs' fee sats though the plan has one.
        XCTAssertEqual(q.stage, OpenExchangeQuoteStage(amount: 100_000, feeSats: 3 * 1301))
        XCTAssertEqual(q.effectivePrice, 100_000 / (453_098 / 100.0))
        XCTAssertGreaterThan(q.impactBps, 0)
    }

    func testASellCountsItsNonZeroFeeOutputs() throws {
        let q = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: T, side: .sell, amountIn: 400_000, maxSlippageBps: 0, maxSources: 1),
            held: try held("[\(row("5", lp: 30, val: 0, comm: 12))]"), sym: "TST", dec: 2, feeRateSatsPerKb: 50
        )
        // 650 sats of miner fee, the LP fee and commission outputs and the token change.
        XCTAssertEqual(q.stage.feeSats, 650 + 3)
        XCTAssertEqual(q.minAmountOut, q.amountOut)
    }

    func testALegsPoolIdComesFromALivePool() throws {
        // The same outpoint twice, the second under a validator that is not live: TS plans over the
        // live row only, so its poolId is the leg's.
        let o = String(repeating: "1", count: 64) + "_0"
        let dead = row("1").replacingOccurrences(of: #""poolId":"\#(o)""#, with: #""poolId":"PID1""#)
            .replacingOccurrences(of: #""validatorPeerId":"p""#, with: #""validatorPeerId":"""#)
            .replacingOccurrences(of: "02" + String(repeating: "a", count: 64), with: "02" + String(repeating: "d", count: 64))
        let q = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: T, side: .buy, amountIn: 100_000, maxSlippageBps: 50, maxSources: 1),
            held: try held("[\(row("1")),\(dead)]"), sym: "TST", dec: 2
        )
        XCTAssertEqual(q.legs.map(\.poolId), [o])
    }

    func testTheSmallestMaxSourcesDoesNotTrap() throws {
        // TS `Math.max(0, maxSources - legs)` is 0 here; Swift's subtraction must not overflow.
        let q = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: T, side: .buy, amountIn: 100_000, maxSlippageBps: 50, maxSources: Int.min),
            held: try held("[\(row("1"))]"), sym: "TST", dec: 2
        )
        XCTAssertEqual(q.stage.feeSats, 1301)
    }

    func testANonTermsAnswerIsCutAt200Units() throws {
        let long = String(repeating: "x", count: 250)
        do {
            _ = try OpenExchange.parseSwapTerms(.string(long))
            XCTFail("expected a failure")
        } catch {
            // `JSON.stringify(x)?.slice(0, 200)`: the opening quote and 199 characters.
            XCTAssertEqual(error as? OpenExchangeError, .failed("relay: not swap terms: \"" + String(repeating: "x", count: 199)))
        }
    }

    func testRefusals() throws {
        let pools = try held("[\(row("1"))]")
        func message(_ req: OpenExchangeQuoteRequest, _ held: OpenExchangePools?) -> OpenExchangeError? {
            do {
                _ = try OpenExchangeQuotes.quoteSwap(req, held: held, sym: "TST", dec: 2)
                return nil
            } catch {
                return error as? OpenExchangeError
            }
        }
        XCTAssertEqual(message(.init(tokenId: T, side: .buy, amountIn: 0, maxSlippageBps: 50, maxSources: 1), pools), .failed("Enter an amount"))
        XCTAssertEqual(message(.init(tokenId: T, side: .buy, amountIn: 5, maxSlippageBps: 50, maxSources: 1), nil), .failed("No pool to swap against"))
        XCTAssertEqual(message(.init(tokenId: T, side: .buy, amountIn: 1, maxSlippageBps: 50, maxSources: 1), pools), .failed("The amount is too small to receive anything"))
        let withMin = try held("[\(row("1"))]", validators: #"[{"identity":"02aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peerId":"p","minLegSats":"25000"}]"#)
        XCTAssertEqual(
            message(.init(tokenId: T, side: .buy, amountIn: 24_999, maxSlippageBps: 50, maxSources: 1), withMin),
            .belowMinimum("No pool here takes a swap this small: at least 25000 sats.")
        )
    }
}
