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

    /// `toBinaryAtomic(txid)` cuts the transactions after `txid`: an earlier subject is wrapped
    /// with its own ancestry only.
    func test_atomicForAnEarlierSubjectDropsTheNewerTransactions() throws {
        let fixture = try chain()
        let atomic = try OneSatBEEF.atomic(fixture.atomicBytes, subject: fixture.parentID)
        XCTAssertEqual(atomic.subjectTransactionID, fixture.parentID)
        XCTAssertEqual(
            try atomic.beef.transactions.map { try $0.transactionID(limits: limits.transactionLimits) },
            [fixture.parentID]
        )
    }

    /// The subject-txid check stays: a txid the graph does not hold is refused by name.
    func test_atomicRefusesASubjectTheGraphDoesNotHold() throws {
        let fixture = try chain()
        let missing = try TransactionID(displayHex: String(repeating: "ab", count: 32))
        XCTAssertThrowsError(try OneSatBEEF.atomic(fixture.atomicBytes, subject: missing)) { error in
            XCTAssertEqual(error as? BEEFError, .missingSubjectTransaction(missing))
        }
    }

    /// `Beef.fromBinary` keeps an unrelated transaction the server put in the envelope;
    /// `AtomicBEEF(bytes:)` refuses it with `unrelatedTransaction`. The graph reads, and the
    /// wrapped envelope is cut back to the subject's ancestry.
    func test_anEnvelopeCarryingAnUnrelatedTransactionStillReads() throws {
        let fixture = try chain()
        let stray = Transaction(
            version: 2,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 7, lockingScript: try Script(bytes: [0x52], maximumByteCount: 10))],
            lockTime: 0
        )
        let strayID = try stray.transactionID(limits: limits.transactionLimits)
        let padded = try BEEF(
            merklePaths: [],
            transactions: [.raw(stray), .raw(try XCTUnwrap(fixture.beef.transactions.first?.transaction)),
                           .raw(try XCTUnwrap(fixture.beef.transactions.last?.transaction))],
            limits: limits
        )
        let bytes = try OneSatTestBEEF.atomicEnvelope(padded, subject: fixture.childID)
        XCTAssertThrowsError(try AtomicBEEF(bytes: bytes, limits: limits)) { error in
            XCTAssertEqual(error as? BEEFError, .unrelatedTransaction(strayID))
        }

        XCTAssertEqual(try OneSatBEEF.graph(bytes), padded)
        XCTAssertEqual(try OneSatBEEF.atomic(bytes, subject: fixture.childID), fixture.atomic)
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

/// Hand-built BRC-95 envelopes, so a test can serve `/1sat/beef` bytes the way the server does,
/// including envelopes `AtomicBEEF(subjectTransactionID:beef:)` would refuse to build.
enum OneSatTestBEEF {
    static func atomicEnvelope(_ beef: BEEF, subject: TransactionID) throws -> [UInt8] {
        [0x01, 0x01, 0x01, 0x01] + subject.wireBytes
            + (try beef.serialized(limits: WalletBEEFLimits.standard))
    }

    /// Plain BEEF bytes re-served as an Atomic envelope naming `subject`.
    static func atomicEnvelope(plain bytes: [UInt8], subject: TransactionID) throws -> [UInt8] {
        try atomicEnvelope(
            try BEEF(bytes: bytes, limits: WalletBEEFLimits.standard),
            subject: subject
        )
    }
}
