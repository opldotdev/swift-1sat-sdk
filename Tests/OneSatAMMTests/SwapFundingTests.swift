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
@testable import OneSatAMM

// Not in skein-amm: a swap's staging funded from the change basket's best coins, chosen here
// (confirmed first, then the least unproven ancestry), as a noSend with `noSendChange`, then sent
// alone with `sendWith`. The outputs, their order, labels and options stay the TS's.

final class SwapFundingTests: XCTestCase {
    func context(_ storage: MemoryStorage) -> OneColorContext {
        OneColorContext(
            identity: SwapFixture.walletRoot, storage: storage,
            auth: AuthID(identityKey: Hex.encode(SwapFixture.walletRoot.publicKey.compressedBytes)), maximumFee: 20_000
        )
    }

    /// A storage that lists only the coins added here.
    func storage() async throws -> MemoryStorage {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setListsChange(true)
        await storage.dropFunding()
        return storage
    }

    // MARK: - rank, pick

    func testRankPutsConfirmedFirstThenTheLeastUnprovenAncestry() async throws {
        let storage = try await storage()
        let deep = try await storage.addFunding(90_000, proven: false, chain: 3)
        let shallow = try await storage.addFunding(7_000, proven: false)
        let small = try await storage.addFunding(5_000, proven: true)
        let large = try await storage.addFunding(20_000, proven: true)
        let ranked = try await OpenExchangeSwapFunding.coins(context(storage))
        XCTAssertEqual(ranked.map(\.outpoint), [large, small, shallow, deep].map(\.description))
        XCTAssertEqual(ranked.map(\.proven), [true, true, false, false])
        XCTAssertEqual(ranked.prefix(2).map(\.unprovenBytes), [0, 0])
        XCTAssertLessThan(ranked[2].unprovenBytes, ranked[3].unprovenBytes)
        // The whole basket is read with its transactions.
        let listed = await storage.listed
        XCTAssertEqual(listed.map(\.basket), ["default"])
        XCTAssertEqual(listed.map(\.include), [.entireTransactions])
    }

    func testRankBreaksTiesByMoreSatsThenOutpoint() {
        let coins = [
            OpenExchangeFundingCoin(outpoint: "bb.0", satoshis: 10, proven: false, unprovenBytes: 100),
            OpenExchangeFundingCoin(outpoint: "aa.1", satoshis: 10, proven: false, unprovenBytes: 100),
            OpenExchangeFundingCoin(outpoint: "cc.0", satoshis: 50, proven: false, unprovenBytes: 100),
            OpenExchangeFundingCoin(outpoint: "dd.0", satoshis: 1, proven: false, unprovenBytes: 99),
        ]
        XCTAssertEqual(coins.sorted(by: OpenExchangeSwapFunding.better).map(\.outpoint), ["dd.0", "cc.0", "aa.1", "bb.0"])
    }

    func testPickTakesTheBestUntilTheNeedIsCovered() {
        let ranked = [
            OpenExchangeFundingCoin(outpoint: "a.0", satoshis: 1_000, proven: true, unprovenBytes: 0),
            OpenExchangeFundingCoin(outpoint: "b.0", satoshis: 2_000, proven: true, unprovenBytes: 0),
            OpenExchangeFundingCoin(outpoint: "c.0", satoshis: 9_000, proven: false, unprovenBytes: 300),
        ]
        XCTAssertEqual(OpenExchangeSwapFunding.pick(ranked, need: 1_000).map(\.outpoint), ["a.0"])
        XCTAssertEqual(OpenExchangeSwapFunding.pick(ranked, need: 2_500).map(\.outpoint), ["a.0", "b.0"])
        // Short: every coin, storage adds the rest.
        XCTAssertEqual(OpenExchangeSwapFunding.pick(ranked, need: 50_000).map(\.outpoint), ["a.0", "b.0", "c.0"])
        XCTAssertEqual(OpenExchangeSwapFunding.pick([], need: 1), [])
        // The outputs less the caller's inputs, the leg fee allowance (13 kB) and one sat.
        XCTAssertEqual(OpenExchangeSwapFunding.need(outputs: 12_345, callerInputs: 0, feeRateSatsPerKb: 100), 12_345 + 1_300 + 1)
        XCTAssertEqual(OpenExchangeSwapFunding.need(outputs: 10, callerInputs: 50, feeRateSatsPerKb: 100), 1_301)
    }

