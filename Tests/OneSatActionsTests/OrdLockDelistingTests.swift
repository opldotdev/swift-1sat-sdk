import BSVCore
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

final class OrdLockDelistingTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard

    func test_mixedLegacyInputsUseBEEFSourceScriptsAndCancelOnlyListings() throws {
        let fixture = try fixture()
        let spends = try AssetSweep.signLegacyInputs(
            transaction: fixture.spend,
            keysByOutpoint: fixture.keys,
            inputBEEF: fixture.beef
        )
        XCTAssertEqual(Set(spends.keys), [0, 1], "funding inputs stay with the wallet signer")
        // TS `assignLegacyUnlock`: `OrdLockV2.cancelListing(key, "all", true)`,
        // i.e. `<"ol2:cancel"> <sig> <pubkey> OP_1`.
        let cancel = try XCTUnwrap(spends[1])
        XCTAssertTrue(OrdLockV2.isCancel(cancel))
        XCTAssertLessThanOrEqual(cancel.bytes.count, OrdLockV2.cancelUnlockLength)
        for index in 0..<2 {
            let unlock = try XCTUnwrap(spends[UInt32(index)])
            let operations = try unlock.operations(maximumPushDataByteCount: 10_000)
            let signature = index == 0 ? operations[0] : operations[1]
            XCTAssertEqual(signature.pushedData?.last, 0xc1, "ALL | FORKID | ANYONECANPAY")
            XCTAssertEqual(operations.count, index == 0 ? 2 : 4)
            if index == 1 {
                XCTAssertEqual(operations[0].pushedData, OrdLockV2.cancelMarker)
                XCTAssertEqual(operations[2].pushedData, fixture.key.publicKey.compressedBytes)
                XCTAssertEqual(operations.last?.opcode, .one)
            }
            let execution = try execute(unlock, inputIndex: index, fixture: fixture)
            XCTAssertTrue(isTruthy(execution.stack.last), "input \(index) leaves a true top of stack")
        }

        // Ordinary P2PKH signing has no cancellation selector and cannot spend this source.
        var actual = fixture.spend
        actual.inputs[1].sourceOutput = fixture.source.outputs[1]
        let plain = try SignP2PKH.unlockingScript(
            privateKey: fixture.key, transaction: actual, inputIndex: 1
        )
        XCTAssertThrowsError(try execute(plain, inputIndex: 1, fixture: fixture))
    }

    func test_wrongOwnerAndMissingBEEFSourceCannotProduceACancellation() throws {
        let fixture = try fixture()
        var wrongKeys = fixture.keys
        wrongKeys[fixture.spend.inputs[1].previousOutput.description] = try ActionVectors.recipient()
        XCTAssertThrowsError(try AssetSweep.signLegacyInputs(
            transaction: fixture.spend, keysByOutpoint: wrongKeys, inputBEEF: fixture.beef
        ))
        let empty = try BEEF(merklePaths: [], transactions: [], limits: WalletBEEFLimits.standard)
        XCTAssertThrowsError(try AssetSweep.signLegacyInputs(
            transaction: fixture.spend, keysByOutpoint: fixture.keys, inputBEEF: empty
        ))
    }

    private struct Fixture {
        let key: PrivateKey
        let source: Transaction
        let spend: Transaction
        let beef: BEEF
        let keys: [String: PrivateKey]
    }

    private func fixture() throws -> Fixture {
        let key = try ActionVectors.identity()
        let address = Address(publicKey: key.publicKey, network: .mainnet)
        let plain = try ActionScript.payToPublicKeyHash(address)
        let listing = try OrdLockV2.lock(
            cancelAddress: address.description, payAddress: ActionVectors.payAddress, price: 50_000
        )
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 1, lockingScript: plain),
            TransactionOutput(satoshis: 1, lockingScript: listing),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: limits)
        let empty = try Script(bytes: [], maximumByteCount: 10_000)
        var inputs = (0..<2).map { index in
            TransactionInput(
                previousOutput: Outpoint(transactionID: txid, outputIndex: UInt32(index)),
                unlockingScript: empty,
                // A stale scanner/storage hint must never replace the actual source in BEEF.
                sourceOutput: TransactionOutput(satoshis: 1, lockingScript: plain)
            )
        }
        let keys = Dictionary(uniqueKeysWithValues: inputs.map { ($0.previousOutput.description, key) })
        inputs.append(TransactionInput(
            previousOutput: Outpoint(transactionID: try TransactionID(displayHex: String(repeating: "22", count: 32)), outputIndex: 0),
            unlockingScript: empty,
            sourceOutput: TransactionOutput(satoshis: 100, lockingScript: plain)
        ))
        let spend = Transaction(version: 1, inputs: inputs, outputs: [
            TransactionOutput(satoshis: 1, lockingScript: plain),
            TransactionOutput(satoshis: 1, lockingScript: plain),
            TransactionOutput(satoshis: 90, lockingScript: plain),
        ], lockTime: 0)
        return Fixture(key: key, source: source, spend: spend,
            beef: try BEEF(merklePaths: [], transactions: [.raw(source)], limits: WalletBEEFLimits.standard),
            keys: keys)
    }

    private func isTruthy(_ element: [UInt8]?) -> Bool {
        guard let element else { return false }
        for (index, byte) in element.enumerated() where byte != 0 {
            return !(index == element.count - 1 && byte == 0x80)
        }
        return false
    }

    private func execute(_ unlock: Script, inputIndex: Int, fixture: Fixture) throws -> ScriptExecutionResult {
        let source = fixture.source.outputs[inputIndex]
        var transaction = fixture.spend
        transaction.inputs[inputIndex].unlockingScript = unlock
        transaction.inputs[inputIndex].sourceOutput = source
        return try ScriptInterpreter.execute(
            unlockingScript: unlock,
            lockingScript: source.lockingScript,
            configuration: ScriptExecutionConfiguration(
                era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                resourceLimits: .standard
            ),
            context: ScriptExecutionContext(
                transaction: transaction, inputIndex: inputIndex, spentOutput: source,
                transactionLimits: limits
            )
        )
    }
}
