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

/// Offline `Ordinals.purchase` path: recorded listing BEEF → parse → find → build →
/// held front funding (listOutputs, prep createAction) → OrdLock v2 layout.
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

    /// With no held deposit funding, the purchase first lists `1sat-deposit`, then
    /// prepares a held front funding output for exactly the payout (TS
    /// `applyOrdLockV2Purchase`). The offline transport fails that prep action.
    func test_purchasePreparesHeldFrontFundingWhenNoneIsHeld() async throws {
        let fixture = try listingFixture()
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
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
        // TS lets the prep createAction error through unchanged, not a generic message.
        let error = try XCTUnwrap(result.error)
        XCTAssertNotEqual(error, OneSatActionError.ordLockV2FrontFundingFailed(nil).wireMessage)
        XCTAssertNil(result.txid)

        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction"])
        let bodies = await transport.bodies
        let listArgs = try rpcArgs(bodies[0])
        XCTAssertEqual(listArgs["basket"] as? String, OneSatConstants.depositBasket)
        XCTAssertEqual(listArgs["includeTags"] as? Bool, true)

        let prepArgs = try rpcArgs(bodies[1])
        XCTAssertEqual((prepArgs["inputs"] as? [Any])?.count, 0)
        let options = try XCTUnwrap(prepArgs["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, false)
        let outputs = try XCTUnwrap(prepArgs["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 50_000)
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.depositBasket)
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertTrue(tags.contains(OneSatConstants.ordlockFundingTag))
        XCTAssertTrue(OneSatConstants.isDepositHeld(tags, nowMilliseconds: OneSatConstants.nowMilliseconds()))
        XCTAssertFalse(tags.contains { $0.hasPrefix("id:") }, "TS prep is a plain createAction, no id: tag")
        let instructions = try CustomInstructions.parse(
            try XCTUnwrap(outputs[0]["customInstructions"] as? String)
        )
        XCTAssertTrue(instructions.keyID.hasPrefix("\(OneSatConstants.ordlockFundingKeyPrefix) "))
    }

    /// `/1sat/beef` answers Atomic BEEF; the purchase reads the listing through it and carries on
    /// to the funding step exactly as with plain BEEF.
    func test_purchaseReadsAnAtomicListingResponse() async throws {
        let fixture = try listingFixture()
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let atomic = try OneSatTestBEEF.atomicEnvelope(
            plain: fixture.beefBytes,
            subject: fixture.outpoint.transactionID
        )
        XCTAssertThrowsError(try BEEF(bytes: atomic, limits: WalletBEEFLimits.standard))
        let ctx = OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            listings: RecordedListingSource(bytes: atomic)
        )

        let result = await Ordinals.purchase(
            ctx,
            Ordinals.PurchaseRequest(outpoint: fixture.outpoint)
        )
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction"])
    }

    /// The purchase action itself: front funding then the listing; cushion, payout
    /// at the listing's input index, the basketed receive, then fees.
    func test_purchaseLayoutPutsThePayoutAtTheListingIndex() throws {
        let fixture = try listingFixture()
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity, listings: nil)
        let prepared = try Ordinals.buildPurchase(
            ctx,
            outpoint: fixture.outpoint,
            listingScript: fixture.listingScript,
            listingSatoshis: 1,
            marketplaceAddress: ActionVectors.templateAddress,
            marketplaceRate: 0.02
        )
        let instructions = try CustomInstructions(keyID: "ordlock-funding test")
        let front = OrdLockV2Purchase.FundingCandidate(
            outpoint: try Outpoint(String(repeating: "ab", count: 32) + ".0"),
            satoshis: 60_000,
            instructions: instructions
        )
        let cushion = try WalletCreateActionOutput(
            lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress).bytes,
            satoshis: 0,
            outputDescription: "OrdLock funding cushion",
            basket: OneSatConstants.depositBasket,
            customInstructions: instructions.encoded(includeSelfCounterparty: true),
            tags: [OneSatConstants.ordlockFundingTag]
        )
        let layout = try OrdLockV2Purchase.layout(
            listingOutpoint: fixture.outpoint,
            listingScript: fixture.listingScript,
            listingInputDescription: "Listed ordinal",
            receive: prepared.outputs[0],
            extras: Array(prepared.outputs.dropFirst(2)),
            front: [front],
            cushion: cushion
        )
        XCTAssertEqual(layout.inputs.map(\.outpoint), [front.outpoint, fixture.outpoint])
        XCTAssertEqual(layout.listingInputIndex, 1)
        XCTAssertEqual(layout.inputs[0].unlocking, .scriptLength(OneSatConstants.p2pkhUnlockingScriptLength))
        XCTAssertEqual(
            layout.inputs[1].unlocking,
            .scriptLength(UInt32(try OrdLockV2.estimatePurchaseUnlockLength(fixture.listingScript)))
        )
        XCTAssertEqual(layout.outputs.map(\.satoshis), [10_000, 50_000, 1, 1_000])
        XCTAssertEqual(layout.outputs[0].basket, OneSatConstants.depositBasket)
        let payout = try OrdLockV2.payoutOutput(fixture.listingScript)
        XCTAssertEqual(layout.outputs[1].lockingScript, payout.script.bytes)
        XCTAssertEqual(layout.outputs[1].outputDescription, "Payment to seller")
        XCTAssertEqual(layout.outputs[2], prepared.outputs[0])
        XCTAssertEqual(layout.outputs[3].outputDescription, "Marketplace fee")
        XCTAssertEqual(layout.receiveVout, 2)
    }

    private func rpcArgs(_ body: [UInt8]) throws -> [String: Any] {
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
        )
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        return try XCTUnwrap(params[1] as? [String: Any])
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
        let listing = try script ?? OrdLockV2.lock(
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

private actor ScriptedTransport: AuthenticatedTransport {
    private(set) var methods: [String] = []
    private(set) var bodies: [[UInt8]] = []
    private let listResult: [String: Any]

    init(listResult: [String: Any]) {
        self.listResult = listResult
    }

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let rpcMethod = object?["method"] as? String ?? ""
        methods.append(rpcMethod)
        bodies.append(body ?? [])
        if rpcMethod == "listOutputs" {
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": object?["id"] as Any,
                "result": listResult,
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
        }
        throw AuthTransportError.notImplemented("offline")
    }
}
