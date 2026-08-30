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

final class CollectionMintTests: XCTestCase {
    private static let sigmaMarker: [UInt8] = [0x01, 0x7c, 0x05] + Array("SIGMA".utf8) + [0x03]
        + Array("BSM".utf8)
    private static let collectionId = String(repeating: "b", count: 64) + "_1"
    private static let ref = String(repeating: "c", count: 64) + "_3:-1"

    func test_rootAndItemsShareMapBytesAndOneSigmaIdentity() async throws {
        let identity = try ActionVectors.identity()
        let transport = MintTransport()
        let ctx = try context(identity: identity, transport: transport)

        let collection = await Collections.mint(
            ctx,
            Collections.MintRequest(
                base64Content: "cm9vdA==",
                contentType: "text/plain",
                name: "Root",
                description: "Collection root",
                quantity: 2
            )
        )
        XCTAssertNil(collection.error, collection.error ?? "")
        XCTAssertNotNil(collection.txid)
        XCTAssertEqual(collection.collectionId, "\(collection.txid!)_0")

        let metadataName = "Item"
        let embedded = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                base64Content: "aW1hZ2U=",
                contentType: "image/png",
                name: metadataName,
                collectionId: Self.collectionId,
                mintNumber: 1,
                rank: 2,
                rarityLabel: "rare",
                traits: [CollectionItemTrait(name: "Color", value: "Blue")]
            )
        )
        let referenced = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                ref: Self.ref,
                name: metadataName,
                collectionId: Self.collectionId,
                mintNumber: 1,
                rank: 2,
                rarityLabel: "rare",
                traits: [CollectionItemTrait(name: "Color", value: "Blue")]
            )
        )
        XCTAssertNil(embedded.error, embedded.error ?? "")
        XCTAssertNil(referenced.error, referenced.error ?? "")

        let bodies = await transport.bodies
        let captured = try Self.parseCreateActions(bodies)
        let anchors = captured.filter { $0.description == "Sigma anchor output" }
        let publishes = captured.filter { $0.description.hasPrefix("Create collection") }
        XCTAssertEqual(anchors.count, 3)
        XCTAssertEqual(publishes.count, 3)

        for anchor in anchors {
            XCTAssertEqual(anchor.outputs.count, 1)
            XCTAssertEqual(anchor.outputs[0].satoshis, 2)
            XCTAssertEqual(anchor.outputs[0].basket, "sigma")
            XCTAssertFalse(anchor.outputs[0].tags.contains { $0.hasPrefix("id:") })
            XCTAssertFalse(anchor.labels.contains(OneSatConstants.p1satLabel))
            XCTAssertEqual(anchor.options["noSend"] as? Bool, true)
        }

        let scripts = try publishes.map {
            try Script(hex: $0.outputs[0].lockingScript, maximumByteCount: ActionScript.maximumByteCount)
        }
        let embeddedMap = try mapFields(scripts[1])
        let referencedMap = try mapFields(scripts[2])
        XCTAssertEqual(referencedMap["subType"], "collectionItem")
        XCTAssertEqual(referencedMap["subTypeData"], embeddedMap["subTypeData"])

        let referencedInscription = try XCTUnwrap(Inscription.decode(scripts[2]))
        XCTAssertEqual(referencedInscription.contentType, "ord-fs/json")
        XCTAssertNotEqual(referencedInscription.contentType, "text/uri-list")
        XCTAssertFalse(referencedInscription.contentType.contains("ref=ordfs"))
        let refJSON = try JSONSerialization.jsonObject(with: Data(referencedInscription.content))
        XCTAssertEqual(refJSON as? [String: String], [".": Self.ref])

        var addresses: [String] = []
        for (index, publish) in publishes.enumerated() {
            XCTAssertEqual(publish.inputs.count, 1)
            XCTAssertEqual(publish.inputs[0].unlockingScriptLength, 108)
            let outpoint = publish.inputs[0].outpoint
            XCTAssertEqual(publish.options["noSend"] as? Bool, true)
            let known = try XCTUnwrap(publish.options["knownTxids"] as? [String])
            let sendWith = try XCTUnwrap(publish.options["sendWith"] as? [String])
            let anchorTxid = String(outpoint.split(separator: ".")[0])
            XCTAssertEqual(known, [anchorTxid])
            XCTAssertEqual(sendWith, [anchorTxid])
            XCTAssertEqual(publish.outputs[0].satoshis, 1)
            XCTAssertEqual(publish.outputs[0].basket, "1sat")
            XCTAssertTrue(publish.outputs[0].tags.contains("origin"))
            if index == 0 {
                XCTAssertTrue(publish.outputs[0].tags.contains("subType:collection"))
                XCTAssertTrue(publish.outputs[0].tags.contains("type:text/plain"))
                XCTAssertTrue(publish.outputs[0].tags.contains("name:Root"))
            } else {
                XCTAssertTrue(publish.outputs[0].tags.contains("subType:collectionItem"))
                XCTAssertTrue(publish.outputs[0].tags.contains("collectionId:\(Self.collectionId)"))
            }
            let address = try expectValidSigma(scripts[index], outpoint: outpoint)
            addresses.append(address)
        }
        XCTAssertEqual(Set(addresses).count, 1)
    }

    func test_mintItemGuards() async throws {
        let identity = try ActionVectors.identity()
        let ctx = try rejectContext(identity: identity)
        let commonId = String(repeating: "d", count: 64) + "_0"

        let neither = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(name: "Item", collectionId: commonId)
        )
        XCTAssertEqual(neither.error, "exactly-one-of-base64Content-or-ref-required")

        let both = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                base64Content: "eA==",
                ref: "_0",
                contentType: "text/plain",
                name: "Item",
                collectionId: commonId
            )
        )
        XCTAssertEqual(both.error, "exactly-one-of-base64Content-or-ref-required")

        let missingType = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                base64Content: "eA==",
                name: "Item",
                collectionId: commonId
            )
        )
        XCTAssertEqual(missingType.error, "contentType-required-with-base64Content")

        let badRef = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                ref: "x_y",
                name: "Item",
                collectionId: commonId
            )
        )
        XCTAssertEqual(badRef.error, "invalid-ref: x_y")

        let badCollection = await Collections.mintItem(
            ctx,
            Collections.MintItemRequest(
                base64Content: "eA==",
                contentType: "text/plain",
                name: "Item",
                collectionId: "_0"
            )
        )
        XCTAssertEqual(badCollection.error, "Invalid collectionId format: _0")
    }

    func test_quantityMustBePositive() async throws {
        let identity = try ActionVectors.identity()
        let ctx = try rejectContext(identity: identity)
        let result = await Collections.mint(
            ctx,
            Collections.MintRequest(
                base64Content: "cm9vdA==",
                contentType: "text/plain",
                name: "Root",
                description: "Collection root",
                quantity: 0
            )
        )
        XCTAssertEqual(result.error, "quantity-must-be-positive")
    }

    private func expectValidSigma(_ script: Script, outpoint: String) throws -> String {
        let bytes = script.bytes
        guard let markerIndex = bytes.lastRange(of: Self.sigmaMarker)?.lowerBound else {
            XCTFail("SIGMA suffix not found")
            return ""
        }
        XCTAssertEqual(
            Array(bytes[markerIndex..<(markerIndex + Self.sigmaMarker.count)]),
            Self.sigmaMarker
        )
        let tail = try Script(
            bytes: Array(bytes[markerIndex...]),
            maximumByteCount: ActionScript.maximumByteCount
        )
        let operations = try tail.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        let addressText = String(bytes: try XCTUnwrap(operations[3].pushedData), encoding: .utf8)
        let signatureBytes = try XCTUnwrap(operations[4].pushedData)
        let unsigned = Array(bytes[..<markerIndex])
        let parts = outpoint.split(separator: ".")
        let inputHash = try Sigma.getInputHash(
            txid: String(parts[0]),
            vout: UInt32(parts[1])!
        )
        let dataHash = BSVHashing.sha256(unsigned).bytes
        let messageHash = BSVHashing.sha256(inputHash + dataHash).bytes
        let address = try Address(try XCTUnwrap(addressText))
        let signature = try BitcoinMessageSignature(signatureBytes)
        XCTAssertTrue(try signature.verifies(message: messageHash, address: address))
        return address.description
    }

    private static func parseCreateActions(_ bodies: [[UInt8]]) throws -> [CapturedAction] {
        var captured: [CapturedAction] = []
        for body in bodies {
            let envelope = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
            guard envelope?["method"] as? String == "createAction" else { continue }
            let params = envelope?["params"] as? [Any]
            let args = params?[1] as? [String: Any] ?? [:]
            let outputs = (args["outputs"] as? [[String: Any]] ?? []).map { output in
                CapturedOutput(
                    satoshis: (output["satoshis"] as? NSNumber)?.uint64Value ?? 0,
                    basket: output["basket"] as? String,
                    lockingScript: output["lockingScript"] as? String ?? "",
                    tags: output["tags"] as? [String] ?? []
                )
            }
            let inputs = (args["inputs"] as? [[String: Any]] ?? []).map { input in
                CapturedInput(
                    outpoint: input["outpoint"] as? String ?? "",
                    unlockingScriptLength: (input["unlockingScriptLength"] as? NSNumber)?.uint32Value ?? 0
                )
            }
            captured.append(
                CapturedAction(
                    description: args["description"] as? String ?? "",
                    labels: args["labels"] as? [String] ?? [],
                    options: args["options"] as? [String: Any] ?? [:],
                    outputs: outputs,
                    inputs: inputs
                )
            )
        }
        return captured
    }

    private func mapFields(_ script: Script) throws -> [String: String] {
        let operations = try script.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        let prefix = Array(OneSatConstants.mapPrefix.utf8)
        guard let prefixIndex = operations.firstIndex(where: { $0.pushedData == prefix }) else {
            throw NSError(domain: "CollectionMintTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "MAP suffix not found",
            ])
        }
        var fields: [String: String] = [:]
        var index = operations.index(prefixIndex, offsetBy: 2)
        while index < operations.endIndex {
            let keyBytes = operations[index].pushedData ?? []
            let key = String(bytes: keyBytes, encoding: .utf8) ?? ""
            if key == "|" { break }
            let next = operations.index(after: index)
            guard next < operations.endIndex, let valueBytes = operations[next].pushedData else { break }
            fields[key] = String(bytes: valueBytes, encoding: .utf8) ?? ""
            index = operations.index(after: next)
        }
        return fields
    }

    private func context(identity: PrivateKey, transport: MintTransport) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }

    private func rejectContext(identity: PrivateKey) throws -> OneSatContext {
        OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: RejectURLTransport()
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes))
        )
    }
}

