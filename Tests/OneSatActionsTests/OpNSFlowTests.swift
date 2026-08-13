import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxAuth
import ToolboxServices
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class OpNSFlowTests: XCTestCase {
    /// `Hex.encode(ActionVectors.identity().publicKey.compressedBytes)`.
    private static let identityPubKeyHex =
        "02bd1e9f9470dad82f75c4ffd03ffe9a5ddc2c5a718084727c027b17e9b7cfd8a5"

    /// `P1SATKey.address(identity:, keyID: ActionVectors.outpoint, counterparty: .self, forSelf: false)`.
    private static let selfAddress = "1FRgL8WGTQ7rd81M5Cj4t6d6HJPverhUVP"

    func test_toSelfBuilderBasketsOpNSAndWritesIdKey() throws {
        let identity = try ActionVectors.identity()
        XCTAssertEqual(Hex.encode(identity.publicKey.compressedBytes), Self.identityPubKeyHex)
        let selfAddr = try P1SATKey.address(
            identity: identity,
            keyID: ActionVectors.outpoint,
            counterparty: .self,
            forSelf: false
        )
        XCTAssertEqual(selfAddr.description, Self.selfAddress)

        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: [
                "type:application/op-ns",
                "origin:\(ActionVectors.outpoint)",
                "name:alice",
                "id:aa_0",
                "opns:published",
            ]
        )
        let prepared = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [
                    Ordinals.TransferItem(
                        ordinal: ordinal,
                        toSelf: true,
                        map: [("opns.idKey", Self.identityPubKeyHex)],
                        extraTags: ["opns:published"]
                    ),
                ]
            )
        )
        XCTAssertEqual(prepared.outputs.count, 1)
        XCTAssertEqual(prepared.outputs[0].satoshis, 1)
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.opnsBasket)
        XCTAssertEqual(
            prepared.outputs[0].tags,
            [
                "type:application/op-ns",
                "origin:\(ActionVectors.outpoint)",
                "name:alice",
                "opns:published",
            ]
        )
        let instructions = try CustomInstructions.parse(
            try XCTUnwrap(prepared.outputs[0].customInstructions)
        )
        XCTAssertEqual(instructions.keyID, ActionVectors.outpoint)
        XCTAssertEqual(instructions.counterparty, .self)
        let expected = try MapSuffix.appending(
            [("opns.idKey", Self.identityPubKeyHex)],
            to: ActionScript.payToPublicKeyHash(selfAddr)
        )
        XCTAssertEqual(prepared.outputs[0].lockingScript, expected.bytes)
        XCTAssertEqual(prepared.outputs[0].outputDescription, "Ordinal transfer")
        XCTAssertEqual(prepared.inputs.count, 1)
        XCTAssertEqual(
            prepared.labels,
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.ordinalsBasket, id: "aa_0")]
        )
    }

    func test_deregisterBuilderWritesEmptyIdKeyAndDropsPublishedTag() throws {
        let identity = try ActionVectors.identity()
        let selfAddr = try P1SATKey.address(
            identity: identity,
            keyID: ActionVectors.outpoint,
            counterparty: .self,
            forSelf: false
        )
        let ctx = try dummyContext(identity: identity)
        let ordinal = try walletOutput(
            tags: [
                "type:application/op-ns",
                "origin:\(ActionVectors.outpoint)",
                "name:alice",
                "id:aa_0",
                "opns:published",
            ]
        )
        let prepared = try Ordinals.buildTransfer(
            ctx,
            Ordinals.TransferRequest(
                transfers: [
                    Ordinals.TransferItem(
                        ordinal: ordinal,
                        toSelf: true,
                        map: [("opns.idKey", "")],
                        extraTags: []
                    ),
                ]
            )
        )
        XCTAssertEqual(prepared.outputs[0].basket, OneSatConstants.opnsBasket)
        XCTAssertEqual(
            prepared.outputs[0].tags,
            [
                "type:application/op-ns",
                "origin:\(ActionVectors.outpoint)",
                "name:alice",
            ]
        )
        XCTAssertFalse(prepared.outputs[0].tags.contains("opns:published"))
        let expected = try MapSuffix.appending(
            [("opns.idKey", "")],
            to: ActionScript.payToPublicKeyHash(selfAddr)
        )
        XCTAssertEqual(prepared.outputs[0].lockingScript, expected.bytes)
    }

    func test_registerRequiresServicesBeforeStorage() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport, services: nil)
        let result = await OpNS.register(
            ctx,
            OpNS.Request(ordinal: try walletOutput(tags: ["type:application/op-ns"]))
        )
        XCTAssertEqual(result.error, "services-required")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_toSelfFalseStillRequiresDestination() throws {
        let identity = try ActionVectors.identity()
        let ctx = try dummyContext(identity: identity)
        XCTAssertThrowsError(
            try Ordinals.buildTransfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [Ordinals.TransferItem(ordinal: try walletOutput(tags: ["type:application/op-ns"]))]
                )
            )
        ) { error in
            XCTAssertEqual(error as? OneSatActionError, .mustProvideCounterpartyOrAddress)
        }
    }

    func test_registerWithoutIdTagReturnsNoBeefAvailable() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let ctx = try context(
            identity: identity,
            transport: transport,
            services: StubServices()
        )
        let result = await OpNS.register(
            ctx,
            OpNS.Request(
                ordinal: try walletOutput(tags: ["type:application/op-ns", "name:alice"])
            )
        )
        XCTAssertEqual(result.error, "no-beef-available")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_getNamesListsOpnsBasketAndReturnsBeef() async throws {
        let fixture = try beefFixture()
        let transport = ScriptedTransport(
            listResult: [
                "totalOutputs": 1,
                "BEEF": fixture.map { Int($0) },
                "outputs": [
                    [
                        "outpoint": ActionVectors.outpoint,
                        "satoshis": 1,
                        "spendable": true,
                        "tags": ["type:application/op-ns", "name:alice"],
                    ],
                ],
            ]
        )
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport)
        let listed = try await OpNS.getNames(ctx)
        XCTAssertEqual(listed.outputs.count, 1)
        XCTAssertEqual(listed.outputs[0].outpoint.description, ActionVectors.outpoint)
        XCTAssertEqual(listed.beef, fixture)

        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
        let bodies = await transport.bodies
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bodies[0])) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "listOutputs")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        let args = try XCTUnwrap(params[1] as? [String: Any])
        XCTAssertEqual(args["basket"] as? String, "p 1sat opns")
        XCTAssertEqual(args["include"] as? String, "entire transactions")
        XCTAssertEqual(args["includeCustomInstructions"] as? Bool, true)
        XCTAssertEqual(args["includeTags"] as? Bool, true)
        XCTAssertEqual((args["limit"] as? NSNumber)?.uint32Value, 100)
    }

    func test_registerCreateActionCarriesInputBEEFAndTracking() async throws {
        let fixture = try beefFixture()
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let ctx = try context(
            identity: identity,
            transport: transport,
            services: StubServices()
        )
        let ordinal = try walletOutput(
            tags: [
                "type:application/op-ns",
                "origin:\(ActionVectors.outpoint)",
                "name:alice",
                "id:aa_0",
                "opns:published",
            ]
        )
        let result = await OpNS.register(
            ctx,
            OpNS.Request(ordinal: ordinal, inputBEEF: fixture)
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)

        let methods = await transport.methods
        XCTAssertEqual(methods, ["createAction"])
        let bodies = await transport.bodies
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bodies[0])) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        let args = try XCTUnwrap(params[1] as? [String: Any])
        let wireBeef = try XCTUnwrap(args["inputBEEF"] as? [NSNumber]).map { UInt8(truncating: $0) }
        XCTAssertEqual(wireBeef, fixture)
        XCTAssertEqual(args["description"] as? String, "Transfer ordinal")
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)

        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.opnsBasket)
        XCTAssertEqual(outputs[0]["outputDescription"] as? String, "Ordinal transfer")
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertEqual(tags.prefix(4), [
            "type:application/op-ns",
            "origin:\(ActionVectors.outpoint)",
            "name:alice",
            "opns:published",
        ])
        let idTag = try XCTUnwrap(tags.last)
        XCTAssertTrue(idTag.hasPrefix("id:"))
        XCTAssertTrue(idTag.hasSuffix("_0"))
        let labels = try XCTUnwrap(args["labels"] as? [String])
        XCTAssertTrue(labels.contains(OneSatConstants.p1satLabel))

        let selfAddr = try P1SATKey.address(
            identity: identity,
            keyID: ActionVectors.outpoint,
            counterparty: .self,
            forSelf: false
        )
        let expected = try MapSuffix.appending(
            [("opns.idKey", Self.identityPubKeyHex)],
            to: ActionScript.payToPublicKeyHash(selfAddr)
        )
        XCTAssertEqual(outputs[0]["lockingScript"] as? String, expected.hex)
        let instructions = try CustomInstructions.parse(
            try XCTUnwrap(outputs[0]["customInstructions"] as? String)
        )
        XCTAssertEqual(instructions.keyID, ActionVectors.outpoint)
        XCTAssertEqual(instructions.counterparty, .self)
    }

    private func walletOutput(tags: [String]) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded(),
            tags: tags,
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
    }

    private func beefFixture() throws -> [UInt8] {
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(
                    satoshis: 1,
                    lockingScript: try Script(bytes: [0x51], maximumByteCount: 10_000)
                ),
            ],
            lockTime: 0
        )
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        return (try beef.serialized(limits: WalletBEEFLimits.standard))
    }

    private func dummyContext(identity: PrivateKey) throws -> OneSatContext {
        try context(identity: identity, transport: RejectTransport())
    }

    private func context(
        identity: PrivateKey,
        transport: any AuthenticatedTransport,
        services: (any WalletServices)? = nil
    ) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            services: services
        )
    }
}

