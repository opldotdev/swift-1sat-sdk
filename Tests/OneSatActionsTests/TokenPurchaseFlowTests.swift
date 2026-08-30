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

/// Offline `Tokens.purchase` path: overlay validate → listing BEEF → createAction capture.
final class TokenPurchaseFlowTests: XCTestCase {
    func test_purchaseRequiresBsv21AndListingServices() async throws {
        let identity = try ActionVectors.identity()
        let transport = CapturingTransport()
        let listings = RecordingListingSource(bytes: [0x00])
        let bsv21 = StubBsv21(details: Self.activeDetails)

        let missingBsv21 = try dummyContext(
            identity: identity,
            transport: transport,
            bsv21: nil,
            listings: listings
        )
        let missingBsv21Result = await Tokens.purchase(
            missingBsv21,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: try Outpoint(ActionVectors.outpoint),
                amount: 500
            )
        )
        XCTAssertEqual(
            missingBsv21Result.error,
            OneSatActionError.servicesRequiredForPurchase.wireMessage
        )
        XCTAssertNil(missingBsv21Result.txid)
        let missingBsv21Bodies = await transport.bodies
        let missingBsv21ListingCalls = await listings.calls
        let missingBsv21ValidateCalls = await bsv21.validateCalls
        XCTAssertEqual(missingBsv21Bodies.count, 0)
        XCTAssertEqual(missingBsv21ListingCalls, [])
        XCTAssertEqual(missingBsv21ValidateCalls.count, 0)

