import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `Fixtures/bsv21-deploy-mint.json`: the `createAction` arguments `@1sat/actions` 0.1.6 sends for
/// `deployBsv21Mint`, `deployBsv21Auth` and `mintBsv21`, recorded at the wallet with
/// `@1sat/templates` 0.1.1 and `@bsv/sdk` 4.1.0 (`meta.packages`). Key IDs and action ids come
/// from a counter in place of `crypto.getRandomValues`, so each case pins its key IDs.
enum Bsv21CreateFixture {
    struct Output {
        let lockingScript: String
        let satoshis: UInt64
        let outputDescription: String
        let basket: String?
        let tags: [String]
        let customInstructions: String?
    }

    struct Input: Equatable {
        let outpoint: String
        let inputDescription: String
        let unlockingScriptLength: Int
    }

    struct Request {
        let description: String
        let labels: [String]
        let inputs: [Input]
        let outputs: [Output]
        let randomizeOutputs: Bool?
    }

    struct Case {
        let input: [String: Any]
        let result: [String: Any]
        let request: Request?
        let overlay: [String]
        let authorities: [[String: Any]]
        let details: [String: Any]?

        var error: String? { result["error"] as? String }

        /// Every key ID in the case's output CI, in output order.
        var keyIDs: [String] {
            (request?.outputs ?? []).compactMap { output in
                output.customInstructions.flatMap { RemittanceJSON.dictionary($0)?["keyID"] as? String }
            }
        }
    }

