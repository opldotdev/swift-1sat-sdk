import BSVWallet
import Foundation
import XCTest

/// Create and restore: a fresh key is an empty account; a second client on the same key sees the
/// same state and can spend it.
final class WalletLifecycleTests: LiveTestCase {
    func testCreateFreshWallet() async throws {
        let wallet = try await LiveWallet.fresh(name: "fresh", backend: backend)
        try wallet.describe()
        let balance = try await wallet.balance()
        XCTAssertEqual(balance, 0)
        let actions = try await wallet.actionTxids()
        XCTAssertTrue(actions.isEmpty, "a fresh key has actions: \(actions)")
        let outputs = try await wallet.outputs(in: "default")
        XCTAssertTrue(outputs.isEmpty, "a fresh key has outputs: \(outputs.map(\.outpoint))")
        // The deposit address is derived offline and is a testnet address.
        let address = try wallet.receiveAddress()
        XCTAssertTrue(address.hasPrefix("m") || address.hasPrefix("n"), "not a testnet address: \(address)")
    }

    func testRestoreSeesSameState() async throws {
        let amount: UInt64 = backend.kind == .local ? 50_000 : 5_000
        let original = try await LiveWallet.fresh(name: "restore-original", backend: backend)
        try original.describe()

        // Fund the new account at its deposit address: the local faucet, or A on testnet.
        let fundTxid: String
        switch backend.kind {
        case .local:
            fundTxid = try await Funding.localFaucet(backend, address: try original.receiveAddress(), satoshis: amount)
        case .testnet:
            let a = try await fundedA()
            fundTxid = try await Funding.pay(from: a, to: try original.receiveAddress(), satoshis: amount, description: "QA restore fund")
        }
        assertTxid(fundTxid, "funding")
        try await Funding.receive(original, txid: fundTxid)
        let funded = try await original.balance()
        XCTAssertGreaterThan(funded, 0)
        XCTAssertLessThanOrEqual(funded, Int64(amount), "the sweep cannot add coins")
        XCTAssertGreaterThanOrEqual(funded, Int64(amount) - 1_000, "sweep fee over 1,000 sats: \(Int64(amount) - funded)")

        // A second, independent client on the same key.
        let restored = try await LiveWallet.connect(name: "restore-restored", key: original.key, backend: backend)
        let restoredBalance = try await restored.balance()
        XCTAssertEqual(restoredBalance, funded)
        let originalActions = try await original.actionTxids()
        let restoredActions = try await restored.actionTxids()
        XCTAssertEqual(restoredActions, originalActions)
        XCTAssertTrue(restoredActions.contains(fundTxid), "restored client lacks the deposit \(fundTxid)")
        let originalOutpoints = Set(try await original.outputs(in: "default").map { "\($0.outpoint)" })
        let restoredOutpoints = Set(try await restored.outputs(in: "default").map { "\($0.outpoint)" })
        XCTAssertEqual(restoredOutpoints, originalOutpoints)

        // The restored client spends; the first client sees it. The coins go to A.
        let a = try await qa(.A)
        let back = UInt64(restoredBalance - 1_000)
        let spendTxid = try await Funding.pay(from: restored, to: try a.receiveAddress(), satoshis: back, description: "QA restore return")
        assertTxid(spendTxid, "restored spend")
        let after = try await original.balance()
        let fee = restoredBalance - after - Int64(back)
        XCTAssertTrue((1...1_000).contains(fee), "spend fee \(fee) sats")
        let originalAfter = try await original.actionTxids()
        XCTAssertTrue(originalAfter.contains(spendTxid), "the first client does not list \(spendTxid)")
        try await Funding.receive(a, txid: spendTxid)
        if backend.kind == .local {
            let broadcasts = try await localBroadcasts()
            XCTAssertTrue(broadcasts.contains(spendTxid), "stub chain never saw \(spendTxid)")
        }
    }
}
