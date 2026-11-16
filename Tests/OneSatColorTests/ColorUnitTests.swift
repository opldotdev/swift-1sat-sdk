import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatMetanet
import ToolboxActions
import ToolboxStorage
import OneSatTemplates
@testable import OneSatColor

final class ColorUnitTests: XCTestCase {
    let identity = try! PrivateKey([UInt8](repeating: 0, count: 31) + [0x0c])

    // MARK: - MIME entity

    func test_mimeEntityParsesHeadersAndBody() throws {
        let entity = try MimeEntity.parse(Array("Content-Type: Application/Vnd.Metanet.Transaction+CBOR; v=1\r\nX-Note: one\r\n two\r\n\r\nBODY".utf8))
        XCTAssertEqual(entity.contentType, "Application/Vnd.Metanet.Transaction+CBOR; v=1")
        XCTAssertEqual(MimeEntity.mediaType(entity.contentType), "application/vnd.metanet.transaction+cbor")
        XCTAssertEqual(entity.headers["x-note"], "one two")
        XCTAssertEqual(entity.body, Array("BODY".utf8))
    }

    func test_contentWithoutAHeaderBlockIsPlainText() throws {
        for text in ["hello", "not a header\r\n\r\nbody", "a b: c\r\n\r\nx"] {
            let entity = try MimeEntity.parse(Array(text.utf8))
            XCTAssertEqual(entity.contentType, "text/plain", text)
            XCTAssertEqual(entity.body, Array(text.utf8), text)
        }
    }

    func test_aHeaderBlockWithoutContentTypeFails() {
        XCTAssertThrowsError(try MimeEntity.parse(Array("X-Note: one\r\n\r\nbody".utf8)))
    }

    // MARK: - Custody

    func test_metadataEncryptionRoundTripsAndPlainJSONPassesThrough() async throws {
        let custody = try ColorCustody(
            asset: .issue, derivationPrefix: "cA==", derivationSuffix: "cw==",
            senderIdentityKey: Hex.encode(identity.publicKey.compressedBytes)
        )
        let stored = try await ColorMetadata.encrypt(custody.json, identity: identity)
        XCTAssertNotEqual(stored, custody.json)
        let decrypted = await ColorMetadata.decrypt(stored, identity: identity)
        XCTAssertEqual(decrypted, custody.json)
        let passthrough = await ColorMetadata.decrypt(custody.json, identity: identity)
        XCTAssertEqual(passthrough, custody.json)
        let other = try PrivateKey([UInt8](repeating: 0, count: 31) + [0x0d])
        let unreadable = await ColorMetadata.decrypt(stored, identity: other)
        XCTAssertNil(unreadable)
    }

