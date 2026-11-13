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
        let unlock = try SignP2PKH.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: OneSatConstants.lockKeyID
            )
        try assertPublicKey(
            "035af5fae93efc7eeb83bc8b6e80b9db72464a40c0b9f6036d8631026e28e3c6b4",
            in: unlock
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
        let unlock = try UnlockScripts.timeLock(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: OneSatConstants.lockKeyID
            )
        try assertPublicKey(
            "035af5fae93efc7eeb83bc8b6e80b9db72464a40c0b9f6036d8631026e28e3c6b4",
            in: unlock
        )
    }

    func test_ordLockV2CancelSignsWithTheListingKey() throws {
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let locking = try OrdLockV2.lock(
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
        let unlock = try UnlockScripts.ordLockV2Cancel(
                identity: identity,
                transaction: transaction,
                inputIndex: 0,
                protocolID: OneSatConstants.p1satProtocolID,
                keyID: ActionVectors.outpoint
            )
        // `<"ol2:cancel"> <sig> <pubkey> OP_1`
        let operations = try unlock.operations(maximumPushDataByteCount: Int(limits.maximumScriptByteCount))
        XCTAssertEqual(operations.count, 4)
        XCTAssertEqual(operations[0].pushedData, OrdLockV2.cancelMarker)
        XCTAssertEqual(operations[1].pushedData?.last, OrdLockV2.cancelSighashByte)
        XCTAssertEqual(
            operations[2].pushedData,
            try Hex.decode(
                "032a9a59e5f238bbff3202d80e1d573dad6202e24db76e609bdb27c35f0205f156",
                maximumDecodedByteCount: 33
            )
        )
        XCTAssertEqual(operations[3].opcode, .one)
        XCTAssertTrue(OrdLockV2.isCancel(unlock))
        XCTAssertLessThanOrEqual(unlock.bytes.count, OrdLockV2.cancelUnlockLength)
    }

    func test_ordLockV2PurchaseIsAPreimageAndTheZeroSelector() throws {
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let locking = try OrdLockV2.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let buyer = Address(publicKey: identity.publicKey, network: .mainnet)
        let empty = try Script(bytes: [], maximumByteCount: 10)
        let fundingScript = try ActionScript.payToPublicKeyHash(buyer)
        // Canonical layout: front funding 0, listing 1; filler 0, payout 1, receive 2.
        let transaction = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: "22", count: 32)),
                        outputIndex: 0
                    ),
                    unlockingScript: empty,
                    sequence: 0xffff_ffff,
                    sourceOutput: TransactionOutput(satoshis: 50_000, lockingScript: fundingScript)
                ),
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: "11", count: 32)),
                        outputIndex: 0
                    ),
                    unlockingScript: empty,
                    sequence: 0xffff_ffff,
                    sourceOutput: TransactionOutput(satoshis: 1, lockingScript: locking)
                ),
            ],
            outputs: [
                TransactionOutput(
                    satoshis: 0,
                    lockingScript: try Script(bytes: OrdLockV2Spend.fillerScriptBytes, maximumByteCount: 2)
                ),
                TransactionOutput(
                    satoshis: 50_000,
                    lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.payAddress)
                ),
                TransactionOutput(satoshis: 1, lockingScript: try ActionScript.payToPublicKeyHash(buyer)),
            ],
            lockTime: 0
        )
        let unlock = try UnlockScripts.ordLockV2Purchase(transaction: transaction, inputIndex: 1)
        let operations = try unlock.operations(maximumPushDataByteCount: Int(limits.maximumScriptByteCount))
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[1].opcode, .zero)
        let preimage = try XCTUnwrap(operations[0].pushedData)
        XCTAssertEqual(Array(preimage.suffix(4)), [OrdLockV2.purchaseSighashByte, 0, 0, 0])
        XCTAssertEqual(unlock.bytes.count, try OrdLockV2.estimatePurchaseUnlockLength(locking))
        XCTAssertTrue(OrdLockV2.isPurchase(unlock))
    }

    /// Public keys independently reproduced with the live TypeScript
    /// `KeyDeriver(...).derivePrivateKey([0, "onesat"], keyID, "self")`.
    private func assertPublicKey(_ expectedHex: String, in script: Script) throws {
        let operations = try script.operations(maximumPushDataByteCount: Int(limits.maximumScriptByteCount))
        XCTAssertGreaterThanOrEqual(operations.count, 2)
        XCTAssertEqual(operations[1].pushedData, try Hex.decode(expectedHex, maximumDecodedByteCount: 33))
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
