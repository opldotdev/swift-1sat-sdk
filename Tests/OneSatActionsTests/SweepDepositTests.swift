import Foundation
import BSVCore
import BSVKeys
import BSVWallet
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class SweepDepositTests: XCTestCase {
    func test_emptyBasketDoesNotCreateAnAction() async throws {
        let transport = ScriptedTransport(
            listResult: ["totalOutputs": 0, "outputs": []]
        )
        let ctx = try context(transport: transport)
        let result = try await SweepDeposit.execute(ctx)
        XCTAssertEqual(result.swept, 0)
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
    }

    func test_seededBasketSendsDepositInputsOnCreateAction() async throws {
        let instructions = try CustomInstructions(keyID: "1sat 0").encoded()
        let transport = ScriptedTransport(
            listResult: [
                "totalOutputs": 1,
                "outputs": [
                    [
                        "outpoint": ActionVectors.outpoint,
                        "satoshis": 1_000,
                        "spendable": true,
                        "customInstructions": instructions,
                    ],
                ],
            ]
        )
        let ctx = try context(transport: transport)
        _ = try? await SweepDeposit.execute(ctx)

        let bodies = await transport.bodies
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs", "createAction"])
        XCTAssertEqual(bodies.count, 2)

        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(bodies[1])) as? [String: Any]
        )
        XCTAssertEqual(envelope["method"] as? String, "createAction")
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        XCTAssertGreaterThanOrEqual(params.count, 2)
        let args = try XCTUnwrap(params[1] as? [String: Any])
        XCTAssertEqual(args["description"] as? String, "Sweep deposit funds")

        let inputs = try XCTUnwrap(args["inputs"] as? [[String: Any]])
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0]["outpoint"] as? String, ActionVectors.outpoint)
        XCTAssertEqual(inputs[0]["inputDescription"] as? String, "Deposit sweep")
        XCTAssertEqual(
            (inputs[0]["unlockingScriptLength"] as? NSNumber)?.uint32Value,
            OneSatConstants.p2pkhUnlockingScriptLength
        )
        XCTAssertEqual(OneSatConstants.p2pkhUnlockingScriptLength, 108)

        let outputs = try XCTUnwrap(args["outputs"] as? [Any])
        XCTAssertTrue(outputs.isEmpty)

        let options = try XCTUnwrap(args["options"] as? [String: Any])
        XCTAssertEqual(options["randomizeOutputs"] as? Bool, false)
        XCTAssertEqual(options["acceptDelayedBroadcast"] as? Bool, false)
    }

    func test_outputsWithoutKeyIDAreSkipped() async throws {
        let transport = ScriptedTransport(
            listResult: [
                "totalOutputs": 1,
                "outputs": [
                    [
                        "outpoint": ActionVectors.outpoint,
                        "satoshis": 1_000,
                        "spendable": true,
                        "customInstructions": "{}",
                    ],
                ],
            ]
        )
        let ctx = try context(transport: transport)
        let result = try await SweepDeposit.execute(ctx)
        XCTAssertEqual(result.swept, 0)
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
    }

    private func context(transport: ScriptedTransport) throws -> OneSatContext {
        let identity = try ActionVectors.identity()
        return OneSatContext(
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
