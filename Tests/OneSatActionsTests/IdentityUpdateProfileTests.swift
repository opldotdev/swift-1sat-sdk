import Foundation
import BSVCompat
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

final class IdentityUpdateProfileTests: XCTestCase {
    private let expectedBapId = "qqeHr1tWxwzvAkd2iUsi8zRuE5S"
    private let profileJSON = "{\"@type\":\"Person\",\"name\":\"Alice\"}"
    private let idCustomInstructions = "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-1\"}"
    private let aliasOutpoint =
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.0"
    private let idOutpoint =
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc.0"

    func test_firstPublishCreatesIdThenAlias() async throws {
        let transport = ScriptedTransport(idOutputs: [], aliasOutputs: [])
        let identity = try ActionVectors.identity()
        _ = await Identity.updateProfile(
            try context(identity: identity, transport: transport),
            profileJSON: profileJSON
        )

        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "listOutputs", "createAction"])
        let captured = await transport.capturedCreateAction()
        let first = try XCTUnwrap(captured)
        XCTAssertEqual(first.description, "BAP identity creation with profile")
        XCTAssertEqual(first.randomizeOutputs, false)
        XCTAssertEqual(first.acceptDelayedBroadcast, false)
        XCTAssertEqual(first.outputs.count, 2)

        let idOutput = first.outputs[0]
        XCTAssertEqual(idOutput.satoshis, 0)
        XCTAssertEqual(idOutput.outputDescription, "BAP ID")
        XCTAssertEqual(idOutput.basket, "bap")
        XCTAssertEqual(idOutput.customInstructions, idCustomInstructions)
        XCTAssertTrue(idOutput.tags.contains("type:id"))
        XCTAssertTrue(idOutput.tags.contains("bapId:\(expectedBapId)"))
        XCTAssertTrue(idOutput.tags.contains("seq:1"))

        let aliasOutput = first.outputs[1]
        XCTAssertEqual(aliasOutput.satoshis, 0)
        XCTAssertEqual(aliasOutput.outputDescription, "BAP ALIAS")
        XCTAssertEqual(aliasOutput.basket, "bap")
        XCTAssertNil(aliasOutput.customInstructions)
        XCTAssertTrue(aliasOutput.tags.contains("type:alias"))
        XCTAssertTrue(aliasOutput.tags.contains("bapId:\(expectedBapId)"))
        XCTAssertTrue(aliasOutput.tags.contains { $0.hasPrefix("publishedAt:") })

        let idScript = try Script(
            hex: idOutput.lockingScript,
            maximumByteCount: ActionScript.maximumByteCount
        )
        let idBitcom = try XCTUnwrap(BitCom.decode(idScript))
        let idBap = try XCTUnwrap(BAPTemplate.decode(idBitcom))
        XCTAssertEqual(idBap.type, .id)
        XCTAssertEqual(idBap.idKey, expectedBapId)
        try assertValidAIP(on: idScript, identity: identity, index: 0)

        let aliasScript = try Script(
            hex: aliasOutput.lockingScript,
            maximumByteCount: ActionScript.maximumByteCount
        )
        let aliasBitcom = try XCTUnwrap(BitCom.decode(aliasScript))
        let aliasBap = try XCTUnwrap(BAPTemplate.decode(aliasBitcom))
        XCTAssertEqual(aliasBap.type, .alias)
        XCTAssertEqual(aliasBap.idKey, expectedBapId)
        XCTAssertEqual(aliasBap.profileJSON, profileJSON)
        try assertValidAIP(on: aliasScript, identity: identity, index: 1)
    }

    func test_existingIdentityUpdatesAliasAndRelinquishesOld() async throws {
        let transport = ScriptedTransport(
            idOutputs: [
                [
                    "outpoint": idOutpoint,
                    "satoshis": 0,
                    "spendable": true,
                    "tags": ["type:id", "bapId:\(expectedBapId)", "seq:1"],
                    "customInstructions": idCustomInstructions,
                ],
            ],
            aliasOutputs: [
                [
                    "outpoint": aliasOutpoint,
                    "satoshis": 0,
                    "spendable": true,
                    "tags": ["type:alias", "bapId:\(expectedBapId)", "publishedAt:1"],
                ],
            ],
            completeAction: true
        )
        let identity = try ActionVectors.identity()
        let result = await Identity.updateProfile(
            try context(identity: identity, transport: transport),
            profileJSON: profileJSON
        )
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNotNil(result.txid)
        XCTAssertEqual(result.bapId, expectedBapId)

        let captured = await transport.capturedCreateAction()
        let update = try XCTUnwrap(captured)
        XCTAssertEqual(update.description, "BAP alias update")
        XCTAssertEqual(update.outputs.count, 1)
        let aliasOutput = update.outputs[0]
        XCTAssertEqual(aliasOutput.satoshis, 0)
        XCTAssertEqual(aliasOutput.outputDescription, "BAP ALIAS")
        XCTAssertTrue(aliasOutput.tags.contains("type:alias"))
        XCTAssertTrue(aliasOutput.tags.contains("bapId:\(expectedBapId)"))

        let aliasScript = try Script(
            hex: aliasOutput.lockingScript,
            maximumByteCount: ActionScript.maximumByteCount
        )
        let aliasBitcom = try XCTUnwrap(BitCom.decode(aliasScript))
        let aliasBap = try XCTUnwrap(BAPTemplate.decode(aliasBitcom))
        XCTAssertEqual(aliasBap.type, .alias)
        XCTAssertEqual(aliasBap.profileJSON, profileJSON)
        try assertValidAIP(on: aliasScript, identity: identity, index: 1)

        let relinquished = await transport.relinquished
        XCTAssertEqual(relinquished, [aliasOutpoint])
    }

    func test_resolveWithoutIdOutputsSurfacesExactMessage() async throws {
        let transport = ScriptedTransport(
            idOutputs: [
                [
                    "outpoint": idOutpoint,
                    "satoshis": 0,
                    "spendable": true,
                    "tags": ["type:id"],
                ],
            ],
            aliasOutputs: []
        )
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport)
        let result = await Identity.updateProfile(ctx, profileJSON: profileJSON)
        XCTAssertEqual(
            result.error,
            "No BAP identity published — cannot resolve current signing key. Publish an identity before signing."
        )
        XCTAssertNil(result.txid)

        do {
            _ = try await Sigma.resolveCurrentKeyId(
                try context(
                    identity: identity,
                    transport: ScriptedTransport(idOutputs: [], aliasOutputs: [])
                )
            )
            XCTFail("expected resolveCurrentKeyId to throw")
        } catch let error as OneSatActionError {
            XCTAssertEqual(error, .noBapIdentity)
            XCTAssertEqual(
                error.wireMessage,
                "No BAP identity published — cannot resolve current signing key. Publish an identity before signing."
            )
        }
    }

    func test_nonObjectProfileIsRefused() async throws {
        let transport = ScriptedTransport(idOutputs: [], aliasOutputs: [])
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport)
        let array = await Identity.updateProfile(ctx, profileJSON: "[1]")
        XCTAssertEqual(array.error, "profile-must-be-json-object")
        let scalar = await Identity.updateProfile(ctx, profileJSON: "\"alice\"")
        XCTAssertEqual(scalar.error, "profile-must-be-json-object")
        let methods = await transport.methods
        XCTAssertTrue(methods.isEmpty)
    }

    private func assertValidAIP(on script: Script, identity: PrivateKey, index: Int) throws {
        let operations = try script.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        XCTAssertGreaterThanOrEqual(operations.count, 5)
        let prefixOps = operations.dropLast(5)
        var unsigned = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        for operation in prefixOps {
            switch operation {
            case .opcode(let opcode):
                try unsigned.append(opcode, maximumScriptByteCount: ActionScript.maximumByteCount)
            case .push(_, let data):
                try unsigned.appendPushData(data, maximumScriptByteCount: ActionScript.maximumByteCount)
            }
        }
        let message = try AIPSign.messageBuffer(unsigned)
        let signatureBytes = try XCTUnwrap(operations.suffix(5).last?.pushedData)
        let signature = try BitcoinMessageSignature(signatureBytes)
        let recovered = try signature.recoverPublicKey(message: message)
        XCTAssertEqual(
            Address(publicKey: recovered, network: .mainnet, compressed: true).description,
            try derivedAddress(identity, index: index).description
        )
    }

    private func derivedKey(_ identity: PrivateKey, index: Int) throws -> PrivateKey {
        try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID(Identity.signingKeyID(index)),
            counterparty: .self
        )
    }

    private func derivedAddress(_ identity: PrivateKey, index: Int) throws -> Address {
        Address(
            publicKey: try derivedKey(identity, index: index).publicKey,
            network: .mainnet,
            compressed: true
        )
    }

    private func context(identity: PrivateKey, transport: ScriptedTransport) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }
}

