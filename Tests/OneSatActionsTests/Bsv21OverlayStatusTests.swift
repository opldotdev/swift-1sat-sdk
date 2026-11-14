import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// Overlay output states gate BSV-21 spends. Ports `tokens/overlayFunding.test.ts` and
/// `sweep/sweepBsv21.test.ts` from `@1sat/actions`.
final class Bsv21OverlayStatusTests: XCTestCase {
    private static let tokenID = String(repeating: "a", count: 64) + "_0"
    private static let destination = "1LqLsubMQFR8i6rReaGp1rrXLhe7ZkGVtg"
    private static let activeDetails = Bsv21TokenDetails(
        isActive: true,
        feeAddress: ActionVectors.templateAddress,
        feePerOutput: 0,
        decimals: 0,
        symbol: "TEST"
    )

    // MARK: sendBsv21

    func test_sendReportsTokensQueuedWhenQueuedOutputsWouldCoverTheAmount() async throws {
        let overlay = OverlayStub(states: [.valid, .queued])
        let transport = OverlayTransport(listed: [tokenRow(1, amt: "1"), tokenRow(2, amt: "5")])

        let result = await Tokens.send(
            try context(transport: transport, bsv21: overlay),
            sendRequest(amount: 3)
        )

        XCTAssertEqual(result.error, OneSatActionError.tokensQueued.wireMessage)
        XCTAssertEqual(result.error, "tokens-queued")
        let statusCalls = await overlay.statusCalls
        XCTAssertEqual(statusCalls, [[outpoint(1), outpoint(2)]])
        let methods = await transport.methods
        XCTAssertEqual(methods, ["listOutputs"])
    }

    func test_sendNeverCountsSpentOrUnknownOutputsTowardTheAmount() async throws {
        let overlay = OverlayStub(states: [.spent, .unknown, .valid])
        let transport = OverlayTransport(listed: [
            tokenRow(1, amt: "5"),
            tokenRow(2, amt: "5"),
            tokenRow(3, amt: "1"),
        ])

        let result = await Tokens.send(
            try context(transport: transport, bsv21: overlay),
            sendRequest(amount: 3)
        )

        XCTAssertEqual(result.error, "insufficient-valid-tokens")
    }

    func test_sendAsksTheOverlayOnlyAboutTheRequestedTokensOutputs() async throws {
        let otherToken = String(repeating: "b", count: 64) + "_0"
        let overlay = OverlayStub(states: [.queued])
        let transport = OverlayTransport(listed: [
            tokenRow(1, amt: "9", tokenID: otherToken),
            tokenRow(2, amt: "9"),
        ])

        let result = await Tokens.send(
            try context(transport: transport, bsv21: overlay),
            sendRequest(amount: 3)
        )

        XCTAssertEqual(result.error, "tokens-queued")
        let statusCalls = await overlay.statusCalls
        XCTAssertEqual(statusCalls, [[outpoint(2)]])
    }

    func test_sendMapsDetailAndStatusFailures() async throws {
        let rows = [tokenRow(1, amt: "5")]
        let missing = await Tokens.send(
            try context(
                transport: OverlayTransport(listed: rows),
                bsv21: OverlayStub(states: [.valid], detailsError: StubFailure.down)
            ),
            sendRequest(amount: 3)
        )
        let inactive = await Tokens.send(
            try context(
                transport: OverlayTransport(listed: rows),
                bsv21: OverlayStub(
                    states: [.valid],
                    details: Bsv21TokenDetails(
                        isActive: false,
                        feeAddress: ActionVectors.templateAddress,
                        feePerOutput: 0,
                        decimals: 0
                    )
                )
            ),
            sendRequest(amount: 3)
        )
        let unreachable = await Tokens.send(
            try context(
                transport: OverlayTransport(listed: rows),
                bsv21: OverlayStub(states: [.valid], statusError: StubFailure.down)
            ),
            sendRequest(amount: 3)
        )
        let noServices = await Tokens.send(
            try context(transport: OverlayTransport(listed: rows), bsv21: nil),
            sendRequest(amount: 3)
        )

        XCTAssertEqual(missing.error, "token-not-found")
        XCTAssertEqual(inactive.error, "token-not-active")
        XCTAssertEqual(unreachable.error, "overlay-validation-failed")
        XCTAssertEqual(noServices.error, "services-required")
    }