    // MARK: - The staging

    /// The sats staging: the same request as the TS's, plus `noSend` and `noSendChange` (every
    /// ranked coin, the best last); processed as a noSend, then sent alone; it spends the picks.
    func testStageSatsSpendsTheChosenCoinsBestLastThenSendsThem() async throws {
        let storage = try await storage()
        let deep = try await storage.addFunding(80_000, proven: false, chain: 2)
        let second = try await storage.addFunding(6_000, proven: true)
        let best = try await storage.addFunding(8_000, proven: true)
        let ctx = context(storage)
        let random = (0..<16).map { UInt8($0) }
        let plain = try OpenExchangeSwapLeg.stageRequest(ctx, sats: 12_345, sym: "TST", keyID: OpenExchangeSwapNames.newSwapKeyID(random: random))
        let staged = try await OpenExchangeSwapLeg.stageSats(ctx, sats: 12_345, sym: "TST", randomKeyID: random)

        let created = await storage.created
        XCTAssertEqual(created.count, 1)
        let got = try XCTUnwrap(created.first)
        XCTAssertEqual(got.options?.noSend, true)
        XCTAssertEqual(got.options?.noSendChange, [deep, second, best])
        XCTAssertNil(got.inputs)
        // Everything else is the TS's request.
        XCTAssertEqual(got.description, plain.description)
        XCTAssertEqual(got.labels, plain.labels)
        XCTAssertEqual(got.outputs, plain.outputs)
        XCTAssertEqual(got.options?.signAndProcess, plain.options?.signAndProcess)
        XCTAssertEqual(got.options?.acceptDelayedBroadcast, plain.options?.acceptDelayedBroadcast)
        XCTAssertEqual(got.options?.randomizeOutputs, plain.options?.randomizeOutputs)

        let processed = await storage.processed
        XCTAssertEqual(processed.count, 2)
        XCTAssertEqual(processed.first?.isNoSend, true)
        XCTAssertEqual(processed.first?.isNewTx, true)
        XCTAssertEqual(processed.last?.isNewTx, false)
        XCTAssertEqual(processed.last?.isSendWith, true)
        XCTAssertEqual(processed.last?.isNoSend, false)
        XCTAssertEqual(processed.last?.sendWith, [staged.txid])

        let tx = try ColorBEEF.open(staged.atomicBEEF).transaction
        XCTAssertEqual(Set(tx.inputs.map(\.previousOutput)), Set([best, second]))
        XCTAssertEqual(staged.funding, ColorFundingReport(
            sent: [deep, second, best].map(\.description), used: [best, second].map(\.description),
            unused: [deep.description], topUps: [], fellBack: nil
        ))
        // The row is the TS's.
        XCTAssertEqual(staged.sats?.outpoint, "\(staged.txid).0")
        XCTAssertEqual(staged.sats?.satoshis, 12_345)
        let aborted = await storage.aborted
        XCTAssertTrue(aborted.isEmpty)
    }

    /// `stage` of sats alone is `stageSats`, funded the same way.
    func testStageWithoutTokensIsFundedAsStageSats() async throws {
        let storage = try await storage()
        let best = try await storage.addFunding(50_000, proven: true)
        let staged = try await OpenExchangeSwapLeg.stage(context(storage), sats: 1_000)
        XCTAssertEqual(staged.funding?.used, [best.description])
    }

