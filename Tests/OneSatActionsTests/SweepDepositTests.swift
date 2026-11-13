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

    /// TS `sweepDeposit` leaves OrdLock v2 front funding and cushions alone
    /// while their `hold:<ms>` tag has not lapsed, and sweeps them afterwards.
    func test_heldOutputsAreSkippedUntilTheHoldLapses() async throws {
        let instructions = try CustomInstructions(keyID: "ordlock-funding abc")
            .encoded(includeSelfCounterparty: true)
        let now: UInt64 = 1_800_000_000_000
        func listResult() -> [String: Any] { [
            "totalOutputs": 1,
            "outputs": [
                [
                    "outpoint": ActionVectors.outpoint,
                    "satoshis": 1_000,
                    "spendable": true,
                    "customInstructions": instructions,
                    "tags": [
                        OneSatConstants.ordlockFundingTag,
                        OneSatConstants.depositHoldTag(untilMilliseconds: now + 1),
                    ],
                ],
            ],
        ] }
        let held = ScriptedTransport(listResult: listResult())
        let heldResult = try await SweepDeposit.execute(try context(transport: held), nowMilliseconds: now)
        XCTAssertEqual(heldResult.swept, 0)
        let heldMethods = await held.methods
        XCTAssertEqual(heldMethods, ["listOutputs"])
        let listBody = await held.bodies[0]
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(listBody)) as? [String: Any]
        )
        let params = try XCTUnwrap(envelope["params"] as? [Any])
        let args = try XCTUnwrap(params[1] as? [String: Any])
        XCTAssertEqual(args["includeTags"] as? Bool, true)

        let lapsed = ScriptedTransport(listResult: listResult())
        _ = try? await SweepDeposit.execute(try context(transport: lapsed), nowMilliseconds: now + 1)
        let lapsedMethods = await lapsed.methods
        XCTAssertEqual(lapsedMethods, ["listOutputs", "createAction"])
    }

    func test_holdTagHelpers() {
        XCTAssertEqual(OneSatConstants.depositHoldTag(untilMilliseconds: 42), "hold:42")
        XCTAssertEqual(OneSatConstants.depositHoldUntil(["x", "hold:5", "hold:9", "hold:bad"]), 9)
        XCTAssertNil(OneSatConstants.depositHoldUntil(nil))
        XCTAssertTrue(OneSatConstants.isDepositHeld(["hold:10"], nowMilliseconds: 9))
        XCTAssertFalse(OneSatConstants.isDepositHeld(["hold:10"], nowMilliseconds: 10))
        XCTAssertFalse(OneSatConstants.isDepositHeld(["ordlock-funding"], nowMilliseconds: 0))
        XCTAssertEqual(OneSatConstants.ordlockFundingHoldMilliseconds, 300_000)
    }

    /// TS `ordlockPurchase.test.ts` "reuses a held output": an expired hold and an
    /// untagged deposit output are never offered as OrdLock v2 front funding.
    func test_ordLockV2FrontFundingOnlyOffersOutputsStillHeld() async throws {
        let now: UInt64 = 1_800_000_000_000
        func output(_ vout: Int, keyID: String, tags: [String]) throws -> [String: Any] {
            [
                "outpoint": String(repeating: "ab", count: 32) + ".\(vout)",
                "satoshis": 9_000,
                "spendable": true,
                "customInstructions": try CustomInstructions(keyID: keyID)
                    .encoded(includeSelfCounterparty: true),
                "tags": tags,
            ]
        }
        let transport = ScriptedTransport(listResult: [
            "totalOutputs": 3,
            "outputs": [
                try output(0, keyID: "ordlock-funding earlier", tags: [
                    OneSatConstants.ordlockFundingTag,
                    OneSatConstants.depositHoldTag(untilMilliseconds: now + 60_000),
                ]),
                try output(1, keyID: "ordlock-funding stale", tags: [
                    OneSatConstants.depositHoldTag(untilMilliseconds: now - 1),
                ]),
                try output(2, keyID: "deposit 1", tags: []),
            ],
        ])
        let held = try await OrdLockV2Purchase.loadHeldFunding(
            try context(transport: transport), excluding: [], nowMilliseconds: now
        )
        XCTAssertEqual(held.candidates.map(\.outpoint.description), [String(repeating: "ab", count: 32) + ".0"])
        XCTAssertEqual(held.candidates.first?.instructions.keyID, "ordlock-funding earlier")
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
