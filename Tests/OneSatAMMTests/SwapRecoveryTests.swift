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

// Recovery and the swap loop against skein-amm 0.55.1 (cc146be): wallet/swapPayouts.ts
// (`legTakeInOf`, `ownKeyInputOf`, `resolveFromOverlay`), market/activeSwap.ts (`moveBackSats`),
// lib/overlay.ts (`readSpendsAll`, `readTx`, `poolOutputOf`) and client.ts (`executeSwap`,
// `runSwap`). The vectors are Fixtures/amm-swap-vectors.json (`takeIn`, `resolve`, `moveBack`);
// the HTTP is StubHTTP and the wallet MemoryStorage: nothing here reaches a network.
//
// The recovery states: staged and never sent (the basket's sats moved back), a leg sent and
// paid out with no answer (the overlay pass takes it in), a leg refused (the pool excluded or
// repriced, then the rows moved back), a payout the wallet did not take in (reported stuck, the
// row kept). A BRC-177 noSend that expired is no state of the TS: its `stage` broadcasts.

/// What a swap told `onProgress`, in order.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OpenExchangeSwapProgress] = []

    func add(_ p: OpenExchangeSwapProgress) { lock.withLock { entries.append(p) } }
    var all: [OpenExchangeSwapProgress] { lock.withLock { entries } }
    /// Each entry's phase.
    var phases: [String] {
        all.map {
            switch $0 {
            case .staging: "staging"
            case .relaying: "relaying"
            case .repricing: "repricing"
            case .returning: "returning"
            case .stuck: "stuck"
            case .done: "done"
            case .failed: "failed"
            }
        }
    }
}

/// What a swap told `onEvent`, in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OpenExchangeSwapEvent] = []

    func add(_ e: OpenExchangeSwapEvent) { lock.withLock { entries.append(e) } }
    var all: [OpenExchangeSwapEvent] { lock.withLock { entries } }
    /// The events other than the passes.
    var notable: [OpenExchangeSwapEvent] { all.filter { if case .resolved = $0 { false } else { true } } }
}

/// The overlay pass's two reads, scripted, each call recorded.
actor ScriptedReads {
    var spendsAsked: [[String]] = []
    var txAsked: [String] = []
    private var spends: [[OpenExchangeSpend]]
    private let tx: [UInt8]?

    init(spends: [[OpenExchangeSpend]], tx: [UInt8]?) {
        self.spends = spends
        self.tx = tx
    }

    func spendsAll(_ ops: [String]) -> [OpenExchangeSpend] {
        spendsAsked.append(ops)
        return spends.isEmpty ? [] : spends.removeFirst()
    }

    func read(_ tokenId: String, _ txid: String) -> [UInt8]? {
        txAsked.append(txid)
        return tx
    }

    nonisolated var reads: OpenExchangeSwapReads {
        OpenExchangeSwapReads(spendsAll: { await self.spendsAll($0) }, tx: { await self.read($0, $1) })
    }
}

extension LegWorld {
    /// The validator's transaction with every input's source (as `Transaction.fromAtomicBEEF`
    /// links them), and its Atomic BEEF.
    func signedWithSources(_ p: OpenExchangePreparedLeg) throws -> (tx: Transaction, beef: [UInt8]) {
        let signed = try signed
        let beef = try p.sources.merging(
            try BEEF(version: .v2, merklePaths: [], transactions: [.raw(signed)], limits: beefLimits), limits: beefLimits
        )
        let atomic = try ColorBEEF.atomic(try signed.transactionID(limits: txLimits), in: beef).serialized(limits: beefLimits)
        return (try OpenExchangeSwapLeg.withSources(signed, from: beef), atomic)
    }

    var rowOutpoint: String { rows[0].outpoint }
}

final class SwapRecoveryTests: XCTestCase {
    static var takeIn: [[String: Any]] { SwapFixture.vectors["takeIn"] as! [[String: Any]] }
    static var resolve: [String: Any] { SwapFixture.vectors["resolve"] as! [String: Any] }
    /// The loop's leg: the whole amount, its commission key the market identity's child.
    static var loop: [String: Any] { SwapFixture.vectors["loop"] as! [String: Any] }

    // MARK: - legTakeInOf, ownKeyInputOf

    func testALegsTakeInIsTheTypeScriptOne() async throws {
        // takeIn[0] is legs[0] (relay commission), takeIn[1] legs[3] (own commission, last).
        for (n, legIndex) in [0, 3].enumerated() {
            let want = Self.takeIn[n]
            let w = try await LegWorld(SwapFixture.legs[legIndex])
            let p = try w.prepare()
            let (tx, _) = try w.signedWithSources(p)
            XCTAssertEqual(try SwapFixture.hex(try w.signed), want["signed"] as? String)
            let own = OpenExchangeSwapLeg.ownKeyInput(tx)
            XCTAssertEqual(own, want["ownKeyInput"] as? String)
            let outputs = try XCTUnwrap(try OpenExchangeSwapLeg.legTakeIn(w.ctx, tx, tokenId: SwapFixture.tokenId, order: try XCTUnwrap(own)))
            XCTAssertEqual(outputs.map(SwapFixture.render) as NSArray, want["outputs"] as! NSArray, "takeIn[\(n)]")
            XCTAssertTrue(want["other"] is NSNull)
            XCTAssertNil(try OpenExchangeSwapLeg.legTakeIn(w.ctx, tx, tokenId: SwapFixture.tokenId, order: String(repeating: "ee", count: 32) + ".0"))
        }
    }

