import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

final class UnlockVectorTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard

    func test_p2pkhUnlockMatchesTheTypeScriptScript() throws {
        let identity = try ActionVectors.identity()
        let lockKey = try P1SATKey.privateKey(identity: identity, keyID: OneSatConstants.lockKeyID)
        let locking = try ActionScript.payToPublicKeyHash(
            Address(publicKey: lockKey.publicKey, network: .mainnet)
        )
        let transaction = try spendTransaction(
            sourceTXID: String(repeating: "00", count: 32),
            sourceSatoshis: 1,
            lockingScript: locking,
            sequence: 0xffff_ffff,
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
                ),
            ]
        )
        XCTAssertEqual(
            try SignP2PKH.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: OneSatConstants.lockKeyID
            ).hex,
            ActionVectors.p2pkhUnlock
        )
    }

    func test_timeLockUnlockMatchesTheTypeScriptScript() throws {
        let identity = try ActionVectors.identity()
        let address = try Locks.lockAddress(identity: identity).description
        let locking = try Locks.lockScript(address: address, until: 100)
        var transaction = try spendTransaction(
            sourceTXID: String(repeating: "00", count: 32),
            sourceSatoshis: 1_000,
            lockingScript: locking,
            sequence: 0,
            outputs: [
                TransactionOutput(
                    satoshis: 900,
                    lockingScript: try ActionScript.payToPublicKeyHash(address)
                ),
            ]
        )
        transaction.lockTime = 100
        XCTAssertEqual(
            try UnlockScripts.timeLock(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: OneSatConstants.lockKeyID
            ).hex,
            ActionVectors.timeLockUnlock
        )
    }

    func test_ordLockCancelMatchesTheTypeScriptScript() throws {
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let locking = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let transaction = try spendTransaction(
            sourceTXID: String(repeating: "11", count: 32),
            sourceSatoshis: 1,
            lockingScript: locking,
            sequence: 0xffff_ffff,
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try ActionScript.payToPublicKeyHash(cancel)
                ),
            ]
        )
        XCTAssertEqual(
            try UnlockScripts.ordLockCancel(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: ActionVectors.outpoint
            ).hex,
            ActionVectors.ordLockCancel
        )
    }

    func test_ordLockPurchaseMatchesTheTypeScriptScript() throws {
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let locking = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let buyer = Address(publicKey: identity.publicKey, network: .mainnet)
        let transaction = try spendTransaction(
            sourceTXID: String(repeating: "11", count: 32),
            sourceSatoshis: 1,
            lockingScript: locking,
            sequence: 0xffff_ffff,
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try ActionScript.payToPublicKeyHash(buyer)
                ),
                TransactionOutput(
                    satoshis: 50_000,
                    lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.payAddress)
                ),
            ]
        )
        XCTAssertEqual(
            try UnlockScripts.ordLockPurchase(transaction: transaction, inputIndex: 0).hex,
            ActionVectors.ordLockPurchase
        )
    }

    private func spendTransaction(
        sourceTXID: String,
        sourceSatoshis: UInt64,
        lockingScript: Script,
        sequence: UInt32,
        outputs: [TransactionOutput]
    ) throws -> Transaction {
        let empty = try Script(bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount))
        return Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: sourceTXID),
                        outputIndex: 0
                    ),
                    unlockingScript: empty,
                    sequence: sequence,
                    sourceOutput: TransactionOutput(
                        satoshis: sourceSatoshis,
                        lockingScript: lockingScript
                    )
                ),
            ],
            outputs: outputs,
            lockTime: 0
        )
    }
}
