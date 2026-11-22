import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import ToolboxActions
import OneSatClient
import XCTest
@testable import OneSatActions

/// A Pixel Foxes item and its collection, as mined (`pixel-foxes-membership.json`): both are
/// signed with SIGMA BSM by the same address.
final class CollectionMembershipTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Item: Decodable {
            let vout: Int
            let origin: String
            let lockingScript: String
            let inputs: [String]
            let proof: String
        }
        struct Collection: Decodable {
            let origin: String
            let vout: Int
            let rawTransaction: String
            let proof: String
        }
        let item: Item
        let collection: Collection
        let signer: String
    }

    private func fixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "pixel-foxes-membership",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func itemScript(_ fixture: Fixture) throws -> [UInt8] {
        try Hex.decode(fixture.item.lockingScript, maximumDecodedByteCount: fixture.item.lockingScript.count / 2)
    }

    private func itemInputs(_ fixture: Fixture) throws -> [Outpoint] {
        try fixture.item.inputs.map { try Outpoint($0) }
    }

    private func collectionTransaction(_ fixture: Fixture) throws -> Transaction {
        let hex = fixture.collection.rawTransaction
        return try Transaction(
            bytes: Hex.decode(hex, maximumDecodedByteCount: hex.count / 2),
            limits: WalletTransactionLimits.standard
        )
    }

    func test_itemSignatureVerifiesForTheCollectionCreator() throws {
        let fixture = try fixture()
        let authorship = CollectionMembership.authorship(
            lockingScript: try itemScript(fixture),
            inputs: try itemInputs(fixture)
        )
        XCTAssertEqual(authorship, .init(signers: [fixture.signer], isSigned: true))
    }

    func test_collectionSignatureVerifiesFromItsTransaction() throws {
        let fixture = try fixture()
        let authorship = CollectionMembership.authorship(
            of: try collectionTransaction(fixture),
            vout: fixture.collection.vout
        )
        XCTAssertEqual(authorship, .init(signers: [fixture.signer], isSigned: true))
    }

    func test_signatureOverAnotherInputDoesNotVerify() throws {
        let fixture = try fixture()
        let other = try Outpoint("10994c042558429911f8e86499d7111dc8ec9c8fe6811a9f15208da120d65e01.301")
        let authorship = CollectionMembership.authorship(lockingScript: try itemScript(fixture), inputs: [other])
        XCTAssertEqual(authorship, .init(signers: [], isSigned: true))
    }

    func test_changedInscriptionDoesNotVerify() throws {
        let fixture = try fixture()
        var script = try itemScript(fixture)
        let name = Array("Pixel Foxes".utf8)
        let at = try XCTUnwrap(script.indices.first { Array(script[$0..<min($0 + name.count, script.count)]) == name })
        script[at] = UInt8(ascii: "Q")
        let authorship = CollectionMembership.authorship(lockingScript: script, inputs: try itemInputs(fixture))
        XCTAssertEqual(authorship, .init(signers: [], isSigned: true))
    }

    /// TS `deduceRecovery` ignores the header byte: a signature written with another header
    /// still verifies for its signer.
    func test_signatureHeaderByteIsIgnoredAsInTypeScript() throws {
        let fixture = try fixture()
        var script = try itemScript(fixture)
        let at = try XCTUnwrap(Self.signatureStart(in: script))
        script[at] = script[at] == 31 ? 27 : 31
        let authorship = CollectionMembership.authorship(lockingScript: script, inputs: try itemInputs(fixture))
        XCTAssertEqual(authorship.signers, [fixture.signer])
    }

    /// Where the 65-byte signature after `SIGMA`, `BSM` and the address starts.
    private static func signatureStart(in script: [UInt8]) -> Int? {
        let marker: [UInt8] = [0x05] + Array("SIGMA".utf8) + [0x03] + Array("BSM".utf8)
        guard let start = script.indices.first(where: { Array(script[$0..<min($0 + marker.count, script.count)]) == marker })
        else { return nil }
        let addressLength = Int(script[start + marker.count])
        let push = start + marker.count + 1 + addressLength
        guard script[push] == 0x41 else { return nil }
        return push + 1
    }

    func test_otherOutputOfTheCollectionIsUnsigned() throws {
        let fixture = try fixture()
        let authorship = CollectionMembership.authorship(of: try collectionTransaction(fixture), vout: 1)
        XCTAssertEqual(authorship, .init(signers: [], isSigned: false))
        XCTAssertEqual(
            CollectionMembership.authorship(of: try collectionTransaction(fixture), vout: 9),
            .init(signers: [], isSigned: false)
        )
    }

    func test_aipIsASignatureThatIsNotChecked() throws {
        var script: [UInt8] = [0x00, 0x6A, 0x05]
        script += Array("hello".utf8)
        script += [0x01, 0x7C, 0x22]
        script += Array(CollectionMembership.aipPrefix.utf8)
        script += [0x03]
        script += Array("BSM".utf8)
        let authorship = CollectionMembership.authorship(lockingScript: script, inputs: [])
        XCTAssertEqual(authorship, CollectionMembership.Authorship(signers: [], isSigned: true))
    }

    // MARK: - Where each was mined

    private func proof(_ hex: String) throws -> MerklePath {
        try MerklePath(
            bytes: Hex.decode(hex, maximumDecodedByteCount: hex.count / 2),
            limits: WalletBEEFLimits.standard.merklePathLimits
        )
    }

    func test_itemWasMinedAfterItsCollection() throws {
        let fixture = try fixture()
        let item = try XCTUnwrap(CollectionMembership.BlockPosition(
            proof: proof(fixture.item.proof),
            txid: Outpoint(ordinal: fixture.item.origin).transactionID
        ))
        let collection = try XCTUnwrap(CollectionMembership.BlockPosition(
            proof: proof(fixture.collection.proof),
            txid: Outpoint(ordinal: fixture.collection.origin).transactionID
        ))
        XCTAssertEqual(item, .init(height: 855_153, index: 344))
        XCTAssertEqual(collection, .init(height: 842_279, index: 103))
        XCTAssertLessThan(collection, item)
    }

    func test_proofOfAnotherTransactionHasNoPosition() throws {
        let fixture = try fixture()
        XCTAssertNil(CollectionMembership.BlockPosition(
            proof: try proof(fixture.collection.proof),
            txid: try Outpoint(ordinal: fixture.item.origin).transactionID
        ))
    }

    func test_evidenceReadsTheCollectionFromTheIndexer() async throws {
        let fixture = try fixture()
        let raw = try Hex.decode(fixture.collection.rawTransaction, maximumDecodedByteCount: fixture.collection.rawTransaction.count / 2)
        let proofBytes = try Hex.decode(fixture.collection.proof, maximumDecodedByteCount: fixture.collection.proof.count / 2)
        let http = IndexerStub(responses: [(200, raw), (200, proofBytes)])
        let evidence = try await CollectionMembership.evidence(
            origin: fixture.collection.origin,
            services: OneSatDepositAssets(baseURL: URL(string: "https://indexer.test")!, transport: http)
        )
        XCTAssertEqual(evidence, .init(
            authorship: .init(signers: [fixture.signer], isSigned: true),
            mined: .init(height: 842_279, index: 103)
        ))
        let paths = await http.calls.map(\.path)
        let txid = String(fixture.collection.origin.prefix(64))
        XCTAssertEqual(paths, ["/1sat/beef/\(txid)/tx", "/1sat/beef/\(txid)/proof"])
    }

    func test_outputsOfOneTransactionAreReadWithOneDownload() async throws {
        let fixture = try fixture()
        let raw = try Hex.decode(fixture.collection.rawTransaction, maximumDecodedByteCount: fixture.collection.rawTransaction.count / 2)
        let proofBytes = try Hex.decode(fixture.collection.proof, maximumDecodedByteCount: fixture.collection.proof.count / 2)
        let http = IndexerStub(responses: [(200, raw), (200, proofBytes)])
        let read = try await CollectionMembership.evidence(
            txid: Outpoint(ordinal: fixture.collection.origin).transactionID,
            vouts: [0, 1],
            services: OneSatDepositAssets(baseURL: URL(string: "https://indexer.test")!, transport: http)
        )
        XCTAssertEqual(read[0]?.authorship.signers, [fixture.signer])
        XCTAssertEqual(read[1]?.authorship, CollectionMembership.Authorship(signers: [], isSigned: false))
        XCTAssertEqual(read[1]?.mined, .init(height: 842_279, index: 103))
        let calls = await http.calls.count
        XCTAssertEqual(calls, 2)
    }

    func test_evidenceOfAnUnminedTransactionHasNoPosition() async throws {
        let fixture = try fixture()
        let raw = try Hex.decode(fixture.collection.rawTransaction, maximumDecodedByteCount: fixture.collection.rawTransaction.count / 2)
        let http = IndexerStub(responses: [(200, raw), (404, Array("not found".utf8))])
        let evidence = try await CollectionMembership.evidence(
            origin: fixture.collection.origin,
            services: OneSatDepositAssets(baseURL: URL(string: "https://indexer.test")!, transport: http)
        )
        XCTAssertNil(evidence.mined)
        XCTAssertEqual(evidence.authorship.signers, [fixture.signer])
    }

    func test_evidenceRefusesAnotherTransaction() async throws {
        let fixture = try fixture()
        let raw = try Hex.decode(fixture.collection.rawTransaction, maximumDecodedByteCount: fixture.collection.rawTransaction.count / 2)
        let http = IndexerStub(responses: [(200, raw)])
        do {
            _ = try await CollectionMembership.evidence(
                origin: fixture.item.origin,
                services: OneSatDepositAssets(baseURL: URL(string: "https://indexer.test")!, transport: http)
            )
            XCTFail("expected wrongTransaction")
        } catch CollectionMembershipError.wrongTransaction(let asked, let got) {
            XCTAssertEqual(asked, String(fixture.item.origin.prefix(64)))
            XCTAssertEqual(got, String(fixture.collection.origin.prefix(64)))
        }
    }

    func test_evidenceSurfacesIndexerFailures() async throws {
        let fixture = try fixture()
        let http = IndexerStub(responses: [(500, Array("boom".utf8))])
        do {
            _ = try await CollectionMembership.evidence(
                origin: fixture.collection.origin,
                services: OneSatDepositAssets(baseURL: URL(string: "https://indexer.test")!, transport: http)
            )
            XCTFail("expected httpFailure")
        } catch DepositAssetError.httpFailure(let status, _) {
            XCTAssertEqual(status, 500)
        }
    }

    // MARK: - Verdicts

    private let creator = "1Jm3WuTxrKMLYXFRCFZuCB879GmqvyQoMf"
    private let stranger = "1BoatSLRHtKNngkdXEeobR76b53LETtpyT"
    private let early = CollectionMembership.BlockPosition(height: 842_279, index: 103)
    private let sameBlockLater = CollectionMembership.BlockPosition(height: 842_279, index: 104)
    private let late = CollectionMembership.BlockPosition(height: 855_153, index: 344)

    private func evidence(
        _ signers: [String],
        signed: Bool? = nil,
        at mined: CollectionMembership.BlockPosition?
    ) -> CollectionMembership.Evidence {
        .init(authorship: .init(signers: signers, isSigned: signed ?? !signers.isEmpty), mined: mined)
    }

    func test_verdicts() {
        let collection = evidence([creator], at: early)
        let verdict = CollectionMembership.verdict
        XCTAssertEqual(verdict(evidence([creator], at: late), collection), .member)
        XCTAssertEqual(verdict(evidence([creator], at: sameBlockLater), collection), .member)
        XCTAssertEqual(verdict(evidence([creator], at: early), collection), .member)
        XCTAssertEqual(verdict(evidence([creator], at: nil), collection), .member)
        XCTAssertEqual(verdict(evidence([stranger], at: late), collection), .notSignedByCreator)
        XCTAssertEqual(verdict(evidence([], at: late), collection), .unsigned)
        XCTAssertEqual(verdict(evidence([], signed: true, at: late), collection), .unverified)
        XCTAssertEqual(verdict(evidence([creator], at: early), evidence([creator], at: late)), .inscribedBeforeCollection)
        XCTAssertEqual(verdict(evidence([creator], at: early), evidence([creator], at: sameBlockLater)), .inscribedBeforeCollection)
        // A collection with no proof yet leaves the order unknown, and the item stays.
        XCTAssertEqual(verdict(evidence([creator], at: early), evidence([creator], at: nil)), .member)
        XCTAssertEqual(verdict(evidence([stranger], at: late), evidence([], at: early)), .unverified)
        XCTAssertEqual(verdict(evidence([], at: late), evidence([], signed: true, at: early)), .unverified)
    }

    func test_onlyRuledOutVerdictsLeaveTheCollection() {
        XCTAssertTrue(CollectionMembership.Verdict.member.isMember)
        XCTAssertTrue(CollectionMembership.Verdict.unverified.isMember)
        XCTAssertFalse(CollectionMembership.Verdict.unsigned.isMember)
        XCTAssertFalse(CollectionMembership.Verdict.notSignedByCreator.isMember)
        XCTAssertFalse(CollectionMembership.Verdict.inscribedBeforeCollection.isMember)
    }
}

private actor IndexerStub: OneSatHTTPTransport {
    private var responses: [(status: Int, body: [UInt8])]
    private(set) var calls: [URL] = []

    init(responses: [(status: Int, body: [UInt8])]) {
        self.responses = responses
    }

    func send(
        method: String,
        url: URL,
        headers _: [String: String],
        body _: [UInt8]?
    ) async throws -> (status: Int, body: [UInt8]) {
        calls.append(url)
        return responses.removeFirst()
    }
}
