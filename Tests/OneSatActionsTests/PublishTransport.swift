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
import ToolboxBRC29
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// Storage that accepts every action, modeled on `CollectionMintTests`' `MintTransport`. Shared by
/// the deploy, inscribe and collection SIGMA publish tests.
///
/// `createAction` echoes the requested outputs at their own vouts and adds BRC-29 change. Caller
/// inputs and `noSendChange` outpoints are resolved from the request's `inputBEEF` (the change
/// as derivation-signed funding); an action without `noSendChange` is funded from a fresh
/// OP_TRUE source added to that graph.
/// `processAction` decodes the signed raw transaction and reports every `sendWith` txid with
/// `sendWithStatus` (unproven unless a test asks otherwise).
///
/// With an `ActionBatch`, it is instead storage that speaks the action-batch protocol for a wallet
/// whose only unspent output is one BRC-29 change output: `getCapabilities` advertises version 1
/// with format-2 manifests, `beginActionBatch` reserves that single output (its source
/// transaction in `inputBeef`), and `commitActionBatch` records the manifest and reports every
/// `sendWith` txid with `sendWithStatus`, or answers `commitError`. `createAction` and
/// `processAction` fail the test there: nothing in a batch may reach them.
actor PublishTransport: AuthenticatedTransport {
    struct Processed: Sendable {
        let txid: String
        let transaction: Transaction
        let sendWith: [String]
        let isSendWith: Bool
        let isNoSend: Bool
        let isDelayed: Bool
    }

    static let derivationPrefix = "cHJlZml4"
    static let derivationSuffix = "c3VmZml4"
    static let fee: UInt64 = 100

    private(set) var methods: [String] = []
    private(set) var bodies: [[UInt8]] = []
    private(set) var processed: [Processed] = []
    private var nextReference = 0
    private let sendWithStatus: String
    private let actionBatch: ActionBatch?

    /// The action-batch storage of a wallet with a single unspent output.
    struct ActionBatch: Sendable {
        /// The wallet the reserved output pays, by BRC-29 change derivation to itself.
        let identity: PrivateKey
        var fundingSatoshis: UInt64 = 10_000
        /// The JSON-RPC `error` member `commitActionBatch` answers with, instead of committing.
        var commitError: [String: String]?
    }

    /// The batch `beginActionBatch` opened, by the id the client chose.
    private(set) var batchId: String?
    /// The wallet's one unspent output, reserved by `beginActionBatch`.
    private(set) var fundingTransaction: Transaction?
    /// The batch ids `abortActionBatch` was called with.
    private(set) var abortedBatches: [String] = []

    init(sendWithStatus: String = "unproven", actionBatch: ActionBatch? = nil) {
        self.sendWithStatus = sendWithStatus
        self.actionBatch = actionBatch
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
        let id = object?["id"] as Any
        methods.append(rpcMethod)
        bodies.append(body ?? [])
        let args = (object?["params"] as? [Any])?.dropFirst().first as? [String: Any] ?? [:]
        switch rpcMethod {
        case "listOutputs":
            return try envelope(id: id, result: [
                "totalOutputs": 1,
                "outputs": [
                    [
                        "outpoint": ActionVectors.outpoint,
                        "satoshis": 0,
                        "spendable": true,
                        "tags": ["type:id", "seq:1"],
                        "customInstructions": "{\"protocolID\":[1,\"sigma\"],\"keyID\":\"identity-1\"}",
                    ],
                ],
            ])
        case "createAction" where actionBatch == nil:
            return try envelope(id: id, result: try createAction(args))
        case "processAction" where actionBatch == nil:
            return try envelope(id: id, result: try processAction(args))
        case "createAction", "processAction":
            XCTFail("\(rpcMethod) reached storage while it speaks the action batch")
            throw AuthTransportError.notImplemented("action batch only")
        default:
            break
        }
        guard let actionBatch else { throw AuthTransportError.notImplemented("offline") }
        let params = object?["params"] as? [Any] ?? []
        switch rpcMethod {
        case "getCapabilities":
            return try envelope(id: id, result: [
                "actionBatch": [
                    "version": 1,
                    "maxInlineBytes": 4 * 1024 * 1024,
                    "maxBlobBytes": 16 * 1024 * 1024,
                    "maxConcurrentUploads": 4,
                    "leaseMs": 60_000,
                    "hardLifetimeMs": 600_000,
                    "compactBegin": true,
                    "manifestVersion": 2,
                    "commitByDigest": false,
                    "resume": false,
                    "maxReservedOutputs": 8,
                ],
            ])
        case "beginActionBatch":
            return try envelope(id: id, result: try beginActionBatch(args, actionBatch))
        case "renewActionBatch":
            return try envelope(id: id, result: ["expiresAt": Self.leaseExpiry])
        case "commitActionBatch":
            if let error = actionBatch.commitError {
                return try envelope(id: id, error: error)
            }
            return try envelope(id: id, result: try commitActionBatch(args))
        case "abortActionBatch":
            abortedBatches.append(params.dropFirst().first as? String ?? "")
            return try envelope(id: id, result: ["aborted": true])
        default:
            XCTFail("unexpected \(rpcMethod) in the action batch")
            throw AuthTransportError.notImplemented("offline")
        }
    }

    /// A lease that never needs renewing while a test runs.
    static let leaseExpiry = "2100-01-01T00:00:00.000Z"

    /// Reserves the wallet's single unspent output: BRC-29 change the identity paid itself, as the
    /// reference storage returns a `TableOutput` row, with its transaction in `inputBeef`.
    private func beginActionBatch(_ args: [String: Any], _ batch: ActionBatch) throws -> [String: Any] {
        let id = try XCTUnwrap(args["batchId"] as? String)
        XCTAssertNil(batchId, "one batch per publish")
        batchId = id
        let key = try BRC29.receivingPrivateKey(
            recipient: batch.identity,
            sender: batch.identity.publicKey,
            prefix: Self.derivationPrefix,
            suffix: Self.derivationSuffix
        )
        let lockingScript = try BRC29.lockingScript(for: key.publicKey)
        let funding = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: batch.fundingSatoshis, lockingScript: lockingScript)],
            lockTime: 0
        )
        fundingTransaction = funding
        let inputBeef = try BEEF(
            version: .v2, merklePaths: [], transactions: [.raw(funding)], limits: WalletBEEFLimits.standard
        ).serialized(limits: WalletBEEFLimits.standard)
        return [
            "batchId": id,
            "expiresAt": Self.leaseExpiry,
            "hardExpiresAt": "2100-01-01T00:10:00.000Z",
            "changeBasket": [
                "basketId": 1, "name": "default", "numberOfDesiredUTXOs": 32, "minimumDesiredUTXOValue": 1_000,
            ],
            "feeModel": ["model": "sat/kb", "value": 100],
            "commissionSatoshis": 0,
            "availableChangeCount": 1,
            "reservedOutputs": [
                [
                    "outputId": 41,
                    "txid": try funding.transactionID(limits: WalletTransactionLimits.standard).displayHex,
                    "vout": 0,
                    "satoshis": Int(batch.fundingSatoshis),
                    "spendable": true,
                    "change": true,
                    "providedBy": "storage",
                    "purpose": "change",
                    "type": "P2PKH",
                    "basketId": 1,
                    "derivationPrefix": Self.derivationPrefix,
                    "derivationSuffix": Self.derivationSuffix,
                    "lockingScript": lockingScript.bytes.map(Int.init),
                ],
            ],
            "explicitOutputs": [],
            "inputBeef": inputBeef.map(Int.init),
        ]
    }

    /// Accepts the manifest and reports every `sendWith` txid with `sendWithStatus`.
    private func commitActionBatch(_ manifest: [String: Any]) throws -> [String: Any] {
        let sendWith = manifest["sendWith"] as? [String] ?? []
        let actions = manifest["actions"] as? [[String: Any]] ?? []
        return [
            "batchId": manifest["batchId"] as? String ?? "",
            "manifestDigest": manifest["digest"] as? String ?? "",
            "committedTxids": actions.compactMap { $0["txid"] as? String },
            "alreadyCommitted": false,
            "sendWithResults": sendWith.map { ["txid": $0, "status": sendWithStatus] },
        ]
    }

    private func createAction(_ args: [String: Any]) throws -> [String: Any] {
        let requested = args["outputs"] as? [[String: Any]] ?? []
        let requestedInputs = args["inputs"] as? [[String: Any]] ?? []
        let options = args["options"] as? [String: Any] ?? [:]
        let change = options["noSendChange"] as? [String] ?? []

        var inputs: [[String: Any]] = []
        var paidIn: UInt64 = 0
        var inputBeef: [UInt8] = []
        if !requestedInputs.isEmpty || !change.isEmpty {
            inputBeef = (args["inputBEEF"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.uint8Value }
            let graph = try BEEF(bytes: inputBeef, limits: WalletBEEFLimits.standard)
            for input in requestedInputs {
                let source = try Self.resolve(try Outpoint(input["outpoint"] as? String ?? ""), in: graph)
                inputs.append(source.row.merging(["unlockingScriptLength": input["unlockingScriptLength"] as Any]) { $1 })
                paidIn += source.output.satoshis
            }
            for outpoint in change {
                let source = try Self.resolve(try Outpoint(outpoint), in: graph)
                inputs.append(source.row.merging([
                    "unlockingScriptLength": 108,
                    "derivationPrefix": Self.derivationPrefix,
                    "derivationSuffix": Self.derivationSuffix,
                ]) { $1 })
                paidIn += source.output.satoshis
            }
        }
        if change.isEmpty {
            // Fund from a fresh OP_TRUE source, added to whatever graph the caller sent. The lock
            // time makes each source distinct from one already in that graph.
            let sourceLock = try Script(bytes: [0x51], maximumByteCount: 10_000)
            let source = Transaction(
                version: 1,
                inputs: [],
                outputs: [TransactionOutput(satoshis: 10_000, lockingScript: sourceLock)],
                lockTime: UInt32(nextReference)
            )
            let graph = inputBeef.isEmpty
                ? try BEEF(merklePaths: [], transactions: [], limits: WalletBEEFLimits.standard)
                : try BEEF(bytes: inputBeef, limits: WalletBEEFLimits.standard)
            inputBeef = try BEEF(
                merklePaths: graph.merklePaths,
                transactions: graph.transactions + [.raw(source)],
                limits: WalletBEEFLimits.standard
            ).serialized(limits: WalletBEEFLimits.standard)
            inputs.append([
                "sourceTxid": try source.transactionID(limits: WalletTransactionLimits.standard).displayHex,
                "sourceVout": 0,
                "sourceSatoshis": 10_000,
                "sourceLockingScript": sourceLock.hex,
                "unlockingScriptLength": 108,
            ])
            paidIn += 10_000
        }

        var outputRows: [[String: Any]] = requested.enumerated().map { index, output in
            [
                "lockingScript": output["lockingScript"] as? String ?? "",
                "satoshis": output["satoshis"] as Any,
                "vout": index,
                "providedBy": "you",
            ]
        }
        let paidOut = requested.reduce(UInt64(0)) { $0 + (($1["satoshis"] as? NSNumber)?.uint64Value ?? 0) }
        if paidIn > paidOut + Self.fee {
            outputRows.append([
                "lockingScript": "51",
                "satoshis": Int(paidIn - paidOut - Self.fee),
                "vout": requested.count,
                "providedBy": "storage",
                "purpose": "change",
                "derivationSuffix": Self.derivationSuffix,
            ])
        }

        defer { nextReference += 1 }
        return [
            "reference": "ref-\(nextReference)",
            "version": 1,
            "lockTime": 0,
            "derivationPrefix": Self.derivationPrefix,
            "inputs": inputs,
            "outputs": outputRows,
            "inputBeef": inputBeef.map(Int.init),
        ]
    }

    private func processAction(_ args: [String: Any]) throws -> [String: Any] {
        let raw = (args["rawTx"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.uint8Value }
        // The toolbox sends the signed transaction itself, as the TS storage client does.
        let subject = try Transaction(bytes: raw, limits: WalletTransactionLimits.standard)
        let sendWith = args["sendWith"] as? [String] ?? []
        processed.append(Processed(
            txid: try subject.transactionID(limits: WalletTransactionLimits.standard).displayHex,
            transaction: subject,
            sendWith: sendWith,
            isSendWith: args["isSendWith"] as? Bool ?? false,
            isNoSend: args["isNoSend"] as? Bool ?? false,
            isDelayed: args["isDelayed"] as? Bool ?? false
        ))
        return ["sendWithResults": sendWith.map { ["txid": $0, "status": sendWithStatus] }]
    }

    /// The source output an outpoint names, as a `createAction` input row.
    private static func resolve(_ outpoint: Outpoint, in graph: BEEF) throws -> (row: [String: Any], output: TransactionOutput) {
        let source = try XCTUnwrap(graph.transactions.compactMap(\.transaction).first {
            (try? $0.transactionID(limits: WalletTransactionLimits.standard)) == outpoint.transactionID
        }, "no source for \(outpoint)")
        let output = source.outputs[Int(outpoint.outputIndex)]
        return ([
            "sourceTxid": outpoint.transactionID.displayHex,
            "sourceVout": Int(outpoint.outputIndex),
            "sourceSatoshis": Int(output.satoshis),
            "sourceLockingScript": output.lockingScript.hex,
        ], output)
    }

    private func envelope(id: Any, result: [String: Any]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }

    private func envelope(id: Any, error: [String: String]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": error])
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}

/// Checks for a SIGMA-sealed output, shared by the SIGMA publish tests.
enum SigmaAssert {
    /// The BAP key `identity-1` the scripted `listOutputs` names as the current identity.
    static func bapKey(_ identity: PrivateKey) throws -> PrivateKey {
        try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID("identity-1"),
            counterparty: .self
        )
    }

    /// Checks the trailing `SIGMA BSM <address> <signature> 0` tape: the signature covers the
    /// script before the tape and anchor input 0, and recovers to the BAP key. Returns the address.
    static func sealed(_ script: Script, anchorTxid: String, identity: PrivateKey) throws -> String {
        let bytes = script.bytes
        let tape: [UInt8] = [0x05] + Array("SIGMA".utf8) + [0x03] + Array("BSM".utf8)
        let tapeStart = try XCTUnwrap(
            stride(from: bytes.count - tape.count, through: 0, by: -1).first {
                Array(bytes[$0..<($0 + tape.count)]) == tape
            },
            "SIGMA tape not found"
        )
        let unsignedEnd: Int
        if tapeStart >= 2, Array(bytes[(tapeStart - 2)..<tapeStart]) == [0x01, 0x7c] {
            unsignedEnd = tapeStart - 2
        } else {
            XCTAssertEqual(bytes[tapeStart - 1], 0x6a)
            unsignedEnd = tapeStart - 1
        }
        let tail = try Script(bytes: Array(bytes[tapeStart...]), maximumByteCount: ActionScript.maximumByteCount)
        let operations = try tail.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
        XCTAssertEqual(operations.count, 5)
        XCTAssertEqual(operations[4].pushedData, Array("0".utf8))
        let addressText = try XCTUnwrap(String(bytes: try XCTUnwrap(operations[2].pushedData), encoding: .utf8))
        let signature = try BitcoinMessageSignature(try XCTUnwrap(operations[3].pushedData))

        let inputHash = try Sigma.getInputHash(txid: anchorTxid, vout: 0)
        let dataHash = BSVHashing.sha256(Array(bytes[..<unsignedEnd])).bytes
        let messageHash = BSVHashing.sha256(inputHash + dataHash).bytes
        let expected = try bapKey(identity).publicKey
        XCTAssertEqual(try signature.recoverPublicKey(message: messageHash).compressedBytes, expected.compressedBytes)
        XCTAssertEqual(addressText, Address(publicKey: expected, network: .mainnet, compressed: true).description)
        XCTAssertTrue(try signature.verifies(message: messageHash, address: try Address(addressText)))
        return addressText
    }

    /// The `createAction` args of each captured request, in order.
    static func createActions(_ bodies: [[UInt8]]) throws -> [[String: Any]] {
        try bodies.compactMap { body in
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
            guard envelope["method"] as? String == "createAction" else { return nil }
            let params = try XCTUnwrap(envelope["params"] as? [Any])
            return try XCTUnwrap(params[1] as? [String: Any])
        }
    }
}
