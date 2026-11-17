import BSVCore
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import Foundation
import OneSatSweep
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// `AssetSweep.bsv` against `@1sat/actions` `sweepBsv` (`sweep/index.ts`).
final class AssetSweepBsvTests: XCTestCase {
    private let limits = WalletTransactionLimits.standard

    func test_fullSweepHasNoExplicitOutputsSoTheWalletChangeTakesIt() throws {
        let fixture = try fixture()
        let plan = try ready(AssetSweep.bsvPlan(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: nil))
        XCTAssertTrue(plan.outputs.isEmpty)
        XCTAssertEqual(plan.description, "Sweep 2 legacy BSV UTXOs")
        XCTAssertEqual(plan.inputs.map(\.outpoint.description), fixture.inputs.map(\.outpoint))
        XCTAssertEqual(plan.inputs.map(\.inputDescription), fixture.inputs.map { "Legacy BSV \($0.outpoint)" })
        XCTAssertEqual(plan.inputs.map(\.sequenceNumber), [0xffff_ffff, 0xffff_ffff])
        for input in plan.inputs {
            guard case .scriptLength(let length) = input.unlocking else { return XCTFail("expected a length reservation") }
            XCTAssertEqual(length, OneSatConstants.p2pkhUnlockingScriptLength)
        }
        // An amount equal to the total is a full sweep.
        let all = try ready(AssetSweep.bsvPlan(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: 15_000))
        XCTAssertTrue(all.outputs.isEmpty)
    }

    func test_partialSweepReturnsTheRestToTheSourceAddress() throws {
        let fixture = try fixture()
        let plan = try ready(AssetSweep.bsvPlan(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: 4_000))
        XCTAssertEqual(plan.description, "Sweep 4000 sats from 2 legacy BSV UTXOs")
        XCTAssertEqual(plan.outputs.count, 1)
        XCTAssertEqual(plan.outputs[0].satoshis, 11_000)
        XCTAssertEqual(plan.outputs[0].lockingScript, fixture.sourceScript.bytes)
        XCTAssertEqual(plan.outputs[0].outputDescription, "Return to legacy address")
    }

    func test_theThreeTypeScriptErrors() async throws {
        let fixture = try fixture()
        let none = await AssetSweep.bsv(fixture.ctx, inputs: [], inputBEEF: fixture.beef)
        XCTAssertEqual(none.error, "no-inputs")
        let zero = await AssetSweep.bsv(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: 0)
        XCTAssertEqual(zero.error, "invalid-amount")
        let over = await AssetSweep.bsv(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: 15_001)
        XCTAssertEqual(over.error, "insufficient-funds")
        let bodies = await fixture.transport.bodies
        XCTAssertTrue(bodies.isEmpty, "nothing reaches the wallet on a refused request")
    }