        let missingListings = try dummyContext(
            identity: identity,
            transport: transport,
            bsv21: bsv21,
            listings: nil
        )
        let missingListingsResult = await Tokens.purchase(
            missingListings,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: try Outpoint(ActionVectors.outpoint),
                amount: 500
            )
        )
        XCTAssertEqual(
            missingListingsResult.error,
            OneSatActionError.servicesRequiredForPurchase.wireMessage
        )
        XCTAssertNil(missingListingsResult.txid)
        let missingListingsBodies = await transport.bodies
        let missingListingsValidateCalls = await bsv21.validateCalls
        let missingListingsTokenDetailsCalls = await bsv21.tokenDetailsCalls
        XCTAssertEqual(missingListingsBodies.count, 0)
        XCTAssertEqual(missingListingsValidateCalls.count, 0)
        XCTAssertEqual(missingListingsTokenDetailsCalls, 0)
    }

    func test_purchaseFailsWhenOverlayDoesNotKnowTheOutpoint() async throws {
        let fixture = try listingFixture()
        let bsv21 = StubBsv21(details: Self.activeDetails, validateError: StubError.overlayMissing)
        let listings = RecordingListingSource(bytes: fixture.beefBytes)
        let transport = CapturingTransport()
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            transport: transport,
            bsv21: bsv21,
            listings: listings
        )
        let result = await Tokens.purchase(
            ctx,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: fixture.outpoint,
                amount: 500
            )
        )
        XCTAssertEqual(result.error, OneSatActionError.listingNotFoundInOverlay.wireMessage)
        XCTAssertNil(result.txid)
        let validateCalls = await bsv21.validateCalls
        let tokenDetailsCalls = await bsv21.tokenDetailsCalls
        let listingCalls = await listings.calls
        let bodies = await transport.bodies
        XCTAssertEqual(validateCalls.count, 1)
        XCTAssertEqual(validateCalls[0].tokenId, ActionVectors.tokenID)
        XCTAssertEqual(validateCalls[0].outpoint, fixture.outpoint.ordinalDescription)
        XCTAssertEqual(tokenDetailsCalls, 0)
        XCTAssertEqual(listingCalls, [])
        XCTAssertEqual(bodies.count, 0)
    }

    func test_purchaseFailsWhenListingTransactionIsMissing() async throws {
        let fixture = try listingFixture()
        let bsv21 = StubBsv21(details: Self.activeDetails)
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            bsv21: bsv21,
            listings: RecordingListingSource(bytes: fixture.beefBytes)
        )
        let result = await Tokens.purchase(
            ctx,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: try Outpoint(ActionVectors.outpoint),
                amount: 500
            )
        )
        XCTAssertEqual(result.error, OneSatActionError.listingTransactionNotFound.wireMessage)
        XCTAssertNil(result.txid)
        let tokenDetailsCalls = await bsv21.tokenDetailsCalls
        XCTAssertEqual(tokenDetailsCalls, 1)
    }

    func test_purchaseFailsWhenListingOutputIsMissing() async throws {
        let fixture = try listingFixture()
        let ctx = try dummyContext(
            identity: try ActionVectors.identity(),
            bsv21: StubBsv21(details: Self.activeDetails),
            listings: RecordingListingSource(bytes: fixture.beefBytes)
        )
        let result = await Tokens.purchase(
            ctx,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: try Outpoint("\(fixture.txid).1"),
                amount: 500
            )
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
            bsv21: StubBsv21(details: Self.activeDetails),
            listings: RecordingListingSource(bytes: fixture.beefBytes)
        )
        let result = await Tokens.purchase(
            ctx,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: fixture.outpoint,
                amount: 500
            )
        )
        XCTAssertEqual(result.error, OneSatActionError.notAnOrdLockListing.wireMessage)
        XCTAssertNil(result.txid)
    }

    func test_purchaseSendsListingBEEFAnd1402OnCreateAction() async throws {
        let envelope = try await capturedPurchaseEnvelope(
            details: Self.activeDetails,
            marketplaceAddress: ActionVectors.templateAddress,
            marketplaceRate: 0.02
        )
        XCTAssertEqual(envelope.wireBeef, envelope.fixture.beefBytes)
        XCTAssertEqual(envelope.inputs.count, 1)
        XCTAssertEqual(envelope.inputs[0]["outpoint"] as? String, envelope.fixture.outpoint.description)
        XCTAssertEqual(
            (envelope.inputs[0]["unlockingScriptLength"] as? NSNumber)?.uint32Value,
            Tokens.purchaseUnlockingScriptLength
        )
        XCTAssertEqual(Tokens.purchaseUnlockingScriptLength, 1_402)

        XCTAssertEqual(envelope.outputs.count, 4)
        XCTAssertEqual((envelope.outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(envelope.outputs[0]["outputDescription"] as? String, "Purchased tokens")
        XCTAssertEqual(envelope.outputs[0]["basket"] as? String, OneSatConstants.bsv21Basket)
        XCTAssertEqual(envelope.outputs[0]["lockingScript"] as? String, envelope.expectedTransfer.hex)
        XCTAssertEqual(envelope.outputs[0]["customInstructions"] as? String, envelope.expectedInstructions)

        let tags = try XCTUnwrap(envelope.outputs[0]["tags"] as? [String])
        XCTAssertTrue(tags.contains("bsv21:\(ActionVectors.tokenID)"))
        XCTAssertFalse(tags.contains { $0.hasPrefix("amt:") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("sym:") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("dec:") })
        XCTAssertFalse(tags.contains { $0.hasPrefix("icon:") })
        XCTAssertEqual(tags.filter { $0.hasPrefix("id:") }.count, 1)
        let ci = Bsv21Remittance.parseCustomInstructions(
            envelope.outputs[0]["customInstructions"] as? String
        )
        XCTAssertEqual(ci.fields?.amt, "500")
        XCTAssertEqual(ci.fields?.symbol, "GOLD")
        XCTAssertEqual(ci.fields?.decimals, "2")
        XCTAssertEqual(ci.fields?.icon, "icon_1")

        XCTAssertEqual((envelope.outputs[1]["satoshis"] as? NSNumber)?.uint64Value, envelope.payout.satoshis)
        XCTAssertEqual(envelope.outputs[1]["lockingScript"] as? String, envelope.payout.script.hex)
        XCTAssertEqual(envelope.outputs[1]["outputDescription"] as? String, "Payment to seller")
        XCTAssertNil(envelope.outputs[1]["basket"])

        XCTAssertEqual((envelope.outputs[2]["satoshis"] as? NSNumber)?.uint64Value, 1_000)
        XCTAssertEqual(envelope.outputs[2]["outputDescription"] as? String, "Marketplace fee")
        XCTAssertEqual(
            envelope.outputs[2]["lockingScript"] as? String,
            try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress).hex
        )

        XCTAssertEqual((envelope.outputs[3]["satoshis"] as? NSNumber)?.uint64Value, 1_000)
        XCTAssertEqual(envelope.outputs[3]["outputDescription"] as? String, "Overlay processing fee")
        XCTAssertEqual(
            envelope.outputs[3]["lockingScript"] as? String,
            try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress).hex
        )

        let labels = try XCTUnwrap(envelope.args["labels"] as? [String])
        XCTAssertTrue(labels.contains(OneSatConstants.tokenLabel(ActionVectors.tokenID)))
        XCTAssertEqual(
            envelope.args["description"] as? String,
            "Purchase 500 tokens for \(envelope.payout.satoshis) sats"
        )
    }

    func test_purchaseOmitsOverlayFeeWhenTokenIsInactive() async throws {
        let envelope = try await capturedPurchaseEnvelope(details: Self.inactiveDetails)
        XCTAssertEqual(envelope.wireBeef, envelope.fixture.beefBytes)
        XCTAssertEqual(
            (envelope.inputs[0]["unlockingScriptLength"] as? NSNumber)?.uint32Value,
            1_402
        )
        XCTAssertEqual(envelope.outputs.count, 2)
        XCTAssertEqual(envelope.outputs[0]["outputDescription"] as? String, "Purchased tokens")
        XCTAssertEqual(envelope.outputs[1]["outputDescription"] as? String, "Payment to seller")
        XCTAssertFalse(
            envelope.outputs.contains { $0["outputDescription"] as? String == "Overlay processing fee" }
        )
        XCTAssertFalse(
            envelope.outputs.contains { $0["outputDescription"] as? String == "Marketplace fee" }
        )
    }

    func test_ordLockPurchaseMatchesHandAssembledThreeOutputUnlock() throws {
        let limits = WalletTransactionLimits.standard
        let identity = try ActionVectors.identity()
        let cancel = try Ordinals.cancelAddress(
            identity: identity,
            outpoint: ActionVectors.outpoint
        )
        let locking = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: ActionVectors.payAddress,
            price: 50_000
        )
        let outputs = [
            TransactionOutput(
                satoshis: 1,
                lockingScript: try ActionScript.payToPublicKeyHash(
                    Address(publicKey: identity.publicKey, network: .mainnet)
                )
            ),
            TransactionOutput(
                satoshis: 50_000,
                lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.payAddress)
            ),
            TransactionOutput(
                satoshis: 1_000,
                lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
            ),
        ]
        let empty = try Script(bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount))
        let transaction = Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: Outpoint(
                        transactionID: try TransactionID(displayHex: String(repeating: "11", count: 32)),
                        outputIndex: 0
                    ),
                    unlockingScript: empty,
                    sequence: 0xffff_ffff,
                    sourceOutput: TransactionOutput(satoshis: 1, lockingScript: locking)
                ),
            ],
            outputs: outputs,
            lockTime: 0
        )

        var expected = try Script(bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount))
        try expected.appendPushData(
            OrdLock.buildOutput(satoshis: outputs[0].satoshis, script: outputs[0].lockingScript),
            maximumScriptByteCount: Int(limits.maximumScriptByteCount)
        )
        try expected.appendPushData(
            OrdLock.buildOutput(satoshis: outputs[2].satoshis, script: outputs[2].lockingScript),
            maximumScriptByteCount: Int(limits.maximumScriptByteCount)
        )
        try expected.appendPushData(
            try transaction.forkIDSignaturePreimage(
                inputIndex: 0,
                hashType: ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true),
                limits: limits
            ),
            maximumScriptByteCount: Int(limits.maximumScriptByteCount)
        )
        try expected.append(Opcode.zero, maximumScriptByteCount: Int(limits.maximumScriptByteCount))

        XCTAssertEqual(
            try UnlockScripts.ordLockPurchase(transaction: transaction, inputIndex: 0).bytes,
            expected.bytes
        )
    }

    private static let activeDetails = Bsv21TokenDetails(
        isActive: true,
        feeAddress: ActionVectors.templateAddress,
        feePerOutput: 1_000,
        decimals: 2,
        symbol: "GOLD",
        icon: "icon_1"
    )

    private static let inactiveDetails = Bsv21TokenDetails(
        isActive: false,
        feeAddress: ActionVectors.templateAddress,
        feePerOutput: 1_000,
        decimals: 2,
        symbol: "GOLD",
        icon: "icon_1"
    )

    private struct ListingFixture {
        let txid: String
        let outpoint: Outpoint
        let beefBytes: [UInt8]
        let listingScript: Script
    }

    private struct CapturedEnvelope {
        let fixture: ListingFixture
        let args: [String: Any]
        let inputs: [[String: Any]]
        let outputs: [[String: Any]]
        let wireBeef: [UInt8]
        let expectedTransfer: Script
        let expectedInstructions: String
        let payout: (satoshis: UInt64, script: Script)
    }

    private func capturedPurchaseEnvelope(
        details: Bsv21TokenDetails,
        marketplaceAddress: String? = nil,
        marketplaceRate: Double? = nil
    ) async throws -> CapturedEnvelope {
        let fixture = try listingFixture()
        let transport = CapturingTransport()
        let identity = try ActionVectors.identity()
        let bsv21 = StubBsv21(details: details)
        let ctx = OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            bsv21: bsv21,
            listings: RecordingListingSource(bytes: fixture.beefBytes)
        )
        let result = await Tokens.purchase(
            ctx,
            Tokens.PurchaseRequest(
                tokenId: ActionVectors.tokenID,
                outpoint: fixture.outpoint,
                amount: 500,
                marketplaceAddress: marketplaceAddress,
                marketplaceRate: marketplaceRate
            )
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)
        XCTAssertNil(result.tx)
        let submitCalls = await bsv21.submitCalls
        XCTAssertEqual(submitCalls, 0)

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
        let inputs = try XCTUnwrap(args["inputs"] as? [[String: Any]])
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])

        let keyID = "\(ActionVectors.tokenID)-\(fixture.outpoint.description)"
        let buyer = try P1SATKey.address(
            identity: identity,
            keyID: keyID,
            counterparty: .self,
            forSelf: true,
            network: .mainnet
        )
        let expectedTransfer = try Tokens.transferScript(
            tokenId: ActionVectors.tokenID,
            amount: 500,
            recipient: ActionScript.payToPublicKeyHash(buyer)
        )
        let expectedInstructions = Bsv21Remittance.buildCustomInstructions(
            token: Bsv21Remittance.Fields(
                id: ActionVectors.tokenID,
                amt: "500",
                op: "transfer",
                symbol: details.symbol,
                decimals: String(details.decimals),
                icon: details.icon
            ),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: keyID,
            counterparty: "self"
        )
        let decoded = try XCTUnwrap(OrdLock.decode(fixture.listingScript))
        let payout = try Ordinals.payoutOutput(decoded.payout)
        return CapturedEnvelope(
            fixture: fixture,
            args: args,
            inputs: inputs,
            outputs: outputs,
            wireBeef: wireBeef,
            expectedTransfer: expectedTransfer,
            expectedInstructions: expectedInstructions,
            payout: payout
        )
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
        transport: CapturingTransport = CapturingTransport(),
        bsv21: (any Bsv21ActionServices)?,
        listings: (any ListingBeefSource)?
    ) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            bsv21: bsv21,
            listings: listings
        )
    }
}

