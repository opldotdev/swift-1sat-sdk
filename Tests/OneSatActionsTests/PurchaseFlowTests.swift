import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// Offline `Ordinals.purchase` path: recorded listing BEEF → parse → find → build → createAction.
final class PurchaseFlowTests: XCTestCase {
    func test_purchaseRequiresListingServices() async throws {
        let ctx = try dummyContext(identity: try ActionVectors.identity(), listings: nil)
        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: try Outpoint(ActionVectors.outpoint))
        )
        XCTAssertEqual(result.error, OneSatActionError.servicesRequiredForPurchase.wireMessage)
        XCTAssertNil(result.txid)
    }

    func test_purchaseFailsWhenListingTransactionIsMissing() async throws {
        let fixture = try listingFixture()
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            listings: RecordedListingSource(bytes: fixture.beefBytes)
        )
        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: try Outpoint(ActionVectors.outpoint))
        )
        XCTAssertEqual(result.error, OneSatActionError.listingTransactionNotFound.wireMessage)
        XCTAssertNil(result.txid)
    }

    func test_purchaseFailsWhenListingOutputIsMissing() async throws {
        let fixture = try listingFixture()
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            listings: RecordedListingSource(bytes: fixture.beefBytes)
        )
        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: try Outpoint("\(fixture.txid).1"))
        )
        XCTAssertEqual(result.error, OneSatActionError.listingOutputNotFound.wireMessage)
        XCTAssertNil(result.txid)
    }

    func test_purchaseFailsWhenOutputIsNotAnOrdLock() async throws {
        let fixture = try listingFixture(
            script: try Script(bytes: [0x51], maximumByteCount: 10_000)
        )
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            listings: RecordedListingSource(bytes: fixture.beefBytes)
        )
        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: fixture.outpoint)
        )
        XCTAssertEqual(result.error, OneSatActionError.notAnOrdLockListing.wireMessage)
        XCTAssertNil(result.txid)
    }

    func test_purchaseSendsTheListingBEEFOnCreateAction() async throws {
        let fixture = try listingFixture()
        let transport = CapturingTransport()
        let identity = try ActionVectors.identity()
        let ctx = OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            listings: RecordedListingSource(bytes: fixture.beefBytes)
        )

        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: fixture.outpoint)
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)

        let parsed = try BEEF(bytes: fixture.beefBytes, limits: WalletBEEFLimits.standard)
        let prepared = try Ordinals.buildPurchase(
            ctx,
            outpoint: fixture.outpoint,
            listingScript: fixture.listingScript,
            listingSatoshis: 1
        )
        let createRequest = try TrackedAction.request(
            description: prepared.description,
            inputBEEF: parsed,
            inputs: prepared.inputs,
            outputs: prepared.outputs,
            labels: prepared.labels,
            actionID: "deadbeef",
            options: TrackedAction.Options(randomizeOutputs: false)
        )
        XCTAssertEqual(
            try createRequest.inputBEEF?.serialized(limits: WalletBEEFLimits.standard),
            fixture.beefBytes
        )

        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 1)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bodies[0])) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        let args = try XCTUnwrap(params[1] as? [String: Any])
        let wireBeef = try XCTUnwrap(args["inputBEEF"] as? [NSNumber]).map { UInt8(truncating: $0) }
        XCTAssertEqual(wireBeef, fixture.beefBytes)
        let inputs = try XCTUnwrap(args["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0]["outpoint"] as? String, fixture.outpoint.description)
        XCTAssertEqual(
            (inputs[0]["unlockingScriptLength"] as? NSNumber)?.uint32Value,
            OneSatConstants.purchaseUnlockingScriptLength
        )

        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(outputs[0]["outputDescription"] as? String, "Purchased ordinal")
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.ordinalsBasket)

        let decoded = try XCTUnwrap(OrdLock.decode(fixture.listingScript))
        let payout = try Ordinals.payoutOutput(decoded.payout)
        XCTAssertEqual((outputs[1]["satoshis"] as? NSNumber)?.uint64Value, payout.satoshis)
        XCTAssertEqual(outputs[1]["lockingScript"] as? String, payout.script.hex)
        XCTAssertEqual(outputs[1]["outputDescription"] as? String, "Payment to seller")
        XCTAssertNil(outputs[1]["basket"])
    }

    private struct ListingFixture {
        let txid: String
        let outpoint: Outpoint
        let beefBytes: [UInt8]
        let listingScript: Script
    }

    private func listingFixture(script: Script? = nil) throws -> ListingFixture {
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let listing = try script ?? OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let listingTx = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(satoshis: 1, lockingScript: listing),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(listingTx)],
            limits: WalletBEEFLimits.standard
        )
        let txid = try listingTx
            .transactionID(limits: WalletBEEFLimits.standard.transactionLimits)
            .displayHex
        return ListingFixture(
            txid: txid,
            outpoint: try Outpoint("\(txid).0"),
            beefBytes: try beef.serialized(limits: WalletBEEFLimits.standard),
            listingScript: listing
        )
    }

    private func dummyContext(
        identity: PrivateKey,
        listings: (any ListingBeefSource)?
    ) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: RejectTransport()
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            listings: listings
        )
    }
}

private struct RecordedListingSource: ListingBeefSource {
    let bytes: [UInt8]

    func beef(forTxid _: String) async throws -> [UInt8] {
        bytes
    }
}

private struct RejectTransport: AuthenticatedTransport {
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

private actor CapturingTransport: AuthenticatedTransport {
    private(set) var bodies: [[UInt8]] = []

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        bodies.append(body ?? [])
        throw AuthTransportError.notImplemented("offline")
    }
}
