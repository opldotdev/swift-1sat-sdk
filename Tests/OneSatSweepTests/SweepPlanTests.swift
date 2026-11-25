import XCTest
@testable import OneSatSweep

/// Categorising an address's outputs before a sweep.
///
/// The point of this file: a sweep must never move an ordinal, a token, or a lock. The plan
/// separates the fundable BSV from everything else, and everything else is reported so the wallet
/// keeps the key and re-visits later — the behaviour Yours Wallet's migration flow makes explicit.
final class SweepPlanTests: XCTestCase {

    private func out(
        _ vout: UInt32, sats: UInt64, events: [String] = []
    ) -> ScannedOutput {
        ScannedOutput(
            txid: "8ac7230489e80000000000000000000000000000000000000000000000000001",
            vout: vout, satoshis: sats, lockingScript: [0x76, 0xa9], events: events
        )
    }

    func test_plainOutputsAreFundable() {
        XCTAssertEqual(out(0, sats: 1000).kind, .fundable)
    }

    func test_taggedOutputsAreCategorised() {
        XCTAssertEqual(out(0, sats: 1, events: ["bsv21:abc"]).kind, .bsv21(tokenID: "abc"))
        XCTAssertEqual(out(0, sats: 1, events: ["lock:830000"]).kind, .locked(until: 830_000))
        XCTAssertEqual(out(0, sats: 1, events: ["ord"]).kind, .ordinal)
    }

    /// The core safety property: only the fundable BSV is put forward to spend.
    func test_onlyFundableOutputsAreSwept() {
        let plan = SweepPlan.from(scan: [
            out(0, sats: 100_000),                      // fundable
            out(1, sats: 1, events: ["ord"]),           // ordinal — keep
            out(2, sats: 1, events: ["bsv21:tok"]),     // token — keep
            out(3, sats: 5000, events: ["lock:900000"]),// locked — keep
            out(4, sats: 50_000),                       // fundable
        ])

        XCTAssertEqual(plan.fundable.count, 2)
        XCTAssertEqual(plan.fundable.map(\.satoshis).reduce(0, +), 150_000)
        XCTAssertEqual(plan.remaining.ordinals.count, 1)
        XCTAssertEqual(plan.remaining.bsv21.count, 1)
        XCTAssertEqual(plan.remaining.locked.count, 1)
        XCTAssertFalse(plan.remaining.isEmpty, "assets remain, so the key must be preserved")
    }

    func test_ownerIndexerTransferAndLockEventsRemainOutsideFunding() {
        let origin = "8ac7230489e80000000000000000000000000000000000000000000000000001.0"
        let owner = "p2pkh:1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
        let plan = SweepPlan.from(scan: [
            out(0, sats: 100_000, events: [owner]),
            out(1, sats: 1, events: ["1sat", owner, "origin:\(origin)", "type:image/png"]),
            out(2, sats: 1, events: [owner, "origin:\(origin)", "type:application/op-ns"]),
            out(3, sats: 1, events: ["1sat", owner]),
            out(4, sats: 5_000, events: ["lock", owner]),
            out(5, sats: 1, events: ["1sat", "bsv21:gold", owner]),
        ])
        XCTAssertEqual(plan.fundable.map(\.vout), [0])
        XCTAssertEqual(plan.remaining.ordinals.map(\.vout), [1, 2, 3])
        XCTAssertEqual(plan.remaining.locked.map(\.vout), [4])
        XCTAssertEqual(plan.remaining.locked.first?.until, 0)
        XCTAssertNil(plan.remaining.nextUnlockHeight)
        XCTAssertEqual(plan.remaining.bsv21.first?.tokenID, "gold")
        XCTAssertFalse(plan.remaining.isEmpty)
    }

    func test_anAllPlainAddressLeavesNothingBehind() {
        let plan = SweepPlan.from(scan: [out(0, sats: 1000), out(1, sats: 2000)])

        XCTAssertEqual(plan.fundable.count, 2)
        XCTAssertTrue(plan.remaining.isEmpty, "the key can be discarded")
    }

    /// The wallet schedules a re-sweep from the earliest unlock height rather than making the user
    /// remember.
    func test_theNextUnlockHeightIsTheEarliestLock() {
        let plan = SweepPlan.from(scan: [
            out(0, sats: 1, events: ["lock:900000"]),
            out(1, sats: 1, events: ["lock:850000"]),
            out(2, sats: 1, events: ["lock:880000"]),
        ])

        XCTAssertEqual(plan.remaining.nextUnlockHeight, 850_000)
    }

    /// A token stays even when it is worth only its dust satoshis — value is off-chain in the token
    /// amount, and spending it as BSV would destroy it.
    func test_aTokenIsNeverTreatedAsFundable() {
        let plan = SweepPlan.from(scan: [out(0, sats: 1, events: ["bsv21:gold"])])

        XCTAssertTrue(plan.fundable.isEmpty)
        XCTAssertEqual(plan.remaining.bsv21.first?.tokenID, "gold")
    }