private actor StubBsv21: Bsv21ActionServices {
    struct Call: Equatable, Sendable {
        let tokenId: String
        let outpoint: String
    }

    let details: Bsv21TokenDetails
    let validateError: Error?
    private(set) var tokenDetailsCalls = 0
    private(set) var submitCalls = 0
    private(set) var validateCalls: [Call] = []

    init(details: Bsv21TokenDetails, validateError: Error? = nil) {
        self.details = details
        self.validateError = validateError
    }

    func tokenDetails(tokenId _: String) async throws -> Bsv21TokenDetails {
        tokenDetailsCalls += 1
        return details
    }

    func validateUnspentOutputs(tokenId _: String, outpoints _: [String]) async throws -> Set<String> {
        throw StubError.unimplemented
    }

    func validateOutput(tokenId: String, outpoint: String) async throws {
        validateCalls.append(Call(tokenId: tokenId, outpoint: outpoint))
        if let validateError { throw validateError }
    }

    func submitTransfer(tx _: [UInt8], tokenId _: String) async throws {
        submitCalls += 1
    }
}

private actor RecordingListingSource: ListingBeefSource {
    let bytes: [UInt8]
    private(set) var calls: [String] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func beef(forTxid txid: String) async throws -> [UInt8] {
        calls.append(txid)
        return bytes
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

private enum StubError: Error {
    case overlayMissing
    case unimplemented
}
