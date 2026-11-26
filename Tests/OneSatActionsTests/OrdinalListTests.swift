import Foundation
import BSVCore
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatAddresses
import OneSatTemplates
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import XCTest
@testable import OneSatActions

/// `Fixtures/ordlock-list-vectors.json`: what `@1sat/actions` (b-open-io/1sat-sdk 71fd3ba) builds
/// for a listing, from its real `buildListOrdinal`, `sellOrdinal` and `sellOpns` run over a
/// ProtoWallet for the `ActionVectors` identity (`ordlock-list-vectors.gen.sh`).
enum OrdLockListVectors {
    struct Case {
        let name: String
        let family: String
        let tags: [String]
        let customInstructions: String
        let price: UInt64
        let payAddress: String?
        let hasMap: Bool
        let error: String?
        /// `buildListOrdinal`'s args (ordinals only).
        let args: Bsv21CreateFixture.Request?
        /// The createAction args after the TS pipeline, `id:<actionId>_<n>` standing for the id.
        let created: Bsv21CreateFixture.Request?

        func walletOutput() throws -> WalletOutput {
            try WalletOutput(
                satoshis: 1,
                spendable: true,
                customInstructions: customInstructions,
                tags: tags,
                outpoint: try Outpoint(ActionVectors.outpoint)
            )
        }

        /// The fixture's `map` is `{ app: "1sat", type: "ord" }`, in that order (`Object.entries`).
        var map: [(String, String)] { hasMap ? [("app", "1sat"), ("type", "ord")] : [] }
    }

    static func root() throws -> [String: Any] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/ordlock-list-vectors", withExtension: "json")
                ?? Bundle.module.url(forResource: "ordlock-list-vectors", withExtension: "json", subdirectory: "Fixtures")
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func cases(family: String) throws -> [Case] {
        try XCTUnwrap(root()["cases"] as? [[String: Any]]).filter { $0["family"] as? String == family }.map { raw in
            let request = raw["request"] as? [String: Any] ?? [:]
            return Case(
                name: raw["name"] as? String ?? "",
                family: family,
                tags: raw["tags"] as? [String] ?? [],
                customInstructions: raw["customInstructions"] as? String ?? "",
                price: (request["price"] as? NSNumber)?.uint64Value ?? 0,
                payAddress: request["payAddress"] as? String,
                hasMap: request["map"] != nil,
                error: raw["error"] as? String,
                args: (raw["args"] as? [String: Any]).map(Self.request),
                created: (raw["created"] as? [String: Any]).map(Self.request)
            )
        }
    }

    static func request(_ r: [String: Any]) -> Bsv21CreateFixture.Request {
        Bsv21CreateFixture.Request(
            description: r["description"] as? String ?? "",
            labels: r["labels"] as? [String] ?? [],
            inputs: (r["inputs"] as? [[String: Any]] ?? []).map {
                Bsv21CreateFixture.Input(
                    outpoint: $0["outpoint"] as? String ?? "",
                    inputDescription: $0["inputDescription"] as? String ?? "",
                    unlockingScriptLength: ($0["unlockingScriptLength"] as? NSNumber)?.intValue ?? -1
                )
            },
            outputs: (r["outputs"] as? [[String: Any]] ?? []).map(Bsv21CreateFixture.output),
            randomizeOutputs: r["randomizeOutputs"] as? Bool
        )
    }

