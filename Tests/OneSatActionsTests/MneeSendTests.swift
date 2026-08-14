import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatAddresses
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class MneeSendTests: XCTestCase {
    func test_missingClientReturnsWireMessage() async throws {
        let stub = MneeStub()
        let ctx = try context(mnee: nil)
        let result = await Mnee.send(ctx, try request()) { _ in }
        XCTAssertEqual(
            result.error,
            "MNEE client not available — services required"
        )
        XCTAssertEqual(OneSatActionError.mneeClientRequired.wireMessage, result.error)
        let calls = await stub.calls
        XCTAssertEqual(calls, [])
    }

    func test_noRecipients() async throws {
        let stub = MneeStub()
        let result = await Mnee.send(
            try context(mnee: stub),
            Mnee.SendRequest(recipients: [], derivations: try derivations())
        ) { _ in }
        XCTAssertEqual(result.error, "no-recipients")
        let calls = await stub.calls
        XCTAssertEqual(calls, [])
    }

    func test_noDerivations() async throws {
        let stub = MneeStub()
        let result = await Mnee.send(
            try context(mnee: stub),
            Mnee.SendRequest(
                recipients: [Mnee.Recipient(address: ActionVectors.payAddress, amount: 1)],
                derivations: []
            )
        ) { _ in }
        XCTAssertEqual(result.error, "no-derivations")
        let calls = await stub.calls
        XCTAssertEqual(calls, [])
    }

    func test_emptyApprover() async throws {
        let stub = MneeStub(config: try fixtureConfig(approver: ""))
        let result = await Mnee.send(try context(mnee: stub), try request()) { _ in }
        XCTAssertEqual(result.error, "failed-to-get-mnee-config")
        let calls = await stub.calls
        XCTAssertEqual(calls, ["config"])
    }

    func test_invalidAmount() async throws {
        let stub = MneeStub()
        let result = await Mnee.send(
            try context(mnee: stub),
            Mnee.SendRequest(
                recipients: [Mnee.Recipient(address: ActionVectors.payAddress, amount: 0)],
                derivations: try derivations()
            )
        ) { _ in }
        XCTAssertEqual(result.error, "invalid-amount")
        let calls = await stub.calls
        XCTAssertEqual(calls, ["config"])
    }

    func test_feeRangesInadequate() async throws {
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10, fee: 1)])
        )
        let result = await Mnee.send(try context(mnee: stub), try request(amount: 1)) { _ in }
        XCTAssertEqual(result.error, "fee-ranges-inadequate")
        let calls = await stub.calls
        XCTAssertEqual(calls, ["config"])
    }

    func test_burnAddressFeeIsZero() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let source = try sourceTransaction(
            lockingScript: try cosignTransferScript(
                address: try Address(derived[0].address),
                amount: 100_000
            )
        )
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(
                    txid: source.txid,
                    vout: 0,
                    amount: 100_000,
                    owners: [derived[0].address]
                ),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let sleeps = SleepRecorder()
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            Mnee.SendRequest(
                recipients: [Mnee.Recipient(address: ActionVectors.templateAddress, amount: 1)],
                derivations: derived
            )
        ) { await sleeps.record($0) }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.ticketId, "ticket-1")
        let submittedBytes = await stub.submitted
        let submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: WalletTransactionLimits.standard
        )
        XCTAssertEqual(submitted.outputs.count, 1)
        XCTAssertEqual(submitted.outputs[0].satoshis, 1)
        let expected = try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: "100000")
            .lock(
                lockingScript: try Cosign.lock(
                    address: try Address(ActionVectors.templateAddress),
                    cosigner: try approverBytes()
                )
            )
        XCTAssertEqual(submitted.outputs[0].lockingScript, expected)
    }

    func test_insufficientMneeExactString() async throws {
        let derived = try derivations()
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 0)]),
            utxos: [
                Mnee.Utxo(txid: String(repeating: "aa", count: 32), vout: 0, amount: 150_000, owners: [derived[0].address]),
            ]
        )
        let result = await Mnee.send(
            try context(mnee: stub),
            try request(amount: 2)
        ) { _ in }
        XCTAssertEqual(result.error, "Insufficient MNEE. Have: 1.5, Need: 2")
        let calls = await stub.calls
        XCTAssertEqual(calls, ["config", "utxos"])
    }

    func test_failedToFetchSourceTx() async throws {
        let derived = try derivations()
        let txid = String(repeating: "ab", count: 32)
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 0)]),
            utxos: [
                Mnee.Utxo(txid: txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [txid: .failure(StubError("offline"))]
        )
        let result = await Mnee.send(try context(mnee: stub), try request(amount: 1)) { _ in }
        XCTAssertEqual(result.error, "failed-to-fetch-source-tx: \(txid)")
    }

    func test_unparsableSourceTx() async throws {
        let derived = try derivations()
        let txid = String(repeating: "cd", count: 32)
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 0)]),
            utxos: [
                Mnee.Utxo(txid: txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [txid: .success([0x00])]
        )
        let result = await Mnee.send(try context(mnee: stub), try request(amount: 1)) { _ in }
        XCTAssertEqual(result.error, "failed-to-fetch-source-tx: \(txid)")
    }

    func test_selectionSkipsZeroAndConsumesInOrder() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let owner = try Address(derived[0].address)
        let sourceA = try sourceTransaction(
            lockingScript: try cosignTransferScript(address: owner, amount: 150_000),
            salt: "11"
        )
        let sourceB = try sourceTransaction(
            lockingScript: try cosignTransferScript(address: owner, amount: 150_000),
            salt: "22"
        )
        let skipped = String(repeating: "00", count: 32)
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(txid: skipped, vout: 0, amount: 0, owners: [derived[0].address]),
                Mnee.Utxo(txid: sourceA.txid, vout: 0, amount: 150_000, owners: [derived[0].address]),
                Mnee.Utxo(txid: sourceB.txid, vout: 0, amount: 150_000, owners: [derived[0].address]),
            ],
            rawTransactions: [
                sourceA.txid: .success(sourceA.bytes),
                sourceB.txid: .success(sourceB.bytes),
            ]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived)
        ) { _ in }
        XCTAssertNil(result.error)
        let submittedBytes = await stub.submitted
        let submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: WalletTransactionLimits.standard
        )
        XCTAssertEqual(submitted.inputs.count, 1)
        XCTAssertEqual(submitted.inputs[0].previousOutput.transactionID.displayHex, sourceA.txid)
        let rawRequested = await stub.rawRequested
        XCTAssertFalse(rawRequested.contains(skipped))
    }

    func test_submittedTxStructureRecipientsFeeChange() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let owner = try Address(derived[0].address)
        let source = try sourceTransaction(
            lockingScript: try cosignTransferScript(address: owner, amount: 200_000)
        )
        let recipientA = try Address(publicKey: ActionVectors.recipient().publicKey, network: .mainnet)
            .description
        let recipientB = ActionVectors.payAddress
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            Mnee.SendRequest(
                recipients: [
                    Mnee.Recipient(address: recipientA, amount: 0.5),
                    Mnee.Recipient(address: recipientB, amount: 0.5),
                ],
                derivations: derived,
                changeAddress: derived[1].address
            )
        ) { _ in }
        XCTAssertNil(result.error)
        let submittedBytes = await stub.submitted
        let submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: WalletTransactionLimits.standard
        )
        XCTAssertEqual(submitted.outputs.count, 4)
        XCTAssertTrue(submitted.outputs.allSatisfy { $0.satoshis == 1 })
        let approver = try approverBytes()
        let expected = [
            try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: "50000")
                .lock(lockingScript: try Cosign.lock(address: try Address(recipientA), cosigner: approver)),
            try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: "50000")
                .lock(lockingScript: try Cosign.lock(address: try Address(recipientB), cosigner: approver)),
            try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: "1000")
                .lock(
                    lockingScript: try Cosign.lock(
                        address: try Address(ActionVectors.payAddress),
                        cosigner: approver
                    )
                ),
            try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: "99000")
                .lock(lockingScript: try Cosign.lock(address: try Address(derived[1].address), cosigner: approver)),
        ]
        XCTAssertEqual(submitted.outputs.map(\.lockingScript), expected)
    }

    func test_changeAddressFromCosignDecode() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let decodedOwner = try Address(ActionVectors.templateAddress)
        let source = try sourceTransaction(
            lockingScript: try cosignTransferScript(address: decodedOwner, amount: 200_000)
        )
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived)
        ) { _ in }
        XCTAssertNil(result.error)
        let submittedBytes = await stub.submitted
        let submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: WalletTransactionLimits.standard
        )
        XCTAssertEqual(submitted.outputs.count, 3)
        let change = try XCTUnwrap(Cosign.decode(submitted.outputs[2].lockingScript))
        XCTAssertEqual(change.address, decodedOwner)
        XCTAssertNotEqual(change.address.description, derived[0].address)
    }

    func test_changeAddressFallsBackToFirstDerivation() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let p2pkh = try Script.payToPublicKeyHash(
            try Address(ActionVectors.templateAddress),
            maximumByteCount: Int(WalletTransactionLimits.standard.maximumScriptByteCount)
        )
        let source = try sourceTransaction(lockingScript: p2pkh)
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived)
        ) { _ in }
        XCTAssertNil(result.error)
        let submittedBytes = await stub.submitted
        let submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: WalletTransactionLimits.standard
        )
        let change = try XCTUnwrap(Cosign.decode(submitted.outputs[2].lockingScript))
        XCTAssertEqual(change.address.description, derived[0].address)
    }

    func test_ownerSignaturesMatchIndependentResign() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let owner = try Address(derived[0].address)
        let sourceScript = try cosignTransferScript(address: owner, amount: 200_000)
        let source = try sourceTransaction(lockingScript: sourceScript)
        let stub = MneeStub(
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived, changeAddress: derived[0].address)
        ) { _ in }
        XCTAssertNil(result.error)
        let limits = WalletTransactionLimits.standard
        let submittedBytes = await stub.submitted
        var submitted = try Transaction(
            bytes: try XCTUnwrap(submittedBytes),
            limits: limits
        )
        submitted.inputs[0].sourceOutput = TransactionOutput(satoshis: 1, lockingScript: sourceScript)
        let hashType = ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true)
        XCTAssertEqual(hashType.rawValue, 0xC1)
        let digest = try submitted.forkIDSignatureHash(
            inputIndex: 0,
            hashType: hashType,
            limits: limits
        )
        let key = try P1SATKey.privateKey(identity: identity, keyID: "1sat 0")
        let first = try key.sign(digest: digest).derBytes
        let second = try key.sign(digest: digest).derBytes
        XCTAssertEqual(first, second)
        let operations = try submitted.inputs[0].unlockingScript.operations(
            maximumPushDataByteCount: Int(limits.maximumScriptByteCount)
        )
        XCTAssertEqual(operations.count, 2)
        let signaturePush = try XCTUnwrap(operations[0].pushedData)
        XCTAssertEqual(signaturePush.last, 0xC1)
        XCTAssertEqual(Array(signaturePush.dropLast()), first)
        XCTAssertEqual(operations[1].pushedData, key.publicKey.serialized(as: .compressed))
    }

    func test_missingKeyForOwnerAddress() async throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let source = try sourceTransaction(
            lockingScript: try cosignTransferScript(
                address: try Address(derived[0].address),
                amount: 200_000
            )
        )
        let foreign = ActionVectors.payAddress
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 0)]),
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [foreign]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        let result = await Mnee.send(
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived)
        ) { _ in }
        XCTAssertEqual(
            result.error,
            "No key found for address \(foreign) — not a yours wallet address"
        )
    }

    func test_emptyTicketId() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setSubmit(.success(""))
        let result = await Mnee.send(fixture.ctx, fixture.request) { _ in }
        XCTAssertEqual(result.error, "no-ticket-id-returned")
        XCTAssertNil(result.ticketId)
    }

    func test_failedStatusSurfacesErrors() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setStatuses([
            .success(Mnee.TicketStatus(status: Mnee.statusFailed, txid: "", errors: "cosigner-rejected")),
        ])
        let sleeps = SleepRecorder()
        let result = await Mnee.send(fixture.ctx, fixture.request) { await sleeps.record($0) }
        XCTAssertEqual(result.ticketId, "ticket-1")
        XCTAssertEqual(result.error, "cosigner-rejected")
        let delays = await sleeps.delays
        XCTAssertEqual(delays, [2000])
    }

    func test_failedStatusWithoutErrors() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setStatuses([
            .success(Mnee.TicketStatus(status: Mnee.statusFailed, txid: "")),
        ])
        let result = await Mnee.send(fixture.ctx, fixture.request) { _ in }
        XCTAssertEqual(result.error, "transaction-failed")
    }

    func test_broadcastingThenSuccess() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setStatuses([
            .success(Mnee.TicketStatus(status: Mnee.statusBroadcasting, txid: "")),
            .success(Mnee.TicketStatus(status: Mnee.statusBroadcasting, txid: "")),
            .success(Mnee.TicketStatus(status: Mnee.statusSuccess, txid: "mined-txid")),
        ])
        let sleeps = SleepRecorder()
        let result = await Mnee.send(fixture.ctx, fixture.request) { await sleeps.record($0) }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.txid, "mined-txid")
        XCTAssertEqual(result.ticketId, "ticket-1")
        let delays = await sleeps.delays
        XCTAssertEqual(delays, [2000, 2000, 2000])
        let statusCalls = await fixture.stub.statusCalls
        XCTAssertEqual(statusCalls, 3)
    }

    func test_timeoutAfterThirtyBroadcasts() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setStatuses(
            Array(
                repeating: .success(Mnee.TicketStatus(status: Mnee.statusBroadcasting, txid: "")),
                count: 30
            )
        )
        let sleeps = SleepRecorder()
        let result = await Mnee.send(fixture.ctx, fixture.request) { await sleeps.record($0) }
        XCTAssertEqual(result.error, "timeout-waiting-for-txid")
        XCTAssertEqual(result.ticketId, "ticket-1")
        let delays = await sleeps.delays
        XCTAssertEqual(delays, Array(repeating: UInt64(2000), count: 30))
        let statusCalls = await fixture.stub.statusCalls
        XCTAssertEqual(statusCalls, 30)
    }

    func test_throwingPollContinues() async throws {
        let fixture = try await fundedStub()
        await fixture.stub.setStatuses([
            .failure(StubError("transient")),
            .success(Mnee.TicketStatus(status: Mnee.statusSuccess, txid: "after-throw")),
        ])
        let sleeps = SleepRecorder()
        let result = await Mnee.send(fixture.ctx, fixture.request) { await sleeps.record($0) }
        XCTAssertNil(result.error)
        XCTAssertEqual(result.txid, "after-throw")
        let delays = await sleeps.delays
        XCTAssertEqual(delays, [2000, 2000])
        let statusCalls = await fixture.stub.statusCalls
        XCTAssertEqual(statusCalls, 2)
    }

    func test_depositDerivations() throws {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        XCTAssertEqual(derived.count, 5)
        for (index, item) in derived.enumerated() {
            XCTAssertEqual(item.derivationPrefix, "1sat")
            XCTAssertEqual(item.derivationSuffix, String(index))
            XCTAssertEqual(
                item.address,
                try DepositAddresses.address(identity: identity, index: index).description
            )
        }
    }

    func test_decimalStringAndToAtomicAmount() {
        XCTAssertEqual(Mnee.decimalString(atomic: 150_000), "1.5")
        XCTAssertEqual(Mnee.decimalString(atomic: 100_000), "1")
        XCTAssertEqual(Mnee.decimalString(atomic: 12), "0.00012")
        XCTAssertEqual(Mnee.decimalString(atomic: 0), "0")
        XCTAssertEqual(Mnee.toAtomicAmount(1.5), 150_000)
        XCTAssertEqual(Mnee.toAtomicAmount(0.00001), 1)
    }

    private func context(
        identity: PrivateKey? = nil,
        mnee: (any MneeActionServices)?
    ) throws -> OneSatContext {
        let identity = try identity ?? ActionVectors.identity()
        return OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: OfflineTransport()
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            mnee: mnee
        )
    }

    private func derivations() throws -> [Mnee.Derivation] {
        try Mnee.depositDerivations(identity: ActionVectors.identity())
    }

    private func request(
        amount: Double = 1,
        derivations: [Mnee.Derivation]? = nil,
        changeAddress: String? = nil
    ) throws -> Mnee.SendRequest {
        Mnee.SendRequest(
            recipients: [Mnee.Recipient(address: ActionVectors.payAddress, amount: amount)],
            derivations: try derivations ?? self.derivations(),
            changeAddress: changeAddress
        )
    }

    private func fixtureConfig(
        approver: String? = nil,
        fees: [Mnee.FeeTier] = [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 1_000)]
    ) throws -> Mnee.Config {
        Mnee.Config(
            approver: try approver ?? Hex.encode(approverBytes()),
            feeAddress: ActionVectors.payAddress,
            burnAddress: ActionVectors.templateAddress,
            fees: fees,
            tokenId: ActionVectors.tokenID
        )
    }

    private func fundedStub() async throws -> (ctx: OneSatContext, request: Mnee.SendRequest, stub: MneeStub) {
        let identity = try ActionVectors.identity()
        let derived = try Mnee.depositDerivations(identity: identity)
        let source = try sourceTransaction(
            lockingScript: try cosignTransferScript(
                address: try Address(derived[0].address),
                amount: 200_000
            )
        )
        let stub = MneeStub(
            config: try fixtureConfig(fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 0)]),
            utxos: [
                Mnee.Utxo(txid: source.txid, vout: 0, amount: 200_000, owners: [derived[0].address]),
            ],
            rawTransactions: [source.txid: .success(source.bytes)]
        )
        return (
            try context(identity: identity, mnee: stub),
            try request(amount: 1, derivations: derived),
            stub
        )
    }

    private func cosignTransferScript(address: Address, amount: Int) throws -> Script {
        try BSV21.transfer(tokenID: ActionVectors.tokenID, amount: String(amount))
            .lock(lockingScript: try Cosign.lock(address: address, cosigner: try approverBytes()))
    }

    private func sourceTransaction(
        lockingScript: Script,
        salt: String = "11"
    ) throws -> (txid: String, bytes: [UInt8]) {
        let limits = WalletTransactionLimits.standard
        let tx = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: salt, count: 32)),
                        outputIndex: 0
                    ),
                    unlockingScript: try Script(
                        bytes: [],
                        maximumByteCount: Int(limits.maximumScriptByteCount)
                    ),
                    sequence: 0xffff_ffff
                ),
            ],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: lockingScript)],
            lockTime: 0
        )
        let bytes = try tx.serialized(format: .raw, limits: limits)
        return (try tx.transactionID(limits: limits).displayHex, bytes)
    }

    private func approverBytes() throws -> [UInt8] {
        try ActionVectors.recipient().publicKey.serialized(as: .compressed)
    }
}