    func test_custodyParseIsStrict() throws {
        let key = Hex.encode(identity.publicKey.compressedBytes)
        let good = #"{"version":1,"assetId":"ISSUE","derivationPrefix":"cA==","derivationSuffix":"cw==","senderIdentityKey":"\#(key)"}"#
        XCTAssertEqual(try ColorCustody.parse(good).asset, .issue)
        XCTAssertNoThrow(try ColorCustody.parse(String(good.dropLast()) + #","profileData":{}}"#))
        XCTAssertThrowsError(try ColorCustody.parse(String(good.dropLast()) + #","profileData":{"x":1}}"#))
        XCTAssertThrowsError(try ColorCustody.parse(String(good.dropLast()) + #","extra":1}"#))
        XCTAssertThrowsError(try ColorCustody.parse(good.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)))
        XCTAssertThrowsError(try ColorCustody.parse(good, maxBytes: 10))
    }

    /// Module 0.2.3 `withSuffixTag`: the caller's tags without any of the suffix tag form, each
    /// once, then one new suffix tag; other `p color ` tags stay.
    func test_withSuffixTagDropsCallerSuffixTagsAndAddsANewOne() throws {
        let fresh = ColorIdentifiers.derivationSuffixTag(random: Array(0x40..<0x60))
        let caller = ColorIdentifiers.derivationSuffixTag(random: Array(0x00..<0x20))
        XCTAssertEqual(ColorModule.withSuffixTag(nil, suffixTag: fresh), [fresh])
        XCTAssertEqual(ColorModule.withSuffixTag(["a", caller, "a"], suffixTag: fresh), ["a", fresh])
        XCTAssertEqual(
            ColorModule.withSuffixTag(["p color offline", "p color \(String(repeating: "A", count: 64))", caller], suffixTag: fresh),
            ["p color offline", "p color \(String(repeating: "A", count: 64))", fresh]
        )
        XCTAssertEqual(ColorModule.withSuffixTag([fresh], suffixTag: fresh), [fresh])
        let drawn = ColorModule.withSuffixTag(["a"])
        XCTAssertEqual(drawn.count, 2)
        XCTAssertTrue(ColorIdentifiers.isDerivationSuffixTag(drawn[1]))
    }

    // MARK: - Overlay answers

    private func tokenTransaction(amount: UInt64) throws -> (Transaction, String) {
        let asset = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let script = try OneColor.value(tokenID: asset.description, amount: amount, lock: .publicKeyHash([UInt8](repeating: 1, count: 20))).lock()
        let transaction = Transaction(version: 1, inputs: [], outputs: [TransactionOutput(satoshis: 1, lockingScript: script)], lockTime: 0)
        return (transaction, try transaction.transactionID(limits: harnessTxLimits).displayHex)
    }

    func test_readOutputListMatchesQueriedOutpointsOnly() throws {
        let (transaction, txid) = try tokenTransaction(amount: 5)
        let beef = try graph([transaction]).serialized(limits: harnessBEEFLimits)
        let item = ColorOutputList.Item(beef: beef, outputIndex: 0)

        let listed = try ColorOverlay.readOutputList(ColorOutputList(outputs: [item]), queried: ["\(txid).0"])
        XCTAssertEqual(listed["\(txid).0"]?.satoshis, 1)

        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [item]), queried: ["\(txid).1"]))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [item, item]), queried: ["\(txid).0"]))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: beef, outputIndex: 3)]), queried: ["\(txid).3"]
        ))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: [1, 2, 3], outputIndex: 0)]), queried: ["\(txid).0"]
        ))
    }

    /// TS `Transaction.fromBEEF(item.beef, item.txid)`: an Atomic BEEF answer reads its subject,
    /// and a named txid picks that transaction from a standard BEEF even when it is not last.
    func test_readOutputListReadsAtomicBEEFAndHonoursANamedTxid() throws {
        let (first, firstTxid) = try tokenTransaction(amount: 5)
        let (second, secondTxid) = try tokenTransaction(amount: 6)
        let atomic = try AtomicBEEF(
            subjectTransactionID: TransactionID(displayHex: firstTxid), beef: graph([first]),
            limits: harnessBEEFLimits
        ).serialized(limits: harnessBEEFLimits)
        let fromAtomic = try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: atomic, outputIndex: 0)]), queried: ["\(firstTxid).0"]
        )
        XCTAssertEqual(fromAtomic["\(firstTxid).0"]?.satoshis, 1)

        let both = try graph([first, second]).serialized(limits: harnessBEEFLimits)
        let named = try ColorOverlay.readOutputList(ColorOutputList(outputs: [
            .init(beef: both, outputIndex: 0, transactionID: TransactionID(displayHex: firstTxid)),
        ]), queried: ["\(firstTxid).0"])
        XCTAssertNotNil(named["\(firstTxid).0"])
        // Unnamed, the answer is the BEEF's last transaction, as before.
        XCTAssertNotNil(try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: both, outputIndex: 0)]), queried: ["\(secondTxid).0"]
        )["\(secondTxid).0"])
        // A txid the BEEF does not hold invalidates the answer.
        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [
            .init(beef: graph([second]).serialized(limits: harnessBEEFLimits), outputIndex: 0,
                  transactionID: TransactionID(displayHex: firstTxid)),
        ]), queried: ["\(firstTxid).0"]))
    }

    /// Swift is stricter than TS `#fromAnyBeef` (`txid ?? atomicTxid ?? last`): a named txid that
    /// disagrees with an Atomic BEEF's subject invalidates the answer, even when the BEEF holds the
    /// named transaction.
    func test_readOutputListRefusesANamedTxidOtherThanTheAtomicSubject() throws {
        let (first, firstTxid) = try tokenTransaction(amount: 5)
        // The subject spends `first`, so the Atomic BEEF holds both.
        let second = Transaction(version: 1, inputs: [TransactionInput(
            previousOutput: Outpoint(transactionID: try TransactionID(displayHex: firstTxid), outputIndex: 0),
            unlockingScript: try Script(bytes: [0x51], maximumByteCount: 10)
        )], outputs: first.outputs, lockTime: 0)
        let secondTxid = try second.transactionID(limits: harnessTxLimits).displayHex
        let atomic = try AtomicBEEF(
            subjectTransactionID: TransactionID(displayHex: secondTxid), beef: graph([first, second]),
            limits: harnessBEEFLimits
        ).serialized(limits: harnessBEEFLimits)
        XCTAssertNotNil(try ColorOverlay.readOutputList(ColorOutputList(outputs: [
            .init(beef: atomic, outputIndex: 0, transactionID: TransactionID(displayHex: secondTxid)),
        ]), queried: ["\(secondTxid).0"])["\(secondTxid).0"])
        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [
            .init(beef: atomic, outputIndex: 0, transactionID: TransactionID(displayHex: firstTxid)),
        ]), queried: ["\(firstTxid).0"])) { error in
            XCTAssertEqual(error as? ColorError, .overlay("overlay answer carries invalid BEEF"))
        }
    }

    // MARK: - Source listing counts

    private func listingContext(_ pages: @escaping ScriptedListStorage.Pages) throws -> (OneColorContext, ScriptedListStorage, [ColorManagedInput]) {
        let (transaction, txid) = try tokenTransaction(amount: 5)
        let storage = ScriptedListStorage(inner: try MockWallet(identity: identity), pages: pages)
        let ctx = OneColorContext(
            identity: identity, storage: storage,
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)), maximumFee: 20_000
        )
        let input = ColorManagedInput(
            outpoint: "\(txid).0", lockingScript: transaction.outputs[0].lockingScript, satoshis: 1,
            assetID: try ColorAssetID(String(repeating: "ab", count: 32) + "_0"), role: .value, amount: 5,
            custody: try ColorCustody(
                asset: .issue, derivationPrefix: "cA==", derivationSuffix: "cw==",
                senderIdentityKey: Hex.encode(identity.publicKey.compressedBytes)
            ),
            suffixTag: "suffix"
        )
        return (ctx, storage, [input])
    }

    /// One unselected output per page, a fresh outpoint each call.
    private static func unselected(_ call: Int) throws -> WalletOutput {
        let hex = String(repeating: "0", count: 56) + String(format: "%08x", call)
        return try WalletOutput(
            satoshis: 1, spendable: true, outpoint: Outpoint(transactionID: TransactionID(displayHex: hex), outputIndex: 0)
        )
    }

    private func assertCustody(
        _ ctx: OneColorContext, _ selected: [ColorManagedInput], _ reason: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await ColorModule.sourceTransactions(ctx, basket: "basket", selected: selected)
            XCTFail("expected a custody failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ColorError, .custody(reason), file: file, line: line)
        }
    }

    /// A count of `UInt64.max` cannot be paged with a UInt32 offset: refused on the first page,
    /// before any offset arithmetic, rather than paged until the offset traps.
    func test_sourceTransactionsRefusesACountBeyondThePaginationRange() async throws {
        let (ctx, storage, selected) = try listingContext { _, call in
            guard call < 3 else { throw HarnessError("the listing kept paging a count of UInt64.max") }
            return try WalletListOutputsResult(totalOutputs: .max, outputs: [try Self.unselected(call)])
        }
        await assertCustody(ctx, selected, "the listing's output count exceeds its pagination range")
        let calls = await storage.requests.count
        XCTAssertEqual(calls, 1)
    }

    func test_sourceTransactionsRefusesACountThatChangesBetweenPages() async throws {
        let (ctx, storage, selected) = try listingContext { _, call in
            try WalletListOutputsResult(totalOutputs: call == 0 ? 3 : 4, outputs: [try Self.unselected(call)])
        }
        await assertCustody(ctx, selected, "the matching output count changed during listing")
        let requests = await storage.requests
        XCTAssertEqual(requests.map(\.pagination.effectiveOffset), [0, 1])
    }

    func test_sourceTransactionsRefusesAPageBeyondItsLimitOrTheRowsLeft() async throws {
        // Two rows for a limit of one.
        let (overLimit, _, selected) = try listingContext { _, call in
            try WalletListOutputsResult(totalOutputs: 5, outputs: [try Self.unselected(call), try Self.unselected(call + 100)])
        }
        await assertCustody(overLimit, selected, "the listing exceeded its bounds")
        // One row against a count of zero.
        let (overCount, _, _) = try listingContext { _, call in
            try WalletListOutputsResult(totalOutputs: 0, outputs: [try Self.unselected(call)])
        }
        await assertCustody(overCount, selected, "the listing exceeded its bounds")
    }

    func test_httpOverlaySubmitsBEEFWithTopicsAndReadsTheSteak() async throws {
        actor Seen { var request: URLRequest?; func set(_ r: URLRequest) { request = r } }
        let seen = Seen()
        let overlay = HTTPColorOverlay(
            baseURL: URL(string: "https://overlay.example.com/")!,
            lookup: { _, _, _ in ColorOutputList(outputs: []) },
            post: { request in
                await seen.set(request)
                return (200, Array(#"{"tm_color_x":{"outputsToAdmit":[0,2],"coinsToRetain":[1]},"tm_color":{"outputsToAdmit":[]}}"#.utf8))
            }
        )
        let steak = try await overlay.submit(topics: ["tm_color", "tm_color_x"], beef: [9, 9])
        XCTAssertEqual(steak["tm_color_x"], ColorAdmittance(outputsToAdmit: [0, 2], coinsToRetain: [1]))
        XCTAssertEqual(steak["tm_color"], ColorAdmittance(outputsToAdmit: []))
        let captured = await seen.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://overlay.example.com/submit")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Topics"), "tm_color,tm_color_x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBody, Data([9, 9]))

        let failing = HTTPColorOverlay(baseURL: URL(string: "https://o.example.com")!, lookup: { _, _, _ in ColorOutputList(outputs: []) },
                                       post: { _ in (500, []) })
        do {
            _ = try await failing.submit(topics: ["tm_color"], beef: [])
            XCTFail("expected a failure")
        } catch {}
        XCTAssertThrowsError(try HTTPColorOverlay.readSteak(Array("[]".utf8)))
    }
}

/// Storage whose `colorListOutputs` answers from a script, recording each request; every other
/// call goes to `inner`.
actor ScriptedListStorage: ColorWalletStorage {
    typealias Pages = @Sendable (_ request: WalletListOutputsRequest, _ call: Int) throws -> WalletListOutputsResult

    let inner: MockWallet
    let pages: Pages
    private(set) var requests: [WalletListOutputsRequest] = []

    init(inner: MockWallet, pages: @escaping Pages) {
        self.inner = inner
        self.pages = pages
    }

    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult {
        requests.append(request)
        return try pages(request, requests.count - 1)
    }

    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult {
        try await inner.colorCreateAction(auth, request)
    }

    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        try await inner.colorInternalizeAction(auth, request)
    }

    func supportsNoSendExpiry() async throws -> Bool { try await inner.supportsNoSendExpiry() }

    func prepareNoSendExpiry(_ auth: AuthID, _ target: WalletCreateActionRequest) async throws -> NoSendExpiryPrepared {
        try await inner.prepareNoSendExpiry(auth, target)
    }

    func activateNoSendExpiry(
        _ auth: AuthID, target: WalletCreateActionRequest, fundingReference: String, fundingTxid: String, anchorVout: UInt32
    ) async throws -> NoSendExpiryActivated {
        try await inner.activateNoSendExpiry(
            auth, target: target, fundingReference: fundingReference, fundingTxid: fundingTxid, anchorVout: anchorVout
        )
    }

    func armNoSendExpiry(_ auth: AuthID, _ arm: NoSendExpiryArm) async throws { try await inner.armNoSendExpiry(auth, arm) }

    func processAction(_ auth: AuthID, _ request: StorageProcessActionRequest) async throws -> StorageProcessActionResult {
        try await inner.processAction(auth, request)
    }

    func abortAction(_ auth: AuthID, _ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult {
        try await inner.abortAction(auth, request)
    }
}
