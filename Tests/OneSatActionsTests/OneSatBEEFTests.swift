import BSVCore
import BSVScript
import BSVTransaction
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `Beef.fromBinary` takes Atomic (BRC-95) and plain BEEF alike; so must every reader of a
/// `/1sat/beef/:txid` response.
final class OneSatBEEFTests: XCTestCase {
    private let limits = WalletBEEFLimits.standard

    func test_graphReadsAtomicAndPlainBEEFAlike() throws {
        let fixture = try chain()
        XCTAssertTrue(OneSatBEEF.isAtomic(fixture.atomicBytes))
        XCTAssertFalse(OneSatBEEF.isAtomic(fixture.plainBytes))
        XCTAssertFalse(OneSatBEEF.isAtomic([0x01, 0x01, 0x01]))

        XCTAssertEqual(try OneSatBEEF.graph(fixture.atomicBytes), fixture.beef)
        XCTAssertEqual(try OneSatBEEF.graph(fixture.plainBytes), fixture.beef)
    }

    func test_atomicKeepsAMatchingEnvelopeAndWrapsPlainBEEF() throws {
        let fixture = try chain()
        XCTAssertEqual(
            try OneSatBEEF.atomic(fixture.atomicBytes, subject: fixture.childID),
            fixture.atomic
        )
        XCTAssertEqual(
            try OneSatBEEF.atomic(fixture.plainBytes, subject: fixture.childID),
            fixture.atomic
        )
    }

    func test_atomicRefusesASubjectTheGraphDoesNotEndIn() throws {
        let fixture = try chain()
        XCTAssertThrowsError(
            try OneSatBEEF.atomic(fixture.atomicBytes, subject: fixture.parentID)
        ) { error in
            XCTAssertEqual(error as? BEEFError, .unrelatedTransaction(fixture.childID))
        }
    }

    func test_aBrokenAtomicEnvelopeReportsItsOwnError() throws {
        let fixture = try chain()
        let truncated = Array(fixture.atomicBytes.prefix(20))
        XCTAssertThrowsError(try OneSatBEEF.graph(truncated)) { error in
            guard case .malformed(field: .atomicSubjectTransactionID, offset: _, cause: _) =
                    error as? BEEFError
            else {
                return XCTFail("expected a malformed atomic subject, got \(error)")
            }
        }
    }

    func test_listingSourceGraphReadsTheServiceResponse() async throws {
        let fixture = try chain()
        let source = Served(bytes: fixture.atomicBytes)
        let graph = try await source.beefGraph(forTxid: fixture.childID.displayHex)
        XCTAssertEqual(graph, fixture.beef)
    }

    private struct Chain {
        let parentID: TransactionID
        let childID: TransactionID
        let beef: BEEF
        let atomic: AtomicBEEF
        let plainBytes: [UInt8]
        let atomicBytes: [UInt8]
    }

    private func chain() throws -> Chain {
        let opTrue = try Script(bytes: [0x51], maximumByteCount: 10)
        let parent = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 2_000, lockingScript: opTrue)],
            lockTime: 0
        )
        let parentID = try parent.transactionID(limits: limits.transactionLimits)
        let child = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(transactionID: parentID, outputIndex: 0),
                    unlockingScript: try Script(bytes: [], maximumByteCount: 10)
                ),
            ],
            outputs: [TransactionOutput(satoshis: 1_500, lockingScript: opTrue)],
            lockTime: 0
        )
        let childID = try child.transactionID(limits: limits.transactionLimits)
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(parent), .raw(child)],
            limits: limits
        )
        let atomic = try AtomicBEEF(subjectTransactionID: childID, beef: beef, limits: limits)
        return Chain(
            parentID: parentID,
            childID: childID,
            beef: beef,
            atomic: atomic,
            plainBytes: try beef.serialized(limits: limits),
            atomicBytes: try atomic.serialized(limits: limits)
        )
    }
}

private struct Served: ListingBeefSource {
    let bytes: [UInt8]
    func beef(forTxid _: String) async throws -> [UInt8] { bytes }
}
