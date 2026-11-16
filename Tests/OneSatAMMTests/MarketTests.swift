import Foundation
import XCTest
import BigInt
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatTemplates
@testable import OneSatAMM

// Vectors of skein-amm 0.55.1 (cc146be): web/engine/test/{pricing,balance}.test.ts and
// web/ui/test/{pool,oneColor,overlay,history,exchange,prices,swap}.test.ts, with the fixtures of
// web/ui/test/fixtures. Values the TS tests only check structurally (a multi-pool price, a
// split) are pinned to an independent Python reading of web/engine/src (IEEE doubles for the JS
// numbers, Python ints for the bigints), checked against the TS tests' own exact values.

private func pool(
    _ outpoint: String, bsv: BigInt = 10_000_000, tokens: BigInt = 10_000_000,
    lp: BigInt = 30, validator: BigInt = 5, commission: BigInt = 0, minLegSats: BigInt? = nil
) -> AMMPoolState {
    // test/helpers.ts makePool.
    AMMPoolState(
        outpoint: outpoint, bsvReserve: bsv, tokenReserve: tokens, liquidityFeeBps: lp,
        validationFeeBps: validator, commissionBps: commission, validatorIdentityKey: "validator-" + outpoint,
        minLegSats: minLegSats
    )
}

private func json(_ text: String) throws -> JSONValue {
    try XCTUnwrap(JSONValue.parse(Array(text.utf8)), "not JSON: \(text)")
}

private let noCost = AMMFixedCost(minerFeeSats: 0)

// MARK: - JS numerics

final class JSNumericsTests: XCTestCase {
    func testNumberOfBigIntRoundsToNearestEven() {
        XCTAssertEqual(JS.number(BigInt(1) << 53), 9_007_199_254_740_992)
        XCTAssertEqual(JS.number((BigInt(1) << 53) + 1), 9_007_199_254_740_992) // tie, to even
        XCTAssertEqual(JS.number((BigInt(1) << 53) + 3), 9_007_199_254_740_996) // tie, to even
        XCTAssertEqual(JS.number((BigInt(1) << 64) - 1), 18_446_744_073_709_551_616)
        XCTAssertEqual(JS.number(-((BigInt(1) << 53) + 1)), -9_007_199_254_740_992)
        XCTAssertEqual(JS.number(BigInt(1) << 1024), .infinity)
        XCTAssertEqual(JS.number(0), 0)
    }

