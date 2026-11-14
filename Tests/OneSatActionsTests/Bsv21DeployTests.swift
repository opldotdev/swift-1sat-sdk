import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `deployBsv21Mint` and `deployBsv21Auth` against the requests `@1sat/actions` 0.1.6 sends
/// (`Fixtures/bsv21-deploy-mint.json`).
final class Bsv21DeployTests: XCTestCase {
    private func mintRequest(_ fixture: Bsv21CreateFixture.Case) throws -> Tokens.DeployMintRequest {
        Tokens.DeployMintRequest(
            symbol: try XCTUnwrap(fixture.input["symbol"] as? String),
            amount: try XCTUnwrap(UInt64(XCTUnwrap(fixture.input["amount"] as? String))),
            decimals: (fixture.input["decimals"] as? NSNumber)?.intValue ?? 0,
            icon: fixture.input["icon"] as? String,
            destination: try Bsv21CreateFixture.destination(fixture.input["destination"])
        )
    }

    private func authRequest(_ fixture: Bsv21CreateFixture.Case) throws -> Tokens.DeployAuthRequest {
        Tokens.DeployAuthRequest(
            symbol: try XCTUnwrap(fixture.input["symbol"] as? String),
            decimals: (fixture.input["decimals"] as? NSNumber)?.intValue ?? 0,
            icon: fixture.input["icon"] as? String,
            destination: try Bsv21CreateFixture.destination(fixture.input["destination"])
        )
    }

    /// Runs a deploy and checks the storage request and the signed output against the fixture.
    private func assertMatches(
        _ name: String,
        isAuth: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let fixture = try Bsv21CreateFixture.named(name)
        let ts = try XCTUnwrap(fixture.request)
        let storage = Bsv21CreateStorage()
        let overlay = Bsv21CreateOverlay()
        let ctx = try bsv21CreateContext(storage: storage, bsv21: overlay)
        let keyID = fixture.keyIDs.first

        let result = isAuth
            ? await Tokens.deployAuth(ctx, try authRequest(fixture), keyID: keyID)
            : await Tokens.deployMint(ctx, try mintRequest(fixture), keyID: keyID)

        XCTAssertNil(result.error, result.error ?? "", file: file, line: line)
        let txid = try XCTUnwrap(result.txid)
        XCTAssertEqual(result.tokenId, "\(txid)_0", file: file, line: line)
        XCTAssertEqual(result.authOutpoint, isAuth ? "\(txid)_0" : nil, file: file, line: line)
        XCTAssertTrue(result.discoverySubmitted, file: file, line: line)
        XCTAssertNil(result.submitError, file: file, line: line)
        XCTAssertNotNil(fixture.result["tokenId"], file: file, line: line)
        XCTAssertEqual(fixture.result["authOutpoint"] != nil, isAuth, file: file, line: line)

        let description = await storage.createdDescription
        let labels = await storage.createdLabels
        let inputs = await storage.createdInputs
        let outputs = await storage.createdOutputs
        let randomize = await storage.createdRandomizeOutputs
        XCTAssertEqual(description, ts.description, file: file, line: line)
        XCTAssertEqual(labels, ts.labels, file: file, line: line)
        XCTAssertEqual(inputs, ts.inputs, file: file, line: line)
        XCTAssertEqual(randomize, ts.randomizeOutputs, file: file, line: line)
        Bsv21CreateFixture.assertOutputs(outputs, equal: ts.outputs, actionId: result.actionId, file: file, line: line)

        // The broadcast transaction carries the fixture's script at output 0, and the overlay
        // got exactly that transaction on the discovery topic.
        let tx = try XCTUnwrap(result.tx)
        let signed = try bsv21SubjectTransaction(tx)
        XCTAssertEqual(signed.outputs.first?.lockingScript.hex, ts.outputs.first?.lockingScript, file: file, line: line)
        XCTAssertEqual(signed.outputs.first?.satoshis, 1, file: file, line: line)
        let discoveries = await overlay.discoveries
        XCTAssertEqual(discoveries, [tx], file: file, line: line)
        XCTAssertEqual(fixture.overlay, ["tm_bsv21"], file: file, line: line)

        // Balances read the new output as token `<txid>_0`.
        let read = Bsv21Remittance.fields(
            tags: outputs.first?.tags,
            customInstructions: outputs.first?.customInstructions,
            outpoint: "\(txid).0"
        )
        XCTAssertEqual(read.tokenId, "\(txid)_0", file: file, line: line)
        XCTAssertTrue(read.isDeploy, file: file, line: line)
        XCTAssertEqual(read.isAuth, isAuth, file: file, line: line)
    }

    func test_deployMintMatchesTheTSRequestAtZeroDecimals() async throws {
        try await assertMatches("deployMintDec0", isAuth: false)
    }

    func test_deployMintMatchesTheTSRequestAtEightDecimals() async throws {
        try await assertMatches("deployMintDec8", isAuth: false)
    }

    func test_deployMintMatchesTheTSRequestWithAnIcon() async throws {
        try await assertMatches("deployMintIcon", isAuth: false)
    }

    func test_deployMintToAnAddressWritesNoCustomInstructions() async throws {
        try await assertMatches("deployMintAddress", isAuth: false)
    }

    func test_deployMintToACounterpartyRecordsTheCounterparty() async throws {
        try await assertMatches("deployMintCounterparty", isAuth: false)
    }

    func test_deployAuthMatchesTheTSRequest() async throws {
        try await assertMatches("deployAuthDec0", isAuth: true)
    }

    func test_deployAuthMatchesTheTSRequestWithDecimalsAndAnIcon() async throws {
        try await assertMatches("deployAuthIcon", isAuth: true)
    }