    func test_selectionSpendsOnlyValidOutputsAndWithoutStatesKeepsTheOldShortfall() throws {
        let outputs = try [tokenOutput(1, amt: "4"), tokenOutput(2, amt: "4"), tokenOutput(3, amt: "4")]
        let selected = try Tokens.selectInputs(
            outputs: outputs,
            tokenId: Self.tokenID,
            amount: 6,
            states: [outpoint(1): .valid, outpoint(2): .queued, outpoint(3): .valid]
        )
        XCTAssertEqual(selected.selected.map(\.output.outpoint.description), [outpoint(1), outpoint(3)])
        XCTAssertEqual(selected.totalIn, 8)

        XCTAssertThrowsError(try Tokens.selectInputs(
            outputs: outputs,
            tokenId: Self.tokenID,
            amount: 20,
            states: nil
        )) { XCTAssertEqual($0 as? OneSatActionError, .insufficientTokens) }
        XCTAssertThrowsError(try Tokens.selectInputs(
            outputs: outputs,
            tokenId: Self.tokenID,
            amount: 9,
            states: [outpoint(1): .valid]
        )) { XCTAssertEqual($0 as? OneSatActionError, .insufficientValidTokens) }
    }

    // MARK: fundBsv21Overlay

    private static let template = Tokens.FundingTemplate(outputs: [
        .init(
            lockingScript: try! Hex.decode(
                "76a914cc5f973def854a5a6015dc619462497473c0b02e88ac",
                maximumDecodedByteCount: 25
            ),
            satoshis: 10_010_000,
            outputDescription: "Fund TEST overlay"
        ),
    ])