private struct StubServices: WalletServices {
    func rawTX(txid: String) async throws -> [UInt8] {
        throw ServiceError.notImplemented("rawTX")
    }
    func postBEEF(_ beef: [UInt8], txids: [String]) async throws -> [BroadcastOutcome] {
        throw ServiceError.notImplemented("postBEEF")
    }
    func merklePath(txid: String) async throws -> [UInt8]? {
        throw ServiceError.notImplemented("merklePath")
    }
    func currentHeight() async throws -> UInt32 {
        throw ServiceError.notImplemented("currentHeight")
    }
    func chainTipHeader() async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("chainTipHeader")
    }
    func header(atHeight height: UInt32) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header")
    }
    func header(forHash hash: String) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header")
    }
    func isValidRoot(_ root: [UInt8], atHeight height: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isValidRoot")
    }
    func statusForTXIDs(_ txids: [String]) async throws -> [TransactionStatusReport] {
        throw ServiceError.notImplemented("status")
    }
    func isUTXO(scriptHash: String, txid: String, vout: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isUTXO")
    }
    func scriptHashHistory(_ scriptHash: String) async throws -> [ScriptHistoryEntry] {
        throw ServiceError.notImplemented("history")
    }
    func usdPerBSV() async throws -> Double {
        throw ServiceError.notImplemented("usd")
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
