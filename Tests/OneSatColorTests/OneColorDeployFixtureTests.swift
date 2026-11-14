import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVWallet
@testable import OneSatColor
import OneSatTemplates

/// A JSON fixture under `Fixtures/`, generated with Bun from the published TS packages.
func colorFixture(_ name: String) throws -> [String: Any] {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")
            ?? Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

/// `OneColorActions.deploy` against `Fixtures/onecolor-deploy.json`: the request `@1sat/actions`
/// `deploy1Color` sends (description, script, satoshis, labels, options) with the derivation pinned,
/// and the custody and tag the `@bopen-io/color-permission-module` 0.2.3 module adds to it.
final class OneColorDeployFixtureTests: XCTestCase {
    func test_deployRequestMatchesDeploy1ColorAndTheModule() async throws {
        let root = try colorFixture("onecolor-deploy")
        let meta = try XCTUnwrap(root["meta"] as? [String: Any])
        let identity = try PrivateKey(try Hex.decode(try XCTUnwrap(meta["identityHex"] as? String), maximumDecodedByteCount: 32))
        let cases = try XCTUnwrap(root["cases"] as? [String: [String: Any]])
        XCTAssertEqual(cases.count, 5)

        for (name, fixture) in cases.sorted(by: { $0.key < $1.key }) {
            let world = try ColorWorld()
            let party = try ColorWorld.party(
                identity, overlay: world.overlay, server: world.server, handles: world.alice.ctx.handles
            )
            let input = try XCTUnwrap(fixture["input"] as? [String: Any])
            let amount = try XCTUnwrap(UInt64(try XCTUnwrap(input["amount"] as? String)))
            var icon: OneColorIcon?
            if let raw = input["icon"] as? [String: Any] {
                icon = OneColorIcon(
                    mediaType: try XCTUnwrap(raw["mediaType"] as? String),
                    bytes: try XCTUnwrap(raw["bytes"] as? [Int]).map { UInt8($0) }
                )
            }
            let custody = try ColorCustody(
                asset: .issue,
                derivationPrefix: try XCTUnwrap(fixture["derivationPrefix"] as? String),
                derivationSuffix: try XCTUnwrap(fixture["derivationSuffix"] as? String),
                senderIdentityKey: party.key
            )
            let result = await OneColorActions.deploy(
                party.ctx, amount: amount, decimals: input["decimals"] as? Int, symbol: input["symbol"] as? String,
                icon: icon, custody: custody
            )
            XCTAssertNil(result.error, name)

            let requests = await party.wallet.createRequests
            let request = try XCTUnwrap(requests.first, name)
            let expected = try XCTUnwrap(fixture["request"] as? [String: Any])
            let forwarded = try XCTUnwrap(fixture["forwarded"] as? [String: Any])
            XCTAssertEqual(request.description, expected["description"] as? String, name)
            XCTAssertEqual(request.labels, expected["labels"] as? [String], name)
            XCTAssertEqual(forwarded["labels"] as? [String], expected["labels"] as? [String], name)
            XCTAssertEqual(request.options?.randomizeOutputs, false, name)
            XCTAssertTrue((request.inputs ?? []).isEmpty, name)
            XCTAssertEqual((forwarded["inputs"] as? [Any])?.count, 0, name)

            let outputs = try XCTUnwrap(request.outputs, name)
            let expectedOutputs = try XCTUnwrap(expected["outputs"] as? [[String: Any]])
            XCTAssertEqual(outputs.count, 1, name)
            XCTAssertEqual(forwarded["outputCount"] as? Int, 1, name)
            let output = try XCTUnwrap(outputs.first)
            XCTAssertEqual(Hex.encode(output.lockingScript), expectedOutputs[0]["lockingScript"] as? String, name)
            XCTAssertEqual(Hex.encode(output.lockingScript), forwarded["lockingScript"] as? String, name)
            XCTAssertEqual(output.satoshis, (expectedOutputs[0]["satoshis"] as? NSNumber)?.uint64Value, name)
            XCTAssertEqual(output.outputDescription, expectedOutputs[0]["outputDescription"] as? String, name)

            // The module's part: no basket before signing, encrypted ISSUE custody, one suffix tag.
            XCTAssertNil(output.basket, name)
            XCTAssertTrue(forwarded["basket"] is NSNull, name)
            let stored = try XCTUnwrap(output.customInstructions, name)
            XCTAssertFalse(stored.hasPrefix("{"), "\(name): custody is encrypted")
            let plaintext = await ColorMetadata.decrypt(stored, identity: identity)
            XCTAssertEqual(plaintext, forwarded["customInstructions"] as? String, name)
            XCTAssertEqual(output.tags, [custody.suffixTag], name)
            let theirTags = try XCTUnwrap(forwarded["tags"] as? [String])
            XCTAssertEqual(theirTags.count, 1, name)
            for tag in output.tags + theirTags {
                XCTAssertNotNil(tag.range(of: "^p color [0-9a-f]{64}$", options: .regularExpression), "\(name): \(tag)")
            }
        }
    }
}
