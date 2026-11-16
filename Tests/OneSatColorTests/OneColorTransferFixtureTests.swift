import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import OneSatTemplates
@testable import OneSatColor

/// `OneColorActions.transfer` against `Fixtures/onecolor-transfer.json`: the createAction arguments
/// the published BRC-207 module 0.2.3 forwards (Bun, no profiles) for a `p color plan` transfer
/// whose requested outputs carry the tokens, as skein-amm's pool deploy sends it, over the same
/// held outputs: A 30, B 50, C 20, D 50 (not admitted until resubmitted), E 80 (custody names
/// another asset, so unreadable) and F 40 (no suffix tag). Selection, change, labels, input BEEF,
/// overlay calls and every refusal are compared case by case.
final class OneColorTransferFixtureTests: XCTestCase {
    func test_transferMatchesTheModule() async throws {
        let root = try colorFixture("onecolor-transfer")
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])
        let identity = try PrivateKey(try Hex.decode(try XCTUnwrap(meta["identityHex"] as? String), maximumDecodedByteCount: 32))
        let deployHex = try XCTUnwrap(meta["deployTx"] as? String)
        let deploy = try Transaction(bytes: try Hex.decode(deployHex, maximumDecodedByteCount: deployHex.count / 2), limits: harnessTxLimits)
        let deployID = try deploy.transactionID(limits: harnessTxLimits).displayHex
        let assetID = try ColorAssetID(try XCTUnwrap(meta["assetId"] as? String))
        let topic = try XCTUnwrap(meta["topic"] as? String)
        XCTAssertEqual(ColorIdentifiers.topic(assetID), topic)
        XCTAssertEqual(ColorIdentifiers.basket(assetID, role: .value), meta["valueBasket"] as? String)
        let description = try XCTUnwrap(meta["description"] as? String)
        let labels = try XCTUnwrap(meta["labels"] as? [String])
        let callerLabels = labels.filter { !$0.hasPrefix(ColorPlan.labelPrefix) }
        XCTAssertEqual(callerLabels, ["amm-pool-deploy"])

        var sources: [String: Transaction] = [:]
        for source in try XCTUnwrap(meta["sources"] as? [[String: Any]]) {
            let hex = try XCTUnwrap(source["hex"] as? String)
            let transaction = try Transaction(bytes: try Hex.decode(hex, maximumDecodedByteCount: hex.count / 2), limits: harnessTxLimits)
            XCTAssertEqual(try transaction.transactionID(limits: harnessTxLimits).displayHex, source["txid"] as? String)
            sources[try XCTUnwrap(source["txid"] as? String)] = transaction
        }
        let held = try XCTUnwrap(meta["held"] as? [[String: Any]])
        XCTAssertEqual(held.compactMap { $0["name"] as? String }, ["A", "B", "C", "D", "E", "F"])

        let cases = try XCTUnwrap(root["cases"] as? [String: [String: Any]])
        XCTAssertEqual(cases.count, 10)
        for (name, fixture) in cases.sorted(by: { $0.key < $1.key }) {
            let world = try ColorWorld()
            let party = try ColorWorld.party(identity, overlay: world.overlay, server: world.server, handles: world.alice.ctx.handles)
            await world.overlay.admit(try graph([deploy]).serialized(limits: harnessBEEFLimits), outpoint: "\(deployID).0", vout: 0)
            for entry in held {
                let row = try XCTUnwrap(entry["row"] as? [String: Any])
                let outpoint = try Outpoint(try XCTUnwrap(row["outpoint"] as? String))
                let source = try XCTUnwrap(sources[outpoint.transactionID.displayHex])
                XCTAssertEqual(Hex.encode(source.outputs[Int(outpoint.outputIndex)].lockingScript.bytes), row["lockingScript"] as? String)
                try await party.wallet.hold(
                    source, vout: outpoint.outputIndex, basket: try XCTUnwrap(row["basket"] as? String),
                    customInstructions: try await ColorMetadata.encrypt(try XCTUnwrap(row["customInstructions"] as? String), identity: identity),
                    tags: try XCTUnwrap(row["tags"] as? [String])
                )
                if entry["admitted"] as? Bool == true {
                    await world.overlay.admit(try graph([source]).serialized(limits: harnessBEEFLimits), outpoint: outpoint.description, vout: outpoint.outputIndex)
                }
            }

            let requested = try XCTUnwrap(fixture["requested"] as? [[String: Any]]).map { output in
                let script = try XCTUnwrap(output["lockingScript"] as? String)
                return try WalletCreateActionOutput(
                    lockingScript: try Hex.decode(script, maximumDecodedByteCount: script.count / 2),
                    satoshis: try XCTUnwrap((output["satoshis"] as? NSNumber)?.uint64Value),
                    outputDescription: try XCTUnwrap(output["outputDescription"] as? String),
                    basket: output["basket"] as? String,
                    tags: output["tags"] as? [String] ?? []
                )
            }
            let theirOutputs = fixture["outputs"] as? [[String: Any]] ?? []
            // The module's change custody, so the change output's key is the module's.
            let changeCustody = try theirOutputs.dropFirst(requested.count).first.map {
                try ColorCustody.parse(try XCTUnwrap($0["customInstructions"] as? String))
            }
            let result = await OneColorActions.transfer(
                party.ctx, assetID: assetID, outputs: requested, description: description, labels: callerLabels,
                changeCustody: changeCustody
            )
            let submissions = await world.overlay.submissions
            let theirSubmissions = try XCTUnwrap(fixture["submissions"] as? [[String]])
            let requests = await party.wallet.createRequests

            if let error = fixture["error"] as? String {
                XCTAssertEqual(result.error, error, name)
                XCTAssertNil(result.txid, name)
                XCTAssertTrue(requests.isEmpty, name)
                XCTAssertEqual(submissions, theirSubmissions, name)
                continue
            }
            XCTAssertNil(result.error, "\(name): \(result.error ?? "")")
            XCTAssertTrue(result.submitted, name)
            // The module's resubmissions while selecting, then this wallet's submit of the transfer.
            XCTAssertEqual(Array(submissions.dropLast()), theirSubmissions, name)
            XCTAssertEqual(submissions.last, [topic], name)

            let request = try XCTUnwrap(requests.first, name)
            XCTAssertEqual(requests.count, 1, name)
            XCTAssertEqual(request.description, description, name)
            XCTAssertEqual(request.labels, labels, name)
            XCTAssertEqual(request.options?.randomizeOutputs, false, name)

            // Inputs: the module's selection, in its order.
            let theirInputs = try XCTUnwrap(fixture["inputs"] as? [[String: Any]])
            let inputs = try XCTUnwrap(request.inputs, name)
            XCTAssertEqual(inputs.count, theirInputs.count, name)
            for (mine, theirs) in zip(inputs, theirInputs) {
                XCTAssertEqual(mine.outpoint.description, theirs["outpoint"] as? String, name)
                XCTAssertEqual(mine.inputDescription, theirs["inputDescription"] as? String, name)
                XCTAssertEqual(mine.unlocking, .scriptLength(try XCTUnwrap(theirs["unlockingScriptLength"] as? UInt32)), name)
            }
            let beefTxids = try XCTUnwrap(request.inputBEEF, name).transactions.compactMap {
                try $0.transaction?.transactionID(limits: harnessTxLimits).displayHex
            }
            XCTAssertEqual(beefTxids.sorted(), fixture["inputBEEFTxids"] as? [String], name)

            // Outputs: the requested ones as given, then the module's token change.
            let outputs = try XCTUnwrap(request.outputs, name)
            XCTAssertEqual(outputs.count, theirOutputs.count, name)
            for (index, (output, theirs)) in zip(outputs, theirOutputs).enumerated() {
                let label = "\(name) output \(index)"
                XCTAssertEqual(Hex.encode(output.lockingScript), theirs["lockingScript"] as? String, label)
                XCTAssertEqual(output.satoshis, (theirs["satoshis"] as? NSNumber)?.uint64Value, label)
                XCTAssertEqual(output.outputDescription, theirs["outputDescription"] as? String, label)
                XCTAssertEqual(output.basket, theirs["basket"] as? String, label)
                if index < requested.count {
                    XCTAssertEqual(output.tags, theirs["tags"] as? [String] ?? [], label)
                    XCTAssertNil(output.customInstructions, label)
                    continue
                }
                let plaintext = await ColorMetadata.decrypt(try XCTUnwrap(output.customInstructions, label), identity: identity)
                XCTAssertEqual(plaintext, theirs["customInstructions"] as? String, label)
                assertOneSuffixTag(output.tags, label)
                assertOneSuffixTag(try XCTUnwrap(theirs["tags"] as? [String]), label)
                XCTAssertFalse(inputs.isEmpty, label)
            }
            let txid = try XCTUnwrap(result.txid, name)
            XCTAssertEqual(result.changeOutpoint, theirOutputs.count > requested.count ? "\(txid).\(requested.count)" : nil, name)
            XCTAssertNotNil(result.tx, name)
        }
    }

    /// The change a transfer keeps is selectable by the next one: it carries its own suffix tag,
    /// which the next selection lists its source transaction by.
    func test_transferChangeFundsTheNextTransfer() async throws {
        let world = try ColorWorld()
        let deployed = await OneColorActions.deploy(world.alice.ctx, amount: 100, symbol: "TOK")
        XCTAssertNil(deployed.error)
        let assetID = try ColorAssetID(try XCTUnwrap(deployed.assetID))
        let pool = try OneColor.value(tokenID: assetID.description, amount: 60, lock: .publicKeyHash([UInt8](repeating: 7, count: 20))).lock()
        // The deploy itself is the asset's first value output; it is spent here.
        let first = await OneColorActions.transfer(
            world.alice.ctx, assetID: assetID,
            outputs: [try WalletCreateActionOutput(lockingScript: pool.bytes, satoshis: 1_000, outputDescription: "pool")],
            description: "first"
        )
        XCTAssertNil(first.error, first.error ?? "")
        let change = try XCTUnwrap(first.changeOutpoint)
        let found = await world.alice.wallet.record(change)
        let record = try XCTUnwrap(found)
        assertOneSuffixTag(record.tags)

        let rest = try OneColor.value(tokenID: assetID.description, amount: 40, lock: .publicKeyHash([UInt8](repeating: 8, count: 20))).lock()
        let second = await OneColorActions.transfer(
            world.alice.ctx, assetID: assetID,
            outputs: [try WalletCreateActionOutput(lockingScript: rest.bytes, satoshis: 1, outputDescription: "rest")],
            description: "second"
        )
        XCTAssertNil(second.error, second.error ?? "")
        XCTAssertTrue(second.submitted)
        XCTAssertNil(second.changeOutpoint)
        let requests = await world.alice.wallet.createRequests
        XCTAssertEqual(requests.last?.inputs?.map(\.outpoint.description), [change])
        let balance = try await OneColorActions.balance(world.alice.ctx, assetID: assetID)
        XCTAssertEqual(balance, 0)
    }

    func test_transferRefusesColorAndHandoffLabelsAndNeedsAnOverlay() async throws {
        let world = try ColorWorld()
        let assetID = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let script = try OneColor.value(tokenID: assetID.description, amount: 1, lock: .publicKeyHash([UInt8](repeating: 7, count: 20))).lock()
        let outputs = [try WalletCreateActionOutput(lockingScript: script.bytes, satoshis: 1, outputDescription: "x")]
        let colorLabel = await OneColorActions.transfer(world.alice.ctx, assetID: assetID, outputs: outputs, description: "x", labels: ["p color plan 0 1 00"])
        XCTAssertEqual(colorLabel.error, "BRC-207: unknown p color label")
        let handoff = await OneColorActions.transfer(world.alice.ctx, assetID: assetID, outputs: outputs, description: "x", labels: ["p nosend expiry seconds 600"])
        XCTAssertNotNil(handoff.error)
        let offline = await OneColorActions.transfer(world.withoutOverlay(world.alice), assetID: assetID, outputs: outputs, description: "x")
        XCTAssertEqual(offline.error, "BRC-207: overlay-required")
        let requests = await world.alice.wallet.createRequests
        XCTAssertTrue(requests.isEmpty)
    }
}