    static func root() -> [String: Any] {
        guard let url = Bundle.module.url(forResource: "Fixtures/bsv21-deploy-mint", withExtension: "json")
            ?? Bundle.module.url(forResource: "bsv21-deploy-mint", withExtension: "json", subdirectory: "Fixtures"),
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fatalError("Fixtures/bsv21-deploy-mint.json is missing or unreadable") }
        return object
    }

    static var recipientPublicKey: String {
        (root()["meta"] as? [String: Any])?["recipientPublicKey"] as? String ?? ""
    }

    static func named(_ name: String) throws -> Case {
        let cases = try XCTUnwrap(root()["cases"] as? [String: Any])
        let raw = try XCTUnwrap(cases[name] as? [String: Any], "fixture case \(name)")
        var request: Request?
        if let r = raw["request"] as? [String: Any] {
            request = Request(
                description: r["description"] as? String ?? "",
                labels: r["labels"] as? [String] ?? [],
                inputs: (r["inputs"] as? [[String: Any]] ?? []).map {
                    Input(
                        outpoint: $0["outpoint"] as? String ?? "",
                        inputDescription: $0["inputDescription"] as? String ?? "",
                        unlockingScriptLength: ($0["unlockingScriptLength"] as? NSNumber)?.intValue ?? -1
                    )
                },
                outputs: (r["outputs"] as? [[String: Any]] ?? []).map(output),
                randomizeOutputs: (r["options"] as? [String: Any])?["randomizeOutputs"] as? Bool
            )
        }
        return Case(
            input: raw["input"] as? [String: Any] ?? [:],
            result: raw["result"] as? [String: Any] ?? [:],
            request: request,
            overlay: raw["overlay"] as? [String] ?? [],
            authorities: raw["authorities"] as? [[String: Any]] ?? [],
            details: raw["details"] as? [String: Any]
        )
    }

    static func output(_ object: [String: Any]) -> Output {
        Output(
            lockingScript: object["lockingScript"] as? String ?? "",
            satoshis: (object["satoshis"] as? NSNumber)?.uint64Value ?? 0,
            outputDescription: object["outputDescription"] as? String ?? "",
            basket: object["basket"] as? String,
            tags: object["tags"] as? [String] ?? [],
            customInstructions: object["customInstructions"] as? String
        )
    }

    /// A TS `destination` object.
    static func destination(_ value: Any?) throws -> Destination? {
        guard let object = value as? [String: Any] else { return nil }
        if let address = object["address"] as? String { return .address(address) }
        if let counterparty = object["counterparty"] as? String {
            let key = try PublicKey(Hex.decode(counterparty, maximumDecodedByteCount: 33))
            return .counterparty(.publicKey(key))
        }
        return .self
    }

    static func details(_ object: [String: Any]?) throws -> Bsv21TokenDetails {
        let object = try XCTUnwrap(object)
        let token = object["token"] as? [String: Any] ?? [:]
        let status = object["status"] as? [String: Any] ?? [:]
        return Bsv21TokenDetails(
            isActive: status["is_active"] as? Bool ?? false,
            feeAddress: status["fee_address"] as? String ?? "",
            feePerOutput: (status["fee_per_output"] as? NSNumber)?.uint64Value ?? 0,
            decimals: (token["dec"] as? NSNumber)?.intValue ?? 0,
            symbol: token["sym"] as? String,
            icon: token["icon"] as? String
        )
    }

    static func walletOutput(_ row: [String: Any]) throws -> WalletOutput {
        try WalletOutput(
            satoshis: (row["satoshis"] as? NSNumber)?.uint64Value ?? 1,
            spendable: row["spendable"] as? Bool ?? true,
            customInstructions: row["customInstructions"] as? String,
            tags: row["tags"] as? [String],
            outpoint: try Outpoint(XCTUnwrap(row["outpoint"] as? String))
        )
    }

    /// Asserts the Swift outputs equal TS's, field for field. `id:` tags are compared apart, since
    /// the action id is random: each basketed output must end with `id:<actionId>_<index>`.
    static func assertOutputs(
        _ swift: [Output],
        equal ts: [Output],
        actionId: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(swift.count, ts.count, "output count", file: file, line: line)
        for (index, (mine, theirs)) in zip(swift, ts).enumerated() {
            XCTAssertEqual(mine.lockingScript, theirs.lockingScript, "output \(index) script", file: file, line: line)
            XCTAssertEqual(mine.satoshis, theirs.satoshis, "output \(index) satoshis", file: file, line: line)
            XCTAssertEqual(mine.outputDescription, theirs.outputDescription, "output \(index) description", file: file, line: line)
            XCTAssertEqual(mine.basket, theirs.basket, "output \(index) basket", file: file, line: line)
            XCTAssertEqual(
                mine.customInstructions, theirs.customInstructions,
                "output \(index) customInstructions", file: file, line: line
            )
            XCTAssertEqual(
                mine.tags.filter { !$0.hasPrefix("id:") }, theirs.tags.filter { !$0.hasPrefix("id:") },
                "output \(index) tags", file: file, line: line
            )
            if theirs.basket != nil {
                XCTAssertEqual(theirs.tags.last?.hasPrefix("id:"), true, file: file, line: line)
                if let actionId {
                    XCTAssertEqual(mine.tags.last, "id:\(actionId)_\(index)", file: file, line: line)
                }
            }
        }
    }
}

/// Overlay services stub: fixed token details, recorded submissions, optional failures.
actor Bsv21CreateOverlay: Bsv21ActionServices {
    var details: Bsv21TokenDetails
    var detailsError: Error?
    var discoveryError: Error?
    var transferError: Error?
    private(set) var discoveries: [[UInt8]] = []
    private(set) var transfers: [(tokenId: String, tx: [UInt8])] = []

    init(details: Bsv21TokenDetails = Bsv21TokenDetails(
        isActive: true, feeAddress: ActionVectors.templateAddress, feePerOutput: 0, decimals: 0
    )) {
        self.details = details
    }

    func failDiscovery(_ error: Error?) { discoveryError = error }
    func failDetails(_ error: Error?) { detailsError = error }

    var transferTokenIds: [String] { transfers.map(\.tokenId) }

    func tokenDetails(tokenId _: String) async throws -> Bsv21TokenDetails {
        if let detailsError { throw detailsError }
        return details
    }

    func outputStatus(tokenId _: String, outpoints: [String]) async throws -> [Tokens.OutputStatus] {
        outpoints.map { Tokens.OutputStatus(outpoint: $0, state: .valid) }
    }

    func fundingTemplate(tokenId _: String) async throws -> Tokens.FundingTemplate {
        .init(outputs: [])
    }

    func submitFunding(tokenId _: String, beef _: [UInt8]) async throws -> Tokens.OverlayStatus {
        Tokens.OverlayStatus(isActive: true)
    }

    func submitTransfer(tx: [UInt8], tokenId: String) async throws {
        transfers.append((tokenId, tx))
        if let transferError { throw transferError }
    }

    func submitDiscovery(tx: [UInt8]) async throws {
        discoveries.append(tx)
        if let discoveryError { throw discoveryError }
    }
}

