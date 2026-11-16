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

// The buy leg against skein-amm 0.55.1 (cc146be): web/ui/src/wallet/color.ts (the swap basket's
// names), lib/keys.ts, market/swapAction.ts (`legNeed`, `selectLegInputs`, `prepareSwap`,
// `takeInOutputs`, `fundingBeef`), pool/template.ts (`planSwap`, `callUnlock`), market/relay.ts
// (`swapBody`, `parseSwapReply`), market/swapFlow.ts (`relaySwap`, `swapIdOf`) and
// market/activeSwap.ts (`stage`). Fixtures/amm-swap-vectors.json is that TS's output over the
// fake wallet of web/ui/test/swap.test.ts, written by Fixtures/amm-swap-vectors.gen.sh under bun
// with seeded randomness; each test rebuilds the case in Swift and compares bytes.

/// The vectors, and the topic fixture they were built over.
enum SwapFixture {
    nonisolated(unsafe) static let vectors: [String: Any] = load("amm-swap-vectors")
    nonisolated(unsafe) static let topic: [String: Any] = load("amm-topic-vectors")

    static func load(_ name: String) -> [String: Any] {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static let tokenId = "948b532f1de8f7bb148f77da824544fe47b02079e7514d5b6a42856651c5214c_0"
    /// The fake wallet's root: `key(31)`.
    static let walletRoot = try! PrivateKey([UInt8](repeating: 0x1f, count: 32))

    static func bytes(_ hex: String) -> [UInt8] { try! Hex.decode(hex, maximumDecodedByteCount: hex.utf8.count / 2) }
    static func tx(_ hex: String) throws -> Transaction { try Transaction(bytes: bytes(hex), limits: txLimits) }
    static func topicTx(_ key: String) throws -> Transaction { try tx(topic[key] as! String) }
    static func hex(_ tx: Transaction) throws -> String { Hex.encode(try tx.serialized(limits: txLimits)) }

    static var legs: [[String: Any]] { vectors["legs"] as! [[String: Any]] }

    /// The pools lookup's Atomic BEEF of pool_deploy, its parents txid-only.
    static func poolBEEF() throws -> [UInt8] {
        let pool = try topicTx("pool_deploy")
        var parents: [TransactionID] = []
        for input in pool.inputs where !parents.contains(input.previousOutput.transactionID) {
            parents.append(input.previousOutput.transactionID)
        }
        let beef = try BEEF(version: .v2, merklePaths: [], transactions: parents.map { .transactionID($0) } + [.raw(pool)], limits: beefLimits)
        return try AtomicBEEF(subjectTransactionID: try pool.transactionID(limits: txLimits), beef: beef, limits: beefLimits)
            .serialized(limits: beefLimits)
    }

    static func leg(_ c: [String: Any]) -> AMMLeg {
        let l = c["leg"] as! [String: String]
        return AMMLeg(
            outpoint: l["outpoint"]!, amountIn: BigInt(l["amountIn"]!)!, liquidityFee: BigInt(l["liquidityFee"]!)!,
            validationFee: BigInt(l["validationFee"]!)!, commission: BigInt(l["commission"]!)!, amountOut: BigInt(l["amountOut"]!)!,
            newBsvReserve: BigInt(l["newBsvReserve"]!)!, newTokenReserve: BigInt(l["newTokenReserve"]!)!
        )
    }

    static func pool(_ c: [String: Any]) -> AMMPoolState {
        let p = c["pool"] as! [String: String]
        return AMMPoolState(
            outpoint: p["outpoint"]!, bsvReserve: BigInt(p["bsvReserve"]!)!, tokenReserve: BigInt(p["tokenReserve"]!)!,
            liquidityFeeBps: BigInt(p["liquidityFeeBps"]!)!, validationFeeBps: BigInt(p["validationFeeBps"]!)!,
            commissionBps: BigInt(p["commissionBps"]!)!, validatorIdentityKey: p["validatorIdentityKey"]!
        )
    }

    /// `takeInOutputs` as the TS writes each `InternalizeOutput`.
    static func render(_ output: ColorInternalize.Output) -> [String: Any] {
        switch output {
        case let .walletPayment(index, prefix, suffix, sender):
            ["outputIndex": Int(index), "protocol": "wallet payment",
             "paymentRemittance": ["derivationPrefix": prefix, "derivationSuffix": suffix, "senderIdentityKey": sender]]
        case let .basketInsertion(index, basket, instructions):
            ["outputIndex": Int(index), "protocol": "basket insertion",
             "insertionRemittance": ["basket": basket, "customInstructions": instructions]]
        }
    }
}

/// A BRC-207 overlay that admits the token's deploy and lists the outputs it is told are unspent.
actor StubOverlay: ColorOverlayProvider {
    private var admitted: [String: (beef: [UInt8], vout: UInt32)] = [:]
    private var unspent: [String: (beef: [UInt8], vout: UInt32)] = [:]

    init() throws {
        let deploy = try SwapFixture.topicTx("token_deploy")
        let id = try deploy.transactionID(limits: txLimits).displayHex
        admitted["\(id).0"] = (try graph([deploy]).serialized(limits: beefLimits), 0)
    }

    /// Lists output `vout` of `transaction` as admitted and unspent.
    func unspent(_ transaction: Transaction, vout: UInt32) throws {
        let id = try transaction.transactionID(limits: txLimits).displayHex
        unspent["\(id).\(vout)"] = (try graph([transaction]).serialized(limits: beefLimits), vout)
    }

    func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        ColorOutputList(outputs: outpoints.compactMap { unspent[$0].map { ColorOutputList.Item(beef: $0.beef, outputIndex: $0.vout) } })
    }

