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
}