    /// Storage leaving a chosen coin it did not spend marked spent (wallet-toolbox 2.1.x took and
    /// let go of `noSendChange` coins as it sized its change): the action is aborted, which
    /// releases it, and the plain request goes instead, reported as a fallback.
    func testAChosenCoinLeftMarkedSpentAbortsAndGoesPlain() async throws {
        let storage = try await storage()
        let deep = try await storage.addFunding(80_000, proven: false, chain: 2)
        let second = try await storage.addFunding(6_000, proven: true)
        let best = try await storage.addFunding(20_000, proven: true)
        await storage.setLocksAnUnusedNoSendChange(true)
        let staged = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 12_345)

        let created = await storage.created
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.first?.options?.noSendChange, [deep, second, best])
        XCTAssertNil(created.last?.options?.noSendChange)
        let aborted = await storage.aborted
        XCTAssertEqual(aborted.count, 1)
        let report = try XCTUnwrap(staged.funding)
        let fellBack = try XCTUnwrap(report.fellBack, report.text)
        XCTAssertTrue(fellBack.contains(second.description), fellBack)
        XCTAssertEqual(report.used, [])
    }

    /// Storage that cannot fund the staging (`WERR_INSUFFICIENT_FUNDS`) has made no action and
    /// marked no coin spent (wallet-toolbox plans the funding before it writes): nothing is
    /// aborted or tried again, every chosen coin is still the basket's, and the error is a
    /// refusal that gives storage's shortfall.
    func testAStagingStorageCannotFundHoldsNothingAndGivesTheShortfall() async throws {
        let storage = try await storage()
        let best = try await storage.addFunding(1_000, proven: true)
        let other = try await storage.addFunding(500, proven: false)
        let ctx = context(storage)
        do {
            _ = try await OpenExchangeSwapLeg.stageSats(ctx, sats: 5_000)
            XCTFail("an unfundable staging returned")
        } catch {
            // 5,000 sats and the fake's 200 fee, from 1,500 offered.
            XCTAssertEqual(WalletShortfall.of(error), WalletShortfall(moreSatoshisNeeded: 3_700, totalSatoshisNeeded: 5_200))
            XCTAssertEqual(OpenExchangeError.of(error), .refused(
                code: "WERR_INSUFFICIENT_FUNDS", message: "WERR_INSUFFICIENT_FUNDS: Not enough BSV: 3700 more sats needed, 5200 in all"
            ))
        }
        let created = await storage.created
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.options?.noSendChange, [other, best])
        let processed = await storage.processed
        XCTAssertTrue(processed.isEmpty)
        let aborted = await storage.aborted
        XCTAssertTrue(aborted.isEmpty)
        let ranked = try await OpenExchangeSwapFunding.coins(ctx)
        XCTAssertEqual(ranked.map(\.outpoint), [best, other].map(\.description))
    }

    /// Storage spending coins of its own beside (or instead of) the chosen ones: reported.
    func testAStorageTopUpIsReported() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setListsChange(true)
        // The basket's roots are not offered (their transaction is still sending), so storage,
        // ignoring the listed coin, tops up from a coin outside the ranking.
        let roots = try await OpenExchangeSwapFunding.coins(context(storage))
        let rootTxid = try XCTUnwrap(roots.first?.outpoint.split(separator: ".").first.map(String.init))
        await storage.setActions([try heldAction(rootTxid, status: .sending)])
        let chosen = try await storage.addFunding(2_000, proven: true)
        await storage.setIgnoresNoSendChange(true)
        let staged = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 500)
        let report = try XCTUnwrap(staged.funding)
        XCTAssertTrue(report.unused.contains(chosen.description), report.text)
        XCTAssertEqual(report.topUps.count, 1, report.text)
        XCTAssertNil(report.fellBack)
    }

    /// Storage refusing a `noSendChange` outpoint: the plain request goes once instead.
    func testAnInvalidNoSendChangeFallsBackToThePlainRequest() async throws {
        let storage = try await storage()
        let coin = try await storage.addFunding(40_000, proven: true)
        await storage.setRefusesNoSendChange(true)
        let staged = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 1_000)
        let created = await storage.created
        XCTAssertEqual(created.count, 2)
        XCTAssertEqual(created.first?.options?.noSendChange, [coin])
        XCTAssertNil(created.last?.options?.noSend)
        XCTAssertNil(created.last?.options?.noSendChange)
        XCTAssertEqual(created.first?.outputs, created.last?.outputs)
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed.first?.isNoSend, false)
        let fellBack = try XCTUnwrap(staged.funding?.fellBack)
        XCTAssertTrue(fellBack.contains("noSendChange"), fellBack)
    }

    /// A send that fails aborts the held action and throws.
    func testASendThatFailsAbortsTheStaging() async throws {
        let storage = try await storage()
        _ = try await storage.addFunding(40_000, proven: true)
        await storage.setSendOnly(.failed)
        do {
            _ = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 1_000)
            XCTFail("a staging whose send failed returned")
        } catch {
            XCTAssertTrue("\(error)".contains("broadcast failed"), "\(error)")
        }
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 2)
        let aborted = await storage.aborted
        XCTAssertEqual(aborted, [try XCTUnwrap(processed.first?.reference)])
    }

    /// A send-only call that throws leaves the staging held, not aborted: it may be out, and
    /// recovery sends it again.
    func testASendThatThrowsLeavesTheStagingHeld() async throws {
        let storage = try await storage()
        _ = try await storage.addFunding(40_000, proven: true)
        await storage.setSendOnly(.unproven, error: "the network is down")
        do {
            _ = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 1_000)
            XCTFail("a staging whose send threw returned")
        } catch {
            XCTAssertTrue("\(error)".contains("the network is down"), "\(error)")
        }
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 2)
        let aborted = await storage.aborted
        XCTAssertEqual(aborted, [])
    }

    /// A send storage leaves `sending` is its monitor's to broadcast: the staging fails, not aborted.
    func testASendLeftSendingIsNotAborted() async throws {
        let storage = try await storage()
        _ = try await storage.addFunding(40_000, proven: true)
        await storage.setSendOnly(.sending)
        do {
            _ = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 1_000)
            XCTFail("a staging left sending returned")
        } catch {
            XCTAssertTrue("\(error)".contains("broadcast sending"), "\(error)")
        }
        let aborted = await storage.aborted
        XCTAssertEqual(aborted, [])
    }

    /// Outputs of a transaction not yet broadcast (`nosend` or `sending`) are not chosen.
    func testCoinsOfUnsentActionsAreLeftOut() async throws {
        let storage = try await storage()
        let held = try await storage.addFunding(90_000, proven: true)
        let queued = try await storage.addFunding(80_000, proven: true)
        let done = try await storage.addFunding(10_000, proven: true)
        await storage.setActions([
            try heldAction(held.transactionID.displayHex, status: .nosend),
            try heldAction(queued.transactionID.displayHex, status: .sending),
            try heldAction(done.transactionID.displayHex, status: .completed),
        ])
        let ranked = try await OpenExchangeSwapFunding.coins(context(storage))
        XCTAssertEqual(ranked.map(\.outpoint), [done.description])
        let asked = await storage.listedActions
        XCTAssertEqual(asked.map(\.labels), [[]])
    }

    /// An empty change basket reads no actions.
    func testAnEmptyBasketReadsNoActions() async throws {
        let storage = try await storage()
        let ranked = try await OpenExchangeSwapFunding.coins(context(storage))
        XCTAssertEqual(ranked, [])
        let asked = await storage.listedActions
        XCTAssertTrue(asked.isEmpty)
    }

    /// A basket that lists nothing: the TS's plain staging, storage choosing the change.
    func testAnEmptyChangeBasketStagesAsTheTypeScriptDoes() async throws {
        let storage = try await storage()
        _ = try await storage.addFunding(40_000, proven: true)
        await storage.setListsChange(false)
        let staged = try await OpenExchangeSwapLeg.stageSats(context(storage), sats: 1_000)
        XCTAssertNil(staged.funding)
        let created = await storage.created
        XCTAssertNil(created.first?.options?.noSend)
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 1)
    }

    // MARK: - A staging held between its two calls

    func heldAction(_ txid: String, status: WalletActionStatus) throws -> WalletAction {
        try WalletAction(
            transactionID: try TransactionID(displayHex: txid), satoshis: 0, status: status, isOutgoing: true,
            description: "AMM swap: TST into the swap basket", version: 1, lockTime: 0
        )
    }

    func testAHeldStagingIsSentOnRecovery() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let held = String(repeating: "ab", count: 32)
        let done = String(repeating: "cd", count: 32)
        await storage.setActions([try heldAction(held, status: .nosend), try heldAction(done, status: .completed)])
        let events = SettleLog()
        let sent = await OpenExchangeSwapLeg.recoverHeldStages(context(storage), onEvent: { events.add($0) })
        XCTAssertEqual(sent, [held])
        XCTAssertEqual(events.all, [.heldSent(txid: held)])
        let processed = await storage.processed
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed.first?.isNewTx, false)
        XCTAssertEqual(processed.first?.sendWith, [held])
        let asked = await storage.listedActions
        XCTAssertEqual(asked.first?.labels, [OpenExchangeSwapNames.label])
        let aborted = await storage.aborted
        XCTAssertTrue(aborted.isEmpty)
    }

    /// Storage's answer to the re-send, told as it is; none is aborted.
    func testAHeldStagingsSendIsToldAsStorageAnswers() async throws {
        let held = String(repeating: "ab", count: 32)
        for (status, error, event) in [
            (SendWithResult.Status.sending, nil, OpenExchangeSettleEvent.heldSending(txid: held)),
            (.failed, nil, .heldFailed(txid: held)),
            (.unproven, "the network is down", .heldKept(txid: held, error: "the network is down")),
        ] as [(SendWithResult.Status, String?, OpenExchangeSettleEvent)] {
            let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
            await storage.setActions([try heldAction(held, status: .nosend)])
            await storage.setSendOnly(status, error: error)
            let events = SettleLog()
            let sent = await OpenExchangeSwapLeg.recoverHeldStages(context(storage), onEvent: { events.add($0) })
            XCTAssertEqual(sent, [], "\(status)")
            XCTAssertEqual(events.all, [event])
            let aborted = await storage.aborted
            XCTAssertEqual(aborted, [], "\(status)")
        }
    }

    /// A held staging past the first page of actions is still found.
    func testHeldStagingsAreFoundOnEveryPage() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        let held = String(repeating: "ab", count: 32)
        var actions = try (0..<1_000).map { i in
            try heldAction(String(format: "%064x", i + 1), status: .completed)
        }
        actions.append(try heldAction(held, status: .nosend))
        await storage.setActions(actions)
        let sent = await OpenExchangeSwapLeg.recoverHeldStages(context(storage))
        XCTAssertEqual(sent, [held])
        let asked = await storage.listedActions
        XCTAssertEqual(asked.map(\.pagination.effectiveOffset), [0, 1_000])
        XCTAssertEqual(asked.map(\.pagination.effectiveLimit), [1_000, 1_000])
    }

    func testUnreadActionsAreToldNotDropped() async throws {
        let storage = try MemoryStorage(identity: SwapFixture.walletRoot)
        await storage.setActions([], error: "down")
        let events = SettleLog()
        let sent = await OpenExchangeSwapLeg.recoverHeldStages(context(storage), onEvent: { events.add($0) })
        XCTAssertEqual(sent, [])
        XCTAssertEqual(events.all, [.heldUnread(error: "down")])
    }
}