    func test_fundPaysTheTemplateOutputsAndSubmitsTheTransactionToTheOverlay() async throws {
        let overlay = OverlayStub(template: Self.template)
        let transport = OverlayTransport()

        let result = await Tokens.fundOverlay(
            try context(transport: transport, bsv21: overlay),
            tokenId: Self.tokenID
        )

        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertEqual(result.status?.isActive, true)
        let txid = try XCTUnwrap(result.txid)
        let tx = try XCTUnwrap(result.tx)
        let captured = await transport.capturedCreateAction()
        let created = try XCTUnwrap(captured)
        XCTAssertEqual(created.description, "Fund TEST overlay")
        XCTAssertEqual(created.acceptDelayedBroadcast, false)
        XCTAssertEqual(created.labels, [])
        XCTAssertEqual(created.inputCount, 0)
        XCTAssertEqual(created.outputs.count, 1)
        XCTAssertEqual(
            created.outputs[0].lockingScript,
            "76a914cc5f973def854a5a6015dc619462497473c0b02e88ac"
        )
        XCTAssertEqual(created.outputs[0].satoshis, 10_010_000)
        XCTAssertEqual(created.outputs[0].outputDescription, "Fund TEST overlay")
        XCTAssertNil(created.outputs[0].basket)
        XCTAssertEqual(created.outputs[0].tags, [])
        let submitted = await overlay.submitted
        XCTAssertEqual(submitted.map(\.tokenId), [Self.tokenID])
        XCTAssertEqual(submitted.map(\.beef), [tx])
        let atomic = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard)
        XCTAssertEqual(atomic.subjectTransactionID.displayHex, txid)
    }

    func test_fundDoesNotPayWhenTheOverlayNeedsNoFunding() async throws {
        let overlay = OverlayStub(template: .init(outputs: []))
        let transport = OverlayTransport()

        let result = await Tokens.fundOverlay(
            try context(transport: transport, bsv21: overlay),
            tokenId: Self.tokenID
        )

        XCTAssertEqual(result.error, "funding-not-needed")
        XCTAssertNil(result.txid)
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
        let submitted = await overlay.submitted
        XCTAssertTrue(submitted.isEmpty)
    }

    func test_fundReturnsTheTxidWhenThePaymentWentOutButSubmissionFailed() async throws {
        let overlay = OverlayStub(template: Self.template, submitError: StubFailure.down)
        let transport = OverlayTransport()

        let result = await Tokens.fundOverlay(
            try context(transport: transport, bsv21: overlay),
            tokenId: Self.tokenID
        )

        XCTAssertNotNil(result.txid)
        XCTAssertNotNil(result.tx)
        XCTAssertNil(result.status)
        XCTAssertEqual(result.error, "funding-submit-failed")
    }

    func test_fundRequiresServicesAndReportsAFailedPayment() async throws {
        let noServices = await Tokens.fundOverlay(
            try context(transport: OverlayTransport(), bsv21: nil),
            tokenId: Self.tokenID
        )
        let overlay = OverlayStub(template: Self.template)
        let failedPayment = await Tokens.fundOverlay(
            try context(transport: OverlayTransport(completeActions: false), bsv21: overlay),
            tokenId: Self.tokenID
        )

        XCTAssertEqual(noServices.error, "services-required")
        XCTAssertNotNil(failedPayment.error)
        XCTAssertNil(failedPayment.txid)
        let submitted = await overlay.submitted
        XCTAssertTrue(submitted.isEmpty)
    }

    // MARK: sweepBsv21

    func test_sweepRefusesWhenTheOverlayReportsNoInputValid() async throws {
        let fixture = try sweepFixture()
        let transport = OverlayTransport()

        let result = await AssetSweep.bsv21(
            try context(transport: transport, bsv21: OverlayStub(states: [.queued, .unknown])),
            inputs: fixture.inputs,
            inputBEEF: fixture.beef,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: 0,
            symbol: nil,
            decimals: 0
        )

        XCTAssertEqual(result.error, "unvalidated-inputs")
        XCTAssertNil(result.spentOutpoints)
        let methods = await transport.methods
        XCTAssertEqual(methods, [])
    }

    func test_sweepRefusesWhenTheOverlayCannotBeReached() async throws {
        let fixture = try sweepFixture()

        let result = await AssetSweep.bsv21(
            try context(
                transport: OverlayTransport(),
                bsv21: OverlayStub(states: [], statusError: StubFailure.down)
            ),
            inputs: fixture.inputs,
            inputBEEF: fixture.beef,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: 0,
            symbol: nil,
            decimals: 0
        )

        XCTAssertEqual(result.error, "overlay-validation-failed")
    }

    func test_sweepRequiresOverlayServices() async throws {
        let fixture = try sweepFixture()

        let result = await AssetSweep.bsv21(
            try context(transport: OverlayTransport(), bsv21: nil),
            inputs: fixture.inputs,
            inputBEEF: fixture.beef,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: 0,
            symbol: nil,
            decimals: 0
        )

        XCTAssertEqual(result.error, "services-required")
    }

    func test_sweepSpendsOnlyValidInputsAndReportsThem() async throws {
        let fixture = try sweepFixture()
        let overlay = OverlayStub(states: [.valid, .spent])
        let transport = OverlayTransport()

        let result = await AssetSweep.bsv21(
            try context(transport: transport, bsv21: overlay),
            inputs: fixture.inputs,
            inputBEEF: fixture.beef,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: 0,
            symbol: nil,
            decimals: 0
        )

        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNotNil(result.txid)
        XCTAssertEqual(result.spentOutpoints, [fixture.inputs[0].outpoint])
        let statusCalls = await overlay.statusCalls
        XCTAssertEqual(statusCalls, [fixture.inputs.map(\.outpoint)])
        let captured = await transport.capturedCreateAction()
        let created = try XCTUnwrap(captured)
        XCTAssertEqual(created.description, "Sweep 1 token UTXO")
        XCTAssertEqual(created.inputOutpoints, [fixture.inputs[0].outpoint])
        XCTAssertEqual(created.outputs.first?.outputDescription, "Sweep 5 tokens")
        // The funded graph carries only the valid input's source transaction.
        let wireBEEF = try BEEF(bytes: created.inputBEEF, limits: WalletBEEFLimits.standard)
        XCTAssertEqual(
            try wireBEEF.transactions.map {
                try $0.transactionID(limits: WalletBEEFLimits.standard.transactionLimits).displayHex
            },
            [fixture.validTxid]
        )
        let submitted = await overlay.transfers
        XCTAssertEqual(submitted, 1)
    }

    // MARK: Fixtures

    private func sendRequest(amount: UInt64) -> Tokens.SendRequest {
        Tokens.SendRequest(
            tokenId: Self.tokenID,
            recipients: [Tokens.Recipient(amount: amount, destination: .address(Self.destination))]
        )
    }

    private func outpoint(_ n: Int) -> String {
        TokenRow.outpoint(n)
    }

    private func tokenRow(_ n: Int, amt: String, tokenID: String = tokenID) -> TokenRow {
        TokenRow(n: n, amt: amt, tokenID: tokenID)
    }

    private func tokenOutput(_ n: Int, amt: String) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            tags: ["bsv21:\(Self.tokenID)", "amt:\(amt)"],
            outpoint: try Outpoint(outpoint(n))
        )
    }

    private struct SweepFixture {
        let inputs: [AssetSweep.TokenInput]
        let beef: BEEF
        let validTxid: String
    }

    /// Two legacy token UTXOs in two source transactions held by one WIF key.
    private func sweepFixture() throws -> SweepFixture {
        let key = try ActionVectors.recipient()
        let lock = try ActionScript.payToPublicKeyHash(Address(publicKey: key.publicKey, network: .mainnet))
        let sources = (0..<2).map { index in
            Transaction(
                version: 1,
                inputs: [],
                outputs: [TransactionOutput(satoshis: 1, lockingScript: lock)],
                lockTime: UInt32(index)
            )
        }
        let txids = try sources.map {
            try $0.transactionID(limits: WalletTransactionLimits.standard).displayHex
        }
        let beef = try BEEF(
            merklePaths: [],
            transactions: sources.map { .raw($0) },
            limits: WalletBEEFLimits.standard
        )
        let inputs = txids.map { txid in
            AssetSweep.TokenInput(
                outpoint: "\(txid)_0",
                satoshis: 1,
                lockingScript: lock.bytes,
                tokenID: Self.tokenID,
                amount: 5,
                key: key
            )
        }
        return SweepFixture(inputs: inputs, beef: beef, validTxid: txids[0])
    }

    private func context(
        transport: OverlayTransport,
        bsv21: (any Bsv21ActionServices)?
    ) throws -> OneSatContext {
        let identity = try ActionVectors.identity()
        return OneSatContext(
            identity: identity,
            storage: StorageClient(
                endpoint: URL(string: "https://example.invalid")!,
                transport: transport
            ),
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
            bsv21: bsv21
        )
    }
}

