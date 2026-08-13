import Foundation
import BSVCompat
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class IdentityFlowTests: XCTestCase {
    /// TS `KeyDeriver` + `Hash.ripemd160(toHex(sha256(address)))` for `ActionVectors.identity()`.
    private let expectedBapId = "qqeHr1tWxwzvAkd2iUsi8zRuE5S"

    func test_signingKeyIDFormat() {
        XCTAssertEqual(Identity.signingKeyID(0), "identity-0")
        XCTAssertEqual(Identity.signingKeyID(1), "identity-1")
    }

    func test_computeBapIdMatchesTheTypeScriptVector() throws {
        let identity = try ActionVectors.identity()
        XCTAssertEqual(try Identity.computeBapId(identity: identity), expectedBapId)
        XCTAssertEqual(try Identity.computeBapId(identity: identity), expectedBapId)
    }

    func test_aipRoundTripRecoversIdentityZeroAddress() throws {
        let identity = try ActionVectors.identity()
        let rootKey = try derivedKey(identity, index: 0)
        let declare = try derivedAddress(identity, index: 1).description
        let unsigned = try idScript(bapId: expectedBapId, declareAddress: declare)
        let signed = try AIPSign.apply(to: unsigned, signingKey: rootKey)
        let message = try AIPSign.messageBuffer(unsigned)
        let operations = try signed.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        XCTAssertGreaterThanOrEqual(operations.count, 5)
        let tail = operations.suffix(5)
        XCTAssertEqual(tail[tail.startIndex].pushedData, Array("|".utf8))
        XCTAssertEqual(tail[tail.startIndex + 1].pushedData, Array(OneSatConstants.aipPrefix.utf8))
        XCTAssertEqual(tail[tail.startIndex + 2].pushedData, Array(OneSatConstants.aipAlgorithm.utf8))
        let addressBytes = try XCTUnwrap(tail[tail.startIndex + 3].pushedData)
        XCTAssertEqual(
            String(bytes: addressBytes, encoding: .utf8),
            try derivedAddress(identity, index: 0).description
        )
        let signatureBytes = try XCTUnwrap(tail[tail.startIndex + 4].pushedData)
        let signature = try BitcoinMessageSignature(signatureBytes)
        let recovered = try signature.recoverPublicKey(message: message)
        XCTAssertEqual(
            Address(publicKey: recovered, network: .mainnet, compressed: true).description,
            try derivedAddress(identity, index: 0).description
        )
    }

    func test_pickNewestAliasOrdering() throws {
        XCTAssertNil(Identity.pickNewestAlias([]))

        let highest = try Identity.pickNewestAlias([
            aliasOutput("a", id: "A", publishedAt: 1_000),
            aliasOutput("b", id: "B", publishedAt: 3_000),
            aliasOutput("c", id: "C", publishedAt: 2_000),
        ])
        XCTAssertEqual(highest?.winner.id, "B")
        XCTAssertEqual(highest?.winner.publishedAt, 3_000)
        XCTAssertEqual(highest?.losers.map { $0.id }, ["C", "A"])

        let taggedBeatsUntagged = try Identity.pickNewestAlias([
            aliasOutput("b", id: "B", publishedAt: nil),
            aliasOutput("a", id: "A", publishedAt: 500),
        ])
        XCTAssertEqual(taggedBeatsUntagged?.winner.id, "A")
        XCTAssertEqual(taggedBeatsUntagged?.losers.first?.id, "B")

        let tie = try Identity.pickNewestAlias([
            aliasOutput("b", id: "B", publishedAt: 1_000),
            aliasOutput("a", id: "A", publishedAt: 1_000),
        ])
        XCTAssertEqual(tie?.winner.id, "A")
    }

    func test_publishSendsOneZeroSatBapOutput() async throws {
        let transport = ScriptedTransport(listResult: ["totalOutputs": 0, "outputs": []])
        let identity = try ActionVectors.identity()
        let ctx = try context(identity: identity, transport: transport)
        _ = await Identity.publish(ctx)

        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction"])
        let bodies = await transport.bodies
        XCTAssertEqual(bodies.count, 2)

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bodies[1])) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        let args = try XCTUnwrap(params[1] as? [String: Any])
        XCTAssertEqual(args["description"] as? String, "BAP identity publication")
        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, false)

        let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]])
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual((outputs[0]["satoshis"] as? NSNumber)?.uint64Value, 0)
        XCTAssertEqual(outputs[0]["outputDescription"] as? String, "BAP ID")
        XCTAssertEqual(outputs[0]["basket"] as? String, "bap")
        XCTAssertEqual(
            outputs[0]["customInstructions"] as? String,
            "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-1\"}"
        )
        let tags = try XCTUnwrap(outputs[0]["tags"] as? [String])
        XCTAssertTrue(tags.contains("type:id"))
        XCTAssertTrue(tags.contains("bapId:\(expectedBapId)"))
        XCTAssertTrue(tags.contains("seq:1"))

        let scriptHex = try XCTUnwrap(outputs[0]["lockingScript"] as? String)
        let script = try Script(hex: scriptHex, maximumByteCount: ActionScript.maximumByteCount)
        let bitcom = try XCTUnwrap(BitCom.decode(script))
        let bap = try XCTUnwrap(BAPTemplate.decode(bitcom))
        XCTAssertEqual(bap.type, .id)
        XCTAssertEqual(bap.idKey, expectedBapId)
        try assertValidAIP(on: script, identity: identity)
    }

    func test_publishRefusesWhenIdentityAlreadyExists() async throws {
        let transport = ScriptedTransport(
            listResult: [
                "totalOutputs": 1,
                "outputs": [
                    [
                        "outpoint": ActionVectors.outpoint,
                        "satoshis": 0,
                        "spendable": true,
                        "tags": ["type:id"],
                    ],
                ],
            ]
        )
        let identity = try ActionVectors.identity()
        let result = await Identity.publish(try context(identity: identity, transport: transport))
        XCTAssertEqual(result.error, "identity-exists: already published")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
    }

    private func assertValidAIP(on script: Script, identity: PrivateKey) throws {
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
            try derivedAddress(identity, index: 0).description
        )
    }

    private func idScript(bapId: String, declareAddress: String) throws -> Script {
        var script = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        try script.append(.zero, maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.append(.return, maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.appendPushData(
            Array(OneSatConstants.bapBitcomAddress.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try script.appendPushData(Array("ID".utf8), maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.appendPushData(Array(bapId.utf8), maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.appendPushData(
            Array(declareAddress.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        return script
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

    private func aliasOutput(_ prefix: Character, id: String, publishedAt: Int64?) throws -> WalletOutput {
        var tags = ["type:alias", "id:\(id)"]
        if let publishedAt {
            tags.append("publishedAt:\(publishedAt)")
        }
        let txid = String(repeating: prefix, count: 64)
        return try WalletOutput(
            satoshis: 0,
            spendable: true,
            tags: tags,
            outpoint: try Outpoint("\(txid).0")
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
