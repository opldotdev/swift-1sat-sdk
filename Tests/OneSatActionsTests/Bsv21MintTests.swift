import Foundation
import BSVCore
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `mintBsv21` against the requests `@1sat/actions` 0.1.6 sends (`Fixtures/bsv21-deploy-mint.json`),
/// plus the signed flow over a real authority transaction.
final class Bsv21MintTests: XCTestCase {
    // MARK: Request parity

    private func request(_ fixture: Bsv21CreateFixture.Case) throws -> Tokens.MintRequest {
        let input = fixture.input
        var mint: Tokens.MintOutput?
        if let object = input["mint"] as? [String: Any] {
            mint = Tokens.MintOutput(
                amount: try XCTUnwrap(UInt64(XCTUnwrap(object["amount"] as? String))),
                destination: try Bsv21CreateFixture.destination(object["destination"])
            )
        }
        var auth: Destination?
        if let object = input["auth"] as? [String: Any] {
            auth = try Bsv21CreateFixture.destination(object["destination"]) ?? .self
        }
        return Tokens.MintRequest(
            tokenId: try XCTUnwrap(input["tokenId"] as? String),
            mint: mint,
            auth: auth,
            endMinting: input["endMinting"] as? Bool ?? false
        )
    }

    private func keyID(_ fixture: Bsv21CreateFixture.Case, op: String) -> String? {
        for output in fixture.request?.outputs ?? [] {
            guard let ci = output.customInstructions,
                  let object = RemittanceJSON.dictionary(ci),
                  object["op"] as? String == op
            else { continue }
            return object["keyID"] as? String
        }
        return nil
    }

    private func assertPreparedMatches(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try Bsv21CreateFixture.named(name)
        let ts = try XCTUnwrap(fixture.request)
        let rows = try fixture.authorities.map(Bsv21CreateFixture.walletOutput)
        let mintRequest = try request(fixture)
        let authority = try XCTUnwrap(
            Tokens.authorityOutput(rows, tokenId: mintRequest.tokenId),
            file: file, line: line
        )

        let prepared = try Tokens.prepareMint(
            identity: try ActionVectors.identity(),
            mintRequest,
            details: try Bsv21CreateFixture.details(fixture.details),
            authority: authority,
            mintKeyID: keyID(fixture, op: "mint"),
            authKeyID: keyID(fixture, op: "auth")
        )

        XCTAssertEqual(prepared.description, ts.description, file: file, line: line)
        XCTAssertEqual(prepared.labels, ts.labels, file: file, line: line)
        XCTAssertEqual(
            [Bsv21CreateFixture.Input(
                outpoint: prepared.input.outpoint.description,
                inputDescription: prepared.input.inputDescription,
                unlockingScriptLength: {
                    if case .scriptLength(let length) = prepared.input.unlocking { return Int(length) }
                    return -1
                }()
            )],
            ts.inputs,
            file: file, line: line
        )
        let outputs = prepared.outputs.map {
            Bsv21CreateFixture.Output(
                lockingScript: Hex.encode($0.lockingScript),
                satoshis: $0.satoshis,
                outputDescription: $0.outputDescription,
                basket: $0.basket,
                tags: $0.tags,
                customInstructions: $0.customInstructions
            )
        }
        Bsv21CreateFixture.assertOutputs(outputs, equal: ts.outputs, actionId: nil, file: file, line: line)

        let tsAuthOutpoint = fixture.result["authOutpoint"] as? String
        XCTAssertEqual(
            prepared.authOutputIndex.map { "\(String(repeating: "c", count: 64))_\($0)" },
            tsAuthOutpoint,
            file: file, line: line
        )
        XCTAssertEqual(fixture.overlay, ["tm_\(mintRequest.tokenId)"], file: file, line: line)
    }

    func test_mintWithAContinuingAuthorityMatchesTS() throws {
        try assertPreparedMatches("mintWithContinuingAuth")
    }

    func test_aFinalMintToAnAddressMatchesTS() throws {
        try assertPreparedMatches("mintToAddressEndMinting")
    }

    func test_movingTheAuthorityAloneMatchesTS() throws {
        try assertPreparedMatches("authTransferOnly")
    }

    func test_endingMintingAloneMatchesTS() throws {
        try assertPreparedMatches("endMintingOnly")
    }

    /// A tracked authority (one with an `id:` tag) adds its input label, and TS carries its
    /// symbol, decimals and icon over the overlay's details.
    func test_aTrackedAuthorityCarriesItsFieldsAsTSDoes() throws {
        try assertPreparedMatches("mintCarriesTrackedAuthority")
    }

    func test_detailsWithoutASymbolMatchTS() throws {
        try assertPreparedMatches("mintNoSymbolDetails")
    }

    func test_inputValidationMatchesTheTSErrors() throws {
        for name in ["errorAuthAndEnd", "errorNothing", "errorMintZero"] {
            let fixture = try Bsv21CreateFixture.named(name)
            XCTAssertThrowsError(try Tokens.validate(try request(fixture)), name) { error in
                XCTAssertEqual((error as? OneSatActionError)?.wireMessage, fixture.error, name)
            }
        }
    }