    /// Asserts what storage was asked to create equals TS's created args, `<actionId>` replaced
    /// by the id Swift stamped (tags compared as storage stores them).
    static func assertCreated(
        _ storage: Bsv21CreateStorage,
        equal ts: Bsv21CreateFixture.Request,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let outputs = await storage.createdOutputs
        let inputs = await storage.createdInputs
        let description = await storage.createdDescription
        let labels = await storage.createdLabels
        let randomize = await storage.createdRandomizeOutputs
        XCTAssertEqual(description, ts.description, file: file, line: line)
        XCTAssertEqual(labels, ts.labels, file: file, line: line)
        XCTAssertEqual(inputs, ts.inputs, file: file, line: line)
        XCTAssertEqual(randomize, false, file: file, line: line)
        XCTAssertEqual(ts.randomizeOutputs, false, file: file, line: line)
        XCTAssertEqual(outputs.count, 1, file: file, line: line)
        XCTAssertEqual(ts.outputs.count, 1, file: file, line: line)
        let mine = try XCTUnwrap(outputs.first, file: file, line: line)
        let theirs = try XCTUnwrap(ts.outputs.first, file: file, line: line)
        XCTAssertEqual(mine.lockingScript, theirs.lockingScript, file: file, line: line)
        XCTAssertEqual(mine.satoshis, theirs.satoshis, file: file, line: line)
        XCTAssertEqual(mine.outputDescription, theirs.outputDescription, file: file, line: line)
        XCTAssertEqual(mine.basket, theirs.basket, file: file, line: line)
        XCTAssertEqual(mine.customInstructions, theirs.customInstructions, file: file, line: line)
        let idTag = try XCTUnwrap(mine.tags.first { $0.hasPrefix("id:") }, file: file, line: line)
        let actionID = String(idTag.dropFirst(3).dropLast(2))
        XCTAssertEqual(
            mine.tags,
            theirs.tags.map { storageTag($0.replacingOccurrences(of: "id:<actionId>_", with: "id:\(actionID)_")) },
            file: file, line: line
        )
    }
}

final class OrdinalListTests: XCTestCase {
    func test_buildListMatchesTheTSBuilder() throws {
        let ctx = try listContext(storage: Bsv21CreateStorage())
        let cases = try OrdLockListVectors.cases(family: "ordinal")
        XCTAssertEqual(cases.count, 3)
        for vector in cases {
            let request = Ordinals.ListRequest(
                ordinal: try vector.walletOutput(),
                price: vector.price,
                payAddress: vector.payAddress,
                map: vector.map
            )
            if let error = vector.error {
                XCTAssertThrowsError(try Ordinals.buildList(ctx, request), vector.name) {
                    XCTAssertEqual(($0 as? OneSatActionError)?.wireMessage, error, vector.name)
                }
                continue
            }
            let ts = try XCTUnwrap(vector.args, vector.name)
            let prepared = try Ordinals.buildList(ctx, request)
            XCTAssertEqual(prepared.description, ts.description, vector.name)
            XCTAssertEqual(prepared.labels, ts.labels, vector.name)
            XCTAssertEqual(
                prepared.inputs.map { input in
                    var length = -1
                    if case .scriptLength(let value) = input.unlocking { length = Int(value) }
                    return Bsv21CreateFixture.Input(
                        outpoint: input.outpoint.description,
                        inputDescription: input.inputDescription,
                        unlockingScriptLength: length
                    )
                },
                ts.inputs,
                vector.name
            )
            XCTAssertEqual(prepared.outputs.count, 1, vector.name)
            let output = try XCTUnwrap(prepared.outputs.first)
            let theirs = try XCTUnwrap(ts.outputs.first)
            XCTAssertEqual(Hex.encode(output.lockingScript), theirs.lockingScript, vector.name)
            XCTAssertEqual(output.satoshis, 1, vector.name)
            XCTAssertEqual(output.outputDescription, theirs.outputDescription, vector.name)
            XCTAssertEqual(output.basket, theirs.basket, vector.name)
            XCTAssertEqual(output.tags, theirs.tags, vector.name)
            XCTAssertEqual(output.customInstructions, theirs.customInstructions, vector.name)

            // One P2PKH signer, from the source's customInstructions.
            XCTAssertEqual(prepared.signers.count, 1)
            XCTAssertEqual(prepared.signers[0].keyID, ActionVectors.outpoint)
            XCTAssertEqual(prepared.signers[0].counterparty, .self)
        }
    }

