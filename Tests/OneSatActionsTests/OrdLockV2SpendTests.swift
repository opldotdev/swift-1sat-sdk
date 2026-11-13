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

/// Port of the purchase and cancel cases of `@1sat/templates` `ordlock/ordlockV2.test.ts`
/// and the selection logic of `@1sat/actions` `apply/ordlockPurchase.ts`.
final class OrdLockV2SpendTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard

    // MARK: - planPurchase

    func test_singlePurchaseLaysOutCushionPayoutReceive() throws {
        let lock = try listing(price: 1_000)
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: [100_000],
            listings: [lock],
            receives: [try receive()],
            cushionScript: try buyerScript()
        )
        XCTAssertEqual(plan.cushionVout, 0)
        XCTAssertEqual(plan.cushion, 99_000)
        XCTAssertEqual(plan.fillerVouts, [])
        XCTAssertEqual(plan.payoutVouts, [1])
        XCTAssertEqual(plan.receiveVouts, [2])
        XCTAssertEqual(plan.outputs[1].satoshis, 1_000)
        XCTAssertEqual(
            plan.outputs[1].lockingScript.bytes,
            try ActionScript.payToPublicKeyHash(ActionVectors.payAddress).bytes
        )
    }

    func test_batchPurchasePutsOnePayoutPerListingIndex() throws {
        let other = Address(publicKey: try ActionVectors.recipient().publicKey, network: .mainnet).description
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: [100_000],
            listings: [
                try listing(price: 1_000),
                try OrdLockV2.lock(cancelAddress: other, payAddress: other, price: 2_500),
            ],
            receives: [try receive(), try receive()],
            cushionScript: try buyerScript()
        )
        XCTAssertEqual(plan.payoutVouts, [1, 2])
        XCTAssertEqual(plan.receiveVouts, [3, 4])
        XCTAssertEqual(plan.cushion, 96_500)
        XCTAssertEqual(plan.outputs[1].satoshis, 1_000)
        XCTAssertEqual(plan.outputs[2].satoshis, 2_500)
    }

    func test_severalFrontInputsGetOneCushionAndOpReturnFillers() throws {
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: [6_000, 4_000],
            listings: [try listing(price: 1_000), try listing(price: 1_500)],
            receives: [try receive(), try receive()],
            cushionScript: try buyerScript()
        )
        XCTAssertEqual(plan.cushionVout, 0)
        XCTAssertEqual(plan.fillerVouts, [1])
        XCTAssertEqual(plan.cushion, 7_500)
        XCTAssertEqual(plan.outputs[1].satoshis, 0)
        XCTAssertEqual(plan.outputs[1].lockingScript.hex, "006a")
        XCTAssertEqual(plan.payoutVouts, [2, 3])
        XCTAssertEqual(plan.receiveVouts, [4, 5])
    }

    func test_exactFrontFundingUsesFillersForEveryLeadingSlot() throws {
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: [600, 400],
            listings: [try listing(price: 1_000)],
            receives: [try receive()],
            cushionScript: try buyerScript()
        )
        XCTAssertEqual(plan.cushion, 0)
        XCTAssertNil(plan.cushionVout)
        XCTAssertEqual(plan.fillerVouts, [0, 1])
        XCTAssertEqual(plan.payoutVouts, [2])
        XCTAssertEqual(plan.receiveVouts, [3])
    }

    func test_planRejectsUnderFundedAndNonOneSatLayouts() throws {
        let lock = try listing(price: 1_000)
        XCTAssertThrowsError(
            try OrdLockV2Spend.planPurchase(
                frontSatoshis: [999], listings: [lock], receives: [try receive()],
                cushionScript: try buyerScript()
            )
        ) { self.assertRefused($0, containing: "does not cover payouts") }
        XCTAssertThrowsError(
            try OrdLockV2Spend.planPurchase(
                frontSatoshis: [5_000], listings: [lock],
                receives: [TransactionOutput(satoshis: 2, lockingScript: try buyerScript())],
                cushionScript: try buyerScript()
            )
        ) { self.assertRefused($0, containing: "exactly 1 satoshi") }
    }

    // MARK: - purchase unlock

    func test_purchaseUnlockIsAPreimageAndOpZeroThatTheContractAccepts() throws {
        let lock = try listing(price: 1_000)
        let transaction = try purchaseTransaction(lock: lock, front: 100_000)
        let delivery = OrdLockV2Spend.DeliveryTarget(vout: 2, lockingScript: try buyerScript())
        let unlock = try UnlockScripts.ordLockV2Purchase(
            transaction: transaction, inputIndex: 1, deliveries: [delivery]
        )
        let operations = try unlock.operations(maximumPushDataByteCount: Int(limits.maximumScriptByteCount))
        XCTAssertEqual(operations.count, 2)
        let preimage = try XCTUnwrap(operations[0].pushedData)
        XCTAssertGreaterThan(preimage.count, 156)
        XCTAssertEqual(preimage[preimage.count - 4], 0xc3, "SINGLE | ANYONECANPAY | FORKID")
        XCTAssertEqual(operations[1].opcode, .zero)
        XCTAssertTrue(OrdLockV2.isPurchase(unlock))
        XCTAssertFalse(OrdLockV2.isCancel(unlock))
        XCTAssertEqual(try OrdLockV2.estimatePurchaseUnlockLength(lock), unlock.bytes.count)
        XCTAssertEqual(try OrdLockV2Spend.ordinalOutput(transaction: transaction, inputIndex: 1), 2)

        let execution = try execute(unlock, transaction: transaction, inputIndex: 1)
        XCTAssertTrue(isTruthy(execution.stack.last))
    }

    func test_purchaseOfAListingWithTrailingMAPKeepsTheExactLength() throws {
        let base = try listing(price: 1_000)
        let lock = try Script(
            bytes: base.bytes + [0x6a, 0x03] + Array("app".utf8),
            maximumByteCount: ActionScript.maximumByteCount
        )
        let transaction = try purchaseTransaction(lock: lock, front: 100_000)
        let unlock = try UnlockScripts.ordLockV2Purchase(transaction: transaction, inputIndex: 1)
        XCTAssertEqual(try OrdLockV2.estimatePurchaseUnlockLength(lock), unlock.bytes.count)
        let execution = try execute(unlock, transaction: transaction, inputIndex: 1)
        XCTAssertTrue(isTruthy(execution.stack.last))
    }

    func test_refusesWhenThePayoutIsNotAtTheListingIndex() throws {
        let lock = try listing(price: 1_000)
        let payout = try OrdLockV2.payoutOutput(lock)
        let transaction = try spend(
            inputs: [(100_000, try buyerScript()), (1, lock)],
            outputs: [
                TransactionOutput(satoshis: payout.satoshis, lockingScript: payout.script),
                TransactionOutput(satoshis: 1, lockingScript: try buyerScript()),
                TransactionOutput(satoshis: 98_000, lockingScript: try buyerScript()),
            ]
        )
        XCTAssertThrowsError(try UnlockScripts.ordLockV2Purchase(transaction: transaction, inputIndex: 1)) {
            self.assertRefused($0, containing: "output 1 must be the listing payout")
        }
    }

    func test_refusesWhenTheListedSatWouldLandInThePayout() throws {
        let lock = try listing(price: 1_000)
        let payout = try OrdLockV2.payoutOutput(lock)
        let transaction = try spend(
            inputs: [(1, lock), (100_000, try buyerScript())],
            outputs: [
                TransactionOutput(satoshis: payout.satoshis, lockingScript: payout.script),
                TransactionOutput(satoshis: 1, lockingScript: try buyerScript()),
                TransactionOutput(satoshis: 98_000, lockingScript: try buyerScript()),
            ]
        )
        XCTAssertThrowsError(try UnlockScripts.ordLockV2Purchase(transaction: transaction, inputIndex: 0)) {
            self.assertRefused($0, containing: "carrying 1000 sats")
        }
    }

    func test_refusesWhenTheReceiveIsNotAnApprovedDelivery() throws {
        let lock = try listing(price: 1_000)
        let transaction = try purchaseTransaction(lock: lock, front: 100_000)
        let other = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        XCTAssertThrowsError(
            try UnlockScripts.ordLockV2Purchase(
                transaction: transaction, inputIndex: 1,
                deliveries: [OrdLockV2Spend.DeliveryTarget(vout: 2, lockingScript: other)]
            )
        ) { self.assertRefused($0, containing: "not an approved receive output") }
        XCTAssertThrowsError(
            try UnlockScripts.ordLockV2Purchase(
                transaction: transaction, inputIndex: 1,
                deliveries: [OrdLockV2Spend.DeliveryTarget(vout: 3, lockingScript: try buyerScript())]
            )
        ) { self.assertRefused($0, containing: "not an approved receive output") }
    }

    func test_refusesWhenTheListedSatWouldBeBurnedAsFee() throws {
        let lock = try listing(price: 1_000)
        let payout = try OrdLockV2.payoutOutput(lock)
        let transaction = try spend(
            inputs: [(100_000, try buyerScript()), (1, lock)],
            outputs: [
                TransactionOutput(satoshis: 99_000, lockingScript: try buyerScript()),
                TransactionOutput(satoshis: payout.satoshis, lockingScript: payout.script),
            ]
        )
        XCTAssertThrowsError(try UnlockScripts.ordLockV2Purchase(transaction: transaction, inputIndex: 1)) {
            self.assertRefused($0, containing: "not mapped to any output")
        }
    }

    // MARK: - cancel

    func test_cancelWithWalletEqualsTheRawKeyCancelAndTheContractAcceptsIt() throws {
        let identity = try ActionVectors.identity()
        let keyID = ActionVectors.outpoint
        let seller = try Ordinals.cancelAddress(identity: identity, outpoint: keyID)
        let lock = try OrdLockV2.lock(
            cancelAddress: seller.description, payAddress: ActionVectors.payAddress, price: 1_000
        )
        let transaction = try spend(
            inputs: [(1, lock)],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: try ActionScript.payToPublicKeyHash(seller))]
        )
        let wallet = try UnlockScripts.ordLockV2Cancel(
            identity: identity, transaction: transaction, inputIndex: 0,
            protocolID: OneSatConstants.p1satProtocolID, keyID: keyID
        )
        let key = try P1SATKey.privateKey(identity: identity, keyID: keyID)
        let raw = try UnlockScripts.ordLockV2Cancel(privateKey: key, transaction: transaction, inputIndex: 0)
        XCTAssertEqual(wallet.bytes, raw.bytes, "RFC 6979 signatures are deterministic")

        let operations = try wallet.operations(maximumPushDataByteCount: Int(limits.maximumScriptByteCount))
        XCTAssertEqual(operations.count, 4)
        XCTAssertEqual(operations[0].pushedData, Array("ol2:cancel".utf8))
        XCTAssertEqual(operations[1].pushedData?.last, 0xc1, "ALL | ANYONECANPAY | FORKID")
        XCTAssertEqual(operations[2].pushedData, key.publicKey.compressedBytes)
        XCTAssertEqual(operations[3].opcode, .one)
        XCTAssertTrue(OrdLockV2.isCancel(wallet))
        XCTAssertFalse(OrdLockV2.isPurchase(wallet))

        let execution = try execute(wallet, transaction: transaction, inputIndex: 0)
        XCTAssertTrue(isTruthy(execution.stack.last))
    }

    func test_cancelRefusesAKeyThatIsNotTheSeller() throws {
        let lock = try listing(price: 1_000)
        let transaction = try spend(
            inputs: [(1, lock)],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: try buyerScript())]
        )
        XCTAssertThrowsError(
            try UnlockScripts.ordLockV2Cancel(
                privateKey: try ActionVectors.recipient(), transaction: transaction, inputIndex: 0
            )
        ) { XCTAssertEqual($0 as? OneSatActionError, .invalidCustomInstructions) }
    }

    // MARK: - front funding selection

    func test_selectFrontFundingPrefersTheSmallestSingleThenTheLargestFew() throws {
        let candidates = try [500, 3_000, 1_200, 800, 900].enumerated().map { index, satoshis in
            OrdLockV2Purchase.FundingCandidate(
                outpoint: try Outpoint(String(repeating: "aa", count: 32) + ".\(index)"),
                satoshis: UInt64(satoshis),
                instructions: try CustomInstructions(keyID: "ordlock-funding \(index)")
            )
        }
        XCTAssertEqual(OrdLockV2Purchase.selectFrontFunding(candidates, needed: 1_000)?.map(\.satoshis), [1_200])
        XCTAssertEqual(OrdLockV2Purchase.selectFrontFunding(candidates, needed: 3_000)?.map(\.satoshis), [3_000])
        XCTAssertEqual(
            OrdLockV2Purchase.selectFrontFunding(candidates, needed: 4_500)?.map(\.satoshis),
            [3_000, 1_200, 900]
        )
        XCTAssertEqual(
            OrdLockV2Purchase.selectFrontFunding(candidates, needed: 5_900)?.map(\.satoshis),
            [3_000, 1_200, 900, 800]
        )
        XCTAssertNil(OrdLockV2Purchase.selectFrontFunding(candidates, needed: 6_000), "at most 4 inputs")
        XCTAssertNil(OrdLockV2Purchase.selectFrontFunding([], needed: 1))
    }

    /// The exact vectors from TS `ordlockPurchase.test.ts` `selectFrontFunding`.
    func test_selectFrontFundingMatchesTheTSVectors() throws {
        func candidates(_ amounts: [UInt64]) throws -> [OrdLockV2Purchase.FundingCandidate] {
            try amounts.enumerated().map { index, satoshis in
                OrdLockV2Purchase.FundingCandidate(
                    outpoint: try Outpoint(String(repeating: "bb", count: 32) + ".\(index)"),
                    satoshis: satoshis,
                    instructions: try CustomInstructions(keyID: "ordlock-funding \(index)")
                )
            }
        }
        XCTAssertEqual(
            OrdLockV2Purchase.selectFrontFunding(try candidates([5_000, 1_200, 900]), needed: 1_000)?.map(\.satoshis),
            [1_200]
        )
        XCTAssertEqual(
            OrdLockV2Purchase.selectFrontFunding(try candidates([600, 500, 100]), needed: 1_000)?.map(\.satoshis),
            [600, 500]
        )
        XCTAssertNil(OrdLockV2Purchase.selectFrontFunding(try candidates([100, 100]), needed: 1_000))
    }

    func test_layoutRefusesAReceiveThatIsNotABasketedOneSatOutput() throws {
        let lock = try listing(price: 1_000)
        let unbasketed = try WalletCreateActionOutput(
            lockingScript: try buyerScript().bytes, satoshis: 1, outputDescription: "Receive", tags: []
        )
        let cushion = try WalletCreateActionOutput(
            lockingScript: try buyerScript().bytes, satoshis: 0, outputDescription: "Cushion",
            basket: OneSatConstants.depositBasket, tags: []
        )
        let front = OrdLockV2Purchase.FundingCandidate(
            outpoint: try Outpoint(String(repeating: "ab", count: 32) + ".0"),
            satoshis: 5_000,
            instructions: try CustomInstructions(keyID: "ordlock-funding x")
        )
        XCTAssertThrowsError(
            try OrdLockV2Purchase.layout(
                listingOutpoint: try Outpoint(ActionVectors.outpoint),
                listingScript: lock,
                listingInputDescription: "Listed ordinal",
                receive: unbasketed,
                extras: [],
                front: [front],
                cushion: cushion
            )
        ) { self.assertRefused($0, containing: "basketed 1-sat receive") }
    }

    // MARK: - helpers

    private func listing(price: UInt64) throws -> Script {
        let seller = Address(publicKey: try ActionVectors.identity().publicKey, network: .mainnet)
        return try OrdLockV2.lock(
            cancelAddress: seller.description, payAddress: ActionVectors.payAddress, price: price
        )
    }

    private func buyerScript() throws -> Script {
        try ActionScript.payToPublicKeyHash(
            Address(publicKey: try ActionVectors.recipient().publicKey, network: .mainnet)
        )
    }

    private func receive() throws -> TransactionOutput {
        TransactionOutput(satoshis: 1, lockingScript: try buyerScript())
    }

    /// Canonical single purchase: front 0 · listing 1 → cushion 0 · payout 1 · receive 2.
    private func purchaseTransaction(lock: Script, front: UInt64) throws -> Transaction {
        let plan = try OrdLockV2Spend.planPurchase(
            frontSatoshis: [front], listings: [lock], receives: [try receive()],
            cushionScript: try buyerScript()
        )
        return try spend(inputs: [(front, try buyerScript()), (1, lock)], outputs: plan.outputs)
    }

    private func spend(
        inputs: [(satoshis: UInt64, script: Script)],
        outputs: [TransactionOutput]
    ) throws -> Transaction {
        let empty = try Script(bytes: [], maximumByteCount: 10)
        return Transaction(
            version: 1,
            inputs: try inputs.enumerated().map { index, input in
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: "11", count: 32)),
                        outputIndex: UInt32(index)
                    ),
                    unlockingScript: empty,
                    sequence: 0xffff_ffff,
                    sourceOutput: TransactionOutput(satoshis: input.satoshis, lockingScript: input.script)
                )
            },
            outputs: outputs,
            lockTime: 0
        )
    }

    private func assertRefused(_ error: Error, containing text: String, line: UInt = #line) {
        guard case .ordLockV2Refused(let message)? = error as? OneSatActionError else {
            return XCTFail("expected ordLockV2Refused, got \(error)", line: line)
        }
        XCTAssertTrue(message.contains(text), "\(message) does not contain \(text)", line: line)
    }

    private func isTruthy(_ element: [UInt8]?) -> Bool {
        guard let element else { return false }
        for (index, byte) in element.enumerated() where byte != 0 {
            return !(index == element.count - 1 && byte == 0x80)
        }
        return false
    }

    private func execute(
        _ unlock: Script,
        transaction: Transaction,
        inputIndex: Int
    ) throws -> ScriptExecutionResult {
        var transaction = transaction
        transaction.inputs[inputIndex].unlockingScript = unlock
        let source = try XCTUnwrap(transaction.inputs[inputIndex].sourceOutput)
        return try ScriptInterpreter.execute(
            unlockingScript: unlock,
            lockingScript: source.lockingScript,
            configuration: ScriptExecutionConfiguration(
                era: .afterChronicle, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                resourceLimits: .standard
            ),
            context: ScriptExecutionContext(
                transaction: transaction, inputIndex: inputIndex, spentOutput: source,
                transactionLimits: limits
            )
        )
    }
}