/// A wallet `bsv21` basket row: tags plus TS-shaped custom instructions.
private struct TokenRow: Sendable {
    let n: Int
    let amt: String
    let tokenID: String

    static func outpoint(_ n: Int) -> String {
        let hex = String(n, radix: 16)
        return String(repeating: "0", count: 64 - hex.count) + hex + ".0"
    }

    var json: [String: Any] {
        [
            "outpoint": Self.outpoint(n),
            "satoshis": 1,
            "spendable": true,
            "tags": ["bsv21:\(tokenID)", "amt:\(amt)"],
            "customInstructions": #"{"id":"\#(tokenID)","amt":"\#(amt)","op":"transfer"}"#,
        ]
    }
}

private enum StubFailure: Error {
    case down
}

/// Answers each requested outpoint, as sent, with the state at its index (TS test stub shape).
private actor OverlayStub: Bsv21ActionServices {
    struct Submission: Equatable {
        let tokenId: String
        let beef: [UInt8]
    }

    let states: [Tokens.OutputState]
    let details: Bsv21TokenDetails
    let detailsError: Error?
    let statusError: Error?
    let template: Tokens.FundingTemplate
    let submitError: Error?
    private(set) var statusCalls: [[String]] = []
    private(set) var submitted: [Submission] = []
    private(set) var transfers = 0

    init(
        states: [Tokens.OutputState] = [],
        details: Bsv21TokenDetails = Bsv21TokenDetails(
            isActive: true,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: 0,
            decimals: 0,
            symbol: "TEST"
        ),
        detailsError: Error? = nil,
        statusError: Error? = nil,
        template: Tokens.FundingTemplate = .init(outputs: []),
        submitError: Error? = nil
    ) {
        self.states = states
        self.details = details
        self.detailsError = detailsError
        self.statusError = statusError
        self.template = template
        self.submitError = submitError
    }

    func tokenDetails(tokenId _: String, fresh _: Bool) async throws -> Bsv21TokenDetails {
        if let detailsError { throw detailsError }
        return details
    }

    func outputStatus(tokenId _: String, outpoints: [String]) async throws -> [Tokens.OutputStatus] {
        statusCalls.append(outpoints)
        if let statusError { throw statusError }
        return zip(outpoints, states).map { Tokens.OutputStatus(outpoint: $0, state: $1) }
    }

    func fundingTemplate(tokenId _: String) async throws -> Tokens.FundingTemplate {
        template
    }

    func submitFunding(tokenId: String, beef: [UInt8]) async throws -> Tokens.OverlayStatus {
        submitted.append(Submission(tokenId: tokenId, beef: beef))
        if let submitError { throw submitError }
        return Tokens.OverlayStatus(isActive: true)
    }

    func submitTransfer(tx _: [UInt8], tokenId _: String) async throws {
        transfers += 1
    }

    func submitDiscovery(tx _: [UInt8]) async throws {}
}

private struct CapturedCreateAction: Sendable {
    struct Output: Sendable {
        let satoshis: UInt64
        let outputDescription: String?
        let basket: String?
        let lockingScript: String
        let tags: [String]
    }

    let description: String
    let acceptDelayedBroadcast: Bool?
    let labels: [String]
    let inputCount: Int
    let inputOutpoints: [String]
    let inputBEEF: [UInt8]
    let outputs: [Output]
}

