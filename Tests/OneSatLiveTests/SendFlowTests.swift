import Foundation
import XCTest

/// Send by address, A to B and back, as the app's Send does (`RemoteWallet.pay(to:)`), with the
/// receiver picking it up through deposit sync (the app's `DepositSyncService`).
final class SendFlowTests: LiveTestCase {
    static let amount: UInt64 = 20_000
    /// What B keeps back from the return to cover its fee.
    static let reserve: Int64 = 1_000

    func testSendByAddressAToBAndBack() async throws {
        let a = try await fundedA()
        let b = try await qa(.B)

        let a0 = try await a.balance()
        let b0 = try await b.balance()

        // A -> B
        let out = try await Funding.pay(from: a, to: try b.receiveAddress(), satoshis: Self.amount, description: "QA send A to B")
        assertTxid(out, "A to B")
        let a1 = try await a.balance()
        let feeOut = a0 - a1 - Int64(Self.amount)
        XCTAssertTrue((1...1_000).contains(feeOut), "A paid \(feeOut) sats in fees")
        try await Funding.receive(b, txid: out)
        let b1 = try await b.balance()
        let sweepB = b0 + Int64(Self.amount) - b1
        XCTAssertTrue((0...1_000).contains(sweepB), "B's balance went \(b0) -> \(b1) after receiving \(Self.amount)")

        // B -> A: everything but the reserve.
        XCTAssertGreaterThan(b1, Self.reserve, "B holds \(b1), not more than the \(Self.reserve) reserve")
        let back = UInt64(b1 - Self.reserve)
        let ret = try await Funding.pay(from: b, to: try a.receiveAddress(), satoshis: back, description: "QA send B to A")
        assertTxid(ret, "B to A")
        let b2 = try await b.balance()
        let feeBack = b1 - b2 - Int64(back)
        XCTAssertTrue((1...1_000).contains(feeBack), "B paid \(feeBack) sats in fees")
        try await Funding.receive(a, txid: ret)
        let a2 = try await a.balance()
        let sweepA = a1 + Int64(back) - a2
        XCTAssertTrue((0...1_000).contains(sweepA), "A's balance went \(a1) -> \(a2) after receiving \(back)")
        print("SEND A->B \(out) B->A \(ret); A \(a0) -> \(a2), B \(b0) -> \(b2)")

        if backend.kind == .local {
            let broadcasts = try await localBroadcasts()
            XCTAssertTrue(broadcasts.contains(out), "stub chain never saw \(out)")
            XCTAssertTrue(broadcasts.contains(ret), "stub chain never saw \(ret)")
            for wallet in [a, b] {
                let calls = try await localCalls(for: wallet.identityHex)
                assertCallsWithinLimits(calls)
            }
        }
    }
}