    func test_listSendsWhatTSSendsToCreateAction() async throws {
        for vector in try OrdLockListVectors.cases(family: "ordinal") {
            let storage = Bsv21CreateStorage()
            let result = await Ordinals.list(
                try listContext(storage: storage),
                Ordinals.ListRequest(
                    ordinal: try vector.walletOutput(),
                    price: vector.price,
                    payAddress: vector.payAddress,
                    map: vector.map
                )
            )
            if let error = vector.error {
                XCTAssertEqual(result.error, error, vector.name)
                let methods = await storage.methods
                XCTAssertFalse(methods.contains("createAction"), vector.name)
                continue
            }
            try await OrdLockListVectors.assertCreated(storage, equal: try XCTUnwrap(vector.created, vector.name))
        }
    }

    /// TS `defaultPayAddress` (P1SAT keyID `1sat 0`, self, forSelf) is the wallet's first deposit
    /// address: a sale pays where the wallet already receives.
    func test_defaultPayAddressIsDepositAddressZero() throws {
        let identity = try ActionVectors.identity()
        let root = try OrdLockListVectors.root()
        let ts = try XCTUnwrap(root["defaultPayAddress"] as? String)
        XCTAssertEqual(try Ordinals.defaultPayAddress(identity: identity).description, ts)
        XCTAssertEqual(try DepositAddresses.address(identity: identity, index: 0).description, ts)
        XCTAssertEqual(
            try Ordinals.defaultPayAddress(identity: identity, network: .testnet).description,
            try DepositAddresses.address(identity: identity, index: 0, network: .testnet).description
        )
    }

    func test_thePriceTagIsReadBackFromTheScript() throws {
        let ctx = try listContext(storage: Bsv21CreateStorage())
        let prepared = try Ordinals.buildList(
            ctx,
            Ordinals.ListRequest(
                ordinal: try ordinal(tags: ["type:image/png"]),
                price: UInt64.max,
                payAddress: ActionVectors.payAddress
            )
        )
        let script = try Script(bytes: prepared.outputs[0].lockingScript, maximumByteCount: 10_000)
        let decoded = try XCTUnwrap(OrdLockV2.decode(script))
        XCTAssertEqual(decoded.price, UInt64.max)
        XCTAssertEqual(prepared.outputs[0].tags.last, "price:\(decoded.price)")
        XCTAssertEqual(try OrdLockV2.payoutOutput(script).script.hex, try ActionScript.payToPublicKeyHash(ActionVectors.payAddress).hex)
        // The seller is the source outpoint's cancel key, as buy and cancel expect.
        XCTAssertEqual(
            decoded.seller,
            try Ordinals.cancelAddress(identity: ActionVectors.identity(), outpoint: ActionVectors.outpoint).description
        )
    }

    func test_priceZeroAndMissingCustomInstructionsFailBeforeStorage() async throws {
        let storage = Bsv21CreateStorage()
        let ctx = try listContext(storage: storage)
        let zero = await Ordinals.list(
            ctx, Ordinals.ListRequest(ordinal: try ordinal(tags: ["type:image/png"]), price: 0)
        )
        XCTAssertEqual(zero.error, "invalid-price")
        XCTAssertEqual(OneSatActionError(wireMessage: "invalid-price"), .invalidPrice)
        let bare = try WalletOutput(
            satoshis: 1, spendable: true, tags: ["type:image/png"], outpoint: try Outpoint(ActionVectors.outpoint)
        )
        let noCI = await Ordinals.list(ctx, Ordinals.ListRequest(ordinal: bare, price: 1))
        XCTAssertEqual(noCI.error, "missing-custom-instructions")
        let methods = await storage.methods
        XCTAssertTrue(methods.isEmpty)
    }

