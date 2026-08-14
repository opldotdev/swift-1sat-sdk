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
        let transport = ScriptedTransport(outputs: [
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1)),
        ])
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

    func test_resolveCurrentKeyIdPicksHighestSeq() async throws {
        let identity = try ActionVectors.identity()
        let transport = ScriptedTransport(outputs: [
            identityOutput(seq: 1, keyID: Identity.signingKeyID(1), prefix: "e"),
            identityOutput(seq: 2, keyID: Identity.signingKeyID(2), prefix: "f"),
        ])
        let ctx = try context(identity: identity, transport: transport)
        let keyID = try await Sigma.resolveCurrentKeyId(ctx)
        XCTAssertEqual(keyID, Identity.signingKeyID(2))
    }

    func test_resolveCurrentKeyIdThrowsWhenNoIdentity() async throws {
        let identity = try ActionVectors.identity()
        let transport = ScriptedTransport(outputs: [])
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
        let instructions = "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"\(keyID)\"}"
        return [
            "outpoint": "\(String(repeating: prefix, count: 64)).0",
            "satoshis": 0,
            "spendable": true,
            "tags": ["type:id", "seq:\(seq)"],
            "customInstructions": instructions,
        ]
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
    private let outputs: [[String: Any]]

    init(outputs: [[String: Any]]) {
        self.outputs = outputs
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
