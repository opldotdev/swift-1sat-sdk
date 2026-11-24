import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxStorage
@testable import OneSatColor

/// `ColorExecutor` with and without chosen funding (not in the TS: the funded path is an Open
/// Exchange swap's staging), and `ColorBEEF.Ancestry`, the order it reads coins in.
final class ColorExecutorTests: XCTestCase {
    let identity = try! PrivateKey([UInt8](repeating: 0, count: 31) + [0x21])

    func context(_ wallet: MockWallet) -> OneColorContext {
        OneColorContext(
            identity: identity, storage: wallet,
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)), maximumFee: 20_000
        )
    }

    func request() throws -> WalletCreateActionRequest {
        try WalletCreateActionRequest(
            description: "an executor test payment",
            outputs: [try WalletCreateActionOutput(
                lockingScript: [0x76, 0xa9, 0x14] + [UInt8](repeating: 7, count: 20) + [0x88, 0xac], satoshis: 1_000,
                outputDescription: "an executor test output"
            )],
            labels: ["executor-test"],
            options: try ColorExecutor.options()
        )
    }

    /// Every caller but a swap's staging: one createAction as given, one processAction that
    /// broadcasts it.
    func testExecuteWithoutFundingProcessesOnce() async throws {
        let wallet = try MockWallet(identity: identity)
        let signed = try await ColorExecutor.execute(context(wallet), request: try request()) { _ in [:] }
        let created = await wallet.createRequests
        XCTAssertEqual(created.count, 1)
        XCTAssertNil(created.first?.options?.noSend)
        XCTAssertNil(created.first?.options?.noSendChange)
        let processed = await wallet.processed
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(processed.first?.isNewTx, true)
        XCTAssertEqual(processed.first?.isNoSend, false)
        XCTAssertNotNil(processed.first?.rawTX)
        XCTAssertEqual(signed.transaction.outputs.first?.satoshis, 1_000)
        let aborted = await wallet.aborted
        XCTAssertTrue(aborted.isEmpty)
    }

    /// With funding: createAction as given plus `noSend` and `noSendChange` (best coin last),
    /// the signed transaction processed as a noSend, then a send-only call (`sendWith` its txid).
    func testExecuteWithFundingHoldsThenSendsAlone() async throws {
        let wallet = try MockWallet(identity: identity)
        let records = await wallet.records
        let coins = records.filter { $0.funding != nil }.prefix(2).map { ColorFundingCoin(outpoint: $0.outpoint, satoshis: $0.satoshis) }
        XCTAssertEqual(coins.count, 2)
        let reports = ReportLog()
        let plain = try request()
        let signed = try await ColorExecutor.execute(
            context(wallet), request: plain, funding: ColorFunding(coins: coins) { reports.add($0) }
        ) { _ in [:] }
        let created = await wallet.createRequests
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.options?.noSend, true)
        XCTAssertEqual(created.first?.options?.noSendChange, [coins[1].outpoint, coins[0].outpoint])
        // Nothing else of the caller's request changes.
        XCTAssertEqual(created.first?.outputs, plain.outputs)
        XCTAssertEqual(created.first?.labels, plain.labels)
        XCTAssertEqual(created.first?.description, plain.description)
        XCTAssertEqual(created.first?.options?.signAndProcess, plain.options?.signAndProcess)
        XCTAssertEqual(created.first?.options?.randomizeOutputs, plain.options?.randomizeOutputs)
        let processed = await wallet.processed
        XCTAssertEqual(processed.count, 2)
        XCTAssertEqual(processed.first?.isNoSend, true)
        XCTAssertEqual(processed.first?.isNewTx, true)
        XCTAssertEqual(processed.last?.isNewTx, false)
        XCTAssertEqual(processed.last?.isSendWith, true)
        XCTAssertEqual(processed.last?.isNoSend, false)
        XCTAssertNil(processed.last?.rawTX)
        XCTAssertEqual(processed.last?.sendWith, [signed.transactionID.displayHex])
        XCTAssertEqual(reports.all.count, 1)
        XCTAssertNil(reports.all.first?.fellBack)
        XCTAssertEqual(reports.all.first?.sent, [coins[1].outpoint.description, coins[0].outpoint.description])
    }

    /// A send that storage does not report `unproven` fails the action and aborts it.
    func testAFundedSendThatFailsAbortsTheAction() async throws {
        let wallet = try MockWallet(identity: identity)
        await wallet.setSendOnlyStatus(.failed)
        let records = await wallet.records
        let coin = try XCTUnwrap(records.first { $0.funding != nil })
        do {
            _ = try await ColorExecutor.execute(
                context(wallet), request: try request(),
                funding: ColorFunding(coins: [ColorFundingCoin(outpoint: coin.outpoint, satoshis: coin.satoshis)])
            ) { _ in [:] }
            XCTFail("a failed send returned")
        } catch {
            XCTAssertTrue("\(error)".contains("broadcast failed"), "\(error)")
        }
        let processed = await wallet.processed
        XCTAssertEqual(processed.count, 2)
        let aborted = await wallet.aborted
        XCTAssertEqual(aborted, [try XCTUnwrap(processed.first?.reference)])
    }

    /// A send-only call that throws, or a send storage leaves `sending`, may be out: the action
    /// is not aborted, and the error is thrown.
    func testAFundedSendThatThrowsOrIsSendingIsNotAborted() async throws {
        for (status, error, expected) in [
            (SendWithResult.Status.unproven, "the network is down" as String?, "the network is down"),
            (.sending, nil, "broadcast sending"),
        ] {
            let wallet = try MockWallet(identity: identity)
            await wallet.setSendOnlyStatus(status)
            await wallet.setSendOnlyError(error)
            let records = await wallet.records
            let coin = try XCTUnwrap(records.first { $0.funding != nil })
            do {
                _ = try await ColorExecutor.execute(
                    context(wallet), request: try request(),
                    funding: ColorFunding(coins: [ColorFundingCoin(outpoint: coin.outpoint, satoshis: coin.satoshis)])
                ) { _ in [:] }
                XCTFail("a send that may be out returned")
            } catch {
                XCTAssertTrue("\(error)".contains(expected), "\(error)")
            }
            let processed = await wallet.processed
            XCTAssertEqual(processed.count, 2)
            let aborted = await wallet.aborted
            XCTAssertEqual(aborted, [], expected)
        }
    }

    func testStorageRefusingANoSendChangeOutpointIsRecognised() {
        XCTAssertTrue(ColorExecutor.refusesNoSendChange(HarnessError("WERR_INVALID_PARAMETER: The noSendChange outpoint parameter must be valid")))
        XCTAssertFalse(ColorExecutor.refusesNoSendChange(HarnessError("WERR_INSUFFICIENT_FUNDS")))
        XCTAssertFalse(ColorExecutor.refusesNoSendChange(HarnessError("noSendChange went wrong")))
    }

    // MARK: - Ancestry

    /// A proven transaction carries no unproven bytes; an unproven one carries its own and its
    /// unproven parents', each once, down to the proven or txid-only records.
    func testAncestryCountsUnprovenBytesDownToProvenRecords() throws {
        func tx(_ marker: UInt8, spending parents: [Transaction]) throws -> Transaction {
            Transaction(
                version: 1,
                inputs: try parents.map {
                    TransactionInput(
                        previousOutput: Outpoint(transactionID: try $0.transactionID(limits: harnessTxLimits), outputIndex: 0),
                        unlockingScript: try Script(bytes: [], maximumByteCount: 10)
                    )
                },
                outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x6a, 0x01, marker], maximumByteCount: 10))],
                lockTime: 0
            )
        }
        let proven = try tx(1, spending: [])
        let middle = try tx(2, spending: [proven])
        let tip = try tx(3, spending: [middle, proven])
        let provenID = try proven.transactionID(limits: harnessTxLimits)
        let path = try MerklePath(blockHeight: 80, levels: [[.hash(offset: 0, hash: try Hash256(provenID.wireBytes), isTransactionID: true)]])
        let beef = try BEEF(
            merklePaths: [path],
            transactions: [.rawWithMerklePath(transaction: proven, merklePathIndex: 0), .raw(middle), .raw(tip)],
            limits: harnessBEEFLimits
        )
        let ancestry = try ColorBEEF.Ancestry(beef)
        let size = { (t: Transaction) in try t.serializedByteCount(limits: harnessTxLimits) }
        let provenOf = try ancestry.of(provenID)
        XCTAssertTrue(provenOf.proven)
        XCTAssertEqual(provenOf.unprovenBytes, 0)
        let middleOf = try ancestry.of(try middle.transactionID(limits: harnessTxLimits))
        XCTAssertFalse(middleOf.proven)
        XCTAssertEqual(middleOf.unprovenBytes, try size(middle))
        let tipOf = try ancestry.of(try tip.transactionID(limits: harnessTxLimits))
        XCTAssertEqual(tipOf.unprovenBytes, try size(tip) + size(middle))
    }
}

final class ReportLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ColorFundingReport] = []

    func add(_ report: ColorFundingReport) { lock.withLock { entries.append(report) } }
    var all: [ColorFundingReport] { lock.withLock { entries } }
}