    // MARK: Flow

    private static let authorityKeyID = "bsv21-auth-TEST-0001"

    private struct Authority {
        let source: Transaction
        let txid: String
        let row: [String: Any]
        let beef: [UInt8]
        var tokenId: String { "\(txid)_0" }
        var outpoint: String { "\(txid).0" }
    }

    /// A `deploy+auth` genesis authority locked to this wallet's P1SAT key, in its own transaction.
    private func authority(customInstructions: String? = nil) throws -> Authority {
        let identity = try ActionVectors.identity()
        let address = try P1SATKey.address(
            identity: identity,
            keyID: Self.authorityKeyID,
            counterparty: .self,
            forSelf: true,
            network: .mainnet
        )
        let script = try BSV21.deployAuth(symbol: "TEST")
            .lock(lockingScript: ActionScript.payToPublicKeyHash(address))
        let source = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: script)],
            lockTime: 7
        )
        let txid = try source.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let beef = try BEEF(merklePaths: [], transactions: [.raw(source)], limits: WalletBEEFLimits.standard)
        var row: [String: Any] = [
            "outpoint": "\(txid).0",
            "satoshis": 1,
            "spendable": true,
            "tags": ["bsv21:deploy", "bsv21:auth"],
        ]
        row["customInstructions"] = customInstructions
            ?? #"{"amt":"0","op":"deploy+auth","sym":"TEST","dec":"0","protocolID":[0,"onesat"],"keyID":"\#(Self.authorityKeyID)"}"#
        return Authority(
            source: source,
            txid: txid,
            row: row,
            beef: try beef.serialized(limits: WalletBEEFLimits.standard)
        )
    }

    private func storage(_ authority: Authority, extra: [[String: Any]] = []) throws -> Bsv21CreateStorage {
        try Bsv21CreateStorage.make(
            rows: extra + [authority.row],
            listBEEF: authority.beef,
            sources: [authority.outpoint: .init(
                lockingScript: authority.source.outputs[0].lockingScript.hex,
                satoshis: 1
            )]
        )
    }

    private func activeOverlay(feePerOutput: UInt64 = 1_000) -> Bsv21CreateOverlay {
        Bsv21CreateOverlay(details: Bsv21TokenDetails(
            isActive: true,
            feeAddress: ActionVectors.templateAddress,
            feePerOutput: feePerOutput,
            decimals: 0,
            symbol: "TEST"
        ))
    }

    func test_mintSpendsTheAuthoritySignsItAndSubmitsToTheTokenTopic() async throws {
        let authority = try authority()
        let other = [
            "outpoint": String(repeating: "b", count: 64) + ".1",
            "satoshis": 1,
            "spendable": true,
            "tags": ["bsv21:\(String(repeating: "b", count: 64))_0", "bsv21:auth"],
            "customInstructions": #"{"id":"\#(String(repeating: "b", count: 64))_0","amt":"0","op":"auth","protocolID":[0,"onesat"],"keyID":"other"}"#,
        ] as [String: Any]
        let storage = try storage(authority, extra: [other])
        let overlay = activeOverlay()
        let ctx = try bsv21CreateContext(storage: storage, bsv21: overlay)

        let result = await Tokens.mint(
            ctx,
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 500))
        )

        XCTAssertNil(result.error, result.error ?? "")
        let txid = try XCTUnwrap(result.txid)
        XCTAssertEqual(result.authOutpoint, "\(txid)_1")
        XCTAssertTrue(result.overlaySubmitted)
        let submitted = await overlay.transferTokenIds
        XCTAssertEqual(submitted, [authority.tokenId])

        // The authority is listed as TS lists it.
        let lists = await storage.listRequests
        XCTAssertEqual(lists.first, .init(
            basket: "bsv21", tags: ["bsv21:auth"], tagQueryMode: "all",
            includeCustomInstructions: true, includeTags: true
        ))

        let inputs = await storage.createdInputs
        XCTAssertEqual(inputs, [.init(outpoint: authority.outpoint, inputDescription: "Mint authority", unlockingScriptLength: 108)])
        let outputs = await storage.createdOutputs
        XCTAssertEqual(outputs.map(\.outputDescription), ["Mint 500 tokens", "Continuing mint authority", "Overlay processing fee"])
        XCTAssertEqual(outputs.map(\.satoshis), [1, 1, 2_000])
        XCTAssertEqual(outputs[2].tags, ["fee:overlay"])
        let description = await storage.createdDescription
        XCTAssertEqual(description, "Mint 500 TEST")
        let labels = await storage.createdLabels
        XCTAssertEqual(labels, ["p bsv21 token \(authority.tokenId)"])

        // The authority input unlocks under the interpreter.
        let signed = try bsv21SubjectTransaction(try XCTUnwrap(result.tx))
        let index = try XCTUnwrap(signed.inputs.firstIndex { $0.previousOutput.description == authority.outpoint })
        var spend = signed
        let spent = authority.source.outputs[0]
        spend.inputs[index].sourceOutput = spent
        let execution = try ScriptInterpreter.execute(
            unlockingScript: spend.inputs[index].unlockingScript,
            lockingScript: spent.lockingScript,
            configuration: ScriptExecutionConfiguration(
                era: .afterGenesis, flags: [.enableForkID, .derSignatures, .lowS, .nullFail],
                resourceLimits: .standard
            ),
            context: ScriptExecutionContext(
                transaction: spend, inputIndex: index, spentOutput: spent,
                transactionLimits: WalletTransactionLimits.standard
            )
        )
        XCTAssertEqual(execution.stack.last, [1])

        // The minted and continuing outputs read back as this token.
        let minted = BSV21.decode(signed.outputs[0].lockingScript)
        XCTAssertEqual(minted?.tokenData.operation, .mint)
        XCTAssertEqual(minted?.tokenData.tokenID, authority.tokenId)
        XCTAssertEqual(minted?.tokenData.amount, "500")
        XCTAssertEqual(BSV21.decode(signed.outputs[1].lockingScript)?.tokenData.operation, .auth)
        let mintedFields = Bsv21Remittance.fields(
            tags: outputs[0].tags, customInstructions: outputs[0].customInstructions, outpoint: "\(txid).0"
        )
        XCTAssertEqual(mintedFields.tokenId, authority.tokenId)
        XCTAssertEqual(mintedFields.amt, "500")
        let authFields = Bsv21Remittance.fields(
            tags: outputs[1].tags, customInstructions: outputs[1].customInstructions, outpoint: "\(txid).1"
        )
        XCTAssertTrue(authFields.isAuth)
        XCTAssertEqual(authFields.tokenId, authority.tokenId)
    }

    func test_endingMintingEmitsNoAuthorityAndNoFeeWhenTheOverlayChargesNone() async throws {
        let authority = try authority()
        let storage = try storage(authority)
        let overlay = activeOverlay(feePerOutput: 0)
        let result = await Tokens.mint(
            try bsv21CreateContext(storage: storage, bsv21: overlay),
            Tokens.MintRequest(tokenId: authority.tokenId, endMinting: true)
        )
        XCTAssertNil(result.error, result.error ?? "")
        XCTAssertNil(result.authOutpoint)
        let outputs = await storage.createdOutputs
        XCTAssertTrue(outputs.isEmpty)
        let description = await storage.createdDescription
        XCTAssertEqual(description, "End TEST mint authority")
    }

    func test_aFailedOverlaySubmitStillReturnsTheMint() async throws {
        let authority = try authority()
        let overlay = activeOverlay()
        await overlay.setTransferError(Bsv21CreateFailure.down)
        let result = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(authority), bsv21: overlay),
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertFalse(result.overlaySubmitted)
    }

    func test_flowErrorsMatchTS() async throws {
        let authority = try authority()

        let inactiveOverlay = Bsv21CreateOverlay(details: Bsv21TokenDetails(
            isActive: false, feeAddress: ActionVectors.templateAddress, feePerOutput: 0, decimals: 0
        ))
        let inactive = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(authority), bsv21: inactiveOverlay),
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertEqual(inactive.error, try Bsv21CreateFixture.named("errorInactive").error)

        let otherToken = String(repeating: "f", count: 64) + "_0"
        let missing = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(authority), bsv21: activeOverlay()),
            Tokens.MintRequest(tokenId: otherToken, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertEqual(missing.error, try Bsv21CreateFixture.named("errorNoAuthority").error)

        var bare = authority
        bare = Authority(source: bare.source, txid: bare.txid, row: bare.row.filter { $0.key != "customInstructions" }, beef: bare.beef)
        let noCI = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(bare), bsv21: activeOverlay()),
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertEqual(noCI.error, try Bsv21CreateFixture.named("errorAuthorityWithoutCI").error)

        let noServices = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(authority), bsv21: nil),
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertEqual(noServices.error, "services-required")

        let both = await Tokens.mint(
            try bsv21CreateContext(storage: try storage(authority), bsv21: activeOverlay()),
            Tokens.MintRequest(tokenId: authority.tokenId, auth: .self, endMinting: true)
        )
        XCTAssertEqual(both.error, "auth-and-end-minting-are-mutually-exclusive")
    }

    func test_aMultisigAuthorityIsRefusedClearly() async throws {
        let authority = try authority(
            customInstructions: #"{"amt":"0","op":"deploy+auth","protocolID":[0,"onesat"],"keyID":"k","multiSig":true}"#
        )
        let storage = try storage(authority)
        let result = await Tokens.mint(
            try bsv21CreateContext(storage: storage, bsv21: activeOverlay()),
            Tokens.MintRequest(tokenId: authority.tokenId, mint: Tokens.MintOutput(amount: 1))
        )
        XCTAssertEqual(result.error, "multisig-auth-not-supported")
        let methods = await storage.methods
        XCTAssertFalse(methods.contains("createAction"))
    }
}

extension Bsv21CreateOverlay {
    func setTransferError(_ error: Error?) { transferError = error }
}