/// Storage stub: `listOutputs` answers `listed`, `createAction` funds from one synthetic
/// source (or echoes caller inputs with their BEEF), `processAction` succeeds.
private actor OverlayTransport: AuthenticatedTransport {
    private(set) var methods: [String] = []
    private(set) var bodies: [[UInt8]] = []
    private let listed: [TokenRow]
    private let completeActions: Bool
    private var nextReference = 0

    init(listed: [TokenRow] = [], completeActions: Bool = true) {
        self.listed = listed
        self.completeActions = completeActions
    }

    func capturedCreateAction() -> CapturedCreateAction? {
        for body in bodies {
            guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
                  object["method"] as? String == "createAction",
                  let params = object["params"] as? [Any],
                  params.count >= 2,
                  let args = params[1] as? [String: Any]
            else { continue }
            let options = args["options"] as? [String: Any] ?? [:]
            let inputs = args["inputs"] as? [[String: Any]] ?? []
            return CapturedCreateAction(
                description: args["description"] as? String ?? "",
                acceptDelayedBroadcast: options["acceptDelayedBroadcast"] as? Bool,
                labels: args["labels"] as? [String] ?? [],
                inputCount: inputs.count,
                inputOutpoints: inputs.compactMap { input in
                    storageOutpoint(input["outpoint"]).map { $0.replacingOccurrences(of: ".", with: "_") }
                },
                inputBEEF: Self.bytes(args["inputBEEF"]),
                outputs: (args["outputs"] as? [[String: Any]] ?? []).map { output in
                    CapturedCreateAction.Output(
                        satoshis: (output["satoshis"] as? NSNumber)?.uint64Value ?? 0,
                        outputDescription: output["outputDescription"] as? String,
                        basket: output["basket"] as? String,
                        lockingScript: output["lockingScript"] as? String ?? "",
                        tags: output["tags"] as? [String] ?? []
                    )
                }
            )
        }
        return nil
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
        methods.append(rpcMethod)
        bodies.append(body ?? [])
        switch rpcMethod {
        case "listOutputs":
            return try envelope(
                id: id,
                result: ["totalOutputs": listed.count, "outputs": listed.map(\.json)]
            )
        case "createAction" where completeActions:
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
        let outputRows = requested.enumerated().map { index, output -> [String: Any] in
            [
                "lockingScript": output["lockingScript"] as? String ?? "",
                "satoshis": output["satoshis"] as Any,
                "vout": index,
                "providedBy": "you",
            ]
        }

        let inputs: [[String: Any]]
        let inputBeef: [UInt8]
        if requestedInputs.isEmpty {
            // Cover the outputs with a 1,000-sat fee, inside the context's maximum.
            let sourceSatoshis = requested.reduce(UInt64(1_000)) {
                $0 + (($1["satoshis"] as? NSNumber)?.uint64Value ?? 0)
            }
            let sourceLock = try Script(bytes: [0x51], maximumByteCount: 10_000)
            let source = Transaction(
                version: 1,
                inputs: [],
                outputs: [TransactionOutput(satoshis: sourceSatoshis, lockingScript: sourceLock)],
                lockTime: 0
            )
            let sourceTxid = try source.transactionID(limits: WalletTransactionLimits.standard)
            inputBeef = try BEEF(
                merklePaths: [],
                transactions: [.raw(source)],
                limits: WalletBEEFLimits.standard
            ).serialized(limits: WalletBEEFLimits.standard)
            inputs = [[
                "sourceTxid": sourceTxid.displayHex,
                "sourceVout": 0,
                "sourceSatoshis": sourceSatoshis,
                "sourceLockingScript": sourceLock.hex,
                "unlockingScriptLength": 108,
            ]]
        } else {
            inputBeef = Self.bytes(args["inputBEEF"])
            inputs = requestedInputs.map { input in
                let parts = (storageOutpoint(input["outpoint"]) ?? "").split(separator: ".")
                return [
                    "sourceTxid": parts.isEmpty ? "" : String(parts[0]),
                    "sourceVout": parts.count > 1 ? Int(parts[1]) ?? 0 : 0,
                    "sourceSatoshis": 1,
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
            result["inputBeef"] = inputBeef.map(Int.init)
        }
        return try envelope(id: id, result: result)
    }

    private static func bytes(_ value: Any?) -> [UInt8] {
        (value as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.uint8Value }
    }

    private func envelope(id: Any, result: [String: Any]) throws -> AuthenticatedResponse {
        let data = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]
        )
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}