private actor MneeStub: MneeActionServices {
    private var configValue: Result<Mnee.Config, Error>
    private var utxoValue: Result<[Mnee.Utxo], Error>
    private var rawTransactions: [String: Result<[UInt8], Error>]
    private var submitValue: Result<String, Error>
    private var statusValues: [Result<Mnee.TicketStatus, Error>]
    private var statusIndex = 0

    private(set) var calls: [String] = []
    private(set) var submitted: [UInt8]?
    private(set) var rawRequested: [String] = []
    private(set) var statusCalls = 0

    init(
        config: Mnee.Config? = nil,
        utxos: [Mnee.Utxo] = [],
        rawTransactions: [String: Result<[UInt8], Error>] = [:],
        submit: Result<String, Error> = .success("ticket-1"),
        statuses: [Result<Mnee.TicketStatus, Error>] = [
            .success(Mnee.TicketStatus(status: Mnee.statusSuccess, txid: "ok-txid")),
        ]
    ) {
        if let config {
            configValue = .success(config)
        } else {
            do {
                configValue = .success(
                    Mnee.Config(
                        approver: Hex.encode(try ActionVectors.recipient().publicKey.serialized(as: .compressed)),
                        feeAddress: ActionVectors.payAddress,
                        burnAddress: ActionVectors.templateAddress,
                        fees: [Mnee.FeeTier(min: 0, max: 10_000_000, fee: 1_000)],
                        tokenId: ActionVectors.tokenID
                    )
                )
            } catch {
                configValue = .failure(error)
            }
        }
        utxoValue = .success(utxos)
        self.rawTransactions = rawTransactions
        submitValue = submit
        statusValues = statuses
    }

    func setSubmit(_ value: Result<String, Error>) {
        submitValue = value
    }

    func setStatuses(_ values: [Result<Mnee.TicketStatus, Error>]) {
        statusValues = values
        statusIndex = 0
    }

    func config() async throws -> Mnee.Config {
        calls.append("config")
        return try configValue.get()
    }

    func utxos(addresses: [String]) async throws -> [Mnee.Utxo] {
        calls.append("utxos")
        return try utxoValue.get()
    }

    func rawTransaction(txid: String) async throws -> [UInt8] {
        calls.append("rawTransaction")
        rawRequested.append(txid)
        if let value = rawTransactions[txid] {
            return try value.get()
        }
        throw StubError("missing-raw-\(txid)")
    }

    func submitTransfer(tx: [UInt8]) async throws -> String {
        calls.append("submitTransfer")
        submitted = tx
        return try submitValue.get()
    }

    func transferStatus(ticketId: String) async throws -> Mnee.TicketStatus {
        calls.append("transferStatus")
        statusCalls += 1
        if statusIndex >= statusValues.count {
            return Mnee.TicketStatus(status: Mnee.statusBroadcasting, txid: "")
        }
        let value = statusValues[statusIndex]
        statusIndex += 1
        return try value.get()
    }
}

private actor SleepRecorder {
    private(set) var delays: [UInt64] = []

    func record(_ milliseconds: UInt64) {
        delays.append(milliseconds)
    }
}

private struct StubError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct OfflineTransport: AuthenticatedTransport {
    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        throw AuthTransportError.notImplemented("offline")
    }
}