    /// A real source coin: the listing signs, its input unlocks under the interpreter, and the
    /// result's `tx` is Atomic BEEF whose subject is the listing.
    func test_listSignsTheOrdinalInputAndReturnsAtomicBEEF() async throws {
        let source = try ListingSource.p2pkh(keyID: "ordinal-key")
        let storage = try source.storage()
        let result = await Ordinals.list(
            try listContext(storage: storage),
            Ordinals.ListRequest(ordinal: source.output, price: 75_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error, result.error ?? "")
        let signed = try bsv21SubjectTransaction(try XCTUnwrap(result.tx))
        XCTAssertEqual(try signed.transactionID(limits: WalletTransactionLimits.standard).displayHex, result.txid)
        XCTAssertEqual(signed.outputs[0].satoshis, 1)
        XCTAssertEqual(OrdLockV2.decode(signed.outputs[0].lockingScript)?.price, 75_000)
        try source.assertUnlocks(signed)
    }

    private func ordinal(tags: [String]) throws -> WalletOutput {
        try WalletOutput(
            satoshis: 1,
            spendable: true,
            customInstructions: try CustomInstructions(keyID: ActionVectors.outpoint).encoded(),
            tags: tags,
            outpoint: try Outpoint(ActionVectors.outpoint)
        )
    }
}

final class OpnsListTests: XCTestCase {
    func test_listSendsWhatTSSellOpnsSendsToCreateAction() async throws {
        let cases = try OrdLockListVectors.cases(family: "opns")
        XCTAssertEqual(cases.count, 3)
        for vector in cases {
            let storage = Bsv21CreateStorage()
            let result = await OpNS.list(
                try listContext(storage: storage),
                OpNS.ListRequest(
                    ordinal: try vector.walletOutput(),
                    price: vector.price,
                    payAddress: vector.payAddress,
                    inputBEEF: try ListingSource.anyBEEF()
                )
            )
            if let error = vector.error {
                XCTAssertEqual(result.error, error, vector.name)
                let methods = await storage.methods
                XCTAssertTrue(methods.isEmpty, vector.name)
                continue
            }
            let ts = try XCTUnwrap(vector.created, vector.name)
            try await OrdLockListVectors.assertCreated(storage, equal: ts)
            // `opns` leads; no MAP after the OrdLock.
            let outputs = await storage.createdOutputs
            XCTAssertEqual(outputs[0].tags.first, "opns")
            let script = try Script(hex: outputs[0].lockingScript, maximumByteCount: 10_000)
            let decoded = try XCTUnwrap(OrdLockV2.decode(script))
            XCTAssertEqual(decoded.end, script.bytes.count, vector.name)
            XCTAssertEqual(decoded.price, vector.price)
        }
    }

    /// TS cuts the action description to 50 characters; no UInt64 price can make it that long,
    /// and the output description is never cut.
    func test_theDescriptionFitsAtTheLargestPrice() async throws {
        let storage = Bsv21CreateStorage()
        _ = await OpNS.list(
            try listContext(storage: storage),
            OpNS.ListRequest(
                ordinal: try OrdLockListVectors.cases(family: "opns")[0].walletOutput(),
                price: UInt64.max,
                inputBEEF: try ListingSource.anyBEEF()
            )
        )
        let description = await storage.createdDescription
        XCTAssertEqual(description, "List OpNS for \(UInt64.max) sats")
        let outputs = await storage.createdOutputs
        XCTAssertEqual(outputs[0].outputDescription, "List OpNS for \(UInt64.max) sats")
        XCTAssertEqual(outputs[0].basket, OneSatConstants.opnsBasket)
    }