    func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        ColorOutputList(outputs: outpoints.compactMap {
            (admitted[$0] ?? unspent[$0]).map { ColorOutputList.Item(beef: $0.beef, outputIndex: $0.vout) }
        })
    }

    func submit(topics: [String], beef: [UInt8]) async throws -> [String: ColorAdmittance] {
        throw TestError("a swap leg submits nothing to the overlay")
    }
}

/// One leg case of the vectors, rebuilt: the fake wallet's swap basket in `MemoryStorage`, the
/// leg's input, the rows the basket lists and its BEEF.
struct LegWorld {
    let c: [String: Any]
    let storage: MemoryStorage
    let overlay: StubOverlay
    let ctx: OneColorContext
    let input: OpenExchangeSwapLeg.LegInput
    let rows: [OpenExchangeSatsRow]
    let holding: BEEF

    init(_ c: [String: Any]) async throws {
        self.c = c
        storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        overlay = try StubOverlay()
        let fund = try SwapFixture.topicTx("fund")
        let keyIDs = c["rowKeyIDs"] as! [String]
        for (n, hex) in (c["rows"] as! [String]).enumerated() {
            try await storage.hold(
                try SwapFixture.tx(hex), vout: 0, basket: "amm-swap",
                customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: keyIDs[n]), sources: [fund]
            )
        }
        ctx = OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000,
            overlay: overlay
        )
        input = OpenExchangeSwapLeg.LegInput(
            tokenId: SwapFixture.tokenId, leg: SwapFixture.leg(c), pool: SwapFixture.pool(c),
            poolBEEF: try SwapFixture.poolBEEF(), poolOutputIndex: 0,
            commissionPkh: c["commissionPkh"] as? String, satsPerKb: 100
        )
        rows = try await OpenExchangeSwapLeg.satsHoldings(ctx)
        let beef = try await OpenExchangeSwapLeg.basketBEEF(ctx)
        holding = try XCTUnwrap(beef)
    }

    /// `prepareSwap` over the rows `selectLegInputs` picks, as the generator calls it.
    func prepare() throws -> OpenExchangePreparedLeg {
        let picked = try XCTUnwrap(try OpenExchangeSwapLeg.selectInputs(input, sats: rows))
        let order = c["order"] as! String
        return try OpenExchangeSwapLeg.prepare(
            ctx, input, inputs: picked.sats, order: order == picked.sats.first?.outpoint ? nil : order,
            last: c["last"] as! Bool, holdingBEEF: holding
        )
    }

    var signed: Transaction { get throws { try SwapFixture.tx(c["signed"] as! String) } }
}

final class SwapLegTests: XCTestCase {
    // MARK: - Shared storage: names, instructions, keys

