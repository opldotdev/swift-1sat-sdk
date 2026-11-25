import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

/// List, cancel and purchase submit their Atomic BEEF to the market overlay when the context has
/// one: a deliberate addition over TS. A failed submit keeps the action's txid and sets
/// `submitError`; with no market nothing is submitted.
final class ListingOverlaySubmitTests: XCTestCase {
    func test_aListingIsSubmittedOnceAsItsAtomicBEEF() async throws {
        let source = try ListingSource.p2pkh(keyID: "ordinal-key")
        let market = FakeMarket()
        let result = await Ordinals.list(
            try listContext(storage: try source.storage(), market: market),
            Ordinals.ListRequest(ordinal: source.output, price: 75_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNil(result.submitError)
        let submitted = await market.submitted
        XCTAssertEqual(submitted, [try XCTUnwrap(result.tx)])
        // The topic manager reads the transaction and the listings it spends from BEEF.
        let atomic = try AtomicBEEF(bytes: submitted[0], limits: WalletBEEFLimits.standard)
        XCTAssertEqual(atomic.subjectTransactionID.displayHex, result.txid)
    }

    func test_aFailedSubmitKeepsTheListing() async throws {
        let source = try ListingSource.p2pkh(keyID: "ordinal-key")
        let market = FakeMarket(error: Bsv21CreateFailure.down)
        let result = await Ordinals.list(
            try listContext(storage: try source.storage(), market: market),
            Ordinals.ListRequest(ordinal: source.output, price: 75_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertNotNil(result.tx)
        XCTAssertEqual(result.submitError, "down")
        let calls = await market.submitted.count
        XCTAssertEqual(calls, 1)
    }

    func test_noMarketNoSubmit() async throws {
        let source = try ListingSource.p2pkh(keyID: "ordinal-key")
        let result = await Ordinals.list(
            try listContext(storage: try source.storage()),
            Ordinals.ListRequest(ordinal: source.output, price: 75_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertNil(result.submitError)
    }

    func test_aFailedListingIsNotSubmitted() async throws {
        let market = FakeMarket()
        let result = await Ordinals.list(
            try listContext(storage: Bsv21CreateStorage(), market: market),
            Ordinals.ListRequest(ordinal: try ListingSource.p2pkh(keyID: "k").output, price: 0)
        )
        XCTAssertEqual(result.error, "invalid-price")
        XCTAssertNil(result.submitError)
        let calls = await market.submitted.count
        XCTAssertEqual(calls, 0)
    }

    func test_anOpnsListingIsSubmitted() async throws {
        let source = try ListingSource.p2pkh(
            keyID: "name-key", tags: ["type:application/op-ns", "name:alice", "id:aa_0"]
        )
        let market = FakeMarket()
        let result = await OpNS.list(
            try listContext(storage: try source.storage(), market: market),
            OpNS.ListRequest(ordinal: source.output, price: 9_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNil(result.submitError)
        let submitted = await market.submitted
        XCTAssertEqual(submitted, [try XCTUnwrap(result.tx)])
    }

    func test_cancellingAnOrdinalOrOpnsListingIsSubmitted() async throws {
        let ordinal = try ListingSource.listing(keyID: "listing-key")
        let market = FakeMarket()
        let cancelled = await Ordinals.cancelListing(
            try listContext(storage: try ordinal.storage(), market: market),
            Ordinals.CancelRequest(listing: ordinal.output, inputBEEF: ordinal.beef)
        )
        XCTAssertNil(cancelled.error, cancelled.error ?? "")
        XCTAssertNil(cancelled.submitError)
        try ordinal.assertUnlocks(try bsv21SubjectTransaction(try XCTUnwrap(cancelled.tx)))

        let name = try ListingSource.listing(
            keyID: "name-listing-key",
            tags: ["opns", "type:application/op-ns", "name:alice", "ordlock2", "price:50000", "id:aa_0"]
        )
        let opns = await OpNS.cancelListing(
            try listContext(storage: try name.storage(), market: market),
            OpNS.Request(ordinal: name.output, inputBEEF: name.beef)
        )
        XCTAssertNil(opns.error, opns.error ?? "")
        XCTAssertNil(opns.submitError)

        let submitted = await market.submitted
        XCTAssertEqual(submitted, [try XCTUnwrap(cancelled.tx), try XCTUnwrap(opns.tx)])
    }

    func test_aCancelWhoseSubmitFailsKeepsItsTxid() async throws {
        let ordinal = try ListingSource.listing(keyID: "listing-key")
        let result = await Ordinals.cancelListing(
            try listContext(storage: try ordinal.storage(), market: FakeMarket(error: Bsv21CreateFailure.down)),
            Ordinals.CancelRequest(listing: ordinal.output, inputBEEF: ordinal.beef)
        )
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertEqual(result.submitError, "down")
    }

    func test_aPurchaseIsSubmitted() async throws {
        let listing = try ListingSource.listing(keyID: "seller-key")
        // One held `ordlock-funding` deposit covers the payout, as a front funding.
        let fundingKeyID = "ordlock-funding held"
        let funding = try OrdLockV2Purchase.fundingKey(try listContext(storage: Bsv21CreateStorage()), keyID: fundingKeyID)
        let fundingTx = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 60_000, lockingScript: funding.lockingScript)],
            lockTime: 3
        )
        let fundingOutpoint = "\(try fundingTx.transactionID(limits: WalletTransactionLimits.standard).displayHex).0"
        let holdUntil = OneSatConstants.nowMilliseconds() + 600_000
        let storage = try Bsv21CreateStorage.make(
            rows: [[
                "outpoint": fundingOutpoint,
                "satoshis": 60_000,
                "spendable": true,
                "customInstructions": try funding.instructions.encoded(includeSelfCounterparty: true),
                "tags": [
                    OneSatConstants.ordlockFundingTag,
                    OneSatConstants.depositHoldTag(untilMilliseconds: holdUntil),
                ],
            ]],
            listBEEF: try BEEF(merklePaths: [], transactions: [.raw(fundingTx)], limits: WalletBEEFLimits.standard)
                .serialized(limits: WalletBEEFLimits.standard),
            sources: [
                fundingOutpoint: .init(lockingScript: funding.lockingScript.hex, satoshis: 60_000),
                listing.outpoint: .init(lockingScript: listing.transaction.outputs[0].lockingScript.hex, satoshis: 1),
            ]
        )
        let market = FakeMarket()
        let result = await Ordinals.purchase(
            try listContext(storage: storage, market: market, listings: StaticListingBeef(bytes: listing.beef)),
            Ordinals.PurchaseRequest(outpoint: try Outpoint(listing.outpoint))
        )
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNil(result.submitError)
        let submitted = await market.submitted
        XCTAssertEqual(submitted, [try XCTUnwrap(result.tx)])
    }

    func test_anActionWithoutATransactionReportsIt() async throws {
        let market = FakeMarket()
        let ctx = try listContext(storage: Bsv21CreateStorage(), market: market)
        let result = await OverlaySubmit.market(ctx, ActionResult(txid: "ab"))
        XCTAssertEqual(result.txid, "ab")
        XCTAssertEqual(result.submitError, "no transaction to submit")
        let calls = await market.submitted.count
        XCTAssertEqual(calls, 0)
    }
}

actor FakeMarket: MarketActionServices {
    private(set) var submitted: [[UInt8]] = []
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    func submitListing(tx: [UInt8]) async throws {
        submitted.append(tx)
        if let error { throw error }
    }
}

struct StaticListingBeef: ListingBeefSource {
    let bytes: [UInt8]

    func beef(forTxid _: String) async throws -> [UInt8] { bytes }
}