    func test_aPlainNameSignsAsP2PKH() async throws {
        let source = try ListingSource.p2pkh(
            keyID: "name-key",
            tags: ["type:application/op-ns", "name:alice", "id:aa_0"]
        )
        let result = await OpNS.list(
            try listContext(storage: try source.storage()),
            OpNS.ListRequest(ordinal: source.output, price: 9_000, inputBEEF: source.beef)
        )
        XCTAssertNil(result.error, result.error ?? "")
        try source.assertUnlocks(try bsv21SubjectTransaction(try XCTUnwrap(result.tx)))
    }
}

/// A coin the wallet can spend: its source transaction, wallet row and BEEF.
struct ListingSource {
    let transaction: Transaction
    let output: WalletOutput
    let beef: [UInt8]
    let outpoint: String

    /// A 1-sat P2PKH to P1SAT `keyID` (self), with customInstructions naming that key.
    static func p2pkh(keyID: String, tags: [String] = ["type:image/png", "id:src_0"]) throws -> ListingSource {
        let address = try P1SATKey.address(
            identity: try ActionVectors.identity(), keyID: keyID, counterparty: .self, forSelf: true
        )
        return try make(
            script: try ActionScript.payToPublicKeyHash(address),
            customInstructions: try CustomInstructions(keyID: keyID, counterparty: .self).encoded(includeSelfCounterparty: true),
            tags: tags
        )
    }

    /// An OrdLock v2 listing whose seller is P1SAT `keyID` (self), with customInstructions naming
    /// that key, as `list` leaves it.
    static func listing(keyID: String, tags: [String] = ["type:image/png", "ordlock2", "price:50000", "id:src_0"]) throws -> ListingSource {
        let cancel = try Ordinals.cancelAddress(identity: try ActionVectors.identity(), outpoint: keyID)
        return try make(
            script: try OrdLockV2.lock(cancelAddress: cancel.description, payAddress: ActionVectors.payAddress, price: 50_000),
            customInstructions: try CustomInstructions(keyID: keyID, counterparty: .self).encoded(includeSelfCounterparty: true),
            tags: tags
        )
    }

    static func make(script: Script, customInstructions: String, tags: [String]) throws -> ListingSource {
        let transaction = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: script)],
            lockTime: 11
        )
        let txid = try transaction.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let outpoint = "\(txid).0"
        return ListingSource(
            transaction: transaction,
            output: try WalletOutput(
                satoshis: 1,
                spendable: true,
                customInstructions: customInstructions,
                tags: tags,
                outpoint: try Outpoint(outpoint)
            ),
            beef: try BEEF(merklePaths: [], transactions: [.raw(transaction)], limits: WalletBEEFLimits.standard)
                .serialized(limits: WalletBEEFLimits.standard),
            outpoint: outpoint
        )
    }

    /// BEEF of an unrelated transaction, for builders that only pass the bytes on.
    static func anyBEEF() throws -> [UInt8] {
        try make(script: try Script(bytes: [0x51], maximumByteCount: 10), customInstructions: "{}", tags: []).beef
    }

    func storage() throws -> Bsv21CreateStorage {
        Bsv21CreateStorage(sources: [
            outpoint: .init(lockingScript: transaction.outputs[0].lockingScript.hex, satoshis: 1),
        ])
    }

    /// The input spending this coin in `signed` unlocks it under the interpreter.
    func assertUnlocks(_ signed: Transaction, file: StaticString = #filePath, line: UInt = #line) throws {
        let index = try XCTUnwrap(signed.inputs.firstIndex { $0.previousOutput.description == outpoint }, file: file, line: line)
        var spend = signed
        let spent = transaction.outputs[0]
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
        XCTAssertEqual(execution.stack.last, [1], file: file, line: line)
    }
}

func listContext(
    storage: Bsv21CreateStorage,
    market: (any MarketActionServices)? = nil,
    listings: (any ListingBeefSource)? = nil
) throws -> OneSatContext {
    let identity = try ActionVectors.identity()
    return OneSatContext(
        identity: identity,
        storage: StorageClient(endpoint: URL(string: "https://example.invalid")!, transport: storage),
        auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)),
        listings: listings,
        market: market
    )
}