private struct CapturedAction {
    let description: String
    let labels: [String]
    let options: [String: Any]
    let outputs: [CapturedOutput]
    let inputs: [CapturedInput]
}

private struct CapturedOutput {
    let satoshis: UInt64
    let basket: String?
    let lockingScript: String
    let tags: [String]
}

private struct CapturedInput {
    let outpoint: String
    let unlockingScriptLength: UInt32
}

private actor MintTransport: AuthenticatedTransport {
    private(set) var methods: [String] = []
    private(set) var bodies: [[UInt8]] = []
    private var nextReference = 0

    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let rpcMethod = object?["method"] as? String ?? ""
        let id = object?["id"] as Any
        methods.append(rpcMethod)
        bodies.append(body ?? [])
        switch rpcMethod {
        case "listOutputs":
            return try envelope(
                id: id,
                result: [
                    "totalOutputs": 1,
                    "outputs": [
                        [
                            "outpoint": "\(String(repeating: "f", count: 64)).0",
                            "satoshis": 1,
                            "spendable": true,
                            "tags": ["type:id", "seq:1"],
                            "customInstructions":
                                "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-1\"}",
                        ],
                    ],
                ]
            )
        case "createAction":
            return try createActionResponse(id: id, object: object)
        case "processAction":
            return try envelope(id: id, result: ["sendWithResults": [Any]()])
        default:
            throw AuthTransportError.notImplemented("offline")
        }
    }

    private func createActionResponse(id: Any, object: [String: Any]?) throws -> AuthenticatedResponse {
        let params = object?["params"] as? [Any]
        let args = params?[1] as? [String: Any] ?? [:]
        let requested = args["outputs"] as? [[String: Any]] ?? []
        let requestedInputs = args["inputs"] as? [[String: Any]] ?? []

        var outputRows: [[String: Any]] = []
        for (index, output) in requested.enumerated() {
            outputRows.append([
                "lockingScript": output["lockingScript"] as? String ?? "",
                "satoshis": output["satoshis"] as Any,
                "vout": index,
                "providedBy": "you",
            ])
        }

        let inputs: [[String: Any]]
        let inputBeef: [Int]
        if requestedInputs.isEmpty {
            let sourceLock = try Script(bytes: [0x51], maximumByteCount: 10_000)
            let source = Transaction(
                version: 1,
                inputs: [],
                outputs: [
                    TransactionOutput(satoshis: 10_000, lockingScript: sourceLock),
                ],
                lockTime: 0
            )
            let sourceTxid = try source.transactionID(limits: WalletTransactionLimits.standard)
            let beef = try BEEF(
                merklePaths: [],
                transactions: [.raw(source)],
                limits: WalletBEEFLimits.standard
            )
            inputBeef = try beef.serialized(limits: WalletBEEFLimits.standard).map(Int.init)
            inputs = [
                [
                    "sourceTxid": sourceTxid.displayHex,
                    "sourceVout": 0,
                    "sourceSatoshis": 10_000,
                    "sourceLockingScript": sourceLock.hex,
                    "unlockingScriptLength": 108,
                ],
            ]
        } else {
            if let raw = args["inputBEEF"] as? [Any] {
                inputBeef = raw.compactMap { value -> Int? in
                    if let number = value as? NSNumber { return number.intValue }
                    return value as? Int
                }
            } else {
                inputBeef = []
            }
            inputs = requestedInputs.map { input in
                let outpoint = input["outpoint"] as? String ?? ""
                let parts = outpoint.split(separator: ".")
                return [
                    "sourceTxid": parts.isEmpty ? "" : String(parts[0]),
                    "sourceVout": parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                    "sourceSatoshis": 2,
                    "sourceLockingScript": "51",
                    "unlockingScriptLength": input["unlockingScriptLength"] as Any,
                ]
            }
        }

        var result: [String: Any] = [
            "reference": "ref-\(nextReference)",
            "version": 1,
            "lockTime": 0,
            "inputs": inputs,
            "outputs": outputRows,
        ]
        nextReference += 1
        if !inputBeef.isEmpty {
            result["inputBeef"] = inputBeef
        }
        return try envelope(id: id, result: result)
    }

    private func envelope(id: Any, result: [String: Any]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "jsonrpc": "2.0",
                "id": id,
                "result": result,
            ]
        )
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}

private struct RejectURLTransport: AuthenticatedTransport {
    func send(
        method: String,
        path: String,
        query: String?,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        throw AuthTransportError.notImplemented("offline")
    }
}
