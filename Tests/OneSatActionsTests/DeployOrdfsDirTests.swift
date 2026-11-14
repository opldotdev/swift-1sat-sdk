import Foundation
import BSVCompat
import BSVCore
import BSVCrypto
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

/// Ports `packages/actions/test/deployOrdfsDir.test.ts` and checks the `createAction` request
/// the action sends (`DeployTransport` refuses `createAction`, so nothing is published), then
/// runs the whole publication against storage that accepts it (`PublishTransport`).
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

    func test_signedBLayoutErrorsComeBeforeTheBapLookup() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(
            try context(transport),
            DeployOrdfsDir.Request(files: files + files, writeMode: .b)
        )
        XCTAssertTrue(response.error?.contains("path collision") == true, "\(String(describing: response.error))")
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_signedBWithoutABapIdentityStopsBeforeCreateAction() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(
            try context(transport),
            DeployOrdfsDir.Request(files: files, writeMode: .b)
        )
        XCTAssertEqual(
            response.error,
            "No BAP identity published — cannot resolve current signing key. Publish an identity before signing."
        )
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
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
        let args = try await createActionArgs(transport, index: 0)
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
        try assertAIPSigned(script, identity: identity)
    }

    func test_signedMixedPublishStartsWithASigmaAnchor() async throws {
        let transport = DeployTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let response = await DeployOrdfsDir.execute(try context(transport), DeployOrdfsDir.Request(files: files))
        XCTAssertNotNil(response.error)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "createAction"])
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

    // MARK: Success path (storage accepts createAction and processAction)

    func test_signedMixedPublishAnchorsSigmaAndPublishesSpendingTheAnchor() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let response = await DeployOrdfsDir.execute(
            try publishContext(transport),
            DeployOrdfsDir.Request(
                files: files + [OrdfsDirFile(path: "refs/b.md", content: Array("b".utf8), contentType: "text/markdown")],
                map: [("app", "test")]
            )
        )
        XCTAssertNil(response.error, response.error ?? "")
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "createAction", "processAction", "listOutputs", "createAction", "processAction"])

        let processed = await transport.processed
        XCTAssertEqual(processed.count, 2)
        let anchor = try XCTUnwrap(processed.first)
        let publish = try XCTUnwrap(processed.last)
        let anchorTxid = anchor.txid
        XCTAssertEqual(response.txid, publish.txid)
        XCTAssertEqual(response.manifestVout, 3)

        // The anchor is sent with the publish, not on its own.
        XCTAssertEqual(anchor.sendWith, [])
        XCTAssertFalse(anchor.isSendWith)
        XCTAssertEqual(publish.sendWith, [anchorTxid])
        XCTAssertTrue(publish.isSendWith)
        XCTAssertTrue(anchor.isNoSend)
        XCTAssertFalse(publish.isNoSend)
        XCTAssertFalse(anchor.isDelayed || publish.isDelayed)
        XCTAssertEqual(anchor.transaction.outputs[0].satoshis, 2)

        let creates = try createActions(await transport.bodies)
        XCTAssertEqual(creates.map { $0["description"] as? String }, ["Sigma anchor output", "Publish ord-fs directory"])
        let anchorOptions = try XCTUnwrap(creates[0]["options"] as? [String: Any])
        XCTAssertEqual(anchorOptions["noSend"] as? Bool, true)
        XCTAssertEqual(anchorOptions["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(anchorOptions["acceptDelayedBroadcast"] as? Bool, true)
        XCTAssertEqual(creates[0]["labels"] as? [String], [])
        let anchorOutputs = try XCTUnwrap(creates[0]["outputs"] as? [[String: Any]])
        XCTAssertEqual(anchorOutputs[0]["outputDescription"] as? String, "Sigma anchor")
        XCTAssertEqual(anchorOutputs[0]["tags"] as? [String], [])
        let anchorKeyID = try CustomInstructions.parse(
            try XCTUnwrap(anchorOutputs[0]["customInstructions"] as? String)
        ).keyID
        XCTAssertTrue(anchorKeyID.hasPrefix("anchor-"))
        let actionID = String(anchorKeyID.dropFirst("anchor-".count))

        let main = creates[1]
        let inputs = try XCTUnwrap(main["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(storageOutpoint(inputs[0]["outpoint"]), "\(anchorTxid).0")
        XCTAssertEqual(
            (inputs[0]["unlockingScriptLength"] as? NSNumber)?.intValue,
            Int(OneSatConstants.p2pkhUnlockingScriptLength)
        )
        XCTAssertEqual(inputs[0]["inputDescription"] as? String, "Sigma anchor")
        // The publish is not noSend: it goes out with the anchor in its sendWith batch.
        let options = try XCTUnwrap(main["options"] as? [String: Any])
        XCTAssertEqual(options["noSend"] as? Bool, false)
        XCTAssertEqual(main["isNoSend"] as? Bool, false)
        XCTAssertEqual(main["isSendWith"] as? Bool, true)
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, true)
        XCTAssertEqual(options["knownTxids"] as? [String], [anchorTxid])
        XCTAssertEqual(options["sendWith"] as? [String], [anchorTxid])
        // Storage reads noSendChange only on a noSend action, so the publish carries none.
        XCTAssertEqual(options["noSendChange"] as? [String], [])

        // The signed publish spends the anchor at input 0 (the SIGMA reference input), signed
        // with the anchor key, and storage's own funding after it.
        let tx = publish.transaction
        XCTAssertEqual(tx.inputs.count, 2)
        XCTAssertEqual(tx.inputs[0].previousOutput.description, "\(anchorTxid).0")
        XCTAssertNotEqual(tx.inputs[1].previousOutput.transactionID.displayHex, anchorTxid)
        let anchorKey = try P1SATKey.privateKey(identity: identity, keyID: anchorKeyID)
        let anchorUnlock = try tx.inputs[0].unlockingScript.operations(
            maximumPushDataByteCount: ActionScript.maximumByteCount
        )
        XCTAssertEqual(anchorUnlock.last?.pushedData, anchorKey.publicKey.compressedBytes)
        XCTAssertEqual(
            try ActionScript.payToPublicKeyHash(Address(publicKey: anchorKey.publicKey, network: .mainnet)).bytes,
            anchor.transaction.outputs[0].lockingScript.bytes
        )

        // Origins name the requested outputs in the signed transaction; change follows them.
        let requested = try XCTUnwrap(main["outputs"] as? [[String: Any]])
        XCTAssertEqual(requested.count, 4)
        XCTAssertEqual(tx.outputs.count, requested.count + 1)
        XCTAssertEqual(response.origins, requested.indices.map { "\(publish.txid)_\($0)" })
        for (index, output) in requested.enumerated() {
            XCTAssertEqual(tx.outputs[index].lockingScript.hex, output["lockingScript"] as? String)
            XCTAssertEqual(tx.outputs[index].satoshis, (output["satoshis"] as? NSNumber)?.uint64Value)
        }
        XCTAssertEqual(tx.outputs.prefix(4).map(\.satoshis), [0, 0, 0, 1])

        let root = tx.outputs[3].lockingScript
        XCTAssertEqual(try XCTUnwrap(Inscription.decode(root)).content, Array(#"{"a.md":"_0","refs":"_2"}"#.utf8))
        let creator = try assertSigmaSigned(root, anchorTxid: anchorTxid, identity: identity)
        // Manifest tags, then the action id the anchor key was named after, then `creator:`.
        XCTAssertEqual(
            requested[3]["tags"] as? [String],
            storageTags(["type:ord-fs/json", "origin", "id:\(actionID)_3", "creator:\(creator)"])
        )
        XCTAssertEqual(requested[3]["basket"] as? String, OneSatConstants.ordinalsBasket)
        XCTAssertEqual(requested[3]["outputDescription"] as? String, "manifest (ord-fs/json)")
        for output in requested.dropLast() {
            XCTAssertNil(output["basket"])
            XCTAssertEqual(output["tags"] as? [String], [])
        }
    }

    func test_rejectedBroadcastReportsNoTxidReturned() async throws {
        let transport = PublishTransport(sendWithStatus: "failed")
        let response = await DeployOrdfsDir.execute(
            try publishContext(transport),
            DeployOrdfsDir.Request(files: files)
        )
        XCTAssertEqual(response.error, "no-txid-returned")
        XCTAssertNil(response.txid)
        XCTAssertNil(response.origins)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["getCapabilities", "createAction", "processAction", "listOutputs", "createAction", "processAction"])
    }

    func test_signedMixedPublishWithoutMapSealsTheRootBehindOpReturn() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let response = await DeployOrdfsDir.execute(
            try publishContext(transport),
            DeployOrdfsDir.Request(files: files)
        )
        XCTAssertNil(response.error, response.error ?? "")
        let processed = await transport.processed
        XCTAssertEqual(processed.count, 2)
        let anchorTxid = processed[0].txid
        let publish = processed[1]
        XCTAssertEqual(response.txid, publish.txid)
        XCTAssertEqual(response.manifestVout, 1)
        XCTAssertEqual(response.origins, ["\(publish.txid)_0", "\(publish.txid)_1"])
        XCTAssertEqual(publish.transaction.inputs[0].previousOutput.description, "\(anchorTxid).0")
        _ = try assertSigmaSigned(publish.transaction.outputs[1].lockingScript, anchorTxid: anchorTxid, identity: identity)
    }

    func test_signedBPublishProcessesOneAIPSignedAction() async throws {
        let identity = try ActionVectors.identity()
        let transport = PublishTransport()
        let response = await DeployOrdfsDir.execute(
            try publishContext(transport),
            DeployOrdfsDir.Request(files: files, map: [("app", "test")], writeMode: .b)
        )
        XCTAssertNil(response.error, response.error ?? "")
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction", "processAction"])

        let processed = await transport.processed
        let publish = try XCTUnwrap(processed.first)
        XCTAssertEqual(processed.count, 1)
        XCTAssertEqual(response.txid, publish.txid)
        XCTAssertEqual(response.manifestVout, 1)
        XCTAssertEqual(response.origins, ["\(publish.txid)_0", "\(publish.txid)_1"])
        XCTAssertEqual(publish.sendWith, [])
        XCTAssertFalse(publish.isSendWith)

        let creates = try createActions(await transport.bodies)
        XCTAssertEqual(creates.count, 1)
        XCTAssertTrue((creates[0]["inputs"] as? [Any] ?? []).isEmpty)
        let options = try XCTUnwrap(creates[0]["options"] as? [String: Any])
        XCTAssertNotEqual(options["noSend"] as? Bool, true)
        XCTAssertEqual(options["sendWith"] as? [String], [])
        let requested = try XCTUnwrap(creates[0]["outputs"] as? [[String: Any]])
        XCTAssertNil(requested[1]["basket"])

        let tx = publish.transaction
        XCTAssertEqual(tx.outputs.count, requested.count + 1)
        for (index, output) in requested.enumerated() {
            XCTAssertEqual(tx.outputs[index].lockingScript.hex, output["lockingScript"] as? String)
        }
        XCTAssertEqual(tx.outputs.prefix(2).map(\.satoshis), [0, 0])
        let root = tx.outputs[1].lockingScript
        XCTAssertEqual(try XCTUnwrap(BTemplate.decode(root)).data, Array(#"{"a.md":"_0"}"#.utf8))
        try assertAIPSigned(root, identity: identity)
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

    private func bapKey(_ identity: PrivateKey) throws -> PrivateKey {
        try SigmaAssert.bapKey(identity)
    }

    /// Checks the trailing `| AIP BITCOIN_ECDSA <address> <signature>` against the BAP key.
    private func assertAIPSigned(_ script: Script, identity: PrivateKey) throws {
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
        XCTAssertEqual(recovered.compressedBytes, try bapKey(identity).publicKey.compressedBytes)
    }

    /// Checks the trailing `SIGMA BSM <address> <signature> 0` tape: the signature covers the
    /// script before its separator (`|` after existing `OP_RETURN` data, else `OP_RETURN`) bound
    /// to anchor input `anchorTxid.0`, and recovers to the BAP key. Returns the signing address.
    @discardableResult
    private func assertSigmaSigned(_ script: Script, anchorTxid: String, identity: PrivateKey) throws -> String {
        try SigmaAssert.sealed(script, anchorTxid: anchorTxid, identity: identity)
    }

    private func createActions(_ bodies: [[UInt8]]) throws -> [[String: Any]] {
        try bodies.compactMap { body in
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
            guard envelope["method"] as? String == "createAction" else { return nil }
            let params = try XCTUnwrap(envelope["params"] as? [Any])
            return try XCTUnwrap(params[1] as? [String: Any])
        }
    }

    private func publishContext(_ transport: PublishTransport) throws -> OneSatContext {
        let identity = try ActionVectors.identity()
        return OneSatContext(
            identity: identity,
            storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: transport),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }

    private func createActionArgs(_ transport: DeployTransport, index: Int) async throws -> [String: Any] {
        // The SIGMA publish asks storage for its action-batch capabilities first, so count only
        // the createAction calls.
        let envelopes = try await transport.bodies.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let creates = envelopes.filter { $0["method"] as? String == "createAction" }
        XCTAssertGreaterThan(creates.count, index)
        guard creates.indices.contains(index) else { return [:] }
        let params = try XCTUnwrap(creates[index]["params"] as? [Any])
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
