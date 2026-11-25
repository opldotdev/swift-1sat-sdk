import Foundation
import XCTest
import BSVCore
import BSVTransaction
import BSVWallet
import ToolboxActions
@testable import OneSatActions
@testable import OneSatTemplates

/// `OpNS.internalize` against the `internalizeAction` request `@1sat/actions` `internalizeOpns`
/// sends for synthetic mints (`Fixtures/opns-internalize.json`, generated with Bun with
/// `crypto.getRandomValues` fixed so the action id is `a1a2a3a4a5a6a7a8`; `{contract}` stands for
/// `OPNS_CONTRACT`). Protocol `[0, "onesat"]`, keyID `1sat 0`.
final class OpNSInternalizeTests: XCTestCase {
    private static let actionID = "a1a2a3a4a5a6a7a8"

    struct Insertion: Decodable {
        let basket: String
        let tags: [String]
        let customInstructions: String
    }

    struct Output: Decodable {
        let outputIndex: UInt32
        let `protocol`: String
        let insertionRemittance: Insertion
    }

    struct Request: Decodable {
        let tx: String
        let outputs: [Output]
        let description: String
    }

    struct Result: Decodable {
        let txid: String?
        let outpoint: String?
        let name: String?
        let id: String?
        let error: String?
    }

    struct Input: Decodable {
        let counterparty: String?
    }

    struct Mint: Decodable {
        let beef: String
        let input: Input
        let result: Result
        let request: Request?
    }

    struct Fixture: Decodable {
        let contract: String
        let mints: [String: Mint]
    }

    private actor CapturingInternalizer: ActionInternalizer {
        private(set) var requests: [WalletInternalizeActionRequest] = []
        func internalizeAction(
            _ request: WalletInternalizeActionRequest
        ) async throws -> WalletInternalizeActionResult {
            requests.append(request)
            return WalletInternalizeActionResult(accepted: true)
        }
    }

    private struct Refusal: Error, LocalizedError {
        var errorDescription: String? { "storage refused the output" }
    }

    private actor RefusingInternalizer: ActionInternalizer {
        func internalizeAction(
            _ request: WalletInternalizeActionRequest
        ) async throws -> WalletInternalizeActionResult {
            throw Refusal()
        }
    }

    private static func fixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/opns-internalize", withExtension: "json")
                ?? Bundle.module.url(forResource: "opns-internalize", withExtension: "json", subdirectory: "Fixtures")
        )
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func bytes(_ hex: String) throws -> [UInt8] {
        let expanded = hex.replacingOccurrences(of: "{contract}", with: Hex.encode(OpNSTemplate.contract))
        return try Hex.decode(expanded, maximumDecodedByteCount: 1_000_000)
    }

    private func run(
        _ mint: Mint,
        internalizer: any ActionInternalizer = CapturingInternalizer()
    ) async throws -> OpNS.InternalizeResult {
        await OpNS.internalize(
            internalizer,
            OpNS.InternalizeRequest(
                tx: try bytes(mint.beef),
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: "1sat 0",
                counterparty: mint.input.counterparty
            ),
            actionID: Self.actionID
        )
    }

    /// Every mint that delivers a name: the request is the one TS sends, field for field, and the
    /// transaction goes to the wallet as given.
    func test_mintRequestsMatchTS() async throws {
        let fixture = try Self.fixture()
        XCTAssertEqual(fixture.contract, Hex.encode(OpNSTemplate.contract))
        for label in ["mint", "mintCounterparty", "offset", "longDomain"] {
            let mint = try XCTUnwrap(fixture.mints[label], label)
            let expected = try XCTUnwrap(mint.request, label)
            let internalizer = CapturingInternalizer()
            let result = try await run(mint, internalizer: internalizer)

            XCTAssertEqual(result, OpNS.InternalizeResult(
                txid: mint.result.txid, outpoint: mint.result.outpoint,
                name: mint.result.name, id: mint.result.id
            ), label)
            let requests = await internalizer.requests
            XCTAssertEqual(requests.count, 1, label)
            let request = try XCTUnwrap(requests.first, label)
            XCTAssertEqual(expected.tx, mint.beef, label)
            XCTAssertEqual(
                try request.transaction.serialized(limits: WalletBEEFLimits.standard),
                try bytes(mint.beef),
                label
            )
            XCTAssertEqual(request.description, expected.description, label)
            XCTAssertEqual(request.labels, [], label)
            XCTAssertNil(request.seekPermission, label)
            XCTAssertEqual(request.outputs.count, expected.outputs.count, label)
            for (output, want) in zip(request.outputs, expected.outputs) {
                XCTAssertEqual(output.outputIndex, want.outputIndex, label)
                XCTAssertEqual(want.protocol, "basket insertion", label)
                guard case .basketInsertion(let insertion) = output.remittance else {
                    XCTFail("\(label): not a basket insertion")
                    continue
                }
                XCTAssertEqual(insertion.basket, want.insertionRemittance.basket, label)
                XCTAssertEqual(insertion.tags, want.insertionRemittance.tags, label)
                XCTAssertEqual(insertion.customInstructions, want.insertionRemittance.customInstructions, label)
            }
        }
    }

    /// An 80-character domain padded with whitespace: trimmed, cut to 64 units for the name, and
    /// the description cut to 50.
    func test_longDomainIsTrimmedAndCut() async throws {
        let mint = try XCTUnwrap(try Self.fixture().mints["longDomain"])
        let result = try await run(mint)
        XCTAssertEqual(result.name, String(String(repeating: "abcdefghij", count: 7).prefix(64)))
        XCTAssertEqual(result.name?.utf16.count, 64)
        XCTAssertEqual(mint.request?.description.utf16.count, 50)
    }

    /// No two adjacent nodes followed by a third output, or a child whose domain is only
    /// whitespace: `not-an-opns-mint`, and nothing reaches the wallet.
    func test_nonMintsAreRefused() async throws {
        let fixture = try Self.fixture()
        for label in ["nonMint", "twoOutputs", "emptyChild"] {
            let mint = try XCTUnwrap(fixture.mints[label], label)
            XCTAssertNil(mint.request, label)
            XCTAssertEqual(mint.result.error, "not-an-opns-mint", label)
            let internalizer = CapturingInternalizer()
            let result = try await run(mint, internalizer: internalizer)
            XCTAssertEqual(result, OpNS.InternalizeResult(error: "not-an-opns-mint"), label)
            XCTAssertEqual(OneSatActionError(wireMessage: try XCTUnwrap(result.error)), .notAnOpnsMint)
            let requests = await internalizer.requests
            XCTAssertTrue(requests.isEmpty, label)
        }
    }

    /// The wallet's own failure comes back as `error`, as TS returns its message.
    func test_walletFailureIsReturned() async throws {
        let mint = try XCTUnwrap(try Self.fixture().mints["mint"])
        let result = try await run(mint, internalizer: RefusingInternalizer())
        XCTAssertEqual(result.error, "storage refused the output")
        XCTAssertNil(result.txid)
        XCTAssertNotNil(result.diagnostic)
    }

    /// Bytes that are not Atomic BEEF fail before the wallet is called.
    func test_notAtomicBEEFFails() async throws {
        let internalizer = CapturingInternalizer()
        let result = await OpNS.internalize(
            internalizer,
            OpNS.InternalizeRequest(tx: [0, 1, 2, 3], protocolID: try OneSatConstants.p1satProtocolID, keyID: "1sat 0")
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
    }
}