    /// TS writes `dec` into custom instructions as a string, `"0"` included.
    func test_customInstructionsCarryDecimalsAsAString() throws {
        let fixture = try Bsv21CreateFixture.named("deployMintDec0")
        let ci = try XCTUnwrap(fixture.request?.outputs.first?.customInstructions)
        XCTAssertTrue(ci.contains(#""dec":"0""#), ci)
        let prepared = try Tokens.prepareDeployMint(
            identity: try ActionVectors.identity(),
            try mintRequest(fixture),
            keyID: fixture.keyIDs.first
        )
        XCTAssertEqual(prepared.customInstructions, ci)
        XCTAssertEqual(prepared.tags, ["bsv21:deploy"])
        XCTAssertEqual(prepared.keyID, fixture.keyIDs.first)
    }

    func test_zeroSupplyFailsWithTheTSError() async throws {
        let fixture = try Bsv21CreateFixture.named("deployMintZero")
        let storage = Bsv21CreateStorage()
        let result = await Tokens.deployMint(
            try bsv21CreateContext(storage: storage, bsv21: Bsv21CreateOverlay()),
            Tokens.DeployMintRequest(symbol: "ZERO", amount: 0)
        )
        XCTAssertEqual(result.error, fixture.error)
        XCTAssertEqual(result.error, "amount-must-be-positive")
        let methods = await storage.methods
        XCTAssertEqual(methods, [])
    }

    func test_aFailedDiscoverySubmitKeepsTheDeployAndCanBeRetried() async throws {
        let fixture = try Bsv21CreateFixture.named("deployMintDiscoveryFails")
        // TS logs the failure and still returns the deploy.
        XCTAssertNil(fixture.error)
        XCTAssertNotNil(fixture.result["txid"])

        let storage = Bsv21CreateStorage()
        let overlay = Bsv21CreateOverlay()
        await overlay.failDiscovery(Bsv21CreateFailure.down)
        let ctx = try bsv21CreateContext(storage: storage, bsv21: overlay)
        let result = await Tokens.deployMint(ctx, Tokens.DeployMintRequest(symbol: "TEST", amount: 1))

        XCTAssertNil(result.error)
        let txid = try XCTUnwrap(result.txid)
        XCTAssertEqual(result.tokenId, "\(txid)_0")
        XCTAssertFalse(result.discoverySubmitted)
        XCTAssertEqual(result.submitError, "down")
        let tx = try XCTUnwrap(result.tx)

        await overlay.failDiscovery(nil)
        try await Tokens.submitDeploy(ctx, tx: tx)
        let discoveries = await overlay.discoveries
        XCTAssertEqual(discoveries, [tx, tx])
    }

    func test_submitDeployRefusesATransactionThatIsNotADeploy() async throws {
        let overlay = Bsv21CreateOverlay()
        let storage = Bsv21CreateStorage()
        let ctx = try bsv21CreateContext(storage: storage, bsv21: overlay)
        let paid = await Tokens.deployMint(ctx, Tokens.DeployMintRequest(symbol: "TEST", amount: 1))
        XCTAssertNil(paid.error)

        // A plain payment's BEEF.
        let plain = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(
                satoshis: 1,
                lockingScript: try ActionScript.payToPublicKeyHash(ActionVectors.payAddress)
            )],
            lockTime: 0
        )
        let txid = try plain.transactionID(limits: WalletTransactionLimits.standard)
        let beef = try BEEF(merklePaths: [], transactions: [.raw(plain)], limits: WalletBEEFLimits.standard)
        let atomic = try AtomicBEEF(subjectTransactionID: txid, beef: beef, limits: WalletBEEFLimits.standard)
        let bytes = try atomic.serialized(limits: WalletBEEFLimits.standard)

        do {
            try await Tokens.submitDeploy(ctx, tx: bytes)
            XCTFail("a payment is not a deploy")
        } catch {
            XCTAssertEqual(error as? OneSatActionError, .notABsv21Deploy)
        }
        do {
            try await Tokens.submitDeploy(
                try bsv21CreateContext(storage: storage, bsv21: nil),
                tx: try XCTUnwrap(paid.tx)
            )
            XCTFail("no overlay services")
        } catch {
            XCTAssertEqual(error as? OneSatActionError, .servicesRequired)
        }
        let discoveries = await overlay.discoveries
        XCTAssertEqual(discoveries.count, 1)
    }

    func test_aDeployWithoutOverlayServicesStillBroadcasts() async throws {
        let storage = Bsv21CreateStorage()
        let result = await Tokens.deployAuth(
            try bsv21CreateContext(storage: storage, bsv21: nil),
            Tokens.DeployAuthRequest(symbol: "AUTH")
        )
        XCTAssertNil(result.error)
        XCTAssertNotNil(result.txid)
        XCTAssertFalse(result.discoverySubmitted)
        XCTAssertEqual(result.submitError, OneSatActionError.servicesRequired.wireMessage)
    }

    func test_anInvalidSymbolFailsBeforeStorage() async throws {
        let storage = Bsv21CreateStorage()
        let ctx = try bsv21CreateContext(storage: storage, bsv21: Bsv21CreateOverlay())
        let result = await Tokens.deployMint(
            ctx,
            Tokens.DeployMintRequest(symbol: String(repeating: "X", count: 33), amount: 1)
        )
        XCTAssertNotNil(result.error)
        XCTAssertNil(result.txid)
        XCTAssertThrowsError(try Tokens.prepareDeployMint(
            identity: try ActionVectors.identity(),
            Tokens.DeployMintRequest(symbol: "T", amount: 1, decimals: 19)
        ))
        let methods = await storage.methods
        XCTAssertEqual(methods, [])
    }
}
