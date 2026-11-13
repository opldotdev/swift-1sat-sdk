import Foundation
import BSVCompat
import BSVCore
import BSVKeys
import BSVScript
import BSVWallet
import OneSatTemplates
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/deployOrdfsDir.test.ts` and checks the `createAction` request
/// the action sends (the scripted storage refuses `createAction`, so nothing is published).
final class DeployOrdfsDirTests: XCTestCase {
    private let files = [OrdfsDirFile(path: "a.md", content: Array("hi".utf8), contentType: "text/markdown")]

    // MARK: Input validation (deployOrdfsDir.test.ts)

    func test_rejectsAnEmptyFileList() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(try context(transport), DeployOrdfsDir.Request(files: []))
        XCTAssertEqual(response.error, "no-files")
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_rejectsAnUnknownWriteMode() {
        XCTAssertThrowsError(try DeployOrdfsDir.Request(
            base64Files: [(path: "a.md", base64Content: "aGk=", contentType: "text/markdown")],
            writeMode: "inscriptoin"
        )) { error in
            XCTAssertTrue((error as? DeployOrdfsDirError)?.message.hasPrefix("invalid-write-mode") == true)
        }
    }

    func test_base64RequestDecodesContentAndDefaultsToMixedSigned() throws {
        let request = try DeployOrdfsDir.Request(
            base64Files: [(path: "a.md", base64Content: "aGk=", contentType: "text/markdown")]
        )
        XCTAssertEqual(request.files, files)
        XCTAssertEqual(request.writeMode, .mixed)
        XCTAssertTrue(request.sign)
    }

    func test_layoutErrorsAreReturnedNotThrown() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(
            try context(transport),
            DeployOrdfsDir.Request(files: files + files, sign: false)
        )
        XCTAssertTrue(response.error?.contains("path collision") == true, "\(String(describing: response.error))")
    }

    // MARK: createAction requests

    func test_unsignedMixedPublishBasketsOnlyTheOrdinalRoot() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(
            try context(transport),
            DeployOrdfsDir.Request(
                files: files + [OrdfsDirFile(path: "refs/b.md", content: Array("b".utf8), contentType: "text/markdown")],
                map: [("app", "test")],
                sign: false
            )
        )
        XCTAssertNotNil(response.error)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["createAction"])
        let args = try await createActionArgs(transport, index: 0)
        XCTAssertEqual(args["description"] as? String, "Publish ord-fs directory")
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, false)

        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.map { ($0["satoshis"] as? NSNumber)?.intValue }, [0, 0, 0, 1])
        XCTAssertEqual(
            outputs.map { $0["outputDescription"] as? String },
            ["file: a.md", "file: refs/b.md", "dir: refs/", "manifest (ord-fs/json)"]
        )
        for output in outputs.dropLast() {
            XCTAssertNil(output["basket"])
            XCTAssertNil(output["customInstructions"])
        }
        let root = try XCTUnwrap(outputs.last)
        XCTAssertEqual(root["basket"] as? String, OneSatConstants.ordinalsBasket)
        let tags = try XCTUnwrap(root["tags"] as? [String])
        XCTAssertTrue(tags.contains("type:ord-fs/json"))
        XCTAssertTrue(tags.contains("origin"))
        let instructions = try CustomInstructions.parse(try XCTUnwrap(root["customInstructions"] as? String))
        XCTAssertTrue(instructions.keyID.hasPrefix("ordfs-dir-"))

        let script = try Script(
            hex: try XCTUnwrap(root["lockingScript"] as? String),
            maximumByteCount: ActionScript.maximumByteCount
        )
        let inscription = try XCTUnwrap(Inscription.decode(script))
        XCTAssertEqual(inscription.content, Array(#"{"a.md":"_0","refs":"_2"}"#.utf8))
        // BitCom.decode scans for the first raw 0x6a byte (as the TS and Go readers do), which
        // may sit inside the P2PKH prefix, so check the MAP suffix bytes directly.
        let map = try MAPTemplate.set([("app", "test")]).bytes
        XCTAssertEqual(Array(script.bytes.suffix(map.count)), map)
    }

    func test_signedBPublishCarriesAnAIPSignedRootAndNoBasket() async throws {
        let transport = DeployTransport(listResult: [
            "totalOutputs": 1,
            "outputs": [
                [
                    "outpoint": ActionVectors.outpoint,
                    "satoshis": 0,
                    "spendable": true,
                    "tags": ["type:id", "seq:1"],
                    "customInstructions": "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-1\"}",
                ],
            ],
        ])
        let identity = try ActionVectors.identity()
        _ = await DeployOrdfsDir.execute(
            try context(transport),
            DeployOrdfsDir.Request(files: files, map: [("app", "test")], writeMode: .b)
        )
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction"])
        let args = try await createActionArgs(transport, index: 1)
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.map { ($0["satoshis"] as? NSNumber)?.intValue }, [0, 0])
        let root = try XCTUnwrap(outputs.last)
        XCTAssertNil(root["basket"])
        XCTAssertEqual(root["tags"] as? [String], ["type:ord-fs/json", "origin"])

        let script = try Script(
            hex: try XCTUnwrap(root["lockingScript"] as? String),
            maximumByteCount: ActionScript.maximumByteCount
        )
        XCTAssertEqual(try XCTUnwrap(BTemplate.decode(script)).data, Array(#"{"a.md":"_0"}"#.utf8))
        let operations = try script.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        var unsigned = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        for operation in operations.dropLast(5) {
            switch operation {
            case .opcode(let opcode):
                try unsigned.append(opcode, maximumScriptByteCount: ActionScript.maximumByteCount)
            case .push(_, let data):
                try unsigned.appendPushData(data, maximumScriptByteCount: ActionScript.maximumByteCount)
            }
        }
        XCTAssertEqual(operations.suffix(5).first?.pushedData, Array("|".utf8))
        XCTAssertEqual(operations.suffix(4).first?.pushedData, Array(OneSatConstants.aipPrefix.utf8))
        let signature = try BitcoinMessageSignature(try XCTUnwrap(operations.last?.pushedData))
        let recovered = try signature.recoverPublicKey(message: try AIPSign.messageBuffer(unsigned))
        let expected = try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID("identity-1"),
            counterparty: .self
        )
        XCTAssertEqual(recovered.compressedBytes, expected.publicKey.compressedBytes)
    }

    func test_signedMixedPublishStartsWithASigmaAnchor() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(try context(transport), DeployOrdfsDir.Request(files: files))
        XCTAssertNotNil(response.error)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["createAction"])
        let args = try await createActionArgs(transport, index: 0)
        XCTAssertEqual(args["description"] as? String, "Sigma anchor output")
        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.intValue, 2)
        XCTAssertEqual(outputs[0]["basket"] as? String, OneSatConstants.sigmaBasket)
        let instructions = try CustomInstructions.parse(try XCTUnwrap(outputs[0]["customInstructions"] as? String))
        XCTAssertTrue(instructions.keyID.hasPrefix("anchor-"))
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["noSend"] as? Bool, true)
    }

    func test_actionOutputsTruncateDescriptionsTo50Characters() throws {
        let long = String(repeating: "x", count: 80)
        let built = try OrdfsDirOutputs.build(
            [OrdfsDirFile(path: long, content: Array("1".utf8), contentType: "text/plain")],
            writeMode: .b
        )
        let outputs = try DeployOrdfsDir.actionOutputs(built, writeMode: .b)
        XCTAssertEqual(outputs[0].outputDescription, String("file: \(long)".prefix(50)))
        XCTAssertEqual(outputs[1].tags, ["type:ord-fs/json", "origin"])
        XCTAssertEqual(outputs[0].tags, [])
    }

    // MARK: Helpers

    private func createActionArgs(_ transport: DeployTransport, index: Int) async throws -> [String: Any] {
        let bodies = await transport.bodies
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bodies[index])) as? [String: Any])
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        return try XCTUnwrap(params[1] as? [String: Any])
    }

    private func context(_ transport: DeployTransport) throws -> OneSatContext {
        let identity = try ActionVectors.identity()
        return OneSatContext(
            identity: identity,
            storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: transport),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }
}

private actor DeployTransport: AuthenticatedTransport {
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