enum Bsv21CreateFailure: Error {
    case down
}

/// Storage stub: `listOutputs` answers `rows` (and `listBEEF`), `createAction` funds from one
/// synthetic source and echoes caller inputs with the source outputs given in `sources`,
/// `processAction` succeeds. The `createAction` arguments are kept as sent.
actor Bsv21CreateStorage: AuthenticatedTransport {
    struct Source: Sendable {
        let lockingScript: String
        let satoshis: UInt64
    }

    private(set) var methods: [String] = []
    struct ListCall: Equatable, Sendable {
        let basket: String?
        let tags: [String]?
        let tagQueryMode: String?
        let includeCustomInstructions: Bool?
        let includeTags: Bool?
    }

    private(set) var listRequests: [ListCall] = []
    private(set) var createArgs: [String: Any]?
    private let rowsJSON: Data
    private let listBEEF: [UInt8]?
    private let sources: [String: Source]
    private var nextReference = 0

    init(rowsJSON: Data = Data("[]".utf8), listBEEF: [UInt8]? = nil, sources: [String: Source] = [:]) {
        self.rowsJSON = rowsJSON
        self.listBEEF = listBEEF
        self.sources = sources
    }

    /// `rows` are wallet `listOutputs` rows as the wire carries them.
    static func make(
        rows: [[String: Any]],
        listBEEF: [UInt8]? = nil,
        sources: [String: Source] = [:]
    ) throws -> Bsv21CreateStorage {
        Bsv21CreateStorage(
            rowsJSON: try JSONSerialization.data(withJSONObject: rows),
            listBEEF: listBEEF,
            sources: sources
        )
    }

    var createdOutputs: [Bsv21CreateFixture.Output] {
        (createArgs?["outputs"] as? [[String: Any]] ?? []).map(Bsv21CreateFixture.output)
    }

    var createdInputs: [Bsv21CreateFixture.Input] {
        (createArgs?["inputs"] as? [[String: Any]] ?? []).map {
            Bsv21CreateFixture.Input(
                outpoint: $0["outpoint"] as? String ?? "",
                inputDescription: $0["inputDescription"] as? String ?? "",
                unlockingScriptLength: ($0["unlockingScriptLength"] as? NSNumber)?.intValue ?? -1
            )
        }
    }

    var createdDescription: String? { createArgs?["description"] as? String }
    var createdLabels: [String] { createArgs?["labels"] as? [String] ?? [] }
    var createdRandomizeOutputs: Bool? {
        (createArgs?["options"] as? [String: Any])?["randomizeOutputs"] as? Bool
    }

    func send(
        method _: String,
        path _: String,
        query _: String?,
        headers _: [String: String],
        body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        let object = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
        let rpcMethod = object?["method"] as? String ?? ""
        let id = object?["id"] as Any
        let params = object?["params"] as? [Any]
        let args = params.flatMap { $0.count > 1 ? $0[1] as? [String: Any] : nil } ?? [:]
        methods.append(rpcMethod)
        switch rpcMethod {
        case "listOutputs":
            listRequests.append(ListCall(
                basket: args["basket"] as? String,
                tags: args["tags"] as? [String],
                tagQueryMode: args["tagQueryMode"] as? String,
                includeCustomInstructions: args["includeCustomInstructions"] as? Bool,
                includeTags: args["includeTags"] as? Bool
            ))
            let rows = try JSONSerialization.jsonObject(with: rowsJSON) as? [[String: Any]] ?? []
            var result: [String: Any] = ["totalOutputs": rows.count, "outputs": rows]
            if let listBEEF { result["BEEF"] = listBEEF.map(Int.init) }
            return try envelope(id: id, result: result)
        case "createAction":
            createArgs = args
            return try createActionResponse(id: id, args: args)
        case "processAction":
            return try envelope(id: id, result: ["sendWithResults": [Any]()])
        case "abortAction":
            return try envelope(id: id, result: ["aborted": true])
        default:
            throw AuthTransportError.notImplemented("offline")
        }
    }

    private func createActionResponse(id: Any, args: [String: Any]) throws -> AuthenticatedResponse {
        let requested = args["outputs"] as? [[String: Any]] ?? []
        let requestedInputs = args["inputs"] as? [[String: Any]] ?? []
        let outputRows = requested.enumerated().map { index, output -> [String: Any] in
            [
                "lockingScript": output["lockingScript"] as? String ?? "",
                "satoshis": output["satoshis"] as Any,
                "vout": index,
                "providedBy": "you",
            ]
        }
        var inputs: [[String: Any]] = requestedInputs.map { input in
            let outpoint = input["outpoint"] as? String ?? ""
            let parts = outpoint.split(separator: ".")
            let source = sources[outpoint] ?? Source(lockingScript: "51", satoshis: 1)
            return [
                "sourceTxid": parts.isEmpty ? "" : String(parts[0]),
                "sourceVout": parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                "sourceSatoshis": source.satoshis,
                "sourceLockingScript": source.lockingScript,
                "unlockingScriptLength": input["unlockingScriptLength"] as Any,
            ]
        }
        // One storage funding input covering the outputs plus a 1,000-sat fee.
        let fundingSatoshis = requested.reduce(UInt64(1_000)) {
            $0 + (($1["satoshis"] as? NSNumber)?.uint64Value ?? 0)
        }
        let fundingLock = try Script(bytes: [0x51], maximumByteCount: 10_000)
        let funding = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: fundingSatoshis, lockingScript: fundingLock)],
            lockTime: 0
        )
        let fundingTxid = try funding.transactionID(limits: WalletTransactionLimits.standard)
        inputs.append([
            "sourceTxid": fundingTxid.displayHex,
            "sourceVout": 0,
            "sourceSatoshis": fundingSatoshis,
            "sourceLockingScript": fundingLock.hex,
            "unlockingScriptLength": 108,
        ])
        var beef = try BEEF(merklePaths: [], transactions: [.raw(funding)], limits: WalletBEEFLimits.standard)
        let callerBEEF = (args["inputBEEF"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.uint8Value }
        if !callerBEEF.isEmpty {
            beef = try beef.merging(
                try BEEF(bytes: callerBEEF, limits: WalletBEEFLimits.standard),
                limits: WalletBEEFLimits.standard
            )
        }
        let result: [String: Any] = [
            "reference": "ref-\(nextReference)",
            "version": 1,
            "lockTime": 0,
            "inputs": inputs,
            "outputs": outputRows,
            "inputBeef": try beef.serialized(limits: WalletBEEFLimits.standard).map(Int.init),
        ]
        nextReference += 1
        return try envelope(id: id, result: result)
    }

    private func envelope(id: Any, result: [String: Any]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]
        )
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}

func bsv21CreateContext(
    storage: Bsv21CreateStorage,
    bsv21: (any Bsv21ActionServices)?
) throws -> OneSatContext {
    let identity = try ActionVectors.identity()
    return OneSatContext(
        identity: identity,
        storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: storage),
        auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
        bsv21: bsv21
    )
}

/// The subject transaction of an Atomic BEEF.
func bsv21SubjectTransaction(_ tx: [UInt8]) throws -> Transaction {
    let atomic = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard)
    return try XCTUnwrap(
        try atomic.beef.transaction(
            for: atomic.subjectTransactionID,
            limits: WalletBEEFLimits.standard.transactionLimits
        )
    )
}
