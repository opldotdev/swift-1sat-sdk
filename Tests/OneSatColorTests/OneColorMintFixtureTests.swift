import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
@testable import OneSatColor

/// `OneColorActions.mint` against `Fixtures/onecolor-mint.json`: the same authority deploy held by
/// the same key, the same new custodies, and the request the published BRC-207 module 0.2.3
/// forwards for that mint (Bun), compared field by field.
final class OneColorMintFixtureTests: XCTestCase {
    func test_mintRequestIsWhatTheModuleForwards() async throws {
        let root = try colorFixture("onecolor-mint")
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])
        let identity = try PrivateKey(try Hex.decode(try XCTUnwrap(meta["identityHex"] as? String), maximumDecodedByteCount: 32))
        let deployHex = try XCTUnwrap(meta["deployTx"] as? String)
        let deploy = try Transaction(bytes: try Hex.decode(deployHex, maximumDecodedByteCount: deployHex.count / 2), limits: harnessTxLimits)
        let deployID = try deploy.transactionID(limits: harnessTxLimits)
        let assetID = try ColorAssetID(try XCTUnwrap(meta["assetId"] as? String))
        XCTAssertEqual(assetID, try ColorAssetID(txid: deployID.displayHex, vout: 0))
        let baskets = try XCTUnwrap(meta["baskets"] as? [String: String])
        XCTAssertEqual(ColorIdentifiers.basket(assetID, role: .value), baskets["value"])
        XCTAssertEqual(ColorIdentifiers.basket(assetID, role: .authority), baskets["authority"])
        XCTAssertEqual(ColorIdentifiers.topic(assetID), meta["topic"] as? String)

        func custody(_ key: String, _ asset: ColorAssetSelector, _ owner: String) throws -> ColorCustody {
            let pair = try XCTUnwrap(meta[key] as? [String: String])
            return try ColorCustody(
                asset: asset, derivationPrefix: try XCTUnwrap(pair["derivationPrefix"]),
                derivationSuffix: try XCTUnwrap(pair["derivationSuffix"]), senderIdentityKey: owner
            )
        }

        let cases = try XCTUnwrap(root["cases"] as? [String: [String: Any]])
        XCTAssertEqual(cases.count, 3)
        for (name, fixture) in cases.sorted(by: { $0.key < $1.key }) {
            let world = try ColorWorld()
            let party = try ColorWorld.party(identity, overlay: world.overlay, server: world.server, handles: world.alice.ctx.handles)
            let deployCustody = try custody("deployCustody", .issue, party.key)
            try await party.wallet.hold(
                deploy, vout: 0, basket: ColorIdentifiers.basket(assetID, role: .authority),
                customInstructions: try await ColorMetadata.encrypt(deployCustody.json, identity: identity),
                tags: [deployCustody.suffixTag]
            )
            await world.overlay.admit(try graph([deploy]).serialized(limits: harnessBEEFLimits), outpoint: "\(deployID.displayHex).0", vout: 0)
            let valueCustody = try custody("valueCustody", .asset(assetID), party.key)
            let authorityCustody = try custody("authorityCustody", .asset(assetID), party.key)
            XCTAssertEqual(
                Hex.encode(try ColorKeys.ownPublicKey(identity: identity, custody: valueCustody).compressedBytes),
                fixture["valuePublicKey"] as? String, name
            )

            let amount = try XCTUnwrap(UInt64(try XCTUnwrap(fixture["amount"] as? String)))
            let endMinting = try XCTUnwrap(fixture["endMinting"] as? Bool)
            let result = await OneColorActions.mint(
                party.ctx, assetID: assetID.description, amount: amount, endMinting: endMinting,
                valueCustody: valueCustody, authorityCustody: authorityCustody
            )
            XCTAssertNil(result.error, "\(name): \(result.error ?? "")")
            XCTAssertTrue(result.submitted, name)
            let submissions = await world.overlay.submissions
            XCTAssertEqual(submissions.last, [ColorIdentifiers.topic(assetID)], name)

            let requests = await party.wallet.createRequests
            let request = try XCTUnwrap(requests.first, name)
            let expected = try XCTUnwrap(fixture["request"] as? [String: Any])
            let forwarded = try XCTUnwrap(fixture["forwarded"] as? [String: Any])
            XCTAssertEqual(request.labels, expected["labels"] as? [String], name)
            XCTAssertEqual(request.labels, forwarded["labels"] as? [String], name)
            XCTAssertEqual(request.options?.randomizeOutputs, false, name)
            XCTAssertEqual(forwarded["randomizeOutputs"] as? Bool, false, name)

            // Inputs: the deploy authority, as the module selects and declares it.
            let theirInputs = try XCTUnwrap(forwarded["inputs"] as? [[String: Any]])
            let inputs = try XCTUnwrap(request.inputs, name)
            XCTAssertEqual(inputs.count, theirInputs.count, name)
            for (mine, theirs) in zip(inputs, theirInputs) {
                XCTAssertEqual(mine.outpoint.description, theirs["outpoint"] as? String, name)
                XCTAssertEqual(mine.inputDescription, theirs["inputDescription"] as? String, name)
                XCTAssertEqual(mine.unlocking, .scriptLength(try XCTUnwrap(theirs["unlockingScriptLength"] as? UInt32)), name)
            }

            // Outputs: the scripts the module checked, in its baskets, with its custody and tag form.
            let theirOutputs = try XCTUnwrap(forwarded["outputs"] as? [[String: Any]])
            let requested = try XCTUnwrap(expected["outputs"] as? [[String: Any]])
            let outputs = try XCTUnwrap(request.outputs, name)
            XCTAssertEqual(outputs.count, theirOutputs.count, name)
            XCTAssertEqual(outputs.count, endMinting ? 1 : 2, name)
            let custodies = try XCTUnwrap(fixture["custody"] as? [String: Any])
            for (index, output) in outputs.enumerated() {
                let theirs = theirOutputs[index]
                let label = "\(name) output \(index)"
                XCTAssertEqual(Hex.encode(output.lockingScript), theirs["lockingScript"] as? String, label)
                XCTAssertEqual(Hex.encode(output.lockingScript), requested[index]["lockingScript"] as? String, label)
                XCTAssertEqual(output.satoshis, (theirs["satoshis"] as? NSNumber)?.uint64Value, label)
                XCTAssertEqual(output.outputDescription, theirs["outputDescription"] as? String, label)
                XCTAssertEqual(output.basket, theirs["basket"] as? String, label)
                let plaintext = await ColorMetadata.decrypt(try XCTUnwrap(output.customInstructions, label), identity: identity)
                XCTAssertEqual(plaintext, theirs["customInstructions"] as? String, label)
                XCTAssertEqual(plaintext, custodies[index == 0 ? "value" : "authority"] as? String, label)
                let mine = index == 0 ? valueCustody : authorityCustody
                XCTAssertEqual(output.tags, [mine.suffixTag], label)
                let theirTags = try XCTUnwrap(theirs["tags"] as? [String])
                XCTAssertEqual(theirTags.count, 1, label)
                for tag in output.tags + theirTags {
                    XCTAssertNotNil(tag.range(of: "^p color [0-9a-f]{64}$", options: .regularExpression), "\(label): \(tag)")
                }
            }
            let txid = try XCTUnwrap(result.txid)
            XCTAssertEqual(result.authorityOutpoint, endMinting ? nil : "\(txid).1", name)
        }
    }
}