    func testATransactionWithoutItsSourcesNamesNoKeyInput() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        XCTAssertNil(OpenExchangeSwapLeg.ownKeyInput(try w.signed))
        XCTAssertTrue(OpenExchangeSwapLeg.legInputs(try w.signed) == ([], []))
    }

    // MARK: - resolveFromOverlay

    /// A leg sent and paid out whose answer was lost: the pass finds the row's spender on the
    /// overlay and takes it in with ONE internalizeAction.
    func testThePassTakesInALegThatLandedWithoutAnAnswer() async throws {
        let want = Self.resolve
        let w = try await LegWorld(SwapFixture.legs[0])
        let p = try w.prepare()
        let signedID = try w.signed.transactionID(limits: txLimits).displayHex
        let (_, beef) = try w.signedWithSources(p)
        try await w.overlay.unspent(try w.signed, vout: 1)
        let reads = ScriptedReads(
            spends: [[OpenExchangeSpend(outpoint: w.rowOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID)]], tx: beef
        )
        let r = await OpenExchangeSwapLeg.resolveFromOverlay(w.ctx, reads: reads.reads)
        let asked = await reads.spendsAsked
        XCTAssertEqual(asked, want["spendsAsked"] as? [[String]])
        let taken = (want["taken"] as! [[String: Any]])[0]
        let payout = taken["payout"] as! [String: Any]
        XCTAssertEqual(r.taken, [OpenExchangeResolvedLeg(
            txid: taken["txid"] as! String, tokenId: taken["tokenId"] as! String, inputs: taken["inputs"] as! [String],
            payoutSatoshis: (payout["satoshis"] as! NSNumber).uint64Value, payoutTokens: BigInt(payout["tokens"] as! String)
        )])
        XCTAssertEqual(r.stuck, [])
        let calls = await w.storage.internalized
        let internalize = want["internalize"] as! [[String: Any]]
        XCTAssertEqual(calls.count, internalize.count)
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.description, internalize[0]["description"] as? String)
        XCTAssertEqual(call.labels, internalize[0]["labels"] as? [String])
        XCTAssertEqual(call.transaction.subjectTransactionID.displayHex, signedID)
        try await assertTakeIn(call.outputs, internalize[0]["outputs"] as! [[String: Any]], "resolve")
    }

    /// A payout the wallet did not take in (its unlock pending): reported stuck, the row kept.
    func testAPayoutTheWalletRefusesIsStuck() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        let p = try w.prepare()
        let signedID = try w.signed.transactionID(limits: txLimits).displayHex
        try await w.overlay.unspent(try w.signed, vout: 1)
        await w.storage.setInternalizeAccepts(false)
        let reads = ScriptedReads(
            spends: [[OpenExchangeSpend(outpoint: w.rowOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID)]],
            tx: try w.signedWithSources(p).beef
        )
        let r = await OpenExchangeSwapLeg.resolveFromOverlay(w.ctx, reads: reads.reads)
        XCTAssertEqual(r.taken, [])
        XCTAssertEqual(r.stuck, [OpenExchangeStuckRow(outpoint: w.rowOutpoint, spentBy: signedID, error: "the wallet did not accept the take-in")])
        // One round: nothing taken in ends the pass.
        let asked = await reads.spendsAsked
        XCTAssertEqual(asked.count, 1)
        let rows = try await OpenExchangeSwapLeg.satsHoldings(w.ctx)
        XCTAssertEqual(rows.map(\.outpoint), [w.rowOutpoint])
    }

    func testTheOtherStuckRows() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        let p = try w.prepare()
        let signedID = try w.signed.transactionID(limits: txLimits).displayHex
        let spend = OpenExchangeSpend(outpoint: w.rowOutpoint, tokenId: SwapFixture.tokenId, spentBy: signedID)
        func pass(_ ctx: OneColorContext, _ spends: [OpenExchangeSpend], _ tx: [UInt8]?) async -> OpenExchangeResolved {
            await OpenExchangeSwapLeg.resolveFromOverlay(ctx, reads: ScriptedReads(spends: [spends], tx: tx).reads)
        }

        // The host served no transaction.
        let none = await pass(w.ctx, [spend], nil)
        XCTAssertEqual(none.stuck, [OpenExchangeStuckRow(outpoint: w.rowOutpoint, spentBy: signedID, error: "the host served no transaction for the spender")])

        // Another wallet's swap: no output pays this wallet's keys.
        let other = OneColorContext(
            identity: try PrivateKey([UInt8](repeating: 0x2f, count: 32)), storage: w.storage,
            auth: w.ctx.auth, maximumFee: 20_000, overlay: w.overlay
        )
        let foreign = await pass(other, [spend], try w.signedWithSources(p).beef)
        XCTAssertEqual(foreign.stuck, [OpenExchangeStuckRow(outpoint: w.rowOutpoint, spentBy: signedID, error: "no output of the spending transaction pays this wallet's keys")])

        // Served without its inputs' sources, for an outpoint that names no row: no order key.
        let signed = try w.signed
        var parents: [TransactionID] = []
        for input in signed.inputs where !parents.contains(input.previousOutput.transactionID) { parents.append(input.previousOutput.transactionID) }
        let bare = try AtomicBEEF(
            subjectTransactionID: try signed.transactionID(limits: txLimits),
            beef: try BEEF(version: .v2, merklePaths: [], transactions: parents.map { .transactionID($0) } + [.raw(signed)], limits: beefLimits),
            limits: beefLimits
        ).serialized(limits: beefLimits)
        let odd = OpenExchangeSpend(outpoint: "x", tokenId: SwapFixture.tokenId, spentBy: signedID)
        let unnamed = await pass(w.ctx, [odd], bare)
        XCTAssertEqual(unnamed.stuck, [OpenExchangeStuckRow(outpoint: "x", spentBy: signedID, error: "the spending transaction names no order key (its inputs' sources are missing)")])

        // Bytes that are no BEEF: the error, reported.
        let broken = await pass(w.ctx, [spend], [1, 2, 3])
        XCTAssertEqual(broken.stuck.count, 1)
        XCTAssertFalse(broken.stuck[0].error.isEmpty)

        // A row with no spender, or no token, is nothing; a failed read ends the pass quietly.
        let unspent = await pass(w.ctx, [OpenExchangeSpend(outpoint: w.rowOutpoint, tokenId: SwapFixture.tokenId, spentBy: nil)], nil)
        XCTAssertEqual(unspent, OpenExchangeResolved(taken: [], stuck: []))
        let failing = OpenExchangeSwapReads(spendsAll: { _ in throw TestError("down") }, tx: { _, _ in nil })
        let quiet = await OpenExchangeSwapLeg.resolveFromOverlay(w.ctx, reads: failing)
        XCTAssertEqual(quiet, OpenExchangeResolved(taken: [], stuck: []))
        let calls = await w.storage.internalized
        XCTAssertTrue(calls.isEmpty)
    }

    func testAnEmptyBasketAsksNothing() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let ctx = OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let reads = ScriptedReads(spends: [], tx: nil)
        let r = await OpenExchangeSwapLeg.resolveFromOverlay(ctx, reads: reads.reads)
        XCTAssertEqual(r, OpenExchangeResolved(taken: [], stuck: []))
        let asked = await reads.spendsAsked
        XCTAssertTrue(asked.isEmpty)
    }

    // MARK: - The reads

    func testTheReadsAreTheTypeScriptURLs() async throws {
        let http = StubHTTP()
        let exchange = try OpenExchange(origin: "https://ex.test", http: http)
        let a = String(repeating: "ab", count: 32) + ".0"
        let b = String(repeating: "cd", count: 32) + ".1"
        let spendsURL = "\(exchange.base)/spends?outpoint=\(a),\(b)"
        await http.json(spendsURL, #"[{"outpoint":"\#(a)","tokenId":"t","spentBy":"ABCD"},{"outpoint":"\#(b)"},{"junk":1}]"#)
        let spends = try await exchange.readSpendsAll([a, b])
        XCTAssertEqual(spends, [OpenExchangeSpend(outpoint: a, tokenId: "t", spentBy: "abcd"), OpenExchangeSpend(outpoint: b, tokenId: nil, spentBy: nil)])
        await http.json("\(exchange.base)/spends?outpoint=\(a)", #"{"outpoint":"\#(a)","spentBy":"ef"}"#)
        let one = try await exchange.readSpendsAll([a])
        XCTAssertEqual(one, [OpenExchangeSpend(outpoint: a, tokenId: nil, spentBy: "ef")])
        let nothing = try await exchange.readSpendsAll([])
        XCTAssertEqual(nothing, [])

        let txid = String(repeating: "12", count: 32)
        let txURL = "\(try exchange.tokenBase(SwapFixture.tokenId))/tx?id=\(txid)"
        await http.route(txURL, 200, [9, 8, 7])
        let held = try await exchange.readTx(tokenId: SwapFixture.tokenId, txid: txid)
        XCTAssertEqual(held, [9, 8, 7])
        let missing = try await exchange.readTx(tokenId: SwapFixture.tokenId, txid: String(repeating: "34", count: 32))
        XCTAssertNil(missing)
        await http.route(txURL, 500, Array("boom".utf8))
        do {
            _ = try await exchange.readTx(tokenId: SwapFixture.tokenId, txid: txid)
            XCTFail("a 500 is an error")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "GET \(txURL): 500 boom")
        }
        let requests = await http.requests
        XCTAssertEqual(requests.last?.headers["accept"] ?? requests.last?.headers["Accept"], "application/octet-stream")
    }

    func testThePoolOutputIsTheReadsAtomicBEEF() throws {
        let pool = try SwapFixture.topicTx("pool_deploy")
        let txid = try pool.transactionID(limits: txLimits).displayHex
        let atomic = try SwapFixture.poolBEEF()
        let out = try XCTUnwrap(OpenExchange.poolOutputOf(atomic, "\(txid)_0"))
        XCTAssertEqual(out.outputIndex, 0)
        XCTAssertEqual(try ColorBEEF.open(out.beef).txid.displayHex, txid)
        XCTAssertNil(OpenExchange.poolOutputOf(atomic, String(repeating: "ab", count: 32) + "_0"))
        XCTAssertNil(OpenExchange.poolOutputOf(nil, "\(txid)_0"))
        XCTAssertNil(OpenExchange.poolOutputOf([], "\(txid)_0"))
        XCTAssertNil(OpenExchange.poolOutputOf(atomic, "not an outpoint"))
    }

    // MARK: - moveBackSats

    /// Staged and never sent: the basket's sats go back to the wallet in ONE plain action with
    /// no outputs, each row unlocked by the page.
    func testMovingBackTheSatsIsTheTypeScriptCreateAction() async throws {
        let moveBack = SwapFixture.vectors["moveBack"] as! [String: Any]
        let args = moveBack["args"] as! [String: Any]
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let ctx = OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let fund = try SwapFixture.topicTx("fund")
        // The generator's rows 8 and 9 (its stagedSats counter after the six legs' seven rows).
        let held: [(keyID: String, order: String?)] = [("amm-swap-s8", nil), ("amm-swap-s9", String(repeating: "ab", count: 32) + ".3")]
        for (hex, row) in zip(moveBack["rows"] as! [String], held) {
            let tx = try SwapFixture.tx(hex)
            let key = try OpenExchangeSwapLeg.swapKey(ctx, keyID: row.keyID)
            XCTAssertEqual(tx.outputs[0].lockingScript.bytes, AMMPoolCall.p2pkh(OpenExchangeSwapLeg.pkh(key)))
            try await storage.hold(tx, vout: 0, basket: "amm-swap",
                                   customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: row.keyID, order: row.order), sources: [fund])
        }
        let moved = try await OpenExchangeSwapLeg.moveBackSats(ctx)

        let created = await storage.created
        XCTAssertEqual(created.count, 1)
        let got = try XCTUnwrap(created.first)
        XCTAssertEqual(got.description, args["description"] as? String)
        XCTAssertEqual(got.labels, args["labels"] as? [String])
        XCTAssertEqual(got.outputs ?? [], [])
        let inputs = args["inputs"] as! [[String: Any]]
        XCTAssertEqual(got.inputs?.map(\.outpoint.description), inputs.map { $0["outpoint"] as! String })
        XCTAssertEqual(got.inputs?.map(\.inputDescription), inputs.map { $0["inputDescription"] as? String })
        for input in got.inputs ?? [] {
            guard case .scriptLength(let n) = input.unlocking else { return XCTFail("an input carries its unlock") }
            XCTAssertEqual(Int(n), 108)
        }
        let options = args["options"] as! [String: Bool]
        XCTAssertEqual(got.options?.randomizeOutputs, options["randomizeOutputs"])
        XCTAssertEqual(got.options?.acceptDelayedBroadcast, options["acceptDelayedBroadcast"])
        XCTAssertNotNil(got.inputBEEF)

        // Each row unlocked (the TS signs a different fake transaction, so the bytes differ):
        // both inputs, the indices the TS's `spends` names, each validating.
        let spends = moveBack["spends"] as! [String: Any]
        XCTAssertEqual(Set(spends.keys), ["0", "1"])
        let processed = await storage.processed
        let raw = try XCTUnwrap(processed.last?.rawTX)
        let tx = try Transaction(bytes: raw, limits: txLimits)
        XCTAssertEqual(try tx.transactionID(limits: txLimits).displayHex, moved.txid)
        XCTAssertEqual(try ColorBEEF.open(moved.atomicBEEF).txid.displayHex, moved.txid)
        XCTAssertEqual(tx.outputs.count, 1, "the wallet's change only")
        let rows = await storage.basketRecords("amm-swap")
        XCTAssertTrue(rows.isEmpty)

        do {
            _ = try await OpenExchangeSwapLeg.moveBackSats(ctx)
            XCTFail("an empty basket moves nothing back")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "the swap basket holds no sats")
        }
    }

    // MARK: - executeSwap

    /// One leg's world at a stub host: its pools route lists the vectors' pool, its `/tx` serves
    /// the pool's BEEF, its `/swap` answers as `answer` says.
    struct Host {
        let w: LegWorld
        let http = StubHTTP()
        let exchange: OpenExchange
        let poolsURL: String
        let swapURL: String
        let poolTxid: String
        let pools: String

        init(_ c: [String: Any]) async throws {
            w = try await LegWorld(c)
            exchange = try OpenExchange(origin: "https://ex.test", http: http)
            let tokenBase = try exchange.tokenBase(SwapFixture.tokenId)
            poolsURL = "\(tokenBase)/pools"
            swapURL = "\(tokenBase)/swap"
            let p = SwapFixture.pool(w.c)
            poolTxid = String(p.outpoint.prefix(64))
            let identity = (SwapFixture.vectors["keys"] as! [String: Any])["identity"] as! String
            pools = #"{"market":{"identityKey":"\#(identity)"},"validators":[{"identity":"\#(p.validatorIdentityKey)","peerId":"peer-1"}],"pools":[{"outpoint":"\#(p.outpoint)","poolId":"\#(p.outpoint)","bsvReserve":"\#(p.bsvReserve)","tokenReserve":"\#(p.tokenReserve)","liquidityFeeBps":\#(p.liquidityFeeBps),"validationFeeBps":\#(p.validationFeeBps),"commissionBps":\#(p.commissionBps),"validatorIdentityKey":"\#(p.validatorIdentityKey)","validatorPeerId":"peer-1"}]}"#
            await http.json(poolsURL, pools)
            await http.route("\(tokenBase)/tx?id=\(poolTxid)", 200, try SwapFixture.poolBEEF())
        }

        func quote(_ amountIn: BigInt = 20_000) throws -> OpenExchangeQuote {
            try OpenExchangeQuotes.quoteSwap(
                OpenExchangeQuoteRequest(tokenId: SwapFixture.tokenId, side: .buy, amountIn: amountIn, maxSlippageBps: 100, maxSources: 1),
                held: try OpenExchangePools.read(JSONValue.parse(Array(pools.utf8))), sym: "TST", dec: 0
            )
        }

        /// The host relays the leg and answers the validator's transaction.
        func accepts() async throws {
            let signed = try w.signed
            let reply = #"{"ok":true,"tx":\#(OpenExchange.dagBytes(try signed.serialized(limits: txLimits))),"txid":"\#(try signed.transactionID(limits: txLimits).displayHex)"}"#
            await http.json(swapURL, reply)
        }

        func run(
            _ log: ProgressLog, cancelled: Bool = false, quote: OpenExchangeQuote? = nil, floor: BigInt? = nil, events: EventLog = EventLog()
        ) async throws -> OpenExchangeSwapResult {
            try await exchange.executeSwap(
                w.ctx, quote: quote ?? (try self.quote()), sym: "TST", floor: floor,
                isCancelled: { cancelled }, onProgress: { log.add($0) }, onEvent: { events.add($0) }
            )
        }

        var posts: Int { get async { await http.requests.filter { $0.url.absoluteString == swapURL }.count } }
    }

    func testABuyThatFillsIsOneLegTakenIn() async throws {
        let h = try await Host(Self.loop)
        let c = h.w.c
        try await h.w.overlay.unspent(try h.w.signed, vout: 1)
        try await h.accepts()
        let log = ProgressLog()
        let result = try await h.run(log)
        let signedID = c["signedTxid"] as! String
        let leg = SwapFixture.leg(c)
        let pool = SwapFixture.pool(c)
        let filled = [OpenExchangeLegResult(
            poolOutpoint: OpenExchangePrices.outpointText(pool.outpoint), poolId: pool.outpoint,
            amountIn: 20_000, amountOut: leg.amountOut, txid: signedID
        )]
        XCTAssertEqual(result, OpenExchangeSwapResult(
            status: .filled, stop: .filled, legs: filled, totalIn: 20_000, totalOut: leg.amountOut, unfilled: 0, stuck: nil, returned: nil
        ))
        XCTAssertEqual(log.all, [
            .relaying(leg: filled[0].poolOutpoint, amountIn: 20_000, amountOut: leg.amountOut, filled: []),
            .done(result),
        ])
        // The basket covered the leg: nothing staged; the leg built is the vectors' (its body).
        let created = await h.w.storage.created
        XCTAssertTrue(created.isEmpty)
        let requests = await h.http.requests
        let post = try XCTUnwrap(requests.first { $0.url.absoluteString == h.swapURL })
        XCTAssertEqual(post.body.map { String(decoding: $0, as: UTF8.self) }, c["body"] as? String)
        let calls = await h.w.storage.internalized
        XCTAssertEqual(calls.count, 1)
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, c["takeIn"] as! [[String: Any]], "fill")
        // The pool list was read before the leg and again before the stop.
        let reads = await h.http.urls.filter { $0 == h.poolsURL }
        XCTAssertEqual(reads.count, 2)
    }

    /// A leg refused (not `pool_spent`): its pool is excluded, the pass runs, and with no pool
    /// left the rows go back to the wallet.
    func testARefusedLegExcludesThePoolAndMovesTheRowsBack() async throws {
        let h = try await Host(Self.loop)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"below_minimum"}"#)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, events: events)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .noPool)
        XCTAssertEqual(result.legs, [])
        XCTAssertEqual(result.unfilled, 20_000)
        let processed = await h.w.storage.processed
        let moved = try Transaction(bytes: try XCTUnwrap(processed.last?.rawTX), limits: txLimits)
        XCTAssertEqual(result.returned, .moved(txid: try moved.transactionID(limits: txLimits).displayHex, tokens: 0))
        XCTAssertEqual(moved.inputs.map { "\($0.previousOutput.transactionID.displayHex).\($0.previousOutput.outputIndex)" }, [h.w.rowOutpoint])
        XCTAssertEqual(log.phases, ["relaying", "returning", "failed"])
        guard case .failed(let reported?, nil) = log.all.last else { return XCTFail("the end is not reported") }
        XCTAssertEqual(reported, result)
        let created = await h.w.storage.created
        XCTAssertEqual(created.last?.description, "AMM move back: TST sats")
        let pool = SwapFixture.pool(h.w.c).outpoint
        let id = try h.w.prepare().id
        XCTAssertEqual(events.notable, [
            .relayed(leg: OpenExchangePrices.outpointText(pool), attempt: 1, outcome: .refused(id: id, reason: "below_minimum", pool: nil)),
            .excluded(pool: pool, reason: "refused: below_minimum"),
            .returned(try XCTUnwrap(result.returned)),
        ])
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
    }

    /// Refused `pool_spent`: repricing; the next read still lists the pool at that outpoint, so
    /// it is not asked again.
    func testAPoolSpentRefusalReprices() async throws {
        let h = try await Host(Self.loop)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"pool_spent","detail":"moved"}"#)
        let log = ProgressLog()
        let result = try await h.run(log)
        XCTAssertEqual(result.stop, .noPool)
        XCTAssertEqual(log.phases, ["relaying", "repricing", "returning", "failed"])
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
    }

    /// No answer twice and nothing on the overlay: the leg is pending, its pool excluded, and
    /// nothing is moved back while it may still land.
    func testNoAnswerIsSentOnceMoreThenLeftPending() async throws {
        let h = try await Host(Self.loop)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"unreachable"}"#)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, events: events)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .noPool)
        XCTAssertNil(result.returned)
        let pool = SwapFixture.pool(h.w.c).outpoint
        let id = try h.w.prepare().id
        let noAnswer = OpenExchangeLegOutcome.unknown(id: id, reason: "no answer yet: the host could not reach the validator (unreachable)")
        XCTAssertEqual(events.notable, [
            .relayed(leg: OpenExchangePrices.outpointText(pool), attempt: 1, outcome: noAnswer),
            .relayed(leg: OpenExchangePrices.outpointText(pool), attempt: 2, outcome: noAnswer),
            .excluded(pool: pool, reason: "no answer twice: no answer yet: the host could not reach the validator (unreachable)"),
        ])
        let posts = await h.posts
        XCTAssertEqual(posts, 2)
        let processed = await h.w.storage.processed
        XCTAssertTrue(processed.isEmpty)
        let rows = try await OpenExchangeSwapLeg.satsHoldings(h.w.ctx)
        XCTAssertEqual(rows.map(\.outpoint), [h.w.rowOutpoint])
        let spends = await h.http.urls.filter { $0.contains("/spends?") }
        XCTAssertTrue(spends.contains("\(h.exchange.base)/spends?outpoint=\(OpenExchangePrices.outpointText(SwapFixture.pool(h.w.c).outpoint)),\(h.w.rowOutpoint)"))
    }

    /// No answer, but the overlay shows the staged row spent: the leg landed, and the pass
    /// takes it in and accounts it.
    func testNoAnswerButTheRowSpentIsALegTakenInByThePass() async throws {
        let h = try await Host(Self.loop)
        let c = h.w.c
        let signedID = c["signedTxid"] as! String
        try await h.w.overlay.unspent(try h.w.signed, vout: 1)
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"unreachable"}"#)
        let poolText = OpenExchangePrices.outpointText(SwapFixture.pool(c).outpoint)
        let row = h.w.rowOutpoint
        // The resolve on start finds the row unspent; after the leg, spent by the swap.
        await h.http.once("\(h.exchange.base)/spends?outpoint=\(row)", #"[{"outpoint":"\#(row)"}]"#)
        await h.http.json("\(h.exchange.base)/spends?outpoint=\(row)",
                          #"[{"outpoint":"\#(row)","tokenId":"\#(SwapFixture.tokenId)","spentBy":"\#(signedID)"}]"#)
        await h.http.json("\(h.exchange.base)/spends?outpoint=\(poolText),\(row)",
                          #"[{"outpoint":"\#(poolText)","spentBy":"\#(signedID)"},{"outpoint":"\#(row)","tokenId":"\#(SwapFixture.tokenId)","spentBy":"\#(signedID)"}]"#)
        let p = try h.w.prepare()
        let beef = try h.w.signedWithSources(p).beef
        let tokenBase = try h.exchange.tokenBase(SwapFixture.tokenId)
        await h.http.route("\(tokenBase)/tx?id=\(signedID)", 200, beef)
        let log = ProgressLog()
        let result = try await h.run(log)
        let leg = SwapFixture.leg(c)
        XCTAssertEqual(result.status, .filled)
        XCTAssertEqual(result.legs, [OpenExchangeLegResult(poolOutpoint: poolText, poolId: SwapFixture.pool(c).outpoint, amountIn: 20_000, amountOut: leg.amountOut, txid: signedID)])
        XCTAssertEqual(log.phases, ["relaying", "done"])
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
        let calls = await h.w.storage.internalized
        XCTAssertEqual(calls.map(\.description), ["AMM swap payout"])
    }

    /// Staged and never sent: what the basket lacked is staged, the swap is cancelled before its
    /// first leg, and every sats row goes back.
    func testACancelledSwapMovesItsStagedSatsBack() async throws {
        let h = try await Host(SwapFixture.legs[0])
        let quote = try h.quote(25_000)
        let have = (h.w.c["rowSats"] as! [NSNumber]).reduce(BigInt(0)) { $0 + BigInt($1.int64Value) }
        let lack = quote.stage.amount + quote.stage.feeSats - have
        XCTAssertGreaterThan(lack, 0)
        let log = ProgressLog()
        let result = try await h.run(log, cancelled: true, quote: quote)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.stop, .cancelled)
        XCTAssertEqual(log.phases, ["staging", "returning", "failed"])
        XCTAssertEqual(log.all.first, .staging(sats: lack, tokens: 0))
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), ["AMM swap: sats into the swap basket", "AMM move back: TST sats"])
        XCTAssertEqual(created[0].outputs?.first.map { BigInt($0.satoshis) }, lack)
        XCTAssertEqual(created[1].inputs?.count, 2)
        let rows = try await OpenExchangeSwapLeg.satsHoldings(h.w.ctx)
        XCTAssertTrue(rows.isEmpty)
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// A one-leg buy staged to the quote alone: the ~13 kB fee estimate is short of the leg's own
    /// fee, so the rows lack a few dozen sats. That shortfall is staged and the leg is sent (here
    /// refused, so the rows go back), where the TS stops `fees` with nothing sent.
    func testAFeeEstimateShortfallIsStagedAndTheLegSent() async throws {
        let h = try await Host(SwapFixture.legs[0])
        await h.http.json(h.swapURL, #"{"ok":false,"reason":"below_minimum"}"#)
        let quote = try h.quote(25_000)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .noPool, "\(events.all)")
        XCTAssertEqual(log.phases.filter { $0 == "staging" }.count, 2)
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), [
            "AMM swap: sats into the swap basket", "AMM swap: sats into the swap basket", "AMM move back: TST sats",
        ])
        let topUp = try XCTUnwrap(created[1].outputs?.first?.satoshis)
        XCTAssertGreaterThan(topUp, 0)
        XCTAssertLessThanOrEqual(BigInt(topUp), quote.legMinerFeeSats)
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
    }

    /// A top-up the wallet stages but whose row the basket still does not show: the leg is not
    /// sent, `onEvent` says the staged txid did not cover it, and the swap stops `fees`.
    func testATopUpStagedButNotInTheBasketStopsFees() async throws {
        let h = try await Host(SwapFixture.legs[0])
        await h.w.storage.unfile(create: 1)
        let quote = try h.quote(25_000)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .fees, "\(events.all)")
        XCTAssertEqual(log.phases.filter { $0 == "staging" }.count, 2)
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), [
            "AMM swap: sats into the swap basket", "AMM swap: sats into the swap basket", "AMM move back: TST sats",
        ])
        let topUp = try XCTUnwrap(created[1].outputs?.first?.satoshis)
        let staged = events.all.compactMap { if case let .staged(txid, sats, _, _, _) = $0 { (txid, sats) } else { nil } }
        XCTAssertEqual(staged.count, 2, "\(events.all)")
        XCTAssertEqual(staged.last.map { BigInt($0.1) }, BigInt(topUp))
        let failed = events.all.compactMap { if case let .stageFailed(sats, error) = $0 { (sats, error) } else { nil } }
        XCTAssertEqual(failed.map(\.0), [topUp])
        XCTAssertEqual(failed.map(\.1), ["staged \(staged.last?.0 ?? "") but the basket still does not cover the leg"])
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// A shortfall just over the allowance is not topped up: a quote priced at 1 sat/kB stages
    /// ~13 sats of miner fee where the leg at 100 sats/kB needs ~1,300 more, so the rows lack just
    /// over `legMinerFeeSats`. One staging, nothing sent, stop `fees`.
    func testAShortfallJustOverTheAllowanceStopsFeesWithOneStaging() async throws {
        let h = try await Host(SwapFixture.legs[0])
        let quote = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: SwapFixture.tokenId, side: .buy, amountIn: 25_000, maxSlippageBps: 100, maxSources: 1),
            held: try OpenExchangePools.read(JSONValue.parse(Array(h.pools.utf8))), sym: "TST", dec: 0, feeRateSatsPerKb: 1
        )
        XCTAssertEqual(quote.legMinerFeeSats, 13)
        // The same leg quoted at 100 sats/kB stages 1,287 sats more and then tops up `usualTopUp`:
        // here the rows lack both, just over that quote's 1,300-sat allowance.
        let usual = try await Host(SwapFixture.legs[0])
        await usual.http.json(usual.swapURL, #"{"ok":false,"reason":"below_minimum"}"#)
        let full = try usual.quote(25_000)
        _ = try await usual.run(ProgressLog(), quote: full)
        let usualCreated = await usual.w.storage.created
        let usualTopUp = BigInt(try XCTUnwrap(usualCreated[1].outputs?.first?.satoshis))
        XCTAssertEqual(full.legs, quote.legs)
        XCTAssertEqual(full.stage.feeSats - quote.stage.feeSats, full.legMinerFeeSats - quote.legMinerFeeSats)
        let lack = usualTopUp + full.legMinerFeeSats - quote.legMinerFeeSats
        XCTAssertGreaterThan(lack, full.legMinerFeeSats)
        XCTAssertLessThan(lack, full.legMinerFeeSats + 100)
        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .fees, "\(events.all)")
        XCTAssertEqual(log.phases.filter { $0 == "staging" }.count, 1)
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), ["AMM swap: sats into the swap basket", "AMM move back: TST sats"])
        XCTAssertTrue(events.all.allSatisfy { if case .stageFailed = $0 { false } else { true } }, "\(events.all)")
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// A later leg's fee shortfall that the wallet cannot stage (a spend-everything buy) stops the
    /// swap `fees`: the wallet's error goes to `onEvent`, the rows go back, and the leg already
    /// filled is in the result. The vectors' `topUp`: 80,000 sats over pool_deploy and a smaller
    /// pool (listed only, never chosen) split 53,333 + 26,667; the first leg's row is exactly its
    /// need, and the second row is 30 sats short of the second leg's.
    func testATopUpTheWalletCannotStageStopsFeesWithTheFilledLegs() async throws {
        let c = SwapFixture.vectors["topUp"] as! [String: Any]
        let h = try await Host(c)
        let p = SwapFixture.pool(c)
        let first = SwapFixture.leg(c)
        let small = #",{"outpoint":"\#(String(repeating: "ff", count: 32))_0","poolId":"small","bsvReserve":"500000","tokenReserve":"2500000","liquidityFeeBps":\#(p.liquidityFeeBps),"validationFeeBps":\#(p.validationFeeBps),"commissionBps":\#(p.commissionBps),"validatorIdentityKey":"\#(p.validatorIdentityKey)","validatorPeerId":"peer-1"}"#
        let pools = String(h.pools.dropLast(2)) + small + "]}"
        await h.http.json(h.poolsURL, pools)
        let quote = try OpenExchangeQuotes.quoteSwap(
            OpenExchangeQuoteRequest(tokenId: SwapFixture.tokenId, side: .buy, amountIn: 80_000, maxSlippageBps: 1_000, maxSources: 2),
            held: try OpenExchangePools.read(JSONValue.parse(Array(pools.utf8))), sym: "TST", dec: 0
        )
        XCTAssertEqual(quote.legs.count, 2)
        // The basket covers the quote's stage: nothing is staged before the first leg.
        let held = h.w.rows.reduce(BigInt(0)) { $0 + BigInt($1.satoshis) }
        XCTAssertGreaterThanOrEqual(held, quote.stage.amount + quote.stage.feeSats)
        // The second leg's row falls short of it by a fee shortfall.
        let secondRow = try XCTUnwrap(h.w.rows.min { $0.satoshis < $1.satoshis })
        let second = SwapFixture.leg(["leg": c["second"]!])
        let secondInput = OpenExchangeSwapLeg.LegInput(
            tokenId: SwapFixture.tokenId, leg: second, pool: p, poolBEEF: try SwapFixture.poolBEEF(), poolOutputIndex: 0,
            commissionPkh: c["commissionPkh"] as? String, satsPerKb: 100
        )
        XCTAssertNil(try OpenExchangeSwapLeg.selectInputs(secondInput, sats: [secondRow]))
        let lack = try XCTUnwrap(try OpenExchangeSwapLeg.feeShortfall(secondInput, sats: [secondRow], allowance: quote.legMinerFeeSats))
        try await h.w.overlay.unspent(try h.w.signed, vout: 1)
        try await h.accepts()
        // The leg taken in spends its row and files what it inserts, as wallet-toolbox does.
        await h.w.storage.setFilesInternalized(true)
        let stage = "AMM swap: sats into the swap basket"
        await h.w.storage.refuse(description: stage)

        let log = ProgressLog()
        let events = EventLog()
        let result = try await h.run(log, quote: quote, events: events)
        XCTAssertEqual(result.stop, .fees, "\(events.all)")
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.legs, [OpenExchangeLegResult(
            poolOutpoint: OpenExchangePrices.outpointText(p.outpoint), poolId: p.outpoint,
            amountIn: first.amountIn, amountOut: first.amountOut, txid: c["signedTxid"] as! String
        )])
        XCTAssertEqual(result.totalIn, 53_333)
        XCTAssertEqual(result.unfilled, 26_667)
        guard case .moved? = result.returned else { return XCTFail("the rows were not moved back: \(String(describing: result.returned))") }
        let failed = events.all.compactMap { if case let .stageFailed(sats, error) = $0 { (sats, error) } else { nil } }
        XCTAssertEqual(failed.map(\.0), [lack])
        XCTAssertTrue(failed.first?.1.contains("insufficient funds: 1 sats short") == true, "\(failed)")
        XCTAssertEqual(Array(log.phases.prefix(3)), ["relaying", "staging", "returning"])
        XCTAssertEqual(log.all[1], .staging(sats: BigInt(lack), tokens: 0))
        let created = await h.w.storage.created
        XCTAssertEqual(created.map(\.description), [stage, "AMM move back: TST sats"])
        XCTAssertEqual(created.last?.inputs?.map(\.outpoint.description), [secondRow.outpoint])
        let rows = try await OpenExchangeSwapLeg.satsHoldings(h.w.ctx)
        XCTAssertTrue(rows.isEmpty)
        let posts = await h.posts
        XCTAssertEqual(posts, 1)
    }

    /// A wallet with no 1Color overlay cannot take a leg's tokens in: the swap is refused before
    /// anything is staged or sent.
    func testASwapWithoutAnOverlayIsRefusedBeforeStaging() async throws {
        let h = try await Host(SwapFixture.legs[0])
        let bare = OneColorContext(
            identity: h.w.ctx.identity, storage: h.w.storage, auth: h.w.ctx.auth, maximumFee: h.w.ctx.maximumFee
        )
        do {
            _ = try await h.exchange.executeSwap(bare, quote: try h.quote(25_000), sym: "TST")
            XCTFail("a swap without an overlay ran")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "a swap needs the wallet's 1Color overlay to take its tokens in")
        }
        let created = await h.w.storage.created
        XCTAssertTrue(created.isEmpty)
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// The floor the person reviewed holds over the quote's: a leg that would bring less is not
    /// sent, and the rows go back.
    func testAFloorAboveTheLegStopsBeforeSending() async throws {
        let h = try await Host(Self.loop)
        let log = ProgressLog()
        let leg = SwapFixture.leg(h.w.c)
        let result = try await h.run(log, floor: leg.amountOut + 1)
        XCTAssertEqual(result.stop, .floor)
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(log.phases, ["returning", "failed"])
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
        // At exactly the leg's amount out, it fills.
        let ok = try await Host(Self.loop)
        try await ok.w.overlay.unspent(try ok.w.signed, vout: 1)
        try await ok.accepts()
        let filled = try await ok.run(ProgressLog(), floor: leg.amountOut)
        XCTAssertEqual(filled.status, .filled)
    }

    /// A caller's floor may only be stricter than the quote's minimum: a lower one is refused
    /// before anything is staged or sent.
    func testAFloorBelowTheQuotesMinimumIsRefused() async throws {
        let h = try await Host(Self.loop)
        let quote = try h.quote()
        do {
            _ = try await h.run(ProgressLog(), quote: quote, floor: quote.minAmountOut - 1)
            XCTFail("a floor below the minimum ran")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "the floor is below the quote's minimum received")
        }
        let created = await h.w.storage.created
        XCTAssertTrue(created.isEmpty)
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
    }

    /// TS `s.swapping`: a second swap on the same wallet while one runs is refused, and the gate
    /// opens again when the first ends.
    func testOneSwapAtATimePerWallet() async throws {
        let h = try await Host(Self.loop)
        let key = h.w.ctx.identityKey
        XCTAssertTrue(OpenExchangeSwapGate.shared.enter(key))
        do {
            _ = try await h.run(ProgressLog())
            XCTFail("a second swap ran")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "A swap is already running: one at a time")
        }
        let posts = await h.posts
        XCTAssertEqual(posts, 0)
        OpenExchangeSwapGate.shared.leave(key)
        try await h.w.overlay.unspent(try h.w.signed, vout: 1)
        try await h.accepts()
        let filled = try await h.run(ProgressLog())
        XCTAssertEqual(filled.status, .filled)
        // A finished run leaves the gate open.
        XCTAssertTrue(OpenExchangeSwapGate.shared.enter(key))
        OpenExchangeSwapGate.shared.leave(key)
    }

    // MARK: - The basket's totals

    func testTheBasketTotalsAreItsSatsAndEachTokensRows() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        let empty = try await OpenExchangeSwapLeg.swapBasketTotals(w.ctx)
        XCTAssertEqual(empty.sats, UInt64((w.c["rowSats"] as! [NSNumber])[0].int64Value))
        XCTAssertEqual(empty.satsOutputs, 1)
        XCTAssertEqual(empty.tokens, [:])
        // A token row (the leg's payout output, held in the basket as a sell's change would be).
        let signed = try w.signed
        try await w.storage.hold(signed, vout: 1, basket: "amm-swap", customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: "amm-swap-t"), sources: [])
        let amount = try XCTUnwrap(AMMPool.decodeOneColor(signed.outputs[1].lockingScript.bytes)).amount
        let totals = try await OpenExchangeSwapLeg.swapBasketTotals(w.ctx)
        XCTAssertEqual(totals.sats, empty.sats)
        XCTAssertEqual(totals.satsOutputs, 1)
        XCTAssertEqual(totals.tokens, [SwapFixture.tokenId: OpenExchangeSwapTokenTotal(amount: BigInt(amount), outputs: 1)])
    }

    func testAWireIdIsItsTokenId() throws {
        let txid = (0..<32).map { UInt8($0) }
        let display = AMMPool.hex(txid.reversed())
        XCTAssertEqual(try OpenExchangeSwapLeg.tokenIdOfWire(txid), "\(display)_0")
        XCTAssertEqual(try OpenExchangeSwapLeg.tokenIdOfWire(txid + [5, 1, 0, 0]), "\(display)_261")
        XCTAssertThrowsError(try OpenExchangeSwapLeg.tokenIdOfWire([1, 2]))
    }
}
