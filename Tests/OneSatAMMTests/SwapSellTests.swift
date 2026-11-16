import Foundation
import XCTest
import BigInt
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxStorage
import OneSatColor
import OneSatTemplates
@testable import OneSatAMM

// The sell (tokenToBsv) against skein-amm 0.55.1 (cc146be): market/swapAction.ts (`tokenInputsOf`,
// `selectLegInputs`, `prepareSwap` and `takeInOutputs` of a sell, `submissionBeef`),
// market/activeSwap.ts (`stage` with tokens, `moveBack`, `unfiledStagedTokens`, `fileStagedToken`,
// `swapKeyDescription`), lp/close.ts (`submitToOverlay`, `steakText`), wallet/swapPayouts.ts
// (`legTakeInOf` of a sell) and client.ts (`runSwap` of a sell, `settleSwaps`). The vectors are
// Fixtures/amm-swap-vectors.json (`sellLegs`, `sellTakeIn`, `sellLoop`, `stageTokens`,
// `moveBackTokens`, `unfiled`, `submit`); the HTTP is StubHTTP, the wallet MemoryStorage, the
// overlay StubOverlay: nothing here reaches a network.
//
// The states of a sell: staged and never sent (the tokens and sats moved back), sent and paid
// out with no answer (the pass takes it in), refused (the pool excluded or repriced, then the
// tokens and sats moved back), a payout the wallet did not take in (stuck, the rows kept).

enum SellFixture {
    static var legs: [[String: Any]] { SwapFixture.vectors["sellLegs"] as! [[String: Any]] }
    static var loop: [String: Any] { SwapFixture.vectors["sellLoop"] as! [String: Any] }
    static var assetID: ColorAssetID { AMMTokenID.parse(SwapFixture.tokenId)! }
    static var topic: String { "tm_color_\(SwapFixture.tokenId)" }
    static var basket: String { ColorIdentifiers.basket(assetID, role: .value) }

    static func steakJSON(_ outputs: [Int] = [0]) -> String {
        #"{"\#(topic)":{"outputsToAdmit":[\#(outputs.map(String.init).joined(separator: ","))],"coinsToRetain":[],"coinsRemoved":[]}}"#
    }

    static func context(_ storage: MemoryStorage, _ overlay: StubOverlay?) -> OneColorContext {
        OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000,
            overlay: overlay
        )
    }

    /// A transaction spending fund:1 (unsigned: nothing here validates it) whose output 0 is `script`.
    static func tokenTx(_ script: [UInt8], marker: UInt32 = 1) throws -> Transaction {
        let fund = try SwapFixture.topicTx("fund")
        return Transaction(
            version: 1,
            inputs: [TransactionInput(
                previousOutput: Outpoint(transactionID: try fund.transactionID(limits: txLimits), outputIndex: 1),
                unlockingScript: try Script(bytes: [], maximumByteCount: 10), sequence: 0xffff_ffff - marker
            )],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: script, maximumByteCount: 1000))],
            lockTime: 0
        )
    }

    /// `tx`'s Atomic BEEF, its parents txid-only.
    static func atomic(_ tx: Transaction) throws -> [UInt8] {
        try AtomicBEEF(subjectTransactionID: try tx.transactionID(limits: txLimits), beef: try boundedGraph([tx]), limits: beefLimits)
            .serialized(limits: beefLimits)
    }

    /// A `p color` value row of `amount` in the wallet, locked to its own module key, admitted
    /// and unspent on the overlay.
    static func holdColor(_ ctx: OneColorContext, _ storage: MemoryStorage, _ overlay: StubOverlay, amount: BigInt) async throws -> Transaction {
        let custody = try ColorCustody(
            asset: .asset(assetID), derivationPrefix: Data("held".utf8).base64EncodedString(),
            derivationSuffix: Data("row-\(amount)".utf8).base64EncodedString(), senderIdentityKey: ctx.identityKey
        )
        let key = try ColorKeys.ownPublicKey(identity: ctx.identity, custody: custody)
        let script = try AMMPoolCall.tokenP2pkh(AMMPool.hex(try OneColor.idFromString(SwapFixture.tokenId)), amount, OpenExchangeSwapLeg.pkh(key))
        let tx = try tokenTx(script, marker: 7)
        try await storage.holdColor(tx, vout: 0, assetID: assetID, custody: custody, sources: [try SwapFixture.topicTx("fund")])
        try await overlay.unspent(tx, vout: 0)
        return tx
    }
}

/// One sell case of the vectors, rebuilt: its token rows and sats rows in the swap basket.
struct SellWorld {
    let c: [String: Any]
    let storage: MemoryStorage
    let overlay: StubOverlay
    let ctx: OneColorContext
    let input: OpenExchangeSwapLeg.LegInput
    let sats: [OpenExchangeSatsRow]
    let tokens: [OpenExchangeTokenRow]
    let holding: BEEF

    init(_ c: [String: Any]) async throws {
        self.c = c
        storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        overlay = try StubOverlay()
        let fund = try SwapFixture.topicTx("fund")
        for r in c["tokenRows"] as! [[String: Any]] {
            try await storage.hold(
                try SwapFixture.tx(r["hex"] as! String), vout: 0, basket: "amm-swap",
                customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: r["keyID"] as! String), sources: [fund]
            )
        }
        for r in c["satsRows"] as! [[String: Any]] {
            try await storage.hold(
                try SwapFixture.tx(r["hex"] as! String), vout: 0, basket: "amm-swap",
                customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: r["keyID"] as! String), sources: [fund]
            )
        }
        ctx = SellFixture.context(storage, overlay)
        input = OpenExchangeSwapLeg.LegInput(
            tokenId: SwapFixture.tokenId, direction: .tokenToBsv, leg: SwapFixture.leg(c), pool: SwapFixture.pool(c),
            poolBEEF: try SwapFixture.poolBEEF(), poolOutputIndex: 0, commissionPkh: c["commissionPkh"] as? String, satsPerKb: 100
        )
        sats = try await OpenExchangeSwapLeg.satsHoldings(ctx)
        tokens = try await OpenExchangeSwapLeg.tokenHoldings(ctx, tokenId: SwapFixture.tokenId)
        let beef = try await OpenExchangeSwapLeg.basketBEEF(ctx)
        holding = try XCTUnwrap(beef)
    }

    func prepare() throws -> OpenExchangePreparedLeg {
        let picked = try XCTUnwrap(try OpenExchangeSwapLeg.selectInputs(input, sats: sats, tokens: tokens))
        let order = c["order"] as! String
        return try OpenExchangeSwapLeg.prepare(
            ctx, input, inputs: picked.sats, tokens: picked.tokens, order: order == picked.tokens.first?.outpoint ? nil : order,
            last: c["last"] as! Bool, holdingBEEF: holding
        )
    }

    var signed: Transaction { get throws { try SwapFixture.tx(c["signed"] as! String) } }

    /// The validator's transaction with its sources, and its Atomic BEEF.
    func signedWithSources(_ p: OpenExchangePreparedLeg) throws -> (tx: Transaction, beef: [UInt8]) {
        let signed = try signed
        let beef = try p.sources.merging(
            try BEEF(version: .v2, merklePaths: [], transactions: [.raw(signed)], limits: beefLimits), limits: beefLimits
        )
        let atomic = try ColorBEEF.atomic(try signed.transactionID(limits: txLimits), in: beef).serialized(limits: beefLimits)
        return (try OpenExchangeSwapLeg.withSources(signed, from: beef), atomic)
    }

    /// Every output of the validator's transaction listed admitted and unspent (its receipts).
    func listSigned() async throws {
        let signed = try signed
        for n in signed.outputs.indices { try await overlay.unspent(signed, vout: UInt32(n)) }
    }

    /// The token rows admitted and unspent, so the module moves them back.
    func admitTokenRows() async throws {
        for r in c["tokenRows"] as! [[String: Any]] { try await overlay.unspent(try SwapFixture.tx(r["hex"] as! String), vout: 0) }
    }

    var tokenOutpoint: String { tokens[0].outpoint }
    var satsOutpoint: String { sats[0].outpoint }
}

final class SwapSellTests: XCTestCase {
    // MARK: - The sell leg

