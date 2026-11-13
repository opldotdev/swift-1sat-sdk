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

/// Port of the `OneColor.unlock` case of `OneColor.test.ts`: the 1Color prefix needs no
/// unlocking data, so a P2PKH inner lock is spent with the plain P2PKH unlock, and the
/// signature covers the whole source script (prefix included).
final class OneColorUnlockTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard
    private let tokenID = String(repeating: "01", count: 31) + "ff_0"

    func test_signsAP2PKHInnerLockAndTheSpendVerifies() throws {
        let key = try PrivateKey([UInt8](repeating: 0, count: 31) + [9])
        let address = Address(publicKey: key.publicKey, network: .mainnet).description
        let token = try OneColor.value(tokenID: tokenID, amount: 5000, lock: .address(address))
        let source = TransactionOutput(satoshis: 1, lockingScript: try token.lock())

        let empty = try Script(bytes: [], maximumByteCount: 0)
        var spend = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: "33", count: 32)),
                        outputIndex: 0
                    ),
                    unlockingScript: empty,
                    sequence: 0xffff_ffff,
                    sourceOutput: source
                ),
            ],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try OneColor.value(tokenID: tokenID, amount: 5000, lock: .address(address)).lock()
                ),
            ],
            lockTime: 0
        )
        let unlock = try SignP2PKH.unlockingScript(privateKey: key, transaction: spend, inputIndex: 0)
        XCTAssertEqual(try unlock.operations(maximumPushDataByteCount: 1_000).count, 2)
        spend.inputs[0].unlockingScript = unlock

        let execution = try execute(unlock, spend: spend, source: source)
        XCTAssertEqual(execution.stack, [[1]])

        // Another key's signature must not spend it.
        let other = try PrivateKey([UInt8](repeating: 0, count: 31) + [10])
        let wrong = try SignP2PKH.unlockingScript(privateKey: other, transaction: spend, inputIndex: 0)
        XCTAssertThrowsError(try execute(wrong, spend: spend, source: source))
    }

    private func execute(_ unlock: Script, spend: Transaction, source: TransactionOutput) throws -> ScriptExecutionResult {
        var transaction = spend
        transaction.inputs[0].unlockingScript = unlock
        return try ScriptInterpreter.execute(
            unlockingScript: unlock,
            lockingScript: source.lockingScript,
            configuration: ScriptExecutionConfiguration(
                era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                resourceLimits: .standard
            ),
            context: ScriptExecutionContext(
                transaction: transaction, inputIndex: 0, spentOutput: source,
                transactionLimits: limits
            )
        )
    }
}
