import BSVKeys
import Foundation
import XCTest

/// Moves testnet sats from one QA wallet to a testnet address: `scripts/qa-transfer.sh`.
///
/// Runs only when `ONESAT_TRANSFER_TO` is set, and only against testnet (`ONESAT_LIVE=testnet`).
/// It refuses a mainnet backend, a mainnet or unparsable address, a role outside A/B/T, and more
/// than `maximumSats`. The `LiveTestCase` host guard refuses any mainnet host the run reaches.
/// The key is the QA root's (`ONESAT_QA_ROOT`, environment only); nothing secret is printed.
///
/// - `ONESAT_TRANSFER_TO`: the testnet address to pay.
/// - `ONESAT_TRANSFER_SATS`: how many sats.
/// - `ONESAT_TRANSFER_FROM`: the paying role, `A`, `B` or `T` (default `T`).
final class TestnetTransfer: LiveTestCase {
    static let maximumSats: UInt64 = 10_000_000

    func testTransfer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let to = environment["ONESAT_TRANSFER_TO"], !to.isEmpty else {
            throw XCTSkip("ONESAT_TRANSFER_TO is not set; this runs only from scripts/qa-transfer.sh.")
        }
        guard backend.kind == .testnet else {
            throw LiveSetupError("a transfer runs only with ONESAT_LIVE=testnet (this run is \(backend.kind.rawValue)).")
        }

        let address: Address
        do {
            address = try Address(to)
        } catch {
            throw LiveSetupError("ONESAT_TRANSFER_TO \(to) is not a P2PKH address: \(error)")
        }
        guard address.network == .testnet else {
            throw LiveSetupError("ONESAT_TRANSFER_TO \(to) is a mainnet address; this tool pays testnet addresses only.")
        }

        let satsText = environment["ONESAT_TRANSFER_SATS"] ?? ""
        guard let sats = UInt64(satsText), sats > 0 else {
            throw LiveSetupError("ONESAT_TRANSFER_SATS must be a whole number of sats above 0 (it is \"\(satsText)\").")
        }
        guard sats <= Self.maximumSats else {
            throw LiveSetupError("ONESAT_TRANSFER_SATS \(sats) is above this tool's limit of \(Self.maximumSats).")
        }

        let roleText = environment["ONESAT_TRANSFER_FROM"] ?? QAWallets.Role.T.rawValue
        guard let role = QAWallets.Role(rawValue: roleText) else {
            throw LiveSetupError("ONESAT_TRANSFER_FROM must be A, B or T (it is \"\(roleText)\").")
        }

        let from = try await qa(role)
        // Take in any deposit that reached the wallet's address since the last run (a bot's or
        // the faucet's), so the balance below is current.
        let synced = try await Funding.sync(from)
        print("SYNC \(from.name): processed \(synced.processed), failed \(synced.failed)"
            + (synced.sweepError.map { ", sweep error: \($0)" } ?? ""))
        let before = try await from.balance()
        print("BALANCE \(from.name) \(before)")
        guard before >= Int64(sats) + 1_000 else {
            throw LiveSetupError(
                "\(from.name) holds \(before) sats, not enough to send \(sats) plus the fee. "
                    + "Fund \(try from.receiveAddress()) and run again.")
        }

        let txid = try await Funding.pay(
            from: from, to: address.description, satoshis: sats, description: "QA transfer")
        assertTxid(txid, "transfer")
        let after = try await from.balance()
        print("SENT \(sats) sats from \(from.name) to \(address.description): \(txid). \(from.name) now holds \(after).")
    }
}