    func testEachSellLegIsTheTypeScriptLegByteForByte() async throws {
        XCTAssertEqual(SellFixture.legs.count, 5)
        for c in SellFixture.legs {
            let name = c["name"] as! String
            let w = try await SellWorld(c)
            let picked = try XCTUnwrap(try OpenExchangeSwapLeg.selectInputs(w.input, sats: w.sats, tokens: w.tokens), name)
            let need = c["need"] as! [String: Any]
            XCTAssertEqual(picked.need.outputs, (need["outputs"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.fee, (need["fee"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.need, (need["need"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.feeWithChange, (need["feeWithChange"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.needWithChange, (need["needWithChange"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.sats.map(\.outpoint), c["selected"] as! [String], name)
            XCTAssertEqual(picked.tokens.map(\.outpoint), c["selectedTokens"] as! [String], name)

            let p = try w.prepare()
            XCTAssertFalse(p.bsvIn, name)
            let plan = c["plan"] as! [String: Any]
            let outputs = plan["outputs"] as! [[String: String]]
            XCTAssertEqual(p.plan.outputs.map { String($0.satoshis) }, outputs.map { $0["satoshis"]! }, name)
            XCTAssertEqual(p.plan.outputs.map { Hex.encode($0.script) }, outputs.map { $0["script"]! }, name)
            XCTAssertEqual(try AMMPoolCall.maxCallUnlockLength(p.plan), plan["maxCallUnlockLength"] as? Int, name)
            XCTAssertEqual(try SwapFixture.hex(p.swap), c["swap"] as? String, name)
            XCTAssertEqual(p.id, c["id"] as? String, name)
            XCTAssertEqual(Hex.encode(p.fundingAtomicBEEF), c["funding"] as? String, name)
            XCTAssertEqual(p.fee, (c["fee"] as! NSNumber).int64Value, name)
            XCTAssertEqual(p.order, c["order"] as? String, name)
            XCTAssertEqual(p.last, c["last"] as? Bool, name)
            let commission = c["commission"] as! [String: String]
            XCTAssertEqual(String(p.commissionAmount), commission["amount"], name)
            XCTAssertEqual(p.commissionPkh, commission["pkh"], name)
            XCTAssertEqual(p.commissionTo, commission["to"], name)
            XCTAssertEqual(p.takeIn.map { SwapFixture.render($0.internalize) } as NSArray, c["takeIn"] as! NSArray, name)
            XCTAssertEqual(String(decoding: try OpenExchange.swapBody(p, peerId: "peer-1"), as: UTF8.self), c["body"] as? String, name)
        }
    }

    func testTokenRowsThatCannotCoverTheAmountAreNoSelection() async throws {
        let w = try await SellWorld(SellFixture.legs[2])
        let short = w.tokens.map {
            OpenExchangeTokenRow(outpoint: $0.outpoint, txid: $0.txid, vout: $0.vout, satoshis: $0.satoshis, lockingScript: $0.lockingScript,
                                 amount: $0.amount - 1, protocolID: $0.protocolID, keyID: $0.keyID, counterparty: $0.counterparty, order: $0.order)
        }
        XCTAssertNil(try OpenExchangeSwapLeg.selectInputs(w.input, sats: w.sats, tokens: short))
        XCTAssertNil(try OpenExchangeSwapLeg.selectInputs(w.input, sats: w.sats, tokens: []))
        do {
            _ = try OpenExchangeSwapLeg.prepare(w.ctx, w.input, inputs: w.sats, tokens: short, last: true, holdingBEEF: w.holding)
            XCTFail("a leg its token rows do not cover was built")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "token inputs carry 49999, the leg needs 50000")
        }
    }

    func testTheSwapBasketsTokenRowsAreItsValueOutputsOfTheToken() async throws {
        let w = try await SellWorld(SellFixture.legs[3])
        let rows = w.c["tokenRows"] as! [[String: Any]]
        XCTAssertEqual(w.tokens.map(\.keyID), rows.map { $0["keyID"] as! String })
        XCTAssertEqual(w.tokens.map { String($0.amount) }, rows.map { $0["amount"] as! String })
        XCTAssertTrue(w.tokens.allSatisfy { $0.satoshis == 1 && $0.order == nil && $0.counterparty == "self" })
        // Another token's rows are not this token's.
        let other = try await OpenExchangeSwapLeg.tokenHoldings(w.ctx, tokenId: String(repeating: "ab", count: 32) + "_0")
        XCTAssertEqual(other, [])
        do {
            _ = try OpenExchangeSwapLeg.assetIdOf(SwapFixture.tokenId.replacingOccurrences(of: "_0", with: "_1"))
            XCTFail("a 36-byte id has a pool asset id")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "pools exist only for 32-byte ids (<txid>_0), not \(SwapFixture.tokenId.replacingOccurrences(of: "_0", with: "_1"))")
        }
    }

    // MARK: - completeSwap of a sell

    func testEachSellLegsTakeInIsOneInternalizeOfTheValidatorsTransaction() async throws {
        for c in SellFixture.legs {
            let name = c["name"] as! String
            let w = try await SellWorld(c)
            let p = try w.prepare()
            try await w.listSigned()
            let done = try await OpenExchangeSwapLeg.complete(w.ctx, p, raw: try w.signed.serialized(limits: txLimits), txid: c["signedTxid"] as? String)
            XCTAssertEqual(done, OpenExchangeCompletedLeg(txid: c["signedTxid"] as! String, internalized: true, errors: []), name)
            let calls = await w.storage.internalized
            XCTAssertEqual(calls.count, 1, name)
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call.description, "AMM swap payout", name)
            XCTAssertEqual(call.labels, ["amm-swap"], name)
            XCTAssertEqual(call.transaction.subjectTransactionID.displayHex, c["signedTxid"] as? String, name)
            try await assertTakeIn(call.outputs, c["takeIn"] as! [[String: Any]], name)
        }
    }

    // MARK: - legTakeInOf, ownKeyInputOf of a sell

    func testASellLegsTakeInIsTheTypeScriptOne() async throws {
        let want = SwapFixture.vectors["sellTakeIn"] as! [[String: Any]]
        for (n, legIndex) in [0, 2].enumerated() {
            let w = try await SellWorld(SellFixture.legs[legIndex])
            let p = try w.prepare()
            let (tx, _) = try w.signedWithSources(p)
            XCTAssertEqual(try SwapFixture.hex(try w.signed), want[n]["signed"] as? String)
            let own = OpenExchangeSwapLeg.ownKeyInput(tx)
            XCTAssertEqual(own, want[n]["ownKeyInput"] as? String)
            XCTAssertEqual(own, w.tokens.first?.outpoint, "a sell's key input is its first token row")
            let outputs = try XCTUnwrap(try OpenExchangeSwapLeg.legTakeIn(w.ctx, tx, tokenId: SwapFixture.tokenId, order: try XCTUnwrap(own)))
            XCTAssertEqual(outputs.map(SwapFixture.render) as NSArray, want[n]["outputs"] as! NSArray, "sellTakeIn[\(n)]")
            XCTAssertTrue(want[n]["other"] is NSNull)
            XCTAssertNil(try OpenExchangeSwapLeg.legTakeIn(w.ctx, tx, tokenId: SwapFixture.tokenId, order: String(repeating: "ee", count: 32) + ".0"))
        }
    }

    /// Sent and paid out with no answer: the pass finds the token row's spender and takes the
    /// sell in, its sats payout a BRC-29 payment.
    func testThePassTakesInASellThatLandedWithoutAnAnswer() async throws {
        let w = try await SellWorld(SellFixture.legs[0])
        let p = try w.prepare()
        let signed = try w.signed
        let signedID = try signed.transactionID(limits: txLimits).displayHex
        let reads = ScriptedReads(
            spends: [[OpenExchangeSpend(outpoint: w.tokenOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID),
                      OpenExchangeSpend(outpoint: w.satsOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID)]],
            tx: try w.signedWithSources(p).beef
        )
        let r = await OpenExchangeSwapLeg.resolveFromOverlay(w.ctx, reads: reads.reads)
        XCTAssertEqual(r.taken, [OpenExchangeResolvedLeg(
            txid: signedID, tokenId: SwapFixture.tokenId, inputs: signed.inputs.map { OpenExchangeSwapLeg.outpointText($0.previousOutput) },
            payoutSatoshis: signed.outputs[1].satoshis, payoutTokens: nil
        )])
        XCTAssertEqual(r.stuck, [])
        let asked = await reads.spendsAsked
        XCTAssertEqual(asked.first, [w.tokenOutpoint, w.satsOutpoint])
        let calls = await w.storage.internalized
        XCTAssertEqual(calls.map(\.description), ["AMM swap payout"])
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, w.c["takeIn"] as! [[String: Any]], "pass")
    }

    /// A sell's payout the wallet did not take in: stuck, the token and sats rows kept.
    func testASellPayoutTheWalletRefusesIsStuck() async throws {
        let w = try await SellWorld(SellFixture.legs[0])
        let p = try w.prepare()
        let signedID = try w.signed.transactionID(limits: txLimits).displayHex
        await w.storage.setInternalizeAccepts(false)
        let reads = ScriptedReads(
            spends: [[OpenExchangeSpend(outpoint: w.tokenOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID)]],
            tx: try w.signedWithSources(p).beef
        )
        let r = await OpenExchangeSwapLeg.resolveFromOverlay(w.ctx, reads: reads.reads)
        XCTAssertEqual(r.taken, [])
        XCTAssertEqual(r.stuck, [OpenExchangeStuckRow(outpoint: w.tokenOutpoint, spentBy: signedID, error: "the wallet did not accept the take-in")])
        let tokens = try await OpenExchangeSwapLeg.tokenHoldings(w.ctx, tokenId: SwapFixture.tokenId)
        XCTAssertEqual(tokens.map(\.outpoint), [w.tokenOutpoint])
        let sats = try await OpenExchangeSwapLeg.satsHoldings(w.ctx)
        XCTAssertEqual(sats.map(\.outpoint), [w.satsOutpoint])
    }

    // MARK: - stage with tokens

    /// The module transfer of the tokens to a fresh swap key (output 0) and the sats (output 1),
    /// the page's submit to the token's topic, and the filing of the token row in `amm-swap`.
    func testStagingTokensIsTheTypeScriptStage() async throws {
        let s = SwapFixture.vectors["stageTokens"] as! [String: Any]
        let random = SwapFixture.bytes(s["random"] as! String)
        let runs = s["runs"] as! [[String: Any]]
        for want in runs {
            let name = want["name"] as! String
            let ok = ((want["result"] as! [String: Any])["errors"] as! [String]).isEmpty
            let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
            let overlay = try StubOverlay()
            await overlay.admitSubmissions()
            let ctx = SellFixture.context(storage, overlay)
            _ = try await SellFixture.holdColor(ctx, storage, overlay, amount: 50_000)
            await storage.setFilesInternalized(true)
            if !ok { await storage.setInternalizeError("the wallet is locked") }
            let submits = SubmitLog()
            let staged = try await OpenExchangeSwapLeg.stage(
                ctx, sats: UInt64((want["sats"] as! NSNumber).intValue), tokens: (SwapFixture.tokenId, 50_000), sym: "TST",
                submit: { topic, beef in
                    submits.add(topic, beef)
                    if !ok { throw OpenExchangeError.failed("POST https://ex.test/submit: 500 down") }
                    return OpenExchange.steak(SellFixture.steakJSON())
                },
                randomKeyIDs: [Array(random[0..<16]), Array(random[16..<32])]
            )

            // The createAction: the page's outputs and labels, the module's token input.
            let created = await storage.created
            let args = want["args"] as! [[String: Any]]
            XCTAssertEqual(created.count, 1, name)
            let got = try XCTUnwrap(created.first)
            XCTAssertEqual(got.description, args[0]["description"] as? String, name)
            XCTAssertEqual(got.labels, args[0]["labels"] as? [String], name)
            let outputs = args[0]["outputs"] as! [[String: Any]]
            XCTAssertEqual(got.outputs?.count, outputs.count, name)
            for (o, wo) in zip(got.outputs ?? [], outputs) {
                XCTAssertEqual(Hex.encode(o.lockingScript), wo["lockingScript"] as? String, name)
                XCTAssertEqual(Int(o.satoshis), wo["satoshis"] as? Int, name)
                XCTAssertEqual(o.outputDescription, wo["outputDescription"] as? String, name)
                XCTAssertEqual(o.basket, wo["basket"] as? String, name)
                XCTAssertEqual(o.customInstructions, wo["customInstructions"] as? String, name)
            }
            let options = args[0]["options"] as! [String: Bool]
            XCTAssertEqual(got.options?.randomizeOutputs, options["randomizeOutputs"], name)
            XCTAssertEqual(got.options?.acceptDelayedBroadcast, options["acceptDelayedBroadcast"], name)
            XCTAssertEqual(got.inputs?.count, 1, "the module's p color row: \(name)")

            // The page's submit: the token's topic, the transaction's Atomic BEEF; the TS's bytes
            // as `submissionBeef` sends them.
            let tsSubmits = want["submits"] as! [[String: String]]
            XCTAssertEqual(submits.all.map(\.topic), tsSubmits.map { $0["topic"]! }, name)
            XCTAssertEqual(try ColorBEEF.open(try XCTUnwrap(submits.all.first).beef).txid.displayHex, staged.txid, name)
            for t in tsSubmits {
                XCTAssertEqual(Hex.encode(try OpenExchange.submissionBEEF(topic: t["topic"]!, SwapFixture.bytes(t["in"]!))), t["out"], name)
            }
            // The module submitted it to the overlay too.
            let moduleSubmits = await overlay.submitted
            XCTAssertEqual(moduleSubmits.map(\.topics), [[SellFixture.topic]], name)

            // The filing.
            let internalized = await storage.internalized
            let tsInternalize = want["internalize"] as! [[String: Any]]
            XCTAssertEqual(internalized.count, tsInternalize.count, name)
            XCTAssertEqual(internalized.first?.description, tsInternalize[0]["description"] as? String, name)
            XCTAssertEqual(internalized.first?.labels, tsInternalize[0]["labels"] as? [String], name)
            XCTAssertEqual(internalized.first?.transaction.subjectTransactionID.displayHex, staged.txid, name)
            try await assertTakeIn(try XCTUnwrap(internalized.first).outputs, tsInternalize[0]["outputs"] as! [[String: Any]], name)

            // The result.
            let result = want["result"] as! [String: Any]
            XCTAssertEqual(staged.filed, result["filed"] as? Bool, name)
            XCTAssertEqual(staged.submitted, result["submitted"] as? String, name)
            XCTAssertEqual(staged.errors, result["errors"] as? [String], name)
            let tokens = result["tokens"] as! [String: Any]
            XCTAssertEqual(staged.tokens?.outpoint, "\(staged.txid).0", name)
            XCTAssertEqual(staged.tokens.map { Hex.encode($0.lockingScript) }, tokens["lockingScript"] as? String, name)
            XCTAssertEqual(staged.tokens.map { String($0.amount) }, tokens["amount"] as? String, name)
            XCTAssertEqual(staged.tokens?.keyID, tokens["keyID"] as? String, name)
            if let sats = result["sats"] as? [String: Any] {
                XCTAssertEqual(staged.sats?.outpoint, "\(staged.txid).1", name)
                XCTAssertEqual(staged.sats.map { Hex.encode($0.lockingScript) }, sats["lockingScript"] as? String, name)
                XCTAssertEqual(staged.sats.map { Int($0.satoshis) }, sats["satoshis"] as? Int, name)
                XCTAssertEqual(staged.sats?.keyID, sats["keyID"] as? String, name)
            } else {
                XCTAssertNil(staged.sats, name)
            }

            // Filed: the leg's token rows are what the basket lists.
            let held = try await OpenExchangeSwapLeg.tokenHoldings(ctx, tokenId: SwapFixture.tokenId)
            XCTAssertEqual(held, ok ? [try XCTUnwrap(staged.tokens)] : [], name)
            let colorRows = await storage.basketRecords(SellFixture.basket)
            XCTAssertTrue(colorRows.isEmpty, "the module spent the wallet's token row: \(name)")
        }

        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        do {
            _ = try await OpenExchangeSwapLeg.stage(SellFixture.context(storage, nil), sats: 0)
            XCTFail("an empty stage ran")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), s["nothing"] as? String)
        }
    }

    /// A transfer the module refuses (no token held) throws its error; nothing is filed.
    func testATokenStageTheModuleRefusesThrows() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let overlay = try StubOverlay()
        let ctx = SellFixture.context(storage, overlay)
        do {
            _ = try await OpenExchangeSwapLeg.stage(ctx, sats: 0, tokens: (SwapFixture.tokenId, 50_000), sym: "TST")
            XCTFail("a stage with no tokens held ran")
        } catch {
            XCTAssertFalse(OpenExchangeError.errorText(error).isEmpty)
        }
        let internalized = await storage.internalized
        XCTAssertTrue(internalized.isEmpty)
    }

    func testTheStagedKeyIsInItsOutputsDescription() throws {
        for d in SwapFixture.vectors["keyDescriptions"] as! [[String: String]] {
            XCTAssertEqual(try OpenExchangeSwapLeg.swapKeyDescription(d["readable"]!, keyID: d["keyID"]!), d["description"])
        }
        for d in SwapFixture.vectors["keyIdsOfDescriptions"] as! [[String: Any]] {
            XCTAssertEqual(OpenExchangeSwapLeg.swapKeyIdOfDescription(d["description"] as? String), d["keyID"] as? String, d["description"] as! String)
        }
        XCTAssertThrowsError(try OpenExchangeSwapLeg.swapKeyDescription("x", keyID: "amm-swap-XY")) {
            XCTAssertEqual(OpenExchangeError.errorText($0), "not a staged key id: amm-swap-XY")
        }
    }

    // MARK: - moveBack with tokens

    /// The swap basket's token rows and sats rows in ONE module plan whose output 0 (the whole
    /// amount) the wallet keeps, then the page's submit.
    func testMovingBackTheTokensIsTheTypeScriptModulePlan() async throws {
        for want in SwapFixture.vectors["moveBackTokens"] as! [[String: Any]] {
            let name = want["name"] as! String
            let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
            let overlay = try StubOverlay()
            await overlay.admitSubmissions()
            let ctx = SellFixture.context(storage, overlay)
            let fund = try SwapFixture.topicTx("fund")
            for r in want["tokenRows"] as! [[String: Any]] {
                let tx = try SwapFixture.tx(r["hex"] as! String)
                try await storage.hold(tx, vout: 0, basket: "amm-swap",
                                       customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: r["keyID"] as! String, order: r["order"] as? String),
                                       sources: [fund])
                try await overlay.unspent(tx, vout: 0)
            }
            for r in want["satsRows"] as! [[String: Any]] {
                try await storage.hold(try SwapFixture.tx(r["hex"] as! String), vout: 0, basket: "amm-swap",
                                       customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: r["keyID"] as! String), sources: [fund])
            }
            let args = want["args"] as! [String: Any]
            let labels = args["labels"] as! [String]
            let owned = try XCTUnwrap(try ColorPlan.fromLabels(labels)?.ownedOutputs.first, name)
            let submits = SubmitLog()
            let moved = try await OpenExchangeSwapLeg.moveBack(
                ctx, tokenId: SwapFixture.tokenId, sym: "TST",
                submit: { topic, beef in
                    submits.add(topic, beef)
                    return OpenExchange.steak(SellFixture.steakJSON())
                },
                derivation: (owned.derivationPrefix, owned.derivationSuffix)
            )

            let created = await storage.created
            XCTAssertEqual(created.count, 1, name)
            let got = try XCTUnwrap(created.first)
            XCTAssertEqual(got.description, args["description"] as? String, name)
            XCTAssertEqual(got.labels, labels, name)
            let inputs = args["inputs"] as! [[String: Any]]
            XCTAssertEqual(got.inputs?.map(\.outpoint.description), inputs.map { $0["outpoint"] as! String }, name)
            XCTAssertEqual(got.inputs?.map(\.inputDescription), inputs.map { $0["inputDescription"] as? String }, name)
            for input in got.inputs ?? [] {
                guard case .scriptLength(let n) = input.unlocking else { return XCTFail("an input carries its unlock: \(name)") }
                XCTAssertEqual(Int(n), 108, name)
            }
            let outputs = args["outputs"] as! [[String: Any]]
            XCTAssertEqual(got.outputs?.count, 1, name)
            let output = try XCTUnwrap(got.outputs?.first)
            XCTAssertEqual(Hex.encode(output.lockingScript), outputs[0]["lockingScript"] as? String, name)
            XCTAssertEqual(Int(output.satoshis), outputs[0]["satoshis"] as? Int, name)
            XCTAssertEqual(output.outputDescription, outputs[0]["outputDescription"] as? String, name)
            // The module files the owned output in the asset's basket with its custody.
            XCTAssertEqual(output.basket, SellFixture.basket, name)
            let options = args["options"] as! [String: Bool]
            XCTAssertEqual(got.options?.randomizeOutputs, options["randomizeOutputs"], name)
            XCTAssertEqual(got.options?.acceptDelayedBroadcast, options["acceptDelayedBroadcast"], name)

            // Each row unlocked by the page, at the inputs the TS's `spends` names.
            let processed = await storage.processed
            let tx = try Transaction(bytes: try XCTUnwrap(processed.last?.rawTX), limits: txLimits)
            XCTAssertEqual(try tx.transactionID(limits: txLimits).displayHex, moved.txid, name)
            let spends = (want["spends"] as! [String]).map { Int($0)! }
            XCTAssertEqual(Array(tx.inputs.indices.prefix(spends.count)), spends, name)
            let (_, movedBEEF, subject) = try ColorBEEF.open(moved.atomicBEEF)
            let linked = try OpenExchangeSwapLeg.withSources(subject, from: movedBEEF)
            for n in spends { XCTAssertTrue(OpenExchangeSwapLeg.spendValid(linked, n), "input \(n): \(name)") }

            // The page's submit.
            let tsSubmits = want["submits"] as! [[String: String]]
            XCTAssertEqual(submits.all.map(\.topic), tsSubmits.map { $0["topic"]! }, name)
            XCTAssertEqual(submits.all.first?.beef, moved.atomicBEEF, name)
            for t in tsSubmits {
                XCTAssertEqual(Hex.encode(try OpenExchange.submissionBEEF(topic: t["topic"]!, SwapFixture.bytes(t["in"]!))), t["out"], name)
            }
            let result = want["result"] as! [String: Any]
            XCTAssertEqual(String(moved.amount), result["amount"] as? String, name)
            XCTAssertEqual(moved.submitted, result["submitted"] as? String, name)
            XCTAssertEqual(moved.errors, result["errors"] as? [String], name)

            // The basket is empty; the tokens are the wallet's again.
            let rows = await storage.basketRecords("amm-swap")
            XCTAssertTrue(rows.isEmpty, name)
            let back = await storage.basketRecords(SellFixture.basket)
            XCTAssertEqual(back.map { Hex.encode($0.script) }, [outputs[0]["lockingScript"] as! String], name)
        }

        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        do {
            _ = try await OpenExchangeSwapLeg.moveBack(SellFixture.context(storage, try StubOverlay()), tokenId: SwapFixture.tokenId, sym: "TST", submit: nil)
            XCTFail("an empty basket moved back")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), SwapFixture.vectors["moveBackNothing"] as? String)
        }
    }

    /// A submit that fails after the move back is reported, not thrown.
    func testAMoveBackWhoseSubmitFailsReportsIt() async throws {
        let w = try await SellWorld(SellFixture.legs[2])
        await w.overlay.admitSubmissions()
        try await w.admitTokenRows()
        let moved = try await OpenExchangeSwapLeg.moveBack(w.ctx, tokenId: SwapFixture.tokenId, sym: "TST", submit: { _, _ in
            throw OpenExchangeError.failed("POST https://ex.test/submit: 500 down")
        })
        XCTAssertEqual(moved.amount, 50_000)
        XCTAssertEqual(moved.submitted, "the submit failed")
        XCTAssertEqual(moved.errors, ["submit: POST https://ex.test/submit: 500 down"])
    }

    /// The module's own overlay submit fails after the broadcast: the move back stands, its txid
    /// reported, the tokens filed in the wallet's basket, the failure in `errors` (the TS throws
    /// and loses the txid).
    func testAMoveBackWhoseModuleSubmitFailsKeepsItsTxid() async throws {
        let w = try await SellWorld(SellFixture.legs[2])
        try await w.admitTokenRows()
        // No `admitSubmissions`: the overlay refuses every submit.
        let moved = try await OpenExchangeSwapLeg.moveBack(w.ctx, tokenId: SwapFixture.tokenId, sym: "TST", submit: { _, _ in
            OpenExchange.steak(SellFixture.steakJSON())
        })
        let processed = await w.storage.processed
        let tx = try Transaction(bytes: try XCTUnwrap(processed.last?.rawTX), limits: txLimits)
        XCTAssertEqual(moved.txid, try tx.transactionID(limits: txLimits).displayHex)
        XCTAssertEqual(moved.amount, 50_000)
        XCTAssertEqual(moved.submitted, "admitted under \(SellFixture.topic) (outputs 0)")
        XCTAssertEqual(moved.errors, ["module submit: a swap leg submits nothing to the overlay"])
        let back = await w.storage.basketRecords(SellFixture.basket)
        XCTAssertEqual(back.count, 1)
        let rows = await w.storage.basketRecords("amm-swap")
        XCTAssertTrue(rows.isEmpty)
    }

    // MARK: - unfiledStagedTokens, fileStagedToken, settleSwaps

    static func action(_ a: [String: Any]) throws -> WalletAction {
        try WalletAction(
            transactionID: try TransactionID(displayHex: a["txid"] as! String), satoshis: 0, status: .completed, isOutgoing: true,
            description: "AMM swap: TST into the swap basket", version: 1, lockTime: 0,
            outputs: try (a["outputs"] as! [[String: Any]]).map {
                try WalletActionOutput(
                    satoshis: UInt64(($0["satoshis"] as! NSNumber).intValue), lockingScript: SwapFixture.bytes($0["lockingScript"] as! String),
                    spendable: true, tags: [], outputIndex: UInt32(($0["outputIndex"] as! NSNumber).intValue),
                    outputDescription: $0["outputDescription"] as! String, basket: $0["basket"] as! String
                )
            }
        )
    }

    func testTheUnfiledStagedTokensAreTheTypeScriptOnes() async throws {
        let u = SwapFixture.vectors["unfiled"] as! [String: Any]
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let ctx = SellFixture.context(storage, try StubOverlay())
        await storage.setActions(try (u["actions"] as! [[String: Any]]).map(Self.action))
        let unfiled = await OpenExchangeSwapLeg.unfiledStagedTokens(ctx)
        XCTAssertEqual(unfiled, (u["unfiled"] as! [[String: Any]]).map {
            OpenExchangeUnfiledStaged(txid: $0["txid"] as! String, vout: $0["vout"] as! Int, tokenId: $0["tokenId"] as! String,
                                      amount: BigInt($0["amount"] as! String)!, keyID: $0["keyID"] as! String)
        })
        let asked = await storage.listedActions
        let want = u["asked"] as! [String: Any]
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.labels, want["labels"] as? [String])
        XCTAssertEqual(asked.first?.includeOutputs, want["includeOutputs"] as? Bool)
        XCTAssertEqual(asked.first?.includeOutputLockingScripts, want["includeOutputLockingScripts"] as? Bool)
        XCTAssertEqual(asked.first.map { Int($0.pagination.effectiveLimit) }, want["limit"] as? Int)

        await storage.setActions([], error: "no")
        let events = SettleLog()
        let refused = await OpenExchangeSwapLeg.unfiledStagedTokens(ctx, onEvent: { events.add($0) })
        XCTAssertEqual(refused, [])
        XCTAssertEqual((u["refused"] as! [Any]).count, 0)
        // Not dropped: reported.
        XCTAssertEqual(events.all, [.historyUnread(error: "no", kept: 0)])
    }

    func testFilingAStagedTokenIsTheTypeScriptInternalize() async throws {
        let u = SwapFixture.vectors["unfiled"] as! [String: Any]
        let first = (u["unfiled"] as! [[String: Any]])[0]
        let script = SwapFixture.bytes(((u["actions"] as! [[String: Any]])[0]["outputs"] as! [[String: Any]])[0]["lockingScript"] as! String)
        let tx = try SellFixture.tokenTx(script)
        let txid = try tx.transactionID(limits: txLimits).displayHex
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setFilesInternalized(true)
        let ctx = SellFixture.context(storage, try StubOverlay())
        let staged = OpenExchangeUnfiledStaged(txid: txid, vout: 0, tokenId: SwapFixture.tokenId, amount: 50_000, keyID: first["keyID"] as! String)
        let accepted = try await OpenExchangeSwapLeg.fileStagedToken(ctx, staged, beef: try SellFixture.atomic(tx))
        let file = u["file"] as! [String: Any]
        XCTAssertEqual(accepted, file["accepted"] as? Bool)
        let calls = await storage.internalized
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.description, file["description"] as? String)
        XCTAssertEqual(calls.first?.labels, file["labels"] as? [String])
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, file["outputs"] as! [[String: Any]], "file")
        let held = try await OpenExchangeSwapLeg.tokenHoldings(ctx, tokenId: SwapFixture.tokenId)
        XCTAssertEqual(held.map(\.outpoint), ["\(txid).0"])
        XCTAssertEqual(held.first?.keyID, "amm-swap-0a1b")
        XCTAssertEqual(held.first?.amount, 50_000)
    }

    /// On load: a staged token output the basket lacks is filed from the host's `/tx` read; one
    /// whose read fails is logged and left; then the pass.
    func testSettlingFilesTheUnfiledStagedTokens() async throws {
        let u = SwapFixture.vectors["unfiled"] as! [String: Any]
        let script = SwapFixture.bytes(((u["actions"] as! [[String: Any]])[0]["outputs"] as! [[String: Any]])[0]["lockingScript"] as! String)
        let tx = try SellFixture.tokenTx(script)
        let txid = try tx.transactionID(limits: txLimits).displayHex
        let unread = try SellFixture.tokenTx(script, marker: 2)
        let unreadID = try unread.transactionID(limits: txLimits).displayHex
        let description = try OpenExchangeSwapLeg.swapKeyDescription("TST for a swap", keyID: "amm-swap-0a1b")
        let output: [String: Any] = ["outputIndex": 0, "satoshis": 1, "lockingScript": Hex.encode(script), "outputDescription": description, "basket": ""]
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setFilesInternalized(true)
        let unserved = try SellFixture.tokenTx(script, marker: 3)
        let unservedID = try unserved.transactionID(limits: txLimits).displayHex
        await storage.setActions([
            try Self.action(["txid": txid, "outputs": [output]]), try Self.action(["txid": unreadID, "outputs": [output]]),
            try Self.action(["txid": unservedID, "outputs": [output]]),
        ])
        let ctx = SellFixture.context(storage, try StubOverlay())
        let http = StubHTTP()
        let exchange = try OpenExchange(origin: "https://ex.test", http: http)
        let tokenBase = try exchange.tokenBase(SwapFixture.tokenId)
        await http.route("\(tokenBase)/tx?id=\(txid)", 200, try SellFixture.atomic(tx))
        await http.json("\(tokenBase)/tx?id=\(unreadID)", "down", status: 500)
        await http.json("\(tokenBase)/tx?id=\(unservedID)", "not found", status: 404)
        let events = SettleLog()
        let settled = await exchange.settleSwaps(ctx, onEvent: { events.add($0) })
        XCTAssertEqual(settled.taken, [])
        XCTAssertEqual(settled.resolved.stuck, [])
        // What was filed is returned, with its token id and amount; the two left unfiled are not.
        XCTAssertEqual(settled.filed, [
            OpenExchangeUnfiledStaged(txid: txid, vout: 0, tokenId: SwapFixture.tokenId, amount: 50_000, keyID: "amm-swap-0a1b"),
        ])
        // Each staged output's fate is told, the read that failed and the one not served included.
        XCTAssertEqual(events.all.count, 3)
        XCTAssertEqual(events.all.first, .filed(outpoint: "\(txid).0"))
        guard case .unread(let unreadAt, let error)? = events.all.dropFirst().first else { return XCTFail("\(events.all)") }
        XCTAssertEqual(unreadAt, "\(unreadID).0")
        XCTAssertTrue(error.contains("500"), error)
        XCTAssertEqual(events.all.last, .notServed(outpoint: "\(unservedID).0"))
        let held = try await OpenExchangeSwapLeg.tokenHoldings(ctx, tokenId: SwapFixture.tokenId)
        XCTAssertEqual(held.map(\.outpoint), ["\(txid).0"])
        let calls = await storage.internalized
        XCTAssertEqual(calls.map(\.description), ["AMM swap: a staged token filed"])
        let urls = await http.urls
        XCTAssertEqual(Array(urls.prefix(3)), ["\(tokenBase)/tx?id=\(txid)", "\(tokenBase)/tx?id=\(unreadID)", "\(tokenBase)/tx?id=\(unservedID)"])
        // The pass ran over the basket after the filing.
        XCTAssertTrue(urls.contains("\(exchange.base)/spends?outpoint=\(txid).0"))
    }

    /// A load with nothing staged outside the basket files nothing, reads no `/tx`, and still
    /// returns the pass.
    func testSettlingWithNothingUnfiledReturnsThePassAlone() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setActions([])
        let ctx = SellFixture.context(storage, try StubOverlay())
        let http = StubHTTP()
        let exchange = try OpenExchange(origin: "https://ex.test", http: http)
        let events = SettleLog()
        let settled = await exchange.settleSwaps(ctx, onEvent: { events.add($0) })
        XCTAssertEqual(settled.filed, [])
        XCTAssertEqual(settled.resolved, OpenExchangeResolved(taken: [], stuck: []))
        XCTAssertEqual(settled.taken, [])
        XCTAssertEqual(events.all, [])
        let urls = await http.urls
        XCTAssertFalse(urls.contains { $0.contains("/tx?id=") }, "\(urls)")
        let internalized = await storage.internalized
        XCTAssertTrue(internalized.isEmpty)
    }

    // MARK: - The page's submit

    func testThePagesSubmitIsTheTypeScriptOne() async throws {
        let s = SwapFixture.vectors["submit"] as! [String: Any]
        let topic = s["topic"] as! String
        let bytes = SwapFixture.bytes(s["bytes"] as! String)
        for run in s["runs"] as! [[String: Any]] {
            let status = run["status"] as! Int
            let http = StubHTTP()
            await http.json("https://ex.test/submit", run["answer"] as! String, status: status)
            let exchange = try OpenExchange(origin: "https://ex.test", http: http)
            do {
                let steak = try await exchange.submitToOverlay(topic: topic, beef: bytes)
                XCTAssertEqual(OpenExchange.steakText(steak), run["text"] as? String, "\(status)")
            } catch {
                XCTAssertEqual(OpenExchangeError.errorText(error), run["error"] as? String, "\(status)")
            }
            let requests = await http.requests
            XCTAssertEqual(requests.count, 1)
            let request = try XCTUnwrap(requests.first)
            let want = run["request"] as! [String: Any]
            XCTAssertEqual(request.url.absoluteString, want["url"] as? String)
            XCTAssertEqual(request.method, want["method"] as? String)
            XCTAssertEqual(request.headers, want["headers"] as? [String: String])
            XCTAssertEqual(request.body.map(Hex.encode), want["body"] as? String)
        }
        let other = s["other"] as! [String: String]
        XCTAssertEqual(Hex.encode(try OpenExchange.submissionBEEF(topic: other["topic"]!, bytes)), other["out"])
        XCTAssertEqual(try OpenExchange.submissionBEEF(topic: other["topic"]!, bytes), bytes)
    }

    // MARK: - executeSwap of a sell

    /// The sell loop's world at a stub host, as `SwapRecoveryTests.Host` is the buy's.
    struct Host {
        let w: SellWorld
        let http = StubHTTP()
        let exchange: OpenExchange
        let poolsURL: String
        let swapURL: String
        let pools: String

        init(_ c: [String: Any]) async throws {
            w = try await SellWorld(c)
            exchange = try OpenExchange(origin: "https://ex.test", http: http)
            let tokenBase = try exchange.tokenBase(SwapFixture.tokenId)
            poolsURL = "\(tokenBase)/pools"
            swapURL = "\(tokenBase)/swap"
            let p = SwapFixture.pool(w.c)
            let identity = (SwapFixture.vectors["keys"] as! [String: Any])["identity"] as! String
            pools = #"{"market":{"identityKey":"\#(identity)"},"validators":[{"identity":"\#(p.validatorIdentityKey)","peerId":"peer-1"}],"pools":[{"outpoint":"\#(p.outpoint)","poolId":"\#(p.outpoint)","bsvReserve":"\#(p.bsvReserve)","tokenReserve":"\#(p.tokenReserve)","liquidityFeeBps":\#(p.liquidityFeeBps),"validationFeeBps":\#(p.validationFeeBps),"commissionBps":\#(p.commissionBps),"validatorIdentityKey":"\#(p.validatorIdentityKey)","validatorPeerId":"peer-1"}]}"#
            await http.json(poolsURL, pools)
            await http.route("\(tokenBase)/tx?id=\(String(p.outpoint.prefix(64)))", 200, try SwapFixture.poolBEEF())
            // The page's submit at the host root, for what goes back.
            await http.json("https://ex.test/submit", SellFixture.steakJSON())
            await w.overlay.admitSubmissions()
            try await w.admitTokenRows()
        }

        func quote(_ amountIn: BigInt = 50_000) throws -> OpenExchangeQuote {
            try OpenExchangeQuotes.quoteSwap(
                OpenExchangeQuoteRequest(tokenId: SwapFixture.tokenId, side: .sell, amountIn: amountIn, maxSlippageBps: 100, maxSources: 1),
                held: try OpenExchangePools.read(JSONValue.parse(Array(pools.utf8))), sym: "TST", dec: 0
            )
        }

        func accepts() async throws {
            let signed = try w.signed
            await http.json(swapURL, #"{"ok":true,"tx":\#(OpenExchange.dagBytes(try signed.serialized(limits: txLimits))),"txid":"\#(try signed.transactionID(limits: txLimits).displayHex)"}"#)
        }

        func run(_ log: ProgressLog, cancelled: Bool = false, quote: OpenExchangeQuote? = nil, events: EventLog = EventLog()) async throws -> OpenExchangeSwapResult {
            try await exchange.executeSwap(
                w.ctx, quote: quote ?? (try self.quote()), sym: "TST",
                isCancelled: { cancelled }, onProgress: { log.add($0) }, onEvent: { events.add($0) }
            )
        }

        var posts: Int { get async { await http.requests.filter { $0.url.absoluteString == swapURL }.count } }
        var submits: [HTTPRequest] { get async { await http.requests.filter { $0.url.absoluteString == "https://ex.test/submit" } } }
        var poolText: String { OpenExchangePrices.outpointText(SwapFixture.pool(w.c).outpoint) }

        /// The move back's transaction (the last processed).
        func moved() async throws -> Transaction {
            let processed = await w.storage.processed
            return try Transaction(bytes: try XCTUnwrap(processed.last?.rawTX), limits: txLimits)
        }

        /// Nothing left in the swap basket; the tokens back in the wallet's own basket.
        func assertAllBack(_ amount: BigInt, file: StaticString = #filePath, line: UInt = #line) async throws {
            let rows = await w.storage.basketRecords("amm-swap")
            XCTAssertTrue(rows.isEmpty, file: file, line: line)
            let back = await w.storage.basketRecords(SellFixture.basket)
            XCTAssertEqual(back.count, 1, file: file, line: line)
            XCTAssertEqual(back.first.flatMap { AMMPool.decodeOneColor($0.script) }.map { BigInt($0.amount) }, amount, file: file, line: line)
        }
    }

    func testASellThatFillsIsOneLegTakenIn() async throws {
        let h = try await Host(SellFixture.loop)
        let c = h.w.c
        try await h.accepts()
        let log = ProgressLog()
        let result = try await h.run(log)
        let leg = SwapFixture.leg(c)
        let pool = SwapFixture.pool(c)
        let filled = [OpenExchangeLegResult(poolOutpoint: h.poolText, poolId: pool.outpoint, amountIn: 50_000, amountOut: leg.amountOut, txid: c["signedTxid"] as! String)]
        XCTAssertEqual(result, OpenExchangeSwapResult(
            status: .filled, stop: .filled, legs: filled, totalIn: 50_000, totalOut: leg.amountOut, unfilled: 0, stuck: nil, returned: nil
        ))
        XCTAssertEqual(log.all, [.relaying(leg: h.poolText, amountIn: 50_000, amountOut: leg.amountOut, filled: []), .done(result)])
        // The basket covered the leg: nothing staged; the leg sent is the vectors' sell.
        let created = await h.w.storage.created
        XCTAssertTrue(created.isEmpty)
        let requests = await h.http.requests
        let post = try XCTUnwrap(requests.first { $0.url.absoluteString == h.swapURL })
        XCTAssertEqual(post.body.map { String(decoding: $0, as: UTF8.self) }, c["body"] as? String)
        let calls = await h.w.storage.internalized
        XCTAssertEqual(calls.map(\.description), ["AMM swap payout"])
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, c["takeIn"] as! [[String: Any]], "sell fill")
        let submits = await h.submits
        XCTAssertTrue(submits.isEmpty)
    }

    /// Staged and never sent: the tokens the basket lacked are staged (the module transfer, the
    /// page's submit, the filing), the swap is cancelled before its first leg, and every token
    /// and sats row goes back in one module plan.
    func testACancelledSellMovesItsStagedTokensAndSatsBack() async throws {
        let h = try await Host(SellFixture.loop)
        await h.w.storage.setFilesInternalized(true)
        _ = try await SellFixture.holdColor(h.w.ctx, h.w.storage, h.w.overlay, amount: 10_000)
        let quote = try h.quote(60_000)
        XCTAssertEqual(quote.stage.amount, 60_000)
        let haveSats = BigInt(h.w.sats.reduce(0) { $0 + $1.satoshis })
        let lackSats = quote.stage.feeSats > haveSats ? quote.stage.feeSats - haveSats : 0
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, cancelled: true, quote: quote, events: events)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .cancelled)
        XCTAssertEqual(result.unfilled, 60_000)
        XCTAssertEqual(log.phases, ["staging", "returning", "failed"])
        XCTAssertEqual(log.all.first, .staging(sats: lackSats, tokens: 10_000))

        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), ["AMM swap: TST into the swap basket", "AMM move back: TST"])
        let staged = try XCTUnwrap(created.first)
        XCTAssertEqual(Array((staged.labels ?? []).suffix(2)), ["amm-swap", "amm-swap-stage"])
        XCTAssertEqual(staged.outputs?.count, lackSats > 0 ? 2 : 1)
        XCTAssertEqual(staged.outputs.flatMap { $0.first.flatMap { AMMPool.decodeOneColor($0.lockingScript) } }.map { BigInt($0.amount) }, 10_000)
        // The move back spends the vectors' token row, the staged one, and the sats rows.
        let moved = try await h.moved()
        let back = try XCTUnwrap(created.last)
        XCTAssertEqual(back.inputs?.count, moved.inputs.count)
        XCTAssertEqual(Set(back.inputs?.map(\.outpoint.description) ?? []).isSuperset(of: [h.w.tokenOutpoint, h.w.satsOutpoint]), true)
        XCTAssertEqual(result.returned, .moved(txid: try moved.transactionID(limits: txLimits).displayHex, tokens: 60_000))
        guard case let .staged(txid, sats, tokens, submitted, errors) = events.notable.first else { return XCTFail("nothing staged: \(events.notable)") }
        XCTAssertEqual(txid.count, 64)
        XCTAssertEqual(BigInt(sats), lackSats)
        XCTAssertEqual(tokens, 10_000)
        XCTAssertEqual(submitted, "admitted under \(SellFixture.topic) (outputs 0)")
        XCTAssertEqual(errors, [])
        XCTAssertEqual(events.notable.last, .returned(try XCTUnwrap(result.returned)))
        // Both submitted at the host root: the stage and the move back.
        let submits = await h.submits
        XCTAssertEqual(submits.count, 2)
        XCTAssertTrue(submits.allSatisfy { $0.headers["x-topics"] == #"["\#(SellFixture.topic)"]"# })
        try await h.assertAllBack(60_000)
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// A sell whose basket covers the quote's fee sats but not the leg's own: the vectors' 60,000
    /// token row and 1,362-sat row (one token input's exact need), and 10,000 more tokens staged
    /// for a 70,000 sell, so the leg spends two token rows and its sats lack a few dozen. The
    /// shortfall is staged in sats alone (a second stage, no token moved, no token row spent) and
    /// the leg is sent (here refused, so everything goes back).
    func testASellsSatsShortfallIsStagedInSatsAloneAndTheLegSent() async throws {
        let h = try await Host(SellFixture.legs[0])
        await h.w.storage.setFilesInternalized(true)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"below_minimum"}"#)
        _ = try await SellFixture.holdColor(h.w.ctx, h.w.storage, h.w.overlay, amount: 10_000)
        let quote = try h.quote(70_000)
        XCTAssertEqual(quote.legs.map(\.amountIn), [70_000])
        XCTAssertLessThanOrEqual(quote.stage.feeSats, 1_362)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .noPool, "\(events.all)")
        XCTAssertEqual(log.phases.filter { $0 == "staging" }.count, 2)
        XCTAssertEqual(log.all.first, .staging(sats: 0, tokens: 10_000))
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), ["AMM swap: TST into the swap basket", "AMM swap: sats into the swap basket", "AMM move back: TST"])
        let topUp = created[1]
        let lack = try XCTUnwrap(topUp.outputs?.first?.satoshis)
        XCTAssertGreaterThan(lack, 0)
        XCTAssertLessThanOrEqual(BigInt(lack), quote.legMinerFeeSats)
        XCTAssertEqual(topUp.outputs?.count, 1)
        XCTAssertNil(topUp.outputs?.first.flatMap { AMMPool.decodeOneColor($0.lockingScript) })
        XCTAssertTrue((topUp.inputs ?? []).isEmpty, "the top-up spent \(topUp.inputs ?? [])")
        XCTAssertEqual(log.all[1], .staging(sats: BigInt(lack), tokens: 0))
        let staged = events.all.compactMap { if case let .staged(_, sats, tokens, _, _) = $0 { (sats, tokens) } else { nil } }
        XCTAssertEqual(staged.map(\.0), [0, lack])
        XCTAssertEqual(staged.map(\.1), [10_000, 0])
        XCTAssertTrue(events.all.allSatisfy { if case .stageFailed = $0 { false } else { true } }, "\(events.all)")
        // The leg sent spends both token rows and the sats rows, the top-up's among them.
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
        try await h.assertAllBack(70_000)
    }

    /// The same basket with the 10,000 tokens left unstaged (a quote staging 60,000): the token
    /// rows are short of the 70,000 leg, so its sats lack is not topped up. No stage, nothing
    /// sent, stop `fees`, the rows go back.
    func testASellsTokenRowsShortStageNothingAndStopFees() async throws {
        let h = try await Host(SellFixture.legs[0])
        await h.w.storage.setFilesInternalized(true)
        _ = try await SellFixture.holdColor(h.w.ctx, h.w.storage, h.w.overlay, amount: 10_000)
        let q = try h.quote(70_000)
        let quote = OpenExchangeQuote(
            request: q.request, legs: q.legs, amountOut: q.amountOut, minAmountOut: q.minAmountOut, effectivePrice: q.effectivePrice,
            marginalPrice: q.marginalPrice, impactBps: q.impactBps, stage: OpenExchangeQuoteStage(amount: 60_000, feeSats: q.stage.feeSats),
            legMinerFeeSats: q.legMinerFeeSats, plan: q.plan, view: q.view
        )
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .fees, "\(events.all)")
        XCTAssertEqual(result.legs, [])
        XCTAssertFalse(log.phases.contains("staging"), "\(log.phases)")
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), ["AMM move back: TST"])
        XCTAssertTrue(events.all.allSatisfy {
            switch $0 { case .staged, .stageFailed: false; default: true }
        }, "\(events.all)")
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
        guard case .moved(_, 60_000)? = result.returned else { return XCTFail("not moved back: \(String(describing: result.returned))") }
    }

    /// The staged token row was not filed in the swap basket: the basket's sats are moved back,
    /// as the TS does at its `fees` stop, then the sell fails with the filing's error and the
    /// move back.
    func testASellWhoseStagedTokensWereNotFiledFailsWithTheFilingError() async throws {
        let h = try await Host(SellFixture.loop)
        _ = try await SellFixture.holdColor(h.w.ctx, h.w.storage, h.w.overlay, amount: 10_000)
        await h.w.storage.setInternalizeError("the wallet is locked")
        let log = ProgressLog()
        let events = EventLog()
        do {
            let result = try await h.run(log, quote: try h.quote(60_000), events: events)
            return XCTFail("the sell ran on: \(result)")
        } catch {
            guard case let .staged(txid, _, tokens, _, errors) = events.notable.first else { return XCTFail("nothing staged: \(events.notable)") }
            XCTAssertEqual(tokens, 10_000)
            XCTAssertEqual(errors, ["internalizeAction: the wallet is locked"])
            let filing = "the staged TST \(txid).0 could not be filed in the swap basket: the wallet is locked (settleSwaps files it later)"
            guard case let .returned(returned) = events.notable.last else { return XCTFail("nothing moved back: \(events.notable)") }
            switch returned {
            case let .moved(backTxid, _):
                XCTAssertEqual(OpenExchangeError.errorText(error), filing + "; the basket's sats were moved back in \(backTxid)")
                let left = try await OpenExchangeSwapLeg.basketRows(h.w.ctx)
                XCTAssertEqual(OpenExchangeSwapLeg.satsRows(left).count, 0, "sats left in the basket")
            case let .error(text):
                XCTFail("the move back failed: \(text)")
            }
        }
        XCTAssertEqual(log.phases, ["staging", "returning", "failed"])
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// No answer, but the overlay shows the token row spent: the sell landed, and the pass takes
    /// it in and accounts it.
    func testNoAnswerButTheTokenRowSpentIsASellTakenInByThePass() async throws {
        let h = try await Host(SellFixture.loop)
        let c = h.w.c
        let signedID = c["signedTxid"] as! String
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"unreachable"}"#)
        let rows = try await OpenExchangeSwapLeg.basketRows(h.w.ctx).map { OpenExchangeSwapLeg.outpointText($0.outpoint) }
        XCTAssertEqual(rows, [h.w.tokenOutpoint, h.w.satsOutpoint])
        let token = h.w.tokenOutpoint
        let sats = h.w.satsOutpoint
        let startURL = "\(h.exchange.base)/spends?outpoint=\(rows.joined(separator: ","))"
        await h.http.once(startURL, #"[{"outpoint":"\#(token)"},{"outpoint":"\#(sats)"}]"#)
        let spent = #"[{"outpoint":"\#(token)","tokenId":"\#(SwapFixture.tokenId)","spentBy":"\#(signedID)"},{"outpoint":"\#(sats)","tokenId":"\#(SwapFixture.tokenId)","spentBy":"\#(signedID)"}]"#
        await h.http.json(startURL, spent)
        await h.http.json("\(h.exchange.base)/spends?outpoint=\(h.poolText),\(sats),\(token)",
                          #"[{"outpoint":"\#(h.poolText)","spentBy":"\#(signedID)"},{"outpoint":"\#(sats)","spentBy":"\#(signedID)"},{"outpoint":"\#(token)","spentBy":"\#(signedID)"}]"#)
        let p = try h.w.prepare()
        await h.http.route("\(try h.exchange.tokenBase(SwapFixture.tokenId))/tx?id=\(signedID)", 200, try h.w.signedWithSources(p).beef)
        let log = ProgressLog()
        let result = try await h.run(log)
        let leg = SwapFixture.leg(c)
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(result.legs, [OpenExchangeLegResult(poolOutpoint: h.poolText, poolId: SwapFixture.pool(c).outpoint, amountIn: 50_000, amountOut: leg.amountOut, txid: signedID)])
        XCTAssertNil(result.returned)
        XCTAssertEqual(log.phases, ["relaying", "done"])
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
        let calls = await h.w.storage.internalized
        XCTAssertEqual(calls.map(\.description), ["AMM swap payout"])
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, c["takeIn"] as! [[String: Any]], "sell pass")
    }

    /// Refused (not `pool_spent`): the pool excluded, and with no pool left the token row and the
    /// sats go back in one module plan, submitted at the host root.
    func testARefusedSellExcludesThePoolAndMovesTheTokensAndSatsBack() async throws {
        let h = try await Host(SellFixture.loop)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"below_minimum"}"#)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, events: events)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .noPool)
        XCTAssertEqual(result.legs, [])
        XCTAssertEqual(result.unfilled, 50_000)
        let moved = try await h.moved()
        XCTAssertEqual(result.returned, .moved(txid: try moved.transactionID(limits: txLimits).displayHex, tokens: 50_000))
        XCTAssertEqual(Array(moved.inputs.prefix(2)).map { OpenExchangeSwapLeg.outpointText($0.previousOutput) }, [h.w.tokenOutpoint, h.w.satsOutpoint])
        XCTAssertEqual(log.phases, ["relaying", "returning", "failed"])
        let created = await h.w.storage.created
        XCTAssertEqual(created.last?.description, "AMM move back: TST")
        let id = try h.w.prepare().id
        XCTAssertEqual(events.notable, [
            .relayed(leg: h.poolText, attempt: 1, outcome: .refused(id: id, reason: "below_minimum", pool: nil)),
            .excluded(pool: SwapFixture.pool(h.w.c).outpoint, reason: "refused: below_minimum"),
            .returned(try XCTUnwrap(result.returned)),
        ])
        let submits = await h.submits
        XCTAssertEqual(submits.count, 1)
        try await h.assertAllBack(50_000)
    }

    /// No answer, nothing on the overlay, then the resend refused `pool_spent`: repricing as the
    /// TS does (a refusal, not a pending leg), the pool still listed at that outpoint excluded,
    /// and everything moved back. The TS's runSwap has no other path for a resend's refusal; the
    /// events report both attempts and their outcomes in full.
    func testAResendRefusedPoolSpentRepricesThenMovesBack() async throws {
        let h = try await Host(SellFixture.loop)
        await h.http.once(h.swapURL, #"{"ok":false,"reason":"unreachable"}"#)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"pool_spent","detail":"at the resend"}"#)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, events: events)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .noPool)
        XCTAssertEqual(result.legs, [])
        XCTAssertEqual(log.phases, ["relaying", "repricing", "returning", "failed"])
        let id = try h.w.prepare().id
        let pool = SwapFixture.pool(h.w.c).outpoint
        XCTAssertEqual(events.notable, [
            .relayed(leg: h.poolText, attempt: 1, outcome: .unknown(id: id, reason: "no answer yet: the host could not reach the validator (unreachable)")),
            .relayed(leg: h.poolText, attempt: 2, outcome: .refused(id: id, reason: "pool_spent: at the resend", pool: nil)),
            .excluded(pool: pool, reason: "still listed at the outpoint refused pool_spent"),
            .returned(try XCTUnwrap(result.returned)),
        ])
        let posts = await h.posts
        XCTAssertEqual(posts, 2)
        let spends = await h.http.urls.filter { $0.contains("/spends?") }
        XCTAssertTrue(spends.contains("\(h.exchange.base)/spends?outpoint=\(h.poolText),\(h.w.satsOutpoint),\(h.w.tokenOutpoint)"))
        guard case .moved(_, 50_000)? = result.returned else { return XCTFail("not moved back: \(String(describing: result.returned))") }
        try await h.assertAllBack(50_000)
    }

    /// A buy that stops early with a sell's token row in the basket moves the token row back
    /// with the sats, as the TS `moveBack` does.
    func testAnEarlyBuyStopMovesATokenRowBackWithTheSats() async throws {
        let h = try await SwapRecoveryTests.Host(SwapFixture.legs[0])
        let sell = SellFixture.legs[2]
        let row = (sell["tokenRows"] as! [[String: Any]])[0]
        let tx = try SwapFixture.tx(row["hex"] as! String)
        try await h.w.storage.hold(tx, vout: 0, basket: "amm-swap",
                                   customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: row["keyID"] as! String),
                                   sources: [try SwapFixture.topicTx("fund")])
        try await h.w.overlay.unspent(tx, vout: 0)
        await h.w.overlay.admitSubmissions()
        await h.http.json("https://ex.test/submit", SellFixture.steakJSON())
        let result = try await h.run(ProgressLog(), cancelled: true, quote: try h.quote(25_000))
        let processed = await h.w.storage.processed
        let moved = try Transaction(bytes: try XCTUnwrap(processed.last?.rawTX), limits: txLimits)
        XCTAssertEqual(result.returned, .moved(txid: try moved.transactionID(limits: txLimits).displayHex, tokens: 50_000))
        let totals = try await OpenExchangeSwapLeg.swapBasketTotals(h.w.ctx)
        XCTAssertEqual(totals.sats, 0)
        XCTAssertEqual(totals.tokens, [:])
    }
}

/// The page's submits, in order.
final class SubmitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(topic: String, beef: [UInt8])] = []

    func add(_ topic: String, _ beef: [UInt8]) { lock.withLock { entries.append((topic, beef)) } }
    var all: [(topic: String, beef: [UInt8])] { lock.withLock { entries } }
}

/// `settleSwaps`'s events, in order.
final class SettleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OpenExchangeSettleEvent] = []

    func add(_ e: OpenExchangeSettleEvent) { lock.withLock { entries.append(e) } }
    var all: [OpenExchangeSettleEvent] { lock.withLock { entries } }
}
