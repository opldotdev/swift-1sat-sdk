import Foundation
import BSVCompat
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

final class SigmaTests: XCTestCase {
    private static let sigmaMarker: [UInt8] = [0x01, 0x7c, 0x05] + Array("SIGMA".utf8) + [0x03]
        + Array("BSM".utf8)

    func test_applyAppendsVerifiableSigmaSuffix() async throws {
        let identity = try ActionVectors.identity()
        let transport = try ScriptedTransport(outputsJSON: JSONSerialization.data(withJSONObject: [
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1)),
        ]))
        let ctx = try context(identity: identity, transport: transport)
        var script = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        try script.append(.zero, maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.append(.return, maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.appendPushData(
            Array("test".utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )

        let outpoint = try Outpoint(ActionVectors.outpoint)
        let signed = try await Sigma.apply(
            ctx,
            to: script,
            inputTxid: outpoint.transactionID.displayHex,
            inputVout: outpoint.outputIndex
        )

        let split = try splitSigma(signed)
        XCTAssertEqual(split.unsigned, script.bytes)
        XCTAssertEqual(Array(signed.bytes[split.markerIndex..<(split.markerIndex + Self.sigmaMarker.count)]), Self.sigmaMarker)
        XCTAssertEqual(split.vin, 0)

        let inputHash = try Sigma.getInputHash(
            txid: outpoint.transactionID.displayHex,
            vout: outpoint.outputIndex
        )
        let dataHash = Sigma.getDataHash(script)
        let messageHash = Sigma.getMessageHash(inputHash: inputHash, dataHash: dataHash)
        let address = try Address(split.address)
        let signature = try BitcoinMessageSignature(split.signature)
        XCTAssertEqual(split.signature.count, 65)
        XCTAssertTrue(try signature.verifies(message: messageHash, address: address))
        XCTAssertEqual(
            address.description,
            try derivedAddress(identity, keyID: Identity.signingKeyID(1)).description
        )
    }

    func test_placeholderSealsAgainstExistingInput() async throws {
        let identity = try ActionVectors.identity()
        let transport = try ScriptedTransport(outputsJSON: JSONSerialization.data(withJSONObject: [
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1)),
        ]))
        let ctx = try context(identity: identity, transport: transport)
        var base = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        try base.append(.zero, maximumScriptByteCount: ActionScript.maximumByteCount)
        try base.append(.return, maximumScriptByteCount: ActionScript.maximumByteCount)
        try base.appendPushData(
            Array("reinscription".utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        let placeholder = try Sigma.appendPlaceholder(to: base, vin: 2)
        XCTAssertTrue(try Sigma.hasPlaceholder(placeholder, vin: 2))

        let outpoint = try Outpoint(ActionVectors.outpoint)
        let sealed = try await Sigma.sealPlaceholder(
            ctx,
            in: placeholder,
            inputTxid: outpoint.transactionID.displayHex,
            inputVout: outpoint.outputIndex,
            refVin: 2
        )
        XCTAssertFalse(try Sigma.hasPlaceholder(sealed.script, vin: 2))
        let split = try splitSigma(sealed.script)
        XCTAssertEqual(split.unsigned, base.bytes)
        XCTAssertEqual(split.vin, 2)
        XCTAssertEqual(split.address, sealed.creator)
    }

    func test_resolveCurrentKeyIdPicksHighestSeq() async throws {
        let keyID = try await resolveKeyID([
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1), prefix: "e"),
            identityOutput(seq: 3, keyID: Identity.signingKeyID(3), prefix: "d"),
            identityOutput(seq: 2, keyID: Identity.signingKeyID(2), prefix: "f"),
        ])
        XCTAssertEqual(keyID, Identity.signingKeyID(3))
    }

    /// TS `aip.ts:36-60` never reads customInstructions, so a plaintext record that
    /// names another key does not change the result: the `seq:` tag decides.
    func test_resolveCurrentKeyIdDerivesFromSeqNotPlaintextInstructions() async throws {
        let keyID = try await resolveKeyID([
            identityOutput(seq: 1, instructions: "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-0\"}"),
        ])
        // Identities published before TS b0b6dff1 declared identity-0 at seq:1; TS signs with identity-1.
        XCTAssertEqual(keyID, Identity.signingKeyID(1))
    }

    /// A wallet behind the permissions manager stores customInstructions encrypted.
    func test_resolveCurrentKeyIdIgnoresEncryptedInstructions() async throws {
        let keyID = try await resolveKeyID([
            identityOutput(seq: 2, instructions: "q83vASNFZ4mrze8BI0VniQ==", prefix: "e"),
            identityOutput(seq: 1, instructions: "not json {", prefix: "f"),
        ])
        XCTAssertEqual(keyID, Identity.signingKeyID(2))
    }

    func test_resolveCurrentKeyIdWithoutInstructions() async throws {
        let keyID = try await resolveKeyID([identityOutput(seq: 1, instructions: nil)])
        XCTAssertEqual(keyID, Identity.signingKeyID(1))
    }

    func test_resolveCurrentKeyIdDoesNotRequestInstructions() async throws {
        let identity = try ActionVectors.identity()
        let transport = try ScriptedTransport(outputsJSON: JSONSerialization.data(withJSONObject: [
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1)),
        ]))
        let ctx = try context(identity: identity, transport: transport)
        _ = try await Sigma.resolveCurrentKeyId(ctx)
        let bodies = await transport.bodies
        let body = try XCTUnwrap(bodies.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [Any])
        let args = try XCTUnwrap(params.compactMap { $0 as? [String: Any] }.first { $0["basket"] != nil })
        XCTAssertEqual(args["basket"] as? String, OneSatConstants.bapBasket)
        XCTAssertEqual(args["tags"] as? [String], ["type:id"])
        XCTAssertEqual(args["includeTags"] as? Bool, true)
        XCTAssertNotEqual(args["includeCustomInstructions"] as? Bool, true)
    }

    func test_resolveCurrentKeyIdRejectsSeqZero() async throws {
        try await assertNoBapIdentity([identityOutput(seq: 0, keyID: Identity.signingKeyID(0))])
    }

    func test_resolveCurrentKeyIdRejectsIdOutputsWithoutValidSeq() async throws {
        try await assertNoBapIdentity([
            identityOutput(tags: ["type:id"], prefix: "a"),
            identityOutput(tags: ["type:id", "seq:"], prefix: "b"),
            identityOutput(tags: ["type:id", "seq:abc"], prefix: "c"),
            identityOutput(tags: ["type:id", "seq:-4"], prefix: "d"),
        ])
    }

    /// `Number.parseInt(tag.slice(4), 10)` takes leading digits after optional whitespace and sign.
    func test_parseSeqMatchesParseInt() {
        XCTAssertEqual(Sigma.parseSeq("7"), 7)
        XCTAssertEqual(Sigma.parseSeq("12abc"), 12)
        XCTAssertEqual(Sigma.parseSeq(" 3"), 3)
        XCTAssertEqual(Sigma.parseSeq("+5"), 5)
        XCTAssertEqual(Sigma.parseSeq("-2"), -2)
        XCTAssertEqual(Sigma.parseSeq("1.9"), 1)
        XCTAssertNil(Sigma.parseSeq(""))
        XCTAssertNil(Sigma.parseSeq("abc"))
        XCTAssertNil(Sigma.parseSeq("-"))
    }

    func test_resolveCurrentKeyIdThrowsWhenNoIdentity() async throws {
        let identity = try ActionVectors.identity()
        let transport = try ScriptedTransport(outputsJSON: JSONSerialization.data(withJSONObject: [[String: Any]]()))
        let ctx = try context(identity: identity, transport: transport)
        do {
            _ = try await Sigma.resolveCurrentKeyId(ctx)
            XCTFail("expected noBapIdentity")
        } catch let error as OneSatActionError {
            XCTAssertEqual(error, .noBapIdentity)
            XCTAssertEqual(
                error.wireMessage,
                "No BAP identity published — cannot resolve current signing key. Publish an identity before signing."
            )
        }
    }

    private func splitSigma(_ script: Script) throws -> (
        unsigned: [UInt8],
        markerIndex: Int,
        address: String,
        signature: [UInt8],
        vin: Int
    ) {
        let bytes = script.bytes
        let marker = Self.sigmaMarker
        guard let markerIndex = bytes.lastRange(of: marker)?.lowerBound else {
            throw NSError(domain: "SigmaTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SIGMA suffix not found",
            ])
        }
        let tail = try Script(
            bytes: Array(bytes[markerIndex...]),
            maximumByteCount: ActionScript.maximumByteCount
        )
        let operations = try tail.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        XCTAssertGreaterThanOrEqual(operations.count, 6)
        let address = String(bytes: try XCTUnwrap(operations[3].pushedData), encoding: .utf8)
        let signature = try XCTUnwrap(operations[4].pushedData)
        let vinText = String(bytes: try XCTUnwrap(operations[5].pushedData), encoding: .utf8)
        return (
            unsigned: Array(bytes[..<markerIndex]),
            markerIndex: markerIndex,
            address: try XCTUnwrap(address),
            signature: signature,
            vin: try XCTUnwrap(Int(try XCTUnwrap(vinText)))
        )
    }

    private func identityOutput(seq: Int, keyID: String, prefix: Character = "f") -> [String: Any] {
        identityOutput(
            seq: seq,
            instructions: "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"\(keyID)\"}",
            prefix: prefix
        )
    }

    private func identityOutput(seq: Int, instructions: String?, prefix: Character = "f") -> [String: Any] {
        identityOutput(tags: ["type:id", "seq:\(seq)"], instructions: instructions, prefix: prefix)
    }

    private func identityOutput(
        tags: [String],
        instructions: String? = nil,
        prefix: Character = "f"
    ) -> [String: Any] {
        var output: [String: Any] = [
            "outpoint": "\(String(repeating: prefix, count: 64)).0",
            "satoshis": 0,
            "spendable": true,
            "tags": tags,
        ]
        if let instructions {
            output["customInstructions"] = instructions
        }
        return output
    }

    private func resolveKeyID(_ outputs: [[String: Any]]) async throws -> String {
        let identity = try ActionVectors.identity()
        let transport = try ScriptedTransport(outputsJSON: JSONSerialization.data(withJSONObject: outputs))
        return try await Sigma.resolveCurrentKeyId(try context(identity: identity, transport: transport))
    }

    private func assertNoBapIdentity(
        _ outputs: [[String: Any]],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            let keyID = try await resolveKeyID(outputs)
            XCTFail("expected noBapIdentity, got \(keyID)", file: file, line: line)
        } catch let error as OneSatActionError {
            XCTAssertEqual(error, .noBapIdentity, file: file, line: line)
        }
    }

    private func derivedAddress(_ identity: PrivateKey, keyID: String) throws -> Address {
        let key = try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID(keyID),
            counterparty: .self
        )
        return Address(publicKey: key.publicKey, network: .mainnet, compressed: true)
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
    private let outputsJSON: Data

    init(outputsJSON: Data) {
        self.outputsJSON = outputsJSON
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
            let outputs = try JSONSerialization.jsonObject(with: outputsJSON) as? [[String: Any]] ?? []
            let envelope: [String: Any] = [
                "jsonrpc": "2.0",
                "id": object?["id"] as Any,
                "result": [
                    "totalOutputs": outputs.count,
                    "outputs": outputs,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope)
            return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
        }
        throw AuthTransportError.notImplemented("offline")
    }
}
