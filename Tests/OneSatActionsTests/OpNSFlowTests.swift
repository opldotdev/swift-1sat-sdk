import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
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

    /// Released `[0, "onesat"]` derivation with counterparty self and `forSelf: true`.
    private static let selfAddress = "1F5UNyuueGgsrGjevcLuicSwtQv8oXxMeS"

    func test_registerBuildsTheSignedIdentityBind() async throws {
        let fixture = try beefFixture()
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        XCTAssertEqual(Hex.encode(identity.publicKey.compressedBytes), Self.identityPubKeyHex)
        let ctx = try context(identity: identity, transport: transport)
        let result = await OpNS.register(
            ctx,
            OpNS.RegisterRequest(
                ordinal: try walletOutput(tags: Self.nameTags),
                profile: OpNS.Profile(
                    domain: "1sat.name",
                    name: "Alice",
                    avatar: String(repeating: "ef", count: 32) + "_1"
                ),
                inputBEEF: fixture
            )
        )
        XCTAssertNotNil(result.error, "the offline transport fails funding")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["createAction"])

        let args = try await createActionArgs(transport)
        XCTAssertEqual(args["description"] as? String, "Publish OpNS alice")
        let wireBeef = try XCTUnwrap(args["inputBEEF"] as? [NSNumber]).map { UInt8(truncating: $0) }
        XCTAssertEqual(wireBeef, fixture)
        XCTAssertEqual(
            args["labels"] as? [String],
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.opnsBasket, id: "aa_0")]
        )
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        let inputs = try XCTUnwrap(args["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(storageOutpoint(inputs[0]["outpoint"]), ActionVectors.outpoint)
        XCTAssertEqual(inputs[0]["inputDescription"] as? String, "OpNS name to register")
        XCTAssertEqual((inputs[0]["unlockingScriptLength"] as? NSNumber)?.intValue, 108)

        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.opnsBasket)
        XCTAssertEqual(outputs[0]["outputDescription"] as? String, "OpNS identity bind")
        XCTAssertEqual(outputs[0]["lockingScript"] as? String, SignOrdinalInputTests.lockFull)
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertEqual(Array(tags.dropLast()), [
            "opns",
            "type:application/op-ns",
            "origin:\(Bsv21Remittance.formatOrdinalOutpoint(ActionVectors.outpoint))",
            OneSatConstants.opnsPublishedTag,
        ])
        XCTAssertTrue(try XCTUnwrap(tags.last).hasPrefix("id:"))
        let instructions = try XCTUnwrap(outputs[0]["customInstructions"] as? String)
        let ci = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(instructions.utf8)) as? [String: Any]
        )
        XCTAssertEqual(ci["keyID"] as? String, "opns:" + String(repeating: "aa", count: 32) + "_0")
        XCTAssertEqual(ci["counterparty"] as? String, "anyone")
        XCTAssertEqual(ci["name"] as? String, "alice")
        XCTAssertEqual(ci["origin"] as? String, Bsv21Remittance.formatOrdinalOutpoint(ActionVectors.outpoint))
        XCTAssertEqual(try CustomInstructions.parse(instructions).protocolID, try OneSatConstants.p1satProtocolID)

        let record = try XCTUnwrap(OpNS.publishedRecord(
            from: try Script(hex: SignOrdinalInputTests.lockFull, maximumByteCount: 10_000)
        ))
        XCTAssertEqual(record.profile?.avatar, [UInt8](repeating: 0xef, count: 32) + [1, 0, 0, 0])
        XCTAssertNil(Inscription.decode(
            try Script(hex: SignOrdinalInputTests.lockFull, maximumByteCount: 10_000)
        ))
    }

    func test_registerRejectsAMissingDomainBeforeStorage() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let ctx = try context(identity: ActionVectors.identity(), transport: transport)
        let result = await OpNS.register(
            ctx,
            OpNS.RegisterRequest(
                ordinal: try walletOutput(tags: Self.nameTags),
                profile: OpNS.Profile(domain: ""),
                inputBEEF: try beefFixture()
            )
        )
        XCTAssertEqual(result.error, "profile domain is required")
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_registerAppendsTheInscriptionAfterThePushDrop() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let ctx = try context(identity: ActionVectors.identity(), transport: transport)
        _ = await OpNS.register(
            ctx,
            OpNS.RegisterRequest(
                ordinal: try walletOutput(tags: Self.nameTags),
                profile: OpNS.Profile(domain: "1sat.name"),
                inscription: Ordinals.InscriptionPayload(content: Array("hello".utf8), contentType: "ordfs/dir"),
                inputBEEF: try beefFixture()
            )
        )
        let args = try await createActionArgs(transport)
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        let lockHex = try XCTUnwrap(outputs[0]["lockingScript"] as? String)
        XCTAssertEqual(lockHex, SignOrdinalInputTests.lockInscribed)

        let lock = try Script(hex: lockHex, maximumByteCount: 10_000)
        let inscription = try XCTUnwrap(Inscription.decode(lock))
        XCTAssertEqual(inscription.contentType, "ordfs/dir")
        XCTAssertEqual(inscription.content, Array("hello".utf8))
        XCTAssertEqual(inscription.scriptPrefix?.hex, SignOrdinalInputTests.lockDomainOnly)
        XCTAssertEqual(OpNS.publishedRecord(from: lock)?.profile, OpnsFields.Profile(domain: "1sat.name"))
    }

    func test_registerNeedsCustomInstructionsAndBEEF() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let ctx = try context(identity: ActionVectors.identity(), transport: transport)
        let noTag = await OpNS.register(
            ctx,
            OpNS.RegisterRequest(
                ordinal: try walletOutput(tags: ["type:application/op-ns", "name:alice"]),
                profile: OpNS.Profile(domain: "1sat.name")
            )
        )
        XCTAssertEqual(noTag.error, "no-beef-available")
        let bare = try WalletOutput(
            satoshis: 1,
            spendable: true,
            tags: Self.nameTags,
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
        let noCI = await OpNS.register(
            ctx,
            OpNS.RegisterRequest(ordinal: bare, profile: OpNS.Profile(domain: "1sat.name"), inputBEEF: try beefFixture())
        )
        XCTAssertEqual(noCI.error, "missing-custom-instructions")
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_deregisterUnbindsToTheP1SatAddress() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport)
        let published = try walletOutput(
            tags: Self.nameTags + [OneSatConstants.opnsPublishedTag, "opns"],
            customInstructions: OrdinalRemittance.buildCustomInstructions(
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: "opns:" + String(repeating: "aa", count: 32) + "_0",
                counterparty: "anyone",
                name: "alice"
            )
        )
        _ = await OpNS.deregister(ctx, OpNS.Request(ordinal: published, inputBEEF: try beefFixture()))
        let args = try await createActionArgs(transport)
        XCTAssertEqual(args["description"] as? String, "Unpublish OpNS alice")
        let inputs = try XCTUnwrap(args["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs[0]["inputDescription"] as? String, "OpNS name to deregister")
        XCTAssertEqual((inputs[0]["unlockingScriptLength"] as? NSNumber)?.intValue, 108)
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs[0]["outputDescription"] as? String, "OpNS name (unbound)")
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.opnsBasket)
        let selfAddr = try P1SATKey.address(
            identity: identity,
            keyID: ActionVectors.outpoint,
            counterparty: .self,
            forSelf: true
        )
        XCTAssertEqual(selfAddr.description, Self.selfAddress)
        XCTAssertEqual(
            outputs[0]["lockingScript"] as? String,
            try ActionScript.payToPublicKeyHash(selfAddr).hex
        )
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertEqual(Array(tags.dropLast()), [
            "opns",
            "type:application/op-ns",
            "origin:\(Bsv21Remittance.formatOrdinalOutpoint(ActionVectors.outpoint))",
        ])
        let ci = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try XCTUnwrap(outputs[0]["customInstructions"] as? String).utf8)
        ) as? [String: Any])
        XCTAssertEqual(ci["keyID"] as? String, ActionVectors.outpoint)
        XCTAssertEqual(ci["counterparty"] as? String, "self")
        XCTAssertEqual(ci["name"] as? String, "alice")
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
        XCTAssertEqual(args["basket"] as? String, "opns")
        // Storage takes the validated flags, not the BRC-100 `include` selector.
        XCTAssertEqual(args["includeTransactions"] as? Bool, true)
        XCTAssertEqual(args["includeLockingScripts"] as? Bool, false)
        XCTAssertEqual(args["includeCustomInstructions"] as? Bool, true)
        XCTAssertEqual(args["includeTags"] as? Bool, true)
        XCTAssertEqual((args["limit"] as? NSNumber)?.uint32Value, 100)
    }

    func test_cancelListingRestoresOpnsMetadataAndReportsFundingFailure() async throws {
        let fixture = try beefFixture()
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let ctx = try context(identity: ActionVectors.identity(), transport: transport)
        let listing = try walletOutput(tags: [
            "opns", "type:application/op-ns", "origin:\(ActionVectors.outpoint)",
            "name:alice", "ordlock", "opns:published", "id:aa_0",
        ])
        let result = await OpNS.cancelListing(ctx, OpNS.Request(ordinal: listing, inputBEEF: fixture))
        XCTAssertNotNil(result.error, "failed funding cannot be reported as a completed cancellation")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["createAction"])
        let bodies = await transport.bodies
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bodies[0])) as? [String: Any])
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        let args = try XCTUnwrap(params[1] as? [String: Any])
        XCTAssertEqual(args["description"] as? String, "Cancel OpNS listing alice")
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.opnsBasket)
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertTrue(tags.contains("opns"))
        XCTAssertTrue(tags.contains("type:application/op-ns"))
        XCTAssertFalse(tags.contains("ordlock"))
        XCTAssertFalse(tags.contains("opns:published"))
        let instructions = try CustomInstructions.parse(try XCTUnwrap(outputs[0]["customInstructions"] as? String))
        XCTAssertEqual(instructions.name, "alice")
        XCTAssertEqual(instructions.keyID, ActionVectors.outpoint)
        XCTAssertEqual(args["labels"] as? [String], [OneSatConstants.inputAssetLabel(basket: OneSatConstants.opnsBasket, id: "aa_0")])
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
    }

    private static let nameTags = [
        "type:application/op-ns",
        "origin:\(ActionVectors.outpoint)",
        "name:alice",
        "id:aa_0",
    ]

    private func createActionArgs(_ transport: ScriptedTransport) async throws -> [String: Any] {
        let bodies = await transport.bodies
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(bodies.first))) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        return try XCTUnwrap(params[1] as? [String: Any])
    }

    private func walletOutput(tags: [String], customInstructions: String? = nil) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: try customInstructions
                ?? CustomInstructions(keyID: ActionVectors.outpoint).encoded(),
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