    func testTheSwapBasketsNamesAreTheTypeScriptOnes() throws {
        let n = SwapFixture.vectors["names"] as! [String: Any]
        XCTAssertEqual(OpenExchangeSwapNames.basket, n["basket"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.label, "amm-swap")
        let proto = try OpenExchangeSwapNames.swapProtocol()
        XCTAssertEqual([Int(proto.securityLevel.rawValue)] as [Any] as NSArray, [2] as NSArray)
        XCTAssertEqual(proto.name, (n["protocolID"] as! [Any])[1] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.keyPrefix, n["keyPrefix"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.stageLabel, n["stageLabel"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.keyMark, n["keyMark"] as? String)
        XCTAssertEqual(Int(OpenExchangeSwapNames.listLimit), n["listLimit"] as? Int)
        XCTAssertEqual(OpenExchangeSwapNames.p2pkhUnlockLength, n["p2pkhUnlockLength"] as? Int)
        XCTAssertEqual(OpenExchangeSwapNames.payoutPrefix, n["payoutPrefix"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.commissionPrefix, n["commissionPrefix"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.changePrefix, n["changePrefix"] as? String)
        for d in n["derivations"] as! [[String: String]] {
            let got = OpenExchangeSwapNames.legDerivation(d["input"]!, OpenExchangeSwapNames.Derivation(rawValue: d["which"]!)!)
            XCTAssertEqual(got.derivationPrefix, d["derivationPrefix"])
            XCTAssertEqual(got.derivationSuffix, d["derivationSuffix"])
        }
        XCTAssertEqual(try OpenExchangeSwapNames.changeKeyID(String(repeating: "cd", count: 32) + ".7"), n["changeKeyID"] as? String)
        let order = String(repeating: "ab", count: 32) + ".3"
        XCTAssertEqual(OpenExchangeSwapNames.swapInstructions(keyID: "amm-swap-0a"), n["swapInstructions"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.swapInstructions(keyID: "amm-swap-0a", order: order), n["swapInstructionsOrder"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.swapSatsInstructions(keyID: "amm-swap-0a"), n["swapSatsInstructions"] as? String)
        XCTAssertEqual(OpenExchangeSwapNames.swapSatsInstructions(keyID: "amm-swap-0a", order: order), n["swapSatsInstructionsOrder"] as? String)
    }

    func testThePoolKeysAreLibKeys() throws {
        let k = SwapFixture.vectors["keys"] as! [String: Any]
        let identity = k["identity"] as! String
        let txid = k["txid"] as! String
        XCTAssertEqual(try OpenExchangeKeys.validatorPubKey(validatorIdentity: identity, txid: txid, vout: 0), k["validatorPubKey"] as? String)
        XCTAssertEqual(try OpenExchangeKeys.firstValidatorPubKey(validatorIdentity: identity, nonce: k["nonce"] as! String), k["firstValidatorPubKey"] as? String)
        XCTAssertEqual(try OpenExchangeKeys.commissionPkh(marketIdentity: identity, txid: txid, vout: 0), k["commissionPkh"] as? String)
        let market = Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)
        XCTAssertEqual(
            try OpenExchangeKeys.commissionPkh(marketIdentity: market, txid: String(repeating: "ab", count: 32), vout: 5),
            k["commissionPkh5"] as? String
        )
    }

    // MARK: - The leg

    func testEachLegIsTheTypeScriptLegByteForByte() async throws {
        for c in SwapFixture.legs {
            let name = c["name"] as! String
            let w = try await LegWorld(c)
            let picked = try XCTUnwrap(try OpenExchangeSwapLeg.selectInputs(w.input, sats: w.rows), name)
            let need = c["need"] as! [String: Any]
            XCTAssertEqual(picked.need.outputs, (need["outputs"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.fee, (need["fee"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.need, (need["need"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.feeWithChange, (need["feeWithChange"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.need.needWithChange, (need["needWithChange"] as! NSNumber).int64Value, name)
            XCTAssertEqual(picked.sats.map(\.outpoint), c["selected"] as! [String], name)

            let p = try w.prepare()
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

    func testRowsThatCannotCoverTheLegAreNoSelection() async throws {
        let c = SwapFixture.legs[0]
        let w = try await LegWorld(c)
        let short = w.rows.map {
            OpenExchangeSatsRow(outpoint: $0.outpoint, txid: $0.txid, vout: $0.vout, satoshis: $0.satoshis - 1,
                                lockingScript: $0.lockingScript, protocolID: $0.protocolID, keyID: $0.keyID,
                                counterparty: $0.counterparty, order: $0.order)
        }
        XCTAssertNil(try OpenExchangeSwapLeg.selectInputs(w.input, sats: short))
        XCTAssertThrowsError(try OpenExchangeSwapLeg.prepare(w.ctx, w.input, inputs: short, last: false, holdingBEEF: w.holding))
    }

    /// Rows a few sats short of the leg: the shortfall is the need with one more row less what
    /// they hold, given only within the allowance; rows that cover the leg lack nothing.
    func testAFeeShortfallIsTheNeedWithOneMoreRowLessTheRows() async throws {
        let c = SwapFixture.legs[0]
        let w = try await LegWorld(c)
        let short = w.rows.map {
            OpenExchangeSatsRow(outpoint: $0.outpoint, txid: $0.txid, vout: $0.vout, satoshis: $0.satoshis - 20,
                                lockingScript: $0.lockingScript, protocolID: $0.protocolID, keyID: $0.keyID,
                                counterparty: $0.counterparty, order: $0.order)
        }
        XCTAssertNil(try OpenExchangeSwapLeg.selectInputs(w.input, sats: short))
        let utxo = try OpenExchangeSwapLeg.poolUtxo(w.input).utxo
        let plan = try OpenExchangeSwapLeg.legPlan(
            w.input, utxo, userPkh: OpenExchangeSwapLeg.zeroPkh, commissionPkh: try OpenExchangeSwapLeg.pkhBytes(w.input.commissionPkh)
        )
        let need = try OpenExchangeSwapLeg.legNeed(plan, inputs: short.count + 1, satsPerKb: 100).need
        let held = short.reduce(Int64(0)) { $0 + Int64($1.satoshis) }
        let lack = try XCTUnwrap(try OpenExchangeSwapLeg.feeShortfall(w.input, sats: short, allowance: 1_301))
        XCTAssertEqual(Int64(lack), need - held)
        // One more row of exactly that covers the leg.
        let topUp = OpenExchangeSatsRow(
            outpoint: String(repeating: "ee", count: 32) + ".0", txid: String(repeating: "ee", count: 32), vout: 0, satoshis: lack,
            lockingScript: short[0].lockingScript, protocolID: short[0].protocolID, keyID: short[0].keyID,
            counterparty: short[0].counterparty, order: nil
        )
        XCTAssertNotNil(try OpenExchangeSwapLeg.selectInputs(w.input, sats: short + [topUp]))
        // Beyond the allowance it is no shortfall to stage.
        XCTAssertNil(try OpenExchangeSwapLeg.feeShortfall(w.input, sats: short, allowance: BigInt(lack) - 1))
    }

    /// A proven funding ancestor can meet the walk ahead of its parent (mined together, or its
    /// parent's proof not yet in storage): the funding BEEF lists the parent first, others as walked.
    func testProvenFundingEntriesListAParentBeforeItsChild() throws {
        func tx(spending parent: Transaction?, tag: UInt32) throws -> Transaction {
            var t = Transaction(version: 1, lockTime: tag)
            let previous = try parent.map { Outpoint(transactionID: try $0.transactionID(limits: OpenExchangeSwapLeg.txLimits), outputIndex: 0) }
                ?? Outpoint(transactionID: try TransactionID(displayHex: String(repeating: "11", count: 32)), outputIndex: tag)
            t.inputs = [TransactionInput(previousOutput: previous, unlockingScript: try AMMPoolCall.script([]))]
            t.outputs = [TransactionOutput(satoshis: 1_000, lockingScript: try AMMPoolCall.script(AMMPoolCall.p2pkh(OpenExchangeSwapLeg.zeroPkh)))]
            return t
        }
        let parent = try tx(spending: nil, tag: 1)
        let child = try tx(spending: parent, tag: 2)
        let other = try tx(spending: nil, tag: 3)
        func ids(_ entries: [BEEFTransaction]) throws -> [String] {
            try entries.map { try $0.transaction!.transactionID(limits: OpenExchangeSwapLeg.txLimits).displayHex }
        }
        let ordered = try OpenExchangeSwapLeg.parentsFirst([.raw(child), .raw(other), .raw(parent)])
        XCTAssertEqual(try ids(ordered), try ids([.raw(other), .raw(parent), .raw(child)]))
        let kept = try OpenExchangeSwapLeg.parentsFirst([.raw(other), .raw(parent), .raw(child)])
        XCTAssertEqual(try ids(kept), try ids([.raw(other), .raw(parent), .raw(child)]))
    }

    func testALegPricedOnAnotherOutpointIsRefused() async throws {
        let c = SwapFixture.legs[0]
        let w = try await LegWorld(c)
        let l = w.input.leg
        let moved = OpenExchangeSwapLeg.LegInput(
            tokenId: w.input.tokenId,
            leg: AMMLeg(outpoint: String(repeating: "aa", count: 32) + "_0", amountIn: l.amountIn, liquidityFee: l.liquidityFee,
                        validationFee: l.validationFee, commission: l.commission, amountOut: l.amountOut,
                        newBsvReserve: l.newBsvReserve, newTokenReserve: l.newTokenReserve),
            pool: w.input.pool, poolBEEF: w.input.poolBEEF, poolOutputIndex: 0, commissionPkh: w.input.commissionPkh, satsPerKb: 100
        )
        XCTAssertThrowsError(try OpenExchangeSwapLeg.prepare(w.ctx, moved, inputs: w.rows, last: false, holdingBEEF: w.holding)) {
            XCTAssertTrue(OpenExchangeError.errorText($0).hasPrefix("the pool moved"), "\($0)")
        }
    }

    // MARK: - completeSwap

    func testEachLegsTakeInIsOneInternalizeOfTheValidatorsTransaction() async throws {
        for c in SwapFixture.legs {
            let name = c["name"] as! String
            let w = try await LegWorld(c)
            let p = try w.prepare()
            let signed = try w.signed
            try await w.overlay.unspent(signed, vout: 1)
            let done = try await OpenExchangeSwapLeg.complete(
                w.ctx, p, raw: try signed.serialized(limits: txLimits), txid: c["signedTxid"] as? String
            )
            XCTAssertEqual(done, OpenExchangeCompletedLeg(txid: c["signedTxid"] as! String, internalized: true, errors: []), name)
            let calls = await w.storage.internalized
            XCTAssertEqual(calls.count, 1, name)
            let call = try XCTUnwrap(calls.first)
            XCTAssertEqual(call.description, "AMM swap tokens", name)
            XCTAssertEqual(call.labels, ["amm-swap"], name)
            XCTAssertEqual(call.transaction.subjectTransactionID.displayHex, c["signedTxid"] as? String, name)
            try await assertTakeIn(call.outputs, c["takeIn"] as! [[String: Any]], name)
        }
    }

    func testATransactionThatIsNotTheSwapBuiltIsRefused() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        let p = try w.prepare()
        var other = try w.signed
        other.outputs[1] = TransactionOutput(satoshis: other.outputs[1].satoshis + 1, lockingScript: other.outputs[1].lockingScript)
        let otherID = try other.transactionID(limits: txLimits).displayHex
        do {
            _ = try await OpenExchangeSwapLeg.complete(w.ctx, p, raw: try other.serialized(limits: txLimits), txid: otherID)
            XCTFail("took in a transaction that is not the swap")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "the relay's transaction is not the swap we built")
        }
        let signedID = try w.signed.transactionID(limits: txLimits).displayHex
        do {
            _ = try await OpenExchangeSwapLeg.complete(w.ctx, p, raw: try w.signed.serialized(limits: txLimits), txid: otherID)
            XCTFail("took in a transaction under another txid")
        } catch {
            XCTAssertEqual(OpenExchangeError.errorText(error), "the relay's transaction is \(signedID), not \(otherID)")
        }
        let calls = await w.storage.internalized
        XCTAssertTrue(calls.isEmpty)
    }

    func testAWalletThatRefusesTheTakeInIsReportedNotThrown() async throws {
        let c = SwapFixture.legs[0]
        let w = try await LegWorld(c)
        let p = try w.prepare()
        // The overlay does not list the payout: the module's receipt check refuses it.
        let done = try await OpenExchangeSwapLeg.complete(w.ctx, p, raw: try w.signed.serialized(limits: txLimits), txid: nil)
        XCTAssertFalse(done.internalized)
        XCTAssertEqual(done.txid, c["signedTxid"] as? String)
        XCTAssertEqual(done.errors.count, 1)
        XCTAssertTrue(done.errors[0].hasPrefix("internalizeAction: "), done.errors[0])

        try await w.overlay.unspent(try w.signed, vout: 1)
        await w.storage.setInternalizeAccepts(false)
        let refused = try await OpenExchangeSwapLeg.complete(w.ctx, p, raw: try w.signed.serialized(limits: txLimits), txid: nil)
        XCTAssertEqual(refused, OpenExchangeCompletedLeg(txid: c["signedTxid"] as! String, internalized: false, errors: []))
    }

    // MARK: - The relay

    func testTheRelayPostsTheLegAndTakesInTheValidatorsTransaction() async throws {
        let relay = SwapFixture.vectors["relay"] as! [String: Any]
        let c = SwapFixture.legs[0]
        let w = try await LegWorld(c)
        let p = try w.prepare()
        try await w.overlay.unspent(try w.signed, vout: 1)
        let url = relay["url"] as! String
        let http = StubHTTP()
        await http.json(url, relay["reply"] as! String)
        let exchange = try OpenExchange(origin: "https://ex.test", http: http)
        let outcome = try await exchange.relayLeg(w.ctx, p, tokenId: SwapFixture.tokenId, peerId: "peer-1")
        let txid = relay["txid"] as! String
        XCTAssertEqual(outcome, .accepted(id: c["id"] as! String, txid: txid, completed: OpenExchangeCompletedLeg(txid: txid, internalized: true, errors: [])))
        let requests = await http.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, url)
        XCTAssertEqual(request.headers, relay["headers"] as? [String: String])
        XCTAssertEqual(request.body.map { String(decoding: $0, as: UTF8.self) }, relay["body"] as? String)
        let calls = await w.storage.internalized
        let internalize = (relay["internalize"] as! [[String: Any]])
        XCTAssertEqual(calls.count, internalize.count)
        XCTAssertEqual(calls.first?.description, internalize.first?["description"] as? String)
        XCTAssertEqual(calls.first?.labels, internalize.first?["labels"] as? [String])
        try await assertTakeIn(try XCTUnwrap(calls.first).outputs, internalize[0]["outputs"] as! [[String: Any]], "relay")
    }

    func testTheRelaysOtherAnswers() async throws {
        let w = try await LegWorld(SwapFixture.legs[0])
        let p = try w.prepare()
        let url = (SwapFixture.vectors["relay"] as! [String: Any])["url"] as! String
        func relay(_ http: any HTTPTransport, patienceMs: Int = OpenExchange.legPatienceMs) async throws -> OpenExchangeLegOutcome {
            try await OpenExchange(origin: "https://ex.test", http: http)
                .relayLeg(w.ctx, p, tokenId: SwapFixture.tokenId, peerId: "peer-1", patienceMs: patienceMs)
        }
        func answering(_ status: Int, _ text: String) async -> StubHTTP {
            let http = StubHTTP()
            await http.json(url, text, status: status)
            return http
        }
        let refusal = #"{"ok":false,"reason":"pool_spent","detail":"at x","pool":{"outpoint":"\#(String(repeating: "aa", count: 32))_0","bsvReserve":10,"tokenReserve":"20","lpFeeBps":30,"validatorFeeBps":5,"validatorIdentity":"02\#(String(repeating: "11", count: 32))"}}"#
        let refused = try await relay(await answering(200, refusal))
        XCTAssertEqual(refused, .refused(id: p.id, reason: "pool_spent: at x", pool: AMMPoolState(
            outpoint: String(repeating: "aa", count: 32) + "_0", bsvReserve: 10, tokenReserve: 20, liquidityFeeBps: 30,
            validationFeeBps: 5, commissionBps: 0, validatorIdentityKey: "02" + String(repeating: "11", count: 32)
        )))
        let bare = try await relay(await answering(200, #"{"ok":false,"reason":"bad_swap"}"#))
        XCTAssertEqual(bare, .refused(id: p.id, reason: "bad_swap", pool: nil))
        let unreachable = try await relay(await answering(200, #"{"ok":false,"reason":"unreachable"}"#))
        XCTAssertEqual(unreachable, .unknown(id: p.id, reason: "no answer yet: the host could not reach the validator (unreachable)"))
        let coded = try await relay(await answering(400, #"{"code":"ERR_BEEF","description":"no funding"}"#))
        XCTAssertEqual(coded, .failed(reason: "swap: ERR_BEEF: no funding"))
        let plain = try await relay(await answering(502, "bad gateway"))
        XCTAssertEqual(plain, .failed(reason: "swap: HTTP 502: bad gateway"))
        let dropped = try await relay(FailingHTTP())
        XCTAssertEqual(dropped, .unknown(id: p.id, reason: "no answer yet: connection reset"))
        let slow = try await relay(SlowHTTP(), patienceMs: 50)
        XCTAssertEqual(slow, .unknown(id: p.id, reason: "no answer yet: no answer within 50 ms"))
        let calls = await w.storage.internalized
        XCTAssertTrue(calls.isEmpty)
    }

    func testSwapRepliesParseAsTheTypeScriptDoes() throws {
        let replies = SwapFixture.vectors["replies"] as! [[String: String]]
        let parsed = try replies.map { try OpenExchange.parseSwapReply(XCTUnwrap(JSONValue.parse(Array($0["reply"]!.utf8)))) }
        XCTAssertEqual(parsed, [
            .accepted(tx: [0x00, 0xff], txid: "aa"),
            .refused(reason: "pool_spent: at x", pool: AMMPoolState(
                outpoint: String(repeating: "aa", count: 32) + "_0", bsvReserve: 10, tokenReserve: 20, liquidityFeeBps: 30,
                validationFeeBps: 5, commissionBps: 0, validatorIdentityKey: "02" + String(repeating: "11", count: 32)
            )),
            .unreachable(reason: "unreachable"),
            .refused(reason: "bad", pool: nil),
        ])
        // The TS parse of each, for the record the cases were read from.
        XCTAssertTrue(replies[1]["parsed"]!.contains(#""reason":"pool_spent: at x""#))
        XCTAssertTrue(replies[2]["parsed"]!.contains(#""unreachable":true"#))
        XCTAssertEqual(replies[3]["parsed"], #"{"ok":false,"reason":"bad"}"#)
    }

    // MARK: - Staging

    func testStagingIsTheTypeScriptCreateAction() async throws {
        let stage = SwapFixture.vectors["stage"] as! [String: Any]
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let ctx = OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let random = SwapFixture.bytes(stage["random"] as! String)
        XCTAssertEqual(OpenExchangeSwapNames.newSwapKeyID(random: random), stage["keyID"] as? String)
        let staged = try await OpenExchangeSwapLeg.stageSats(ctx, sats: 12_345, sym: "TST", randomKeyID: random)
        let next = (16..<32).map { UInt8(($0 * 37 + 11) & 0xff) }
        let long = try await OpenExchangeSwapLeg.stageSats(
            ctx, sats: 1, sym: "A very long token symbol for the swap description test", randomKeyID: next
        )
        XCTAssertEqual(long.sats.keyID, stage["longKeyID"] as? String)

        let created = await storage.created
        let want = stage["args"] as! [[String: Any]]
        XCTAssertEqual(created.count, want.count)
        for (got, w) in zip(created, want) {
            XCTAssertEqual(got.description, w["description"] as? String)
            XCTAssertEqual(got.labels, w["labels"] as? [String])
            XCTAssertNil(got.inputs)
            let outputs = w["outputs"] as! [[String: Any]]
            XCTAssertEqual(got.outputs?.count, outputs.count)
            for (o, wo) in zip(got.outputs ?? [], outputs) {
                XCTAssertEqual(Hex.encode(o.lockingScript), wo["lockingScript"] as? String)
                XCTAssertEqual(Int(o.satoshis), wo["satoshis"] as? Int)
                XCTAssertEqual(o.outputDescription, wo["outputDescription"] as? String)
                XCTAssertEqual(o.basket, wo["basket"] as? String)
                XCTAssertEqual(o.customInstructions, wo["customInstructions"] as? String)
            }
            let options = w["options"] as! [String: Bool]
            XCTAssertEqual(got.options?.randomizeOutputs, options["randomizeOutputs"])
            XCTAssertEqual(got.options?.acceptDelayedBroadcast, options["acceptDelayedBroadcast"])
            // Broadcast at once: the TS stage is a plain createAction, not a BRC-177 noSend.
            XCTAssertNil(got.options?.noSend)
        }
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 2)
        XCTAssertTrue(processed.allSatisfy { !$0.isNoSend })

        // The rows are what the basket lists, for the leg to spend.
        let rows = try await OpenExchangeSwapLeg.satsHoldings(ctx)
        XCTAssertEqual(Set(rows.map(\.outpoint)), [staged.sats.outpoint, long.sats.outpoint])
        XCTAssertEqual(rows.first { $0.outpoint == staged.sats.outpoint }, staged.sats)
        let total = try await OpenExchangeSwapLeg.swapBasketSats(ctx)
        XCTAssertEqual(total, 12_346)
        let records = await storage.basketRecords("amm-swap")
        let stored: [String?] = records.map(\.customInstructions)
        let wanted: [String?] = want.map { ($0["outputs"] as! [[String: Any]])[0]["customInstructions"] as? String }
        XCTAssertEqual(stored, wanted)
    }

    func testOnlyMarkedP2PKHRowsAreSatsRows() throws {
        let id = try TransactionID(displayHex: String(repeating: "12", count: 32))
        let p2pkh = [0x76, 0xa9, 0x14] + [UInt8](repeating: 7, count: 20) + [0x88, 0xac]
        func row(_ vout: UInt32, _ script: [UInt8], _ instructions: String?) throws -> WalletOutput {
            try WalletOutput(satoshis: 500, lockingScript: script, spendable: true, customInstructions: instructions, outpoint: Outpoint(transactionID: id, outputIndex: vout))
        }
        let rows = OpenExchangeSwapLeg.satsRows([
            try row(0, p2pkh, OpenExchangeSwapNames.swapSatsInstructions(keyID: "amm-swap-a", order: "o.1")),
            try row(1, p2pkh, OpenExchangeSwapNames.swapInstructions(keyID: "amm-swap-b")),
            try row(2, [0x6a] + p2pkh, OpenExchangeSwapNames.swapSatsInstructions(keyID: "amm-swap-c")),
            try row(3, p2pkh, nil),
        ])
        XCTAssertEqual(rows.map(\.outpoint), ["\(id.displayHex).0"])
        XCTAssertEqual(rows.first?.keyID, "amm-swap-a")
        XCTAssertEqual(rows.first?.order, "o.1")
    }
}

/// A transport whose request fails before any answer.
struct FailingHTTP: HTTPTransport {
    struct Reset: Error, LocalizedError { var errorDescription: String? { "connection reset" } }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw Reset() }
}

/// A transport that answers after the page's patience has run out.
struct SlowHTTP: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return HTTPResponse(statusCode: 200, body: Array(#"{"ok":false,"reason":"late"}"#.utf8))
    }
}

extension XCTestCase {
    /// The wallet's take-in is the TS one, except that a `p color` receipt is stored as the
    /// color module stores it: encrypted to the wallet, with a derivation-suffix tag.
    func assertTakeIn(_ got: [WalletInternalizeOutput], _ want: [[String: Any]], _ name: String) async throws {
        XCTAssertEqual(got.count, want.count, name)
        for (output, w) in zip(got, want) {
            XCTAssertEqual(Int(output.outputIndex), w["outputIndex"] as? Int, name)
            switch output.remittance {
            case .walletPayment(let r):
                let pay = try XCTUnwrap(w["paymentRemittance"] as? [String: String], name)
                XCTAssertEqual(r.derivationPrefix.base64, pay["derivationPrefix"], name)
                XCTAssertEqual(r.derivationSuffix.base64, pay["derivationSuffix"], name)
                XCTAssertEqual(Hex.encode(r.senderIdentityKey.compressedBytes), pay["senderIdentityKey"], name)
            case .basketInsertion(let r):
                let insertion = try XCTUnwrap(w["insertionRemittance"] as? [String: String], name)
                XCTAssertEqual(r.basket, insertion["basket"], name)
                if r.basket.hasPrefix("p color ") {
                    let stored = try XCTUnwrap(r.customInstructions)
                    XCTAssertNotEqual(stored, insertion["customInstructions"], name)
                    let plain = await ColorMetadata.decrypt(stored, identity: SwapFixture.walletRoot)
                    XCTAssertEqual(plain, insertion["customInstructions"], name)
                    XCTAssertEqual(r.tags.filter(ColorIdentifiers.isDerivationSuffixTag).count, 1, name)
                } else {
                    XCTAssertEqual(r.customInstructions, insertion["customInstructions"], name)
                }
            }
        }
    }
}