    /// The `createAction` on the wire: every legacy input, no outputs, outputs kept in order.
    func test_theWalletRequestCarriesTheInputsAndNoOutputs() async throws {
        let fixture = try fixture()
        _ = await AssetSweep.bsv(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef)
        let bodies = await fixture.transport.bodies
        let create = try XCTUnwrap(bodies.compactMap { body -> [String: Any]? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  object["method"] as? String == "createAction",
                  let params = object["params"] as? [Any], params.count >= 2
            else { return nil }
            return params[1] as? [String: Any]
        }.first)
        XCTAssertEqual((create["inputs"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((create["outputs"] as? [Any])?.count ?? 0, 0)
    }

    /// The signer unlocks every legacy input with its own key and leaves the wallet's input alone.
    func test_signingCoversEveryLegacyInput() throws {
        let fixture = try fixture()
        let plan = try ready(AssetSweep.bsvPlan(fixture.ctx, inputs: fixture.inputs, inputBEEF: fixture.beef, amount: nil))
        let empty = try Script(bytes: [], maximumByteCount: 10)
        var inputs = plan.inputs.map { TransactionInput(previousOutput: $0.outpoint, unlockingScript: empty) }
        inputs.append(TransactionInput(
            previousOutput: Outpoint(transactionID: try TransactionID(displayHex: String(repeating: "22", count: 32)), outputIndex: 0),
            unlockingScript: empty,
            sourceOutput: TransactionOutput(satoshis: 100, lockingScript: fixture.sourceScript)
        ))
        let spend = Transaction(version: 1, inputs: inputs, outputs: [
            TransactionOutput(satoshis: 14_900, lockingScript: fixture.sourceScript),
        ], lockTime: 0)
        let spends = try AssetSweep.signLegacyInputs(transaction: spend, keysByOutpoint: plan.keysByOutpoint, inputBEEF: fixture.beef)
        XCTAssertEqual(Set(spends.keys), [0, 1])
        for index in 0..<2 {
            let unlock = try XCTUnwrap(spends[UInt32(index)])
            XCTAssertLessThanOrEqual(unlock.bytes.count, Int(OneSatConstants.p2pkhUnlockingScriptLength))
            let source = fixture.source.outputs[index]
            var tx = spend
            tx.inputs[index].unlockingScript = unlock
            tx.inputs[index].sourceOutput = source
            let result = try ScriptInterpreter.execute(
                unlockingScript: unlock,
                lockingScript: source.lockingScript,
                configuration: ScriptExecutionConfiguration(
                    era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                    resourceLimits: .standard
                ),
                context: ScriptExecutionContext(
                    transaction: tx, inputIndex: index, spentOutput: source, transactionLimits: limits
                )
            )
            XCTAssertTrue(result.stack.last?.contains { $0 != 0 } ?? false, "input \(index) verifies")
        }
    }

    func test_batchHelpers() {
        XCTAssertEqual(AssetSweep.batchSize, 25)
        XCTAssertEqual(AssetSweep.batches(Array(0..<26)).map(\.count), [25, 1])
        XCTAssertEqual(AssetSweep.batches(Array(0..<60)).map(\.count), [25, 25, 10])
        XCTAssertTrue(AssetSweep.batches([Int]()).isEmpty)

        XCTAssertTrue(AssetSweep.isListed(events: ["ordlock2"]))
        XCTAssertTrue(AssetSweep.isListed(events: ["list:500"]))
        XCTAssertFalse(AssetSweep.isListed(events: ["ordlock", "1sat"]), "v1 is not a listing (TS dropped it)")
        let items: [(Int, [String])] = [(0, []), (1, ["ordlock2"]), (2, []), (3, ["list:9"])]
        XCTAssertEqual(AssetSweep.listedBatches(items, events: \.1).map { $0.map(\.0) }, [[1], [3], [0, 2]])
        XCTAssertEqual(AssetSweep.listedBatches([(0, [String]()), (1, [])], events: \.1).map { $0.map(\.0) }, [[0, 1]])
    }

    // MARK: - Fixture

    private struct Fixture {
        let ctx: OneSatContext
        let transport: Capture
        let source: Transaction
        let sourceScript: Script
        let beef: BEEF
        let inputs: [AssetSweep.FundingInput]
    }

    private func ready(_ result: AssetSweep.BsvPlanResult) throws -> AssetSweep.BsvPlan {
        guard case .ready(let plan) = result else {
            XCTFail("expected a plan, got \(result)")
            throw PlanFailed()
        }
        return plan
    }

    private func fixture() throws -> Fixture {
        let key = try ActionVectors.identity()
        let address = Address(publicKey: key.publicKey, network: .mainnet)
        let script = try ActionScript.payToPublicKeyHash(address)
        let source = Transaction(version: 1, inputs: [], outputs: [
            TransactionOutput(satoshis: 10_000, lockingScript: script),
            TransactionOutput(satoshis: 5_000, lockingScript: script),
        ], lockTime: 0)
        let txid = try source.transactionID(limits: limits).displayHex
        let transport = Capture()
        let ctx = OneSatContext(
            identity: key,
            storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: transport),
            auth: AuthID(identityKey: Hex.encode(key.publicKey.compressedBytes))
        )
        return Fixture(
            ctx: ctx, transport: transport, source: source, sourceScript: script,
            beef: try BEEF(merklePaths: [], transactions: [.raw(source)], limits: WalletBEEFLimits.standard),
            inputs: [
                AssetSweep.FundingInput(outpoint: "\(txid).0", satoshis: 10_000, lockingScript: script.bytes, key: key),
                AssetSweep.FundingInput(outpoint: "\(txid).1", satoshis: 5_000, lockingScript: script.bytes, key: key),
            ]
        )
    }
}

private struct PlanFailed: Error {}

private actor Capture: AuthenticatedTransport {
    private(set) var bodies: [[UInt8]] = []

    func send(
        method: String, path: String, query: String?, headers: [String: String], body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        if let reply = ActiveStorageFixture.reply(to: body) { return reply }
        bodies.append(body ?? [])
        throw AuthTransportError.notImplemented("offline")
    }
}
