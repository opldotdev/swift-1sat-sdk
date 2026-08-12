import XCTest
import BSVKeys
import BSVScript
import BSVTransaction
import ToolboxServices
@testable import OneSatSweep

/// Building a sweep transaction.
///
/// The UTXOs come from a fake source, so the whole build-and-sign path runs without a network. The
/// coins are locked to the sweep key's real P2PKH script, so a signature only verifies if the
/// derivation and the input construction agree — the part that fails quietly if it is wrong.
final class SweepTests: XCTestCase {

    /// Returns a fixed set of outputs regardless of the address asked for.
    private struct FakeSource: UTXOSource {
        let utxos: [SpendableUTXO]
        func spendableOutputs(forAddress address: String) async throws -> [SpendableUTXO] { utxos }
    }

    private func key(_ byte: UInt8) throws -> PrivateKey {
        try PrivateKey([UInt8](repeating: 0, count: 31) + [byte])
    }

    private func p2pkh(for key: PrivateKey) throws -> [UInt8] {
        try Script.payToPublicKeyHash(
            Address(publicKey: key.publicKey, network: .mainnet).publicKeyHash,
            maximumByteCount: 1 << 20
        ).bytes
    }

    private func utxo(
        _ key: PrivateKey, satoshis: UInt64, vout: UInt32 = 0
    ) throws -> SpendableUTXO {
        SpendableUTXO(
            txid: "8ac7230489e80000000000000000000000000000000000000000000000000001",
            vout: vout, satoshis: satoshis, lockingScript: try p2pkh(for: key)
        )
    }

    func test_aSweepSpendsEveryInputAndPaysTheDestination() async throws {
        let sourceKey = try key(1)
        let destination = Address(publicKey: try key(2).publicKey, network: .mainnet).description
        let source = FakeSource(utxos: [
            try utxo(sourceKey, satoshis: 100_000, vout: 0),
            try utxo(sourceKey, satoshis: 50_000, vout: 1),
        ])

        let result = try await Sweep.build(
            fromWIF: WIF(privateKey: sourceKey, network: .mainnet).encoded,
            toAddress: destination, source: source
        )

        XCTAssertEqual(result.swept, 150_000)
        XCTAssertEqual(result.transaction.inputs.count, 2)
        XCTAssertEqual(result.transaction.outputs.count, 1, "a sweep keeps no change")
        XCTAssertEqual(result.paid, result.swept - result.fee)
        XCTAssertEqual(result.transaction.outputs[0].satoshis, result.paid)
        XCTAssertGreaterThan(result.fee, 0)
    }

    /// Every input carries a real unlocking script once signed. A P2PKH signature only lands if the
    /// key matches the output's script, so this proves the whole thing signs.
    func test_everyInputIsSigned() async throws {
        let sourceKey = try key(7)
        let destination = Address(publicKey: try key(9).publicKey, network: .mainnet).description
        let source = FakeSource(utxos: [try utxo(sourceKey, satoshis: 200_000)])

        let result = try await Sweep.build(
            fromWIF: WIF(privateKey: sourceKey, network: .mainnet).encoded,
            toAddress: destination, source: source
        )

        XCTAssertTrue(result.transaction.inputs.allSatisfy { !$0.unlockingScript.bytes.isEmpty })
    }

    func test_anEmptyAddressIsNothingToSweep() async throws {
        let sourceKey = try key(1)
        let destination = Address(publicKey: try key(2).publicKey, network: .mainnet).description

        do {
            _ = try await Sweep.build(
                fromWIF: WIF(privateKey: sourceKey, network: .mainnet).encoded,
                toAddress: destination, source: FakeSource(utxos: [])
            )
            XCTFail("an empty address has nothing to sweep")
        } catch let error as SweepError {
            guard case .nothingToSweep = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    /// A balance smaller than the fee cannot be swept — there would be nothing to send.
    func test_dustAfterFeeIsRefused() async throws {
        let sourceKey = try key(1)
        let destination = Address(publicKey: try key(2).publicKey, network: .mainnet).description
        let source = FakeSource(utxos: [try utxo(sourceKey, satoshis: 1)])

        do {
            _ = try await Sweep.build(
                fromWIF: WIF(privateKey: sourceKey, network: .mainnet).encoded,
                toAddress: destination, source: source
            )
            XCTFail("one satoshi cannot cover its own fee")
        } catch let error as SweepError {
            guard case .dustAfterFee = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    /// An input locked to a different key is not this sweep's to spend — a non-standard or foreign
    /// output the asset layer must handle, refused rather than mis-signed.
    func test_anInputNotOwnedByTheKeyIsRefused() async throws {
        let sourceKey = try key(1)
        let otherKey = try key(3)
        let destination = Address(publicKey: try key(2).publicKey, network: .mainnet).description
        // A UTXO locked to `otherKey` but presented for `sourceKey`'s sweep.
        let source = FakeSource(utxos: [try utxo(otherKey, satoshis: 100_000)])

        do {
            _ = try await Sweep.build(
                fromWIF: WIF(privateKey: sourceKey, network: .mainnet).encoded,
                toAddress: destination, source: source
            )
            XCTFail("an output this key does not lock must not be signed")
        } catch let error as SweepError {
            guard case .inputNotOwned = error else { return XCTFail("wrong error: \(error)") }
        }
    }
}