    func testBigIntOfNumbersAndStrings() throws {
        XCTAssertEqual(try JS.bigInt(1e21), BigInt("1000000000000000000000"))
        XCTAssertEqual(try JS.bigInt(-0.0), 0)
        XCTAssertThrowsError(try JS.bigInt(1.5))
        XCTAssertThrowsError(try JS.bigInt(Double.nan))
        XCTAssertThrowsError(try JS.bigInt(Double.infinity))
        XCTAssertEqual(try JS.bigInt(" -12\n"), -12)
        XCTAssertEqual(try JS.bigInt("+7"), 7)
        XCTAssertEqual(try JS.bigInt(""), 0)
        XCTAssertEqual(try JS.bigInt("0x1F"), 31)
        XCTAssertEqual(try JS.bigInt("0b101"), 5)
        XCTAssertEqual(try JS.bigInt("0o17"), 15)
        XCTAssertThrowsError(try JS.bigInt("-0x1"))
        XCTAssertThrowsError(try JS.bigInt("1.0"))
        XCTAssertThrowsError(try JS.bigInt("1e3"))
        XCTAssertThrowsError(try JS.bigInt("0x"))
        XCTAssertEqual(try JS.bigInt(json("[]")), 0)
        XCTAssertEqual(try JS.bigInt(json(#"["5"]"#)), 5)
        XCTAssertEqual(try JS.bigInt(json("true")), 1)
        XCTAssertThrowsError(try JS.bigInt(json("null")))
        XCTAssertThrowsError(try JS.bigInt(json("{}")))
    }

    func testNumberOfStrings() throws {
        XCTAssertEqual(JS.number("  12.5 "), 12.5)
        XCTAssertEqual(JS.number("0x10"), 16)
        XCTAssertEqual(JS.number("1e3"), 1000)
        XCTAssertEqual(JS.number(".5"), 0.5)
        XCTAssertEqual(JS.number("5."), 5)
        XCTAssertEqual(JS.number(""), 0)
        XCTAssertEqual(JS.number("-Infinity"), -.infinity)
        XCTAssertTrue(JS.number("inf").isNaN)
        XCTAssertTrue(JS.number("abc").isNaN)
        XCTAssertTrue(JS.number("1_000").isNaN)
        XCTAssertEqual(JS.number(try json("null")), 0)
        XCTAssertEqual(JS.number(try json(#"["7"]"#)), 7)
        XCTAssertTrue(JS.number(try json("{}")).isNaN)
    }

    func testStringOfNumbersIsNumberToString() {
        XCTAssertEqual(JS.string(18_446_744_073_709_551_616.0), "18446744073709552000")
        XCTAssertEqual(JS.string(1e21), "1e+21")
        XCTAssertEqual(JS.string(1.5e300), "1.5e+300")
        XCTAssertEqual(JS.string(0.000001), "0.000001")
        XCTAssertEqual(JS.string(1e-7), "1e-7")
        XCTAssertEqual(JS.string(-1.5), "-1.5")
        XCTAssertEqual(JS.string(123.456), "123.456")
        XCTAssertEqual(JS.string(100), "100")
        XCTAssertEqual(JS.string(0.1 + 0.2), "0.30000000000000004")
        XCTAssertEqual(JS.string(.nan), "NaN")
        XCTAssertEqual(JS.string(-0.0), "0")
    }

    func testMathAndStrings() throws {
        XCTAssertEqual(JS.round(2.5), 3)
        XCTAssertEqual(JS.round(-2.5), -2)
        XCTAssertEqual(JS.round(9950.49383620783), 9950)
        XCTAssertEqual(JS.pow10(8), 100_000_000)
        XCTAssertEqual(JS.pow10(22), 1e22)
        // bigint `/` truncates toward zero; a zero divisor is a RangeError, thrown.
        XCTAssertEqual(BigInt(-7) / 2, -3)
        XCTAssertThrowsError(try AMMPricing.divide(1, 0))
        // UTF-16 code units: U+1F600 (D83D DE00) sorts before U+FF61.
        XCTAssertTrue(JS.less("\u{1F600}", "\u{FF61}"))
        XCTAssertFalse(JS.less("b", "a"))
        XCTAssertEqual(JS.prefix("abcdefghij", 8), "abcdefgh")
    }
}

// MARK: - pricing.test.ts

final class AMMPricingTests: XCTestCase {
    /// pool/Pool.runar.go's Swap arithmetic, as the TS test transcribes it.
    private func contractOracle(
        _ bsv: BigInt, _ tok: BigInt, _ lpBps: BigInt, _ valBps: BigInt, _ amountIn: BigInt, bsvIn: Bool
    ) -> (lpFee: BigInt, validatorFee: BigInt, net: BigInt, out: BigInt)? {
        let lpFee = (amountIn * lpBps + 9999) / 10000
        let validatorFee = (amountIn * valBps + 9999) / 10000
        let net = amountIn - lpFee - validatorFee
        guard net > 0 else { return nil }
        let out = bsvIn ? (net * tok) / (bsv + net) : (net * bsv) / (tok + net)
        guard out > 0 else { return nil }
        return (lpFee, validatorFee, net, out)
    }

    func testComputeSwapMatchesTheContract() throws {
        let cases: [(String, BigInt, BigInt, BigInt, BigInt, BigInt, AMMDirection)] = [
            ("simple token->bsv", 10_000_000, 5_000_000, 30, 5, 100_000, .tokenToBsv),
            ("simple bsv->token", 10_000_000, 5_000_000, 30, 5, 250_000, .bsvToToken),
            ("zero fees", 1_000_000, 1_000_000, 0, 0, 10_000, .tokenToBsv),
            ("large fees", 2_000_000, 8_000_000, 300, 200, 50_000, .bsvToToken),
            ("tiny amountIn", 1_000_000, 1_000_000, 30, 5, 7, .tokenToBsv),
            ("amountIn 1 rejected", 1_000_000, 1_000_000, 30, 5, 1, .tokenToBsv),
            ("asymmetric", 21_000_000, 100, 25, 5, 1_000_000, .bsvToToken),
            ("heavy impact", 1_000_000, 1_000_000, 30, 5, 5_000_000, .tokenToBsv),
            ("very large", 2_100_000_000_000_000, 21_000_000_000_000, 30, 5, 123_456_789_012, .bsvToToken),
        ]
        for (name, bsv, tok, lp, val, amountIn, direction) in cases {
            let p = pool("p:0", bsv: bsv, tokens: tok, lp: lp, validator: val)
            let actual = try AMMPricing.computeSwap(p, direction, amountIn)
            guard let oracle = contractOracle(bsv, tok, lp, val, amountIn, bsvIn: direction == .bsvToToken) else {
                XCTAssertNil(actual, name)
                continue
            }
            let r = try XCTUnwrap(actual, name)
            XCTAssertEqual(r.liquidityFee, oracle.lpFee, name)
            XCTAssertEqual(r.validationFee, oracle.validatorFee, name)
            XCTAssertEqual(r.commission, 0, name)
            XCTAssertEqual(r.net, oracle.net, name)
            XCTAssertEqual(r.amountOut, oracle.out, name)
            if direction == .tokenToBsv {
                XCTAssertEqual(r.newBsvReserve, bsv - oracle.out, name)
                XCTAssertEqual(r.newTokenReserve, tok + oracle.net, name)
            } else {
                XCTAssertEqual(r.newBsvReserve, bsv + oracle.net, name)
                XCTAssertEqual(r.newTokenReserve, tok - oracle.out, name)
            }
        }
        // "amountIn 1" is the one the fees consume.
        XCTAssertNil(contractOracle(1_000_000, 1_000_000, 30, 5, 1, bsvIn: false))
    }

    func testFeeAmountRoundsUp() {
        XCTAssertEqual(AMMPricing.feeAmount(1, 1), 1)
        XCTAssertEqual(AMMPricing.feeAmount(10_000, 1), 1)
        XCTAssertEqual(AMMPricing.feeAmount(10_001, 1), 2)
        XCTAssertEqual(AMMPricing.feeAmount(100, 0), 0)
        XCTAssertEqual(AMMPricing.feeAmount(1, 10), 1)
    }

    func testInvariants() throws {
        let p = pool("p:0", bsv: 1000, tokens: 1000)
        XCTAssertNil(try AMMPricing.computeSwap(p, .tokenToBsv, 0))
        XCTAssertNil(try AMMPricing.computeSwap(p, .tokenToBsv, -5))
        let huge = try XCTUnwrap(try AMMPricing.computeSwap(p, .tokenToBsv, 1_000_000_000))
        XCTAssertLessThan(huge.amountOut, p.bsvReserve)
    }

    func testCommission() throws {
        let pool0 = pool("p:0", bsv: 1_000_000, tokens: 5_000_000, commission: 10)
        let s1 = try XCTUnwrap(try AMMPricing.computeSwap(pool0, .bsvToToken, 20_000))
        XCTAssertEqual(s1, AMMSwapResult(
            liquidityFee: 60, validationFee: 10, commission: 20, net: 19_910, amountOut: 97_606,
            newBsvReserve: 1_019_910, newTokenReserve: 4_902_394
        ))
        var pool1 = pool0
        pool1.bsvReserve = s1.newBsvReserve
        pool1.tokenReserve = s1.newTokenReserve
        let s2 = try XCTUnwrap(try AMMPricing.computeSwap(pool1, .tokenToBsv, 50_000))
        XCTAssertEqual(s2.commission, 50)
        XCTAssertEqual([s2.newBsvReserve, s2.newTokenReserve], [1_009_659, 4_952_169])
        var free = pool0
        free.commissionBps = 0
        XCTAssertGreaterThan(try XCTUnwrap(try AMMPricing.computeSwap(free, .bsvToToken, 20_000)).amountOut, s1.amountOut)
        let eaten = pool("p:0", bsv: 1000, tokens: 1000, lp: 3000, validator: 3000, commission: 4000)
        XCTAssertNil(try AMMPricing.computeSwap(eaten, .bsvToToken, 100))
    }

    func testMinimumLeg() throws {
        let p = pool("p:0", bsv: 1_000_000, tokens: 5_000_000, minLegSats: 2_000)
        XCTAssertNil(try AMMPricing.acceptedSwap(p, .bsvToToken, 1_999))
        XCTAssertNotNil(try AMMPricing.acceptedSwap(p, .bsvToToken, 2_000))
        XCTAssertEqual(try AMMPricing.smallestAccepted(p, .bsvToToken), 2_000)
        // A sell's sats are what it pays out.
        let sell = try XCTUnwrap(try AMMPricing.smallestAccepted(p, .tokenToBsv))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(try AMMPricing.computeSwap(p, .tokenToBsv, sell)).amountOut, 2_000)
        XCTAssertNil(try AMMPricing.acceptedSwap(p, .tokenToBsv, sell - 1))
    }
}

// MARK: - balance.test.ts item 4 (price.ts) and the split it rests on

final class AMMPriceTests: XCTestCase {
    func testShareIs100Bps() {
        XCTAssertEqual(AMMPrice.shareBps, 100)
    }

    func testNoPoolNoPrice() throws {
        XCTAssertNil(try AMMPrice.of([]))
    }

    func testBuyAndSellAreTheSplitOfOnePercent() throws {
        let a = pool("a:0", bsv: 4_000_000, tokens: 8_000_000)
        let b = pool("b:0", bsv: 6_000_000, tokens: 12_000_000)
        let p = try XCTUnwrap(try AMMPrice.of([a, b]))
        let buyLegs = try AMMAllocation.planSplit([a, b], .bsvToToken, 100_000, noCost)
        let sellLegs = try AMMAllocation.planSplit([a, b], .tokenToBsv, 200_000, noCost)
        XCTAssertEqual(p.buy, AMMPricePair(sats: 100_000, tokens: buyLegs.reduce(0) { $0 + $1.amountOut }))
        XCTAssertEqual(p.sell, AMMPricePair(sats: sellLegs.reduce(0) { $0 + $1.amountOut }, tokens: 200_000))
        XCTAssertEqual(p.mid, AMMPricePair(
            sats: p.buy.sats * p.sell.tokens + p.sell.sats * p.buy.tokens, tokens: 2 * p.buy.tokens * p.sell.tokens
        ))
        XCTAssertGreaterThan(p.buy.sats * p.sell.tokens, p.sell.sats * p.buy.tokens)
        let mid = JS.number(p.mid.sats) / JS.number(p.mid.tokens)
        XCTAssertGreaterThan(mid, JS.number(p.sell.sats) / JS.number(p.sell.tokens))
        XCTAssertLessThan(mid, JS.number(p.buy.sats) / JS.number(p.buy.tokens))
        // Exact (the oracle).
        XCTAssertEqual(p, AMMPrice(
            buy: AMMPricePair(sats: 100_000, tokens: 197_333),
            sell: AMMPricePair(sats: 98_666, tokens: 200_000),
            mid: AMMPricePair(sats: 39_470_057_778, tokens: 78_933_200_000)
        ))
    }

    func testMinimumsAreNotApplied() throws {
        let a = pool("a:0", minLegSats: 10_000_000_000)
        let p = try AMMPrice.of([a])
        XCTAssertNotNil(p)
        XCTAssertEqual(p, try AMMPrice.of([pool("a:0")]))
    }

    func testAnotherShareAndAtLeastOne() throws {
        XCTAssertEqual(try AMMPrice.of([pool("a:0")], shareBps: 500)?.buy.sats, 500_000)
        XCTAssertNil(try AMMPrice.of([pool("t:0", bsv: 50, tokens: 50, lp: 0, validator: 0)]))
    }

    /// Exact prices from the oracle: one pool, a share of 5%, three pools, a commission, and
    /// reserves past 2^53 (where `Number(bigint)` rounds).
    func testOraclePrices() throws {
        func pair(_ s: String, _ t: String) -> AMMPricePair { AMMPricePair(sats: BigInt(s)!, tokens: BigInt(t)!) }
        XCTAssertEqual(try AMMPrice.of([pool("a:0")]), AMMPrice(
            buy: pair("100000", "98666"), sell: pair("98666", "100000"), mid: pair("19734979556", "19733200000")
        ))
        XCTAssertEqual(try AMMPrice.of([pool("a:0")], shareBps: 500), AMMPrice(
            buy: pair("500000", "474602"), sell: pair("474602", "500000"), mid: pair("475247058404", "474602000000")
        ))
        let three = [
            pool("a:0", bsv: 1_000_000, tokens: 5_000_000), pool("b:0", bsv: 1_200_000, tokens: 6_000_000),
            pool("c:0", bsv: 900_000, tokens: 4_500_000),
        ]
        XCTAssertEqual(try AMMPrice.of(three), AMMPrice(
            buy: pair("31000", "152930"), sell: pair("30585", "155000"), mid: pair("9482364050", "47408300000")
        ))
        XCTAssertEqual(try AMMPrice.of([pool("p:0", bsv: 1_000_000, tokens: 5_000_000, commission: 10)]), AMMPrice(
            buy: pair("10000", "49284"), sell: pair("9856", "50000"), mid: pair("985743104", "4928400000")
        ))
        let wide = [
            pool("x:0", bsv: 2_100_000_000_000_000, tokens: 21_000_000_000_000, lp: 25, validator: 5, commission: 10),
            pool("y:0", bsv: 3_000_000_000, tokens: 40_000_000, lp: 30, validator: 5),
            pool("z:0", bsv: 777_777, tokens: 123_456_789, lp: 100, validator: 20, commission: 5),
        ]
        XCTAssertEqual(try AMMPrice.of(wide), AMMPrice(
            buy: pair("21000030007777", "207219934329"), sell: pair("20709890685931", "210001634567"),
            mid: pair("8701542815488610306252858", "87033049847912792701086")
        ))
    }

    func testSplitVectors() throws {
        let three = [
            pool("a:0", bsv: 1_000_000, tokens: 5_000_000), pool("b:0", bsv: 1_200_000, tokens: 6_000_000),
            pool("c:0", bsv: 900_000, tokens: 4_500_000),
        ]
        func leg(_ o: String, _ i: BigInt, _ lf: BigInt, _ vf: BigInt, _ out: BigInt, _ nb: BigInt, _ nt: BigInt) -> AMMLeg {
            AMMLeg(outpoint: o, amountIn: i, liquidityFee: lf, validationFee: vf, commission: 0, amountOut: out, newBsvReserve: nb, newTokenReserve: nt)
        }
        XCTAssertEqual(try AMMAllocation.planSplit(three, .bsvToToken, 600_000, noCost, maxSources: 5), [
            leg("a:0", 193_548, 581, 97, 808_428, 1_192_870, 4_191_572),
            leg("b:0", 232_258, 697, 117, 970_114, 1_431_444, 5_029_886),
            leg("c:0", 174_194, 523, 88, 727_585, 1_073_583, 3_772_415),
        ])
        XCTAssertEqual(try AMMAllocation.planSplit(three, .bsvToToken, 600_000, noCost, maxSources: 2), [
            leg("a:0", 272_727, 819, 137, 1_068_474, 1_271_771, 3_931_526),
            leg("b:0", 327_273, 982, 164, 1_282_175, 1_526_127, 4_717_825),
        ])
        XCTAssertEqual(try AMMAllocation.planSplit(three, .bsvToToken, 600_000, noCost, maxSources: 1), [
            leg("a:0", 600_000, 1_800, 300, 1_870_893, 1_597_900, 3_129_107),
        ])
        XCTAssertEqual(try AMMAllocation.planSplit(three, .tokenToBsv, 2_000_000, AMMFixedCost(minerFeeSats: 5_000)), [
            leg("a:0", 645_161, 1_936, 323, 113_931, 886_069, 5_642_902),
            leg("b:0", 774_194, 2_323, 388, 136_717, 1_063_283, 6_771_483),
            leg("c:0", 580_645, 1_742, 291, 102_538, 797_462, 5_078_612),
        ])
        // A leg under its pool's minimum folds into the other.
        var withMin = three
        withMin[1].minLegSats = 150_000
        XCTAssertEqual(try AMMAllocation.planSplit(withMin, .bsvToToken, 200_000, noCost, maxSources: 2), [
            leg("a:0", 200_000, 600, 100, 830_901, 1_199_300, 4_169_099),
        ])
        // balance.test item 1: a heavy per-leg cost keeps one leg; the free split pays more.
        let a = pool("a:0", bsv: 5_000_000, tokens: 5_000_000)
        let b = pool("b:0", bsv: 5_000_000, tokens: 5_000_000)
        let one = try AMMAllocation.planSplit([a, b], .bsvToToken, 1_000_000, AMMFixedCost(minerFeeSats: 10_000_000))
        XCTAssertEqual(one, [leg("a:0", 1_000_000, 3_000, 500, 830_901, 5_996_500, 4_169_099)])
        XCTAssertGreaterThan(try AMMAllocation.quoteMid([a, b], .bsvToToken, 1_000_000), one[0].amountOut)
    }
}

// MARK: - pool.test.ts and oneColor.test.ts (decode)

final class AMMPoolDecodeTests: XCTestCase {
    private struct Vectors {
        let raw: [String: Any]
        subscript(_ key: String) -> String { raw[key] as? String ?? "" }
        func pool(_ key: String) -> (bsv: Int, tokens: Int, validator: String) {
            let p = raw[key] as? [String: Any] ?? [:]
            return (p["bsv"] as? Int ?? -1, p["tokens"] as? Int ?? -1, p["validator"] as? String ?? "")
        }
        func int(_ key: String) -> Int { raw[key] as? Int ?? -1 }
    }

    private func vectors(_ name: String) throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return Vectors(raw: try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]))
    }

    private func tx(_ hex: String) throws -> Transaction {
        try Transaction(bytes: try Hex.decode(hex, maximumDecodedByteCount: hex.utf8.count / 2), limits: txLimits)
    }

    func testThePoolsOfTheFixtures() throws {
        let v = try vectors("amm-topic-vectors")
        let assetId = Hex.encode(try tx(v["token_deploy"]).transactionID(limits: txLimits).wireBytes)
        // key(10): 32 bytes of 0x0a.
        let lp = Hex.encode(try PrivateKey([UInt8](repeating: 0x0a, count: 32)).publicKey.compressedBytes)
        XCTAssertEqual(lp, v["lp"])
        for (name, key) in [("pool_deploy", "pool0"), ("swap_bsv_in", "pool1"), ("swap_tokens_in", "pool2")] {
            let t = try tx(v[name])
            let p = v.pool(key)
            let decoded = try XCTUnwrap(AMMPool.decode(t.outputs[0].lockingScript), name)
            XCTAssertEqual(t.outputs[0].satoshis, UInt64(p.bsv))
            XCTAssertEqual(decoded.version, 3)
            XCTAssertEqual(decoded.args, AMMPoolArgs(
                assetId: assetId, lpFeeBps: BigInt(v.int("lpFeeBps")), validatorFeeBps: BigInt(v.int("validatorFeeBps")),
                commissionBps: BigInt(v.int("commissionBps"))
            ))
            XCTAssertEqual(decoded.state, AMMPoolFields(
                tokenReserve: BigInt(p.tokens), lpPubKey: lp, validatorPubKey: p.validator, validatorIdentity: v["identity"],
                nonce: v["nonce"], lpSatsPkh: v["lpSatsPkh"], lpTokenPkh: v["lpTokenPkh"], affirmation: v["affirmation"]
            ))
            XCTAssertFalse(decoded.rescinded)
            XCTAssertTrue(decoded.contractScript.hasPrefix(decoded.code))
            XCTAssertEqual(AMMPool.decode(t.outputs[0].lockingScript.bytes), decoded)
        }
    }

    func testEveryOtherOutputIsNoPool() throws {
        let v = try vectors("amm-topic-vectors")
        for name in ["fund", "token_deploy", "pool_deploy", "swap_bsv_in", "swap_tokens_in", "close", "close_rescinded"] {
            for (i, o) in try tx(v[name]).outputs.enumerated() {
                if i == 0 && name != "fund" && name != "token_deploy" { continue }
                XCTAssertNil(AMMPool.decode(o.lockingScript), "\(name) output \(i)")
            }
        }
    }

    func testAPrefixThatDisagreesWithTheState() throws {
        let v = try vectors("amm-topic-vectors")
        let hex = Hex.encode(try tx(v["pool_deploy"]).outputs[0].lockingScript.bytes)
        let bytes = Array(hex.utf8)
        XCTAssertEqual(String(decoding: bytes[66..<74], as: UTF8.self), "03404b4c")
        let tampered = String(decoding: bytes[..<66], as: UTF8.self) + "03414b4c" + String(decoding: bytes[74...], as: UTF8.self)
        XCTAssertNil(AMMPool.decode(try Hex.decode(tampered, maximumDecodedByteCount: tampered.utf8.count / 2)))
    }

    func testOtherDeploysStillDecodeAndTheRescind() throws {
        let v = try vectors("amm-topic-vectors")
        for name in ["pool_deploy_unaffirmed", "pool_deploy_forged", "pool_deploy_own_key"] {
            XCTAssertNotNil(AMMPool.decode(try tx(v[name]).outputs[0].lockingScript), name)
        }
        let rescind = try tx(v["rescind"])
        let r = try XCTUnwrap(AMMPool.decode(rescind.outputs[0].lockingScript))
        XCTAssertTrue(r.rescinded)
        XCTAssertEqual(r.state.validatorPubKey, AMMPool.rescindedKey)
        XCTAssertEqual(r.state.tokenReserve, BigInt(v.pool("pool2").tokens))
        XCTAssertEqual(rescind.outputs[0].satoshis, UInt64(v.pool("pool2").bsv))
        XCTAssertFalse(try XCTUnwrap(AMMPool.decode(try tx(v["swap_tokens_in"]).outputs[0].lockingScript)).rescinded)
    }

    func testALayoutOnePoolIsNoPool() throws {
        let v1 = try vectors("amm-topic-vectors-v1")
        for name in ["pool_deploy", "swap_tokens_in"] {
            XCTAssertNil(AMMPool.decode(try tx(v1[name]).outputs[0].lockingScript), name)
        }
    }

    // oneColor.test.ts, the decode half.
    private let id = [UInt8](repeating: 0x11, count: 32)
    private let p2pkh: [UInt8] = [0x76, 0xa9, 0x14] + [UInt8](repeating: 0x22, count: 20) + [0x88, 0xac]

    func testOneColorValuePrefixes() throws {
        let pushes: [(UInt64, [UInt8])] = [
            (1, [0x51]), (16, [0x60]), (17, [1, 0x11]), (255, [2, 0xff, 0x00]), (256, [2, 0x00, 0x01]),
            (1_000_000, [3, 0x40, 0x42, 0x0f]), (UInt64.max, [9] + [UInt8](repeating: 0xff, count: 8) + [0x00]),
        ]
        for (amount, push) in pushes {
            let script = [0x20] + id + push + [0x6d] + p2pkh
            let t = try XCTUnwrap(AMMPool.decodeOneColor(script), "\(amount)")
            XCTAssertEqual(t.role, .value)
            XCTAssertEqual(t.amount, amount)
            XCTAssertEqual(t.idBytes, id)
            XCTAssertEqual(Array(script[t.length...]), p2pkh)
        }
    }

    func testOneColorDeployAuthorityAndPayload() throws {
        XCTAssertEqual(AMMPool.decodeOneColor([0x00, 0x51, 0x6d] + p2pkh)?.role, .deploy)
        XCTAssertEqual(AMMPool.decodeOneColor([0x20] + id + [0x00, 0x6d] + p2pkh)?.role, .authority)
        let withPayload = try XCTUnwrap(AMMPool.decodeOneColor([0x20] + id + [0x51, 0x6d, 0x02, 0xaa, 0xbb, 0x75] + p2pkh))
        XCTAssertEqual(withPayload.payload, [0xaa, 0xbb])
        XCTAssertEqual(withPayload.length, 33 + 1 + 1 + 4)
    }

    func testOneColorRefusals() {
        XCTAssertNil(AMMPool.decodeOneColor([0x20] + id + [0x01, 0x05, 0x6d]))
        XCTAssertNil(AMMPool.decodeOneColor([0x20] + id + [0x02, 0x11, 0x00, 0x6d]))
        XCTAssertNil(AMMPool.decodeOneColor([0x4c, 0x20] + id + [0x51, 0x6d]))
        XCTAssertNil(AMMPool.decodeOneColor([0x24] + id + [0, 0, 0, 0, 0x51, 0x6d]))
        XCTAssertNil(AMMPool.decodeOneColor([0x20] + id + [0x51, 0x75]))
    }

    func testArtifactIsTheVendoredOne() {
        let template = Runar.hexBytes(PoolArtifact.templateHex)
        XCTAssertEqual(template.count, 3773)
        XCTAssertEqual(Hex.encode(BSVHashing.sha256(template).bytes), "5c2f71f05f4bcbe7c002f6ba7240aa97d9e80f2338fb37d33b2caf44f1175c7b")
        // The code-separator slots resolved (pool/artifact.ts resolveCodeSepSlots), nothing else.
        let resolved = Runar.pool.script
        XCTAssertEqual(resolved.count, template.count)
        let changed = resolved.indices.filter { resolved[$0] != template[$0] }
        XCTAssertEqual(changed, [608, 2704, 3371])
        XCTAssertEqual(changed.map { resolved[$0] }, [0x51, 0x51, 0x51])
    }
}

// MARK: - overlay.test.ts, history.test.ts, exchange.test.ts

private let K = "03142715675faf8da1ecc4d51e0b9e539fa0d52fdd96ed60dbe99adb15d6b05ad9"
private let LP = "02" + String(repeating: "aa", count: 32)
private let PEER = "16Uiu2HAm6mP74uTowae2xMtAKJpqw1Dt2NhcgSdXgyDoyfmkwGqq"
private let T = String(repeating: "11", count: 32) + "_0"
private let U = String(repeating: "cd", count: 32) + "_0"

/// A wire row: `base` with `extra`'s keys over it (`{...base, ...extra}`); `nil` drops a key
/// (TS's `undefined`), `NSNull()` is null.
private func wire(_ base: [String: Any], _ extra: [String: Any?]) -> String {
    var row = base
    for (key, value) in extra { row[key] = value }
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func poolRow(_ outpoint: String, _ extra: [String: Any?] = [:]) -> String {
    wire([
        "poolId": "dd_0", "lpPubKey": LP, "swaps": 3, "outpoint": outpoint, "bsvReserve": 1_000_000,
        "tokenReserve": 5_000_000, "liquidityFeeBps": 30, "validationFeeBps": 5, "commissionBps": 10,
        "validatorIdentityKey": K,
    ], extra)
}

private func statsRow(_ tokenId: String, _ extra: [String: Any?] = [:]) -> String {
    wire([
        "tokenId": tokenId, "price": ["sats": 20000, "tokens": 97606], "buyPrice": ["sats": 20100, "tokens": 97606],
        "sellPrice": ["sats": 19900, "tokens": 97606], "lastTradePrice": ["sats": 20000, "tokens": 97000],
        "change1h": 125, "change24h": -310, "volume24hSats": 41230, "volume24hTokens": 200_811, "buys24h": 3,
        "sells24h": 1, "lastTradeAt": 1_793_000_000_000, "tvlSats": 2_019_910, "tvlTokens": 9_902_394, "pools": 2,
        "volumeSats": 512_345, "volumeTokens": 2_600_000, "trades": 41,
    ], extra)
}

private let expectedStats = OpenExchangeTokenStats(
    tokenId: T, price: AMMPricePair(sats: 20000, tokens: 97606), buyPrice: AMMPricePair(sats: 20100, tokens: 97606),
    sellPrice: AMMPricePair(sats: 19900, tokens: 97606), lastTradePrice: AMMPricePair(sats: 20000, tokens: 97000),
    change1h: 125, change24h: -310, volume24hSats: 41230, volume24hTokens: 200811, buys24h: 3, sells24h: 1,
    lastTradeAt: 1_793_000_000_000, tvlSats: 2_019_910, tvlTokens: 9_902_394, pools: 2, volumeSats: 512_345,
    volumeTokens: 2_600_000, trades: 41
)

final class OpenExchangeMarketReadTests: XCTestCase {
    func testParsePools() throws {
        let a = try OpenExchangePools.read(try json("""
        {"market":{"identityKey":"02\(String(repeating: "AB", count: 32))","minCommissionBps":5},
         "validators":[{"identity":"\(K.uppercased())","peerId":"\(PEER)","minLegSats":2000},{"identity":"\(LP)","peerId":"\(PEER)","minLegSats":0},{"junk":1}],
         "pools":[\(poolRow("aa_0", ["validatorPeerId": PEER])),{"junk":true}]}
        """))
        XCTAssertEqual(a.market, .init(identityKey: "02" + String(repeating: "ab", count: 32), minCommissionBps: 5))
        XCTAssertEqual(a.validators, [.init(identity: K, peerId: PEER, minLegSats: 2000), .init(identity: LP, peerId: PEER, minLegSats: nil)])
        XCTAssertEqual(a.pools, [OpenExchangePoolRow(
            pool: AMMPoolState(
                outpoint: "aa_0", bsvReserve: 1_000_000, tokenReserve: 5_000_000, liquidityFeeBps: 30, validationFeeBps: 5,
                commissionBps: 10, validatorIdentityKey: K
            ),
            poolId: "dd_0", lpPubKey: LP, swaps: 3, validatorPeerId: PEER, tokenId: nil
        )])
        XCTAssertEqual(try OpenExchangePools.read(try json(#"{"pools":[]}"#)), .empty)
        XCTAssertEqual(try OpenExchangePoolRow.read(try json(poolRow("x_0", ["commissionBps": nil])))?.pool.commissionBps, 0)
        XCTAssertEqual(try OpenExchangePoolRow.read(try json(poolRow("x_0", ["bsvReserve": "7"])))?.pool.bsvReserve, 7)
        // `BigInt(1.5)` throws in TS too.
        XCTAssertThrowsError(try OpenExchangePoolRow.read(try json(poolRow("x_0", ["bsvReserve": 1.5]))))
        // A pool's validator minimum, onto the engine's pool.
        let withMin = OpenExchangePrices.poolsWithMinimums(a)
        XCTAssertEqual(withMin[0].pool.minLegSats, 2000)
    }

    func testStatsAndStatsAll() async throws {
        let http = StubHTTP()
        await http.json("https://swap.example/@\(T)/amm/stats", statsRow(T))
        let all = "[\(statsRow(T)),\(statsRow(U, ["price": NSNull(), "change1h": NSNull()])),{\"junk\":1}]"
        await http.json("https://swap.example/amm/stats", all)
        await http.json("https://swap.example/amm/stats?ids=\(T)", "[\(statsRow(T))]")
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        let one = try await exchange.stats(T)
        XCTAssertEqual(one, expectedStats)
        let rows = try await exchange.statsAll()
        XCTAssertEqual(rows.count, 2)
        XCTAssertNil(rows[1].price)
        XCTAssertNil(rows[1].change1h)
        XCTAssertEqual(rows[1].change24h, -310)
        let some = try await exchange.statsAll(ids: [T])
        XCTAssertEqual(some, [expectedStats])
        let urls = await http.urls
        XCTAssertEqual(urls, [
            "https://swap.example/@\(T)/amm/stats", "https://swap.example/amm/stats", "https://swap.example/amm/stats?ids=\(T)",
        ])
    }

    func testTokenPools() async throws {
        let http = StubHTTP()
        let row = poolRow(String(repeating: "ab", count: 32) + "_0")
        await http.json("https://swap.example/@\(T)/amm/pools", #"{"market":{},"pools":["# + row + "]}")
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        let answer = try await exchange.tokenPools(T)
        XCTAssertEqual(answer.pools.count, 1)
        XCTAssertEqual(OpenExchangePrices.poolViews(answer, tokenId: T), [OpenExchangePoolView(
            outpoint: String(repeating: "ab", count: 32) + ".0", poolId: "dd_0", tokenId: T, sats: 1_000_000, tokens: 5_000_000,
            validator: .init(identityKey: K, live: true)
        )])
        XCTAssertEqual(OpenExchangePrices.poolViews(nil, tokenId: T), [])
        XCTAssertEqual(OpenExchangePrices.poolFees(answer.pools[0].pool), OpenExchangeFees(lpBps: 30, validatorBps: 5, commissionBps: 10))
    }

    private func token(_ id: String, sym: String = "TST", dec: Int = 2, status: OpenExchangeToken.Status = .enabled, topic: String? = nil) -> OpenExchangeToken {
        let txid = String(id.prefix(64))
        return OpenExchangeToken(tokenId: id, topic: topic ?? "tm_color_\(txid)_0", sym: sym, dec: dec, icon: nil, status: status, since: 0)
    }

    func testHostedFrom() throws {
        let list = [
            token(T), token(U, sym: ""), token(String(repeating: "ee", count: 32) + "_0", status: .disabled),
            token(String(repeating: "ff", count: 32) + "_1", topic: "tm_color_" + String(repeating: "ff", count: 32) + "_1"),
        ]
        let stats = try XCTUnwrap(try OpenExchangeTokenStats.read(try json(statsRow(T))))
        let hosted = try OpenExchangePrices.hostedFrom(list, stats: [stats])
        XCTAssertEqual(hosted.map(\.tokenId), [T, U])
        XCTAssertEqual(hosted[0].reserves, OpenExchangeReserves(sats: 2_019_910, tokens: 9_902_394))
        XCTAssertEqual(hosted[0].pools, 2)
        XCTAssertEqual(hosted[0].marginalPrice, 20000 / (97606 / 100.0))
        XCTAssertEqual(hosted[0].depth, try OpenExchangePrices.depthOf(2_019_910))
        XCTAssertEqual(hosted[0].stats, stats)
        XCTAssertEqual(hosted[1].sym, "cdcdcdcd")
        XCTAssertNil(hosted[1].marginalPrice)
        XCTAssertNil(hosted[1].depth)
        XCTAssertEqual(hosted[1].pools, 0)
        XCTAssertEqual(hosted[1].reserves, OpenExchangeReserves(sats: 0, tokens: 0))
        // Not read yet: no prices.
        XCTAssertNil(try OpenExchangePrices.hostedFrom(list, stats: nil)[0].marginalPrice)
        // The price is the stats' pair per base unit: 3 sats per 200 units at 2 decimals.
        let other = try XCTUnwrap(try OpenExchangeTokenStats.read(try json(statsRow(U, ["price": ["sats": 3, "tokens": 200], "pools": 1]))))
        let priced = try OpenExchangePrices.hostedFrom(list, stats: [other])[1]
        XCTAssertEqual(priced.marginalPrice, 1.5)
        XCTAssertEqual(priced.pools, 1)
    }

    func testHostedTokensReadsTheListAndTheStatsOnce() async throws {
        let http = StubHTTP()
        await http.json("https://swap.example/amm/tokens", #"[{"tokenId":"\#(T)","topic":"tm_color_\#(String(T.prefix(64)))_0","sym":"TST","dec":0,"status":"enabled"}]"#)
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        // The stats read fails (404): every token unpriced.
        let unpriced = try await exchange.hostedTokens()
        XCTAssertEqual(unpriced.map(\.tokenId), [T])
        XCTAssertNil(unpriced[0].marginalPrice)
        await http.json("https://swap.example/amm/stats", "[\(statsRow(T))]")
        let priced = try await exchange.hostedTokens()
        XCTAssertEqual(priced[0].marginalPrice, 20000 / 97606.0)
        let urls = await http.urls
        XCTAssertEqual(Set(urls), ["https://swap.example/amm/tokens", "https://swap.example/amm/stats"])
        XCTAssertEqual(urls.count, 4)
    }

    func testDiscoverySearchAndSearchTokens() async throws {
        let http = StubHTTP()
        let base = "https://swap.example/@discovery/1color/tokens"
        await http.json("\(base)?q=te+s%2Bt&limit=100&after=\(U)", "[]")
        await http.json("\(base)?q=ts&limit=5", """
        [{"tokenId":"\(T)","sym":"TST","dec":2,"iconUrl":"/@discovery/1color/\(T)/icon","amount":"21000000","height":900},
         {"tokenId":"\(U)","amount":12.5,"dec":1.5},
         {"sym":"X"}]
        """)
        let exchange = try OpenExchange(origin: "https://swap.example", http: http)
        _ = try await exchange.discoverySearch("te s+t", limit: 500, after: U)
        let rows = try await exchange.discoverySearch("ts", limit: 5)
        XCTAssertEqual(rows, [
            OpenExchangeDiscoveryRow(tokenId: T, sym: "TST", dec: 2, icon: "https://swap.example/@discovery/1color/\(T)/icon", amount: 21_000_000, height: 900),
            OpenExchangeDiscoveryRow(tokenId: U, sym: nil, dec: nil, icon: nil, amount: 0, height: nil),
        ])

        // Local hits first (symbol contains, id prefix), then discovery's not among them.
        let hosted = try OpenExchangePrices.hostedFrom([token(T, sym: "TST")], stats: nil)
        let hits = await exchange.searchTokens(" ts ", in: hosted, limit: 5)
        XCTAssertEqual(hits.map(\.tokenId), [T, U])
        XCTAssertEqual(hits.map(\.listed), [true, false])
        XCTAssertEqual(hits[0].hosted, hosted[0])
        XCTAssertEqual(hits[1].sym, "cdcdcdcd")
        XCTAssertEqual(hits[1].dec, 0)
        let none = await exchange.searchTokens("  ", in: hosted)
        XCTAssertEqual(none, [])
        // Discovery down: the local hits.
        let local = await exchange.searchTokens("1111", in: hosted)
        XCTAssertEqual(local.map(\.tokenId), [T])
    }
}

// MARK: - prices.test.ts, swap.test.ts (view.ts), the filter, USD

final class OpenExchangePricesTests: XCTestCase {
    func testDepth() throws {
        XCTAssertEqual(try OpenExchangePrices.depthOf(1_000_000), OpenExchangeDepth(bps: 200, sats: 9950))
        XCTAssertNil(try OpenExchangePrices.depthOf(0))
    }

    func testMarginalPriceIsExact() throws {
        XCTAssertEqual(try OpenExchangePrices.marginalPrice(bsvReserve: 1_000_000, tokenReserve: 5_000_000, dec: 0), "0.2")
        XCTAssertEqual(try OpenExchangePrices.marginalPrice(bsvReserve: 1, tokenReserve: 3, dec: 8), "33333333.33333333")
        XCTAssertEqual(try OpenExchangePrices.marginalPrice(bsvReserve: 5, tokenReserve: 0), "—")
        XCTAssertEqual(try OpenExchangePrices.priceText(sats: 0, tokens: 5), "—")
        XCTAssertEqual(try OpenExchangePrices.priceText(sats: 20_000, tokens: 97_606, dec: 2), "20.49054361")
        XCTAssertEqual(try OpenExchangePrices.formatAmount(-1_050, dec: 2), "-10.5")
        XCTAssertThrowsError(try OpenExchangePrices.formatAmount(1, dec: 19))
    }

    func testPairPrice() {
        XCTAssertEqual(OpenExchangePrices.pairPrice(AMMPricePair(sats: 3, tokens: 200), dec: 2), 1.5)
        XCTAssertEqual(OpenExchangePrices.pairPrice(AMMPricePair(sats: 3, tokens: 0), dec: 2), 0)
    }

    private func hosted(_ id: String, _ sym: String) throws -> OpenExchangeHostedToken {
        let t = OpenExchangeToken(tokenId: id, topic: "tm_color_\(id.prefix(64))_0", sym: sym, dec: 0, icon: nil, status: .enabled, since: 0)
        return try OpenExchangePrices.hostedFrom([t], stats: nil)[0]
    }

    func testFilter() throws {
        let a = try hosted(T, "Gold")
        let b = try hosted(U, "SILVER")
        let c = try hosted(String(repeating: "ab", count: 32) + "_0", "ŞAHİN")
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: ""), [a, b, c])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: "  "), [a, b, c])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: "LV"), [b])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: " old "), [a])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: "CDCD"), [b])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: "dcd"), [])
        XCTAssertEqual(OpenExchangePrices.filter([a, b, c], query: "şah"), [c])
    }

    func testUSD() throws {
        let price = AMMPricePair(sats: 3, tokens: 200)
        XCTAssertEqual(OpenExchangePrices.priceUSD(price, dec: 2, usdPerBSV: 50), 7.499999999999999e-07)
        XCTAssertEqual(OpenExchangePrices.valueUSD(amount: 12_345, dec: 2, priceUSD: 7.499999999999999e-07), 9.25875e-05)

        let stats = try XCTUnwrap(try OpenExchangeTokenStats.read(try json(statsRow(T, ["price": ["sats": 3, "tokens": 200]]))))
        let m = try OpenExchangePrices.market(stats: stats, pools: nil, dec: 2, usdPerBSV: 50)
        XCTAssertEqual(m.priceUSD, 7.499999999999999e-07)
        XCTAssertEqual(m.priceBSV, 1.5e-08)
        XCTAssertEqual(m.change24h, -3.1)
        XCTAssertEqual(m.change1h, 1.25)
        XCTAssertEqual(m.liquidityUSD, 1.0842229550000002)
        XCTAssertEqual(m.volume24hUSD, 0.020615)
        XCTAssertEqual(m.buys24h, 3)
        XCTAssertEqual(m.sells24h, 1)
        XCTAssertEqual(m.buyVolume24hUSD, 0.015461250000000001)
        XCTAssertEqual(m.sellVolume24hUSD, 0.00515375)

        // Pools given: the engine's mid over them, their reserves the liquidity.
        let pools = [pool("p:0", bsv: 1_000_000, tokens: 5_000_000, commission: 10)]
        XCTAssertEqual(try OpenExchangePrices.spotSatsPerToken(pools: pools, statsPrice: nil, dec: 0), 0.20001280415550685)
        let live = try OpenExchangePrices.market(stats: nil, pools: pools, dec: 0, usdPerBSV: 40)
        XCTAssertEqual(live.priceUSD, 8.000512166220273e-08)
        XCTAssertEqual(live.liquidityUSD, 0.8000256083110137)
        XCTAssertTrue(live.change24h.isNaN)
        XCTAssertEqual(live.volume24hUSD, 0)
        XCTAssertEqual(live.buyVolume24hUSD, 0)
        // Neither: no price.
        XCTAssertEqual(try OpenExchangePrices.spotSatsPerToken(pools: [], statsPrice: nil, dec: 0), 0)
    }
}