    // MARK: - G3 untagged 1-sat / 0-sat (`scan.ts` `categorizeOutputs`)

    func test_untaggedOneSatIsAnOrdinalAndZeroSatIsSkipped() {
        let plan = SweepPlan.from(scan: [
            out(0, sats: 1),
            out(1, sats: 0),
            out(2, sats: 2),
            out(3, sats: 546, events: ["insc", "type:image/png"]),
        ])
        XCTAssertEqual(out(0, sats: 1).kind, .ordinal)
        XCTAssertEqual(out(1, sats: 0).kind, .unspendable)
        XCTAssertEqual(plan.fundable.map(\.vout), [2], "only above 1 sat funds")
        XCTAssertEqual(plan.remaining.ordinals.map(\.vout), [0, 3], "a tagged 546-sat inscription stays an ordinal")
        XCTAssertEqual(plan.remaining.skipped.map(\.vout), [1])
        XCTAssertFalse(plan.remaining.isEmpty)
    }

    // MARK: - G14 token signals

    func test_tickOrBsv20MimeEventIsABsv20TokenNotAnOrdinal() {
        XCTAssertEqual(out(0, sats: 1, events: ["1sat", "tick:PEPE"]).kind, .bsv20(tick: "PEPE"))
        XCTAssertEqual(out(0, sats: 1, events: ["1sat", "insc", "type:application/bsv-20"]).kind, .bsv20(tick: nil))
        XCTAssertEqual(out(0, sats: 1, events: ["tick:"]).kind, .ordinal, "an empty tick is no tick")
        XCTAssertEqual(out(0, sats: 1, events: ["bsv21:x", "tick:PEPE"]).kind, .bsv21(tokenID: "x"))
        XCTAssertEqual(out(0, sats: 1, events: ["lock:5", "tick:PEPE"]).kind, .locked(until: 5), "lock before BSV-20 as in TS")
        let plan = SweepPlan.from(scan: [out(0, sats: 1, events: ["tick:PEPE"]), out(1, sats: 1000, events: ["type:application/bsv-20"])])
        XCTAssertTrue(plan.fundable.isEmpty)
        XCTAssertTrue(plan.remaining.ordinals.isEmpty)
        XCTAssertEqual(plan.remaining.bsv20.map(\.vout), [0, 1])
    }

    // MARK: - G4 RUN

    func test_aRunSourceHoldsBackWouldBeFunding() {
        let run = ScannedOutput(
            txid: String(repeating: "1", count: 64), vout: 0, satoshis: 5_000, lockingScript: [0x76],
            events: [], sourceHasRunOutput: true
        )
        XCTAssertEqual(run.kind, .run)
        let plan = SweepPlan.from(scan: [run, out(1, sats: 5_000)])
        XCTAssertEqual(plan.fundable.map(\.vout), [1])
        XCTAssertEqual(plan.remaining.run.map(\.vout), [0])
        XCTAssertFalse(plan.remaining.isEmpty)
        XCTAssertTrue(ScannedOutput.hasRunPrefix([0x00, 0x6a, 0x03, 0x72, 0x75, 0x6e, 0x05]))
        XCTAssertFalse(ScannedOutput.hasRunPrefix([0x00, 0x6a, 0x03, 0x72, 0x75]), "one byte short is not RUN")
        XCTAssertFalse(ScannedOutput.hasRunPrefix([0x6a, 0x03, 0x72, 0x75, 0x6e, 0x00]))
    }

    // MARK: - Twetch NFTs

    /// A Twetch NFT holds 2180 sats behind a hash lock; spending it as BSV would fail.
    func test_aTwetchNFTIsNeverFundable() {
        let twonk = out(0, sats: 2180, events: ["twetch"])
        XCTAssertEqual(twonk.kind, .twetch)
        let plan = SweepPlan.from(scan: [twonk, out(1, sats: 5_000)])
        XCTAssertEqual(plan.fundable.map(\.vout), [1])
        XCTAssertEqual(plan.remaining.twetch.map(\.vout), [0])
        XCTAssertFalse(plan.remaining.isEmpty)
    }

    /// Without the `twetch` event, the script shape alone keeps a twonk out of funding.
    func test_anUntaggedTwetchScriptIsStillATwonk() {
        var script: [UInt8] = [0xa9, 0x14]
        script += [UInt8](repeating: 0x41, count: 20)
        script += [0x88, 0x76, 0xa9, 0x14]
        script += [UInt8](repeating: 0xbb, count: 20)
        script += [0x88, 0xac, 0x6a, 0x01, 0x7b]
        let twonk = ScannedOutput(
            txid: "8ac7230489e80000000000000000000000000000000000000000000000000001",
            vout: 0, satoshis: 2_180, lockingScript: script, events: []
        )
        XCTAssertEqual(twonk.kind, .twetch)
    }
}