private struct CapturedCreateAction: Sendable {
    let description: String
    let randomizeOutputs: Bool?
    let acceptDelayedBroadcast: Bool?
    let outputs: [CapturedOutput]
}

private struct CapturedOutput: Sendable {
    let satoshis: UInt64
    let outputDescription: String?
    let basket: String?
    let lockingScript: String
    let tags: [String]
    let customInstructions: String?
}

private actor ScriptedTransport: AuthenticatedTransport {
    private(set) var methods: [String] = []
    private(set) var bodies: [[UInt8]] = []
    private(set) var relinquished: [String] = []
    private let idOutputs: [[String: Any]]
    private let aliasOutputs: [[String: Any]]
    private let completeAction: Bool
    private var nextReference = 0

    init(
        idOutputs: [[String: Any]],
        aliasOutputs: [[String: Any]],
        completeAction: Bool = false
    ) {
        self.idOutputs = idOutputs
        self.aliasOutputs = aliasOutputs
        self.completeAction = completeAction
    }

    func capturedCreateAction() -> CapturedCreateAction? {
        for body in bodies {
            guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  object["method"] as? String == "createAction",
                  let params = object["params"] as? [Any],
                  params.count >= 2,
                  let args = params[1] as? [String: Any]
            else { continue }
            let rawOutputs = args["outputs"] as? [[String: Any]] ?? []
            let options = args["options"] as? [String: Any] ?? [:]
            return CapturedCreateAction(
                description: args["description"] as? String ?? "",
                randomizeOutputs: options["randomizeOutputs"] as? Bool,
                acceptDelayedBroadcast: options["acceptDelayedBroadcast"] as? Bool,
                outputs: rawOutputs.map { output in
                    CapturedOutput(
                        satoshis: (output["satoshis"] as? NSNumber)?.uint64Value ?? 0,
                        outputDescription: output["outputDescription"] as? String,
                        basket: output["basket"] as? String,
                        lockingScript: output["lockingScript"] as? String ?? "",
                        tags: output["tags"] as? [String] ?? [],
                        customInstructions: output["customInstructions"] as? String
                    )
                }
            )
        }
        return nil
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
        let id = object?["id"] as Any
        switch rpcMethod {
        case "listOutputs":
            let params = object?["params"] as? [Any]
            let args = params?.dropFirst().first as? [String: Any]
            let tags = args?["tags"] as? [String] ?? []
            let rows = tags.contains("type:alias") ? aliasOutputs : idOutputs
            return try envelope(
                id: id,
                result: [
                    "totalOutputs": rows.count,
                    "outputs": rows,
                ]
            )
        case "createAction":
            if completeAction {
                return try createActionResponse(id: id, object: object)
            }
            throw AuthTransportError.notImplemented("offline")
        case "processAction":
            return try envelope(id: id, result: ["sendWithResults": [Any]()])
        case "relinquishOutput":
            let params = object?["params"] as? [Any]
            let args = params?.dropFirst().first as? [String: Any]
            if let output = args?["output"] as? String {
                relinquished.append(output)
            }
            return try envelope(id: id, result: ["relinquished": true])
        default:
            throw AuthTransportError.notImplemented("offline")
        }
    }

    private func createActionResponse(id: Any, object: [String: Any]?) throws -> AuthenticatedResponse {
        let params = object?["params"] as? [Any]
        let args = params?[1] as? [String: Any] ?? [:]
        let requested = args["outputs"] as? [[String: Any]] ?? []
        var outputRows: [[String: Any]] = []
        for (index, output) in requested.enumerated() {
            outputRows.append([
                "lockingScript": output["lockingScript"] as? String ?? "",
                "satoshis": output["satoshis"] as Any,
                "vout": index,
                "providedBy": "you",
            ])
        }
        let sourceLock = try Script(bytes: [0x51], maximumByteCount: 10_000)
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [
                TransactionOutput(satoshis: 10_000, lockingScript: sourceLock),
            ],
            lockTime: 0
        )
        let sourceTxid = try source.transactionID(limits: WalletTransactionLimits.standard)
        let beef = try BEEF(
            merklePaths: [],
            transactions: [.raw(source)],
            limits: WalletBEEFLimits.standard
        )
        let result: [String: Any] = [
            "reference": "ref-\(nextReference)",
            "version": 1,
            "lockTime": 0,
            "inputs": [
                [
                    "sourceTxid": sourceTxid.displayHex,
                    "sourceVout": 0,
                    "sourceSatoshis": 10_000,
                    "sourceLockingScript": sourceLock.hex,
                    "unlockingScriptLength": 108,
                ],
            ],
            "outputs": outputRows,
            "inputBeef": try beef.serialized(limits: WalletBEEFLimits.standard).map(Int.init),
        ]
        nextReference += 1
        return try envelope(id: id, result: result)
    }

    private func envelope(id: Any, result: [String: Any]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ]
        )
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}
