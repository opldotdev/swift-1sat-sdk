import BSVKeys
import BSVTransaction
import BSVWallet
import Foundation
import OneSatClient
import OneSatSweep
import ToolboxActions
import XCTest
@testable import OneSatActions

/// The per-step runner against `@1sat/sweep-ui` `sweeper.ts` `sweepAllClasses`, with fake steps.
final class LegacySweepRunnerTests: XCTestCase {

    // MARK: - G2: a failing step does not end the run

    func test_aFailedBsvStepStillRunsTheOrdinalsAndKeepsTheirTxids() async throws {
        let recorder = Recorder()
        let input = try keyInput([
            out(0, sats: 5_000),
            out(1, sats: 1, events: ["1sat"]),
        ])
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder, failBsv: true))
        XCTAssertEqual(report.failures.map(\.label), ["BSV"])
        XCTAssertEqual(report.failures.first?.message, "dust")
        XCTAssertEqual(report.ordinalTxids, ["ord-1"])
        XCTAssertTrue(report.bsvTxids.isEmpty)
        XCTAssertEqual(report.leftovers, [leftover(.bsv, 0, .stepFailed)])
        XCTAssertEqual(report.sweptOutpoints, [ref(1)])
        XCTAssertEqual(report.sweptSatoshis, 0)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step != "beef" }.map(\.step), ["bsv", "ordinals"])
    }

    func test_aFailedResultThatStillBroadcastKeepsItsTxid() async throws {
        let recorder = Recorder()
        let input = try keyInput([out(0, sats: 5_000)])
        var steps = steps(recorder)
        steps.fundBsv = { _, _ in ActionResult(txid: "late", error: "submit failed") }
        let report = try await LegacySweepRunner.run(input, steps: steps)
        XCTAssertEqual(report.bsvTxids, ["late"])
        XCTAssertEqual(report.failures.map(\.message), ["submit failed"])
        XCTAssertEqual(report.leftovers, [leftover(.bsv, 0, .broadcastUnconfirmed)])
    }

    // MARK: - G5: ordinals in batches of 25, BEEF per batch

    func test_sixtyOrdinalsGoInBatchesOf25_25_10() async throws {
        let recorder = Recorder()
        let input = try keyInput((0..<60).map { out(UInt32($0), sats: 1, events: ["1sat"]) })
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.map(\.count), [25, 25, 10])
        XCTAssertEqual(calls.filter { $0.step == "beef" }.map(\.count), [25, 25, 10])
        XCTAssertEqual(report.ordinalTxids.count, 3)
        XCTAssertTrue(report.leftovers.isEmpty)
        XCTAssertTrue(report.failures.isEmpty)
    }

    func test_aFailedSecondBatchKeepsTheFirstAndLeaves35() async throws {
        let recorder = Recorder()
        let input = try keyInput((0..<60).map { out(UInt32($0), sats: 1, events: ["1sat"]) })
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder, failOrdinalCall: 2))
        XCTAssertEqual(report.ordinalTxids, ["ord-1"])
        XCTAssertEqual(report.failures.map(\.label), ["Ordinals batch 2/3"])
        XCTAssertEqual(report.leftovers.count, 35)
        XCTAssertEqual(report.leftovers.filter { $0.reason == .stepFailed }.count, 25)
        XCTAssertEqual(report.leftovers.filter { $0.reason == .notAttempted }.count, 10)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.count, 2, "a failed batch stops the class")
    }

    // MARK: - G6: only 1-sat ordinals move

    func test_aTwoSatInscriptionIsLeftAndTheRestMove() async throws {
        let recorder = Recorder()
        let input = try keyInput([
            out(0, sats: 1, events: ["1sat"]),
            out(1, sats: 2, events: ["insc", "type:image/png"]),
            out(2, sats: 1, events: ["1sat", "type:application/op-ns"]),
        ])
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        XCTAssertEqual(report.leftovers, [leftover(.ordinals, 1, .notOneSat)])
        XCTAssertEqual(report.ordinalTxids, ["ord-1"])
        XCTAssertEqual(report.opnsTxids, ["ord-2"], "OpNS after ordinals, as its own class")
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.map(\.outpoints), [[op(0)], [op(2)]])
    }

    // MARK: - G13: every outpoint not spent is counted

    func test_leftoversCountUnreadableTokensRunAndZeroSat() async throws {
        let recorder = Recorder()
        let run = ScannedOutput(
            txid: txid, vout: 3, satoshis: 9_000, lockingScript: [0x76], events: [], sourceHasRunOutput: true
        )
        let input = try keyInput(
            [
                out(0, sats: 1, events: ["bsv21:\(tokenID)"]),
                out(1, sats: 1, events: ["bsv21:\(tokenID)"]),
                out(2, sats: 0),
                run,
                out(4, sats: 5_000, events: ["lock:900"]),
                out(5, sats: 2_180, events: ["twetch"]),
            ],
            tokens: listing([token(0, amount: 40, kind: .bsv21)], unreadable: [ref(1)])
        )
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        XCTAssertEqual(Set(report.leftovers), [
            leftover(.bsv21, 1, .unreadableTokenAmount),
            leftover(.unspendable, 2, .zeroSatoshis),
            leftover(.run, 3, .runTransaction),
            leftover(.twetch, 5, .twetchNotSupported),
        ])
        XCTAssertEqual(report.locked.map(\.vout), [4])
        XCTAssertEqual(report.bsv21Txids, ["bsv21-1"])
        XCTAssertEqual(report.sweptOutpoints, [ref(0)])
        let calls = await recorder.calls
        XCTAssertFalse(calls.contains { $0.step == "bsv" }, "RUN, 0-sat and Twetch outputs never fund")
    }

    func test_aBsv21OutputTheOverlayLeftIsCountedAndAnUnfiledSweepIsNoted() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [out(0, sats: 1, events: ["bsv21:\(tokenID)"]), out(1, sats: 1, events: ["bsv21:\(tokenID)"])],
            tokens: listing([token(0, amount: 4, kind: .bsv21), token(1, amount: 6, kind: .bsv21)], unreadable: [])
        )
        var steps = steps(recorder)
        steps.moveBsv21 = { _, inputs, _, _ in
            AssetSweep.SweepBsv21Result(
                result: ActionResult(txid: "t", submitError: "overlay down"), spentOutpoints: [inputs[0].outpoint]
            )
        }
        let report = try await LegacySweepRunner.run(input, steps: steps)
        XCTAssertEqual(report.leftovers, [leftover(.bsv21, 1, .notValidOnOverlay)])
        XCTAssertEqual(report.unfiledTokenSweeps, 1)
        XCTAssertEqual(report.sweptOutpoints, [ref(0)])
    }

    // MARK: - G15: listed tokens one per transaction

    func test_aListedTokenOutputGoesInItsOwnTransaction() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [
                out(0, sats: 1, events: ["bsv21:\(tokenID)"]),
                out(1, sats: 1, events: ["bsv21:\(tokenID)", "ordlock2"]),
                out(2, sats: 1, events: ["bsv21:\(tokenID)"]),
                out(3, sats: 1, events: ["tick:PEPE"]),
                out(4, sats: 1, events: ["tick:PEPE", "list:100"]),
            ],
            tokens: listing([
                token(0, amount: 1, kind: .bsv21), token(1, amount: 2, kind: .bsv21), token(2, amount: 3, kind: .bsv21),
                token(3, amount: 5, kind: .bsv20, id: "PEPE"), token(4, amount: 7, kind: .bsv20, id: "PEPE"),
            ], unreadable: [])
        )
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "bsv20" }.map(\.outpoints), [[op(4)], [op(3)]])
        XCTAssertEqual(calls.filter { $0.step == "bsv21" }.map(\.outpoints), [[op(1)], [op(0), op(2)]])
        XCTAssertEqual(Set(report.cancelledListings), [ref(1), ref(4)])
        XCTAssertEqual(calls.filter { $0.step != "beef" }.map(\.step), ["bsv20", "bsv20", "bsv21", "bsv21"], "BSV-20 before BSV-21")
    }

    // MARK: - G14: the token listing keeps tokens off the ordinal and funding paths

    func test_aDataOnlyTokenMovesAsATokenNotAnOrdinal() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [out(0, sats: 1, events: ["1sat", "insc"]), out(1, sats: 1, events: ["1sat"])],
            tokens: listing([token(0, amount: 9, kind: .bsv20, id: "SHUA")], unreadable: [])
        )
        _ = try await LegacySweepRunner.run(input, steps: steps(recorder))
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "bsv20" }.map(\.outpoints), [[op(0)]])
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.map(\.outpoints), [[op(1)]])
    }

    /// An ordinal the token listing did not return was never checked for token data: it stays.
    func test_anOrdinalMissingFromTheTokenListingDoesNotMove() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [out(0, sats: 1, events: ["1sat"]), out(1, sats: 1, events: ["1sat"]),
             out(2, sats: 1, events: ["1sat", "type:application/op-ns"])],
            unlisted: [0, 2]
        )
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.map(\.outpoints), [[op(1)]])
        XCTAssertEqual(report.leftovers, [leftover(.ordinals, 0, .notInTokenListing), leftover(.opns, 2, .notInTokenListing)])
    }

    func test_withoutTheTokenListingNoOrdinalOrTokenMoves() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [out(0, sats: 5_000), out(1, sats: 1, events: ["1sat"]), out(2, sats: 1, events: ["bsv21:\(tokenID)"])],
            tokens: .unavailable("HTTP 503")
        )
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder))
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step != "beef" }.map(\.step), ["bsv"])
        XCTAssertEqual(report.failures.map(\.message), ["HTTP 503"])
        XCTAssertEqual(Set(report.leftovers.map(\.reason)), [.tokenListingUnavailable])
        XCTAssertEqual(report.leftovers.count, 2)
        XCTAssertEqual(report.sweptSatoshis, 5_000)
    }

    // MARK: - Interruption

    func test_aFailedCheckpointStopsTheRunWithTheReportSoFar() async throws {
        let recorder = Recorder()
        let input = try keyInput([out(0, sats: 5_000), out(1, sats: 1, events: ["1sat"])])
        var steps = steps(recorder)
        let counter = Counter()
        steps.checkpoint = {
            if counter.next() == 2 { throw CocoaError(.userCancelled) }
        }
        do {
            _ = try await LegacySweepRunner.run(input, steps: steps)
            XCTFail("expected the interruption")
        } catch let interrupted as LegacySweepRunner.Interrupted {
            XCTAssertEqual(interrupted.report.bsvTxids, ["bsv-1"])
            XCTAssertEqual(interrupted.report.sweptOutpoints, [ref(0)])
            XCTAssertEqual(interrupted.report.leftovers, [leftover(.ordinals, 1, .notAttempted)],
                           "the unreached ordinal is reported, so the report does not read complete")
        }
    }

    func test_reportsMerge() {
        var a = LegacySweepRunner.Report()
        a.bsvTxids = ["a"]
        a.sweptSatoshis = 5
        var b = LegacySweepRunner.Report()
        b.ordinalTxids = ["b"]
        b.sweptSatoshis = 7
        b.failures = [.init(sweepClass: .ordinals, label: "Ordinals", message: "x")]
        let merged = a.merging(b)
        XCTAssertEqual(merged.txids, ["a", "b"])
        XCTAssertEqual(merged.sweptSatoshis, 12)
        XCTAssertEqual(merged.failures.count, 1)
    }

    // MARK: - Class skips (`sweeper.ts` `SweepClassSelection`)

    func test_aSkippedClassRunsNoStepAndItsOutputsStayAsSkipped() async throws {
        let recorder = Recorder()
        let input = try keyInput(
            [
                out(0, sats: 5_000),
                out(1, sats: 1, events: ["1sat"]),
                out(2, sats: 1, events: ["1sat", "type:application/op-ns"]),
                out(3, sats: 1, events: ["bsv21"]),
            ],
            tokens: listing([token(3, amount: 9, kind: .bsv21)], unreadable: [])
        )
        let report = try await LegacySweepRunner.run(input, steps: steps(recorder), skipping: [.ordinals, .bsv21])
        XCTAssertEqual(report.bsvTxids, ["bsv-1"])
        XCTAssertEqual(report.opnsTxids, ["ord-1"])
        XCTAssertTrue(report.ordinalTxids.isEmpty)
        XCTAssertTrue(report.bsv21Txids.isEmpty)
        XCTAssertEqual(report.leftovers, [leftover(.ordinals, 1, .skipped), leftover(.bsv21, 3, .skipped)])
        XCTAssertTrue(report.failures.isEmpty)
        let calls = await recorder.calls
        XCTAssertEqual(calls.filter { $0.step != "beef" }.map(\.step), ["bsv", "ordinals"])
        XCTAssertEqual(calls.filter { $0.step == "ordinals" }.map(\.outpoints), [[op(2)]])
    }

    /// A retired token (MNEE) is neither moved nor reported as a leftover; the BSV beside it
    /// still sweeps.
    func test_retiredTokenIsNeitherSweptNorLeftOver() throws {
        let retired = RetiredTokens.ids.first!
        let input = try keyInput(
            [out(0, sats: 5_000), out(1, sats: 1, events: ["bsv21:\(retired)"])],
            tokens: listing([token(1, amount: 500, kind: .bsv21, id: retired)], unreadable: [])
        )
        let plan = LegacySweepRunner.plan(input)
        XCTAssertEqual(plan.funding.map(\.vout), [0])
        XCTAssertTrue(plan.bsv21.isEmpty)
        XCTAssertTrue(plan.leftovers.isEmpty)
    }

    /// A retired token output whose scan lacks the `bsv21:` tag reads as an ordinal there; the
    /// listing's `retired` keeps it from moving as one or being reported as a leftover.
    func test_untaggedRetiredTokenIsNeitherMovedAsAnOrdinalNorLeftOver() throws {
        let input = try keyInput(
            [out(0, sats: 5_000), out(1, sats: 1, events: ["1sat", "insc"]), out(2, sats: 1, events: ["1sat"])],
            retired: [1]
        )
        let plan = LegacySweepRunner.plan(input)
        XCTAssertEqual(plan.funding.map(\.vout), [0])
        XCTAssertEqual(plan.ordinals.map(\.vout), [2])
        XCTAssertTrue(plan.leftovers.isEmpty)
    }

    func test_noSkipsLeavesThePlanAsItWas() throws {
        let input = try keyInput([out(0, sats: 5_000), out(1, sats: 1, events: ["1sat"])])
        let plan = LegacySweepRunner.plan(input)
        XCTAssertEqual(LegacySweepRunner.skipping([], in: plan), plan)
    }

    func test_sweepAllIsDisabledOnlyWhenEveryAvailableClassIsSkipped() {
        XCTAssertFalse(LegacySweepRunner.isSweepAllDisabled(available: [.bsv, .ordinals], skipped: [.bsv]))
        XCTAssertTrue(LegacySweepRunner.isSweepAllDisabled(available: [.bsv, .ordinals], skipped: [.bsv, .ordinals]))
        // A stale skip of a class the rescan dropped does not strand the button.
        XCTAssertFalse(LegacySweepRunner.isSweepAllDisabled(available: [.bsv], skipped: [.ordinals]))
        XCTAssertTrue(LegacySweepRunner.showClassSkips(available: [.bsv, .bsv21], skipped: []))
        XCTAssertFalse(LegacySweepRunner.showClassSkips(available: [.bsv], skipped: []))
        XCTAssertTrue(LegacySweepRunner.showClassSkips(available: [.bsv], skipped: [.opns]))
    }

    // MARK: - Progress

    func test_progressNamesEveryStepBeforeItRuns() async throws {
        let recorder = Recorder()
        let stages = StageLog()
        let input = try keyInput((0..<30).map { out(UInt32($0), sats: 1, events: ["1sat"]) } + [out(40, sats: 900)])
        var steps = steps(recorder)
        steps.progress = { await stages.append($0) }
        _ = try await LegacySweepRunner.run(input, steps: steps)
        let logged = await stages.stages
        XCTAssertEqual(logged.map(\.label), ["BSV", "Ordinals batch 1/2", "Ordinals batch 2/2"])
        XCTAssertEqual(logged.map(\.outputs), [1, 25, 5])
        XCTAssertEqual(logged.map(\.sweepClass), [.bsv, .ordinals, .ordinals])
    }

    // MARK: - Fixture

    private let txid = String(repeating: "ab", count: 32)
    private let tokenID = String(repeating: "cd", count: 32) + "_0"

    private func out(_ vout: UInt32, sats: UInt64, events: [String] = []) -> ScannedOutput {
        ScannedOutput(txid: txid, vout: vout, satoshis: sats, lockingScript: [0x76, 0xa9], events: events)
    }

    private func ref(_ vout: UInt32) -> OutputRef { OutputRef(txid: txid, vout: vout) }
    private func op(_ vout: UInt32) -> String { "\(txid).\(vout)" }

    private func leftover(
        _ sweepClass: LegacySweepRunner.SweepClass, _ vout: UInt32, _ reason: LegacySweepRunner.LeftoverReason
    ) -> LegacySweepRunner.Leftover {
        .init(sweepClass: sweepClass, outpoint: ref(vout), reason: reason)
    }

    private func token(_ vout: UInt32, amount: UInt64, kind: TokenKind, id: String? = nil) -> TokenOutput {
        TokenOutput(txid: txid, vout: vout, tokenID: id ?? tokenID, amount: amount, symbol: nil, decimals: 0, kind: kind)
    }

    private func keyInput(
        _ scanned: [ScannedOutput],
        tokens: Listing = .listed([], unreadable: []),
        unlisted: Set<UInt32> = [],
        retired: Set<UInt32> = []
    ) throws -> LegacySweepRunner.KeyInput {
        let listing: LegacySweepRunner.TokenListing
        switch tokens {
        case .listed(let outputs, let unreadable):
            // The listing read returns every outpoint of the address unless a test leaves one out.
            let listed = Set(
                scanned.filter { !unlisted.contains($0.vout) && !retired.contains($0.vout) }
                    .map { OutputRef(txid: $0.txid, vout: $0.vout) }
            )
            let retiredRefs = Set(retired.map { OutputRef(txid: txid, vout: $0) })
            listing = .listed(outputs: outputs, unreadable: unreadable, listed: listed, retired: retiredRefs)
        case .unavailable(let reason):
            listing = .unavailable(reason: reason)
        }
        return LegacySweepRunner.KeyInput(key: try ActionVectors.identity(), scanned: scanned, ordinalMetadata: [], tokens: listing)
    }

    private enum Listing {
        case listed([TokenOutput], unreadable: [OutputRef])
        case unavailable(String)
    }

    private func listing(_ outputs: [TokenOutput], unreadable: [OutputRef]) -> Listing {
        .listed(outputs, unreadable: unreadable)
    }

    private func steps(
        _ recorder: Recorder, failBsv: Bool = false, failOrdinalCall: Int? = nil
    ) -> LegacySweepRunner.Steps {
        LegacySweepRunner.Steps(
            beef: { outpoints in
                await recorder.record("beef", outpoints)
                return try BEEF(merklePaths: [], transactions: [], limits: WalletBEEFLimits.standard)
            },
            fundBsv: { inputs, _ in
                let n = await recorder.record("bsv", inputs.map(\.outpoint))
                return failBsv ? ActionResult.failure("dust") : ActionResult(txid: "bsv-\(n)")
            },
            moveOrdinals: { inputs, _ in
                let n = await recorder.record("ordinals", inputs.map(\.outpoint))
                return n == failOrdinalCall ? ActionResult.failure("too big") : ActionResult(txid: "ord-\(n)")
            },
            moveBsv20: { inputs, _, _ in
                let n = await recorder.record("bsv20", inputs.map(\.outpoint))
                return ActionResult(txid: "bsv20-\(n)")
            },
            moveBsv21: { _, inputs, _, _ in
                let n = await recorder.record("bsv21", inputs.map(\.outpoint))
                return AssetSweep.SweepBsv21Result(
                    result: ActionResult(txid: "bsv21-\(n)"), spentOutpoints: inputs.map(\.outpoint)
                )
            }
        )
    }
}

private actor StageLog {
    private(set) var stages: [LegacySweepRunner.Stage] = []
    func append(_ stage: LegacySweepRunner.Stage) { stages.append(stage) }
}

private actor Recorder {
    struct Call { let step: String; let outpoints: [String]; var count: Int { outpoints.count } }
    private(set) var calls: [Call] = []

    /// Records a call and returns its number within its step, from 1.
    @discardableResult
    func record(_ step: String, _ outpoints: [String]) -> Int {
        calls.append(Call(step: step, outpoints: outpoints))
        return calls.filter { $0.step == step }.count
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
