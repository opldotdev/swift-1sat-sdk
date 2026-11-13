import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatClient
import ToolboxActions
import XCTest
@testable import OneSatActions

/// `wallet-server/src/paymail/resolve.ts`: `verifyPushDropBind` (cases from
/// `test/opnsBind.test.ts`) and `resolvePaymailBind` through scripted OpNS / ORDFS / BEEF
/// transports.
final class OpnsBindTests: XCTestCase {
    private static let sourceTxid = String(repeating: "9a", count: 32)
    private static let avatar = String(repeating: "ef", count: 32) + "_2"
    private let baseURL = URL(string: "https://api.1sat.app")!

    // MARK: verifyPushDropBind

    func test_verifiesTheTypeScriptPublishLock() async throws {
        let identity = try ActionVectors.identity()
        let tx = try bindTransaction(
            lock: try script(SignOrdinalInputTests.lockFull),
            spending: ActionVectors.outpoint
        )

        let bind = try await OpNS.verifyPushDropBind(
            transaction: tx,
            vout: 0,
            lockingScript: tx.outputs[0].lockingScript
        )

        XCTAssertEqual(bind, OpNS.Bind(
            identityKey: Hex.encode(identity.publicKey.compressedBytes),
            domain: "1sat.name",
            profileName: "Alice",
            avatarOrigin: String(repeating: "ef", count: 32) + ".1"
        ))
    }

    func test_ignoresAnInscriptionAfterTheDrops() async throws {
        let identity = try ActionVectors.identity()
        let tx = try bindTransaction(
            lock: try script(SignOrdinalInputTests.lockInscribed),
            spending: ActionVectors.outpoint
        )

        let bind = try await OpNS.verifyPushDropBind(
            transaction: tx,
            vout: 0,
            lockingScript: tx.outputs[0].lockingScript
        )

        XCTAssertEqual(bind, OpNS.Bind(
            identityKey: Hex.encode(identity.publicKey.compressedBytes),
            domain: "1sat.name"
        ))
    }

    func test_decodesIdentityAndProfileFromSignedFields() async throws {
        let identity = try key(7001)
        let lock = try await OpNS.publishLock(
            identity: identity,
            nameOutpoint: try Outpoint(Self.sourceTxid + ".0"),
            profile: OpnsFields.Profile(
                domain: "1sat.name",
                name: "Alice",
                avatar: try OpnsFields.outpointWire(Self.avatar)
            )
        )

        let bind = try await verify(lock)

        XCTAssertEqual(bind, OpNS.Bind(
            identityKey: Hex.encode(identity.publicKey.compressedBytes),
            domain: "1sat.name",
            profileName: "Alice",
            avatarOrigin: String(repeating: "ef", count: 32) + ".2"
        ))
    }

    func test_identityOnlyHasNoProfileMembers() async throws {
        let identity = try key(7002)
        let lock = try await signedLock(identity, publishFields(identity.publicKey))

        let bind = try await verify(lock)

        XCTAssertEqual(bind, OpNS.Bind(identityKey: Hex.encode(identity.publicKey.compressedBytes)))
    }

    func test_unknownPairsAreSkippedInAnyPosition() async throws {
        let identity = try key(7006)
        let pairs = try publishFields(identity.publicKey, profile: OpnsFields.Profile(domain: "1sat.name"))
        let lock = try await signedLock(identity, [
            utf8("future"), [1, 2, 3],
            pairs[0], pairs[1],
            utf8("other"), utf8("x"),
            pairs[2], pairs[3],
        ])

        let bind = try await verify(lock)

        XCTAssertEqual(bind, OpNS.Bind(
            identityKey: Hex.encode(identity.publicKey.compressedBytes),
            domain: "1sat.name"
        ))
    }

    func test_missingOrDuplicateIdentityIsNoBind() async throws {
        let identity = try key(7007)
        let pairs = try publishFields(identity.publicKey, profile: OpnsFields.Profile(domain: "1sat.name"))

        let missing = try await signedLock(identity, [pairs[2], pairs[3]])
        await assertThrows(.noBind("missing identity"), "no bind: missing identity") {
            _ = try await self.verify(missing)
        }

        let duplicate = try await signedLock(identity, [pairs[0], pairs[1], pairs[0], pairs[1]])
        await assertThrows(.noBind("duplicate identity"), "no bind: duplicate identity") {
            _ = try await self.verify(duplicate)
        }
    }

    func test_duplicateProfileAndBadValuesAreNoBind() async throws {
        let identity = try key(7008)
        let pairs = try publishFields(identity.publicKey, profile: OpnsFields.Profile(domain: "1sat.name"))

        let twoProfiles = try await signedLock(identity, pairs + [pairs[2], pairs[3]])
        await assertThrows(.noBind("duplicate profile"), "no bind: duplicate profile") {
            _ = try await self.verify(twoProfiles)
        }

        let shortKey = try await signedLock(identity, [pairs[0], Array(pairs[1].dropLast())])
        await assertThrows(.noBind("identity is not a key"), "no bind: identity is not a key") {
            _ = try await self.verify(shortKey)
        }

        let oddFields = try await signedLock(identity, [pairs[0], pairs[1], utf8("dangling")])
        await assertThrows(
            .noBind("fields are not key/value pairs"),
            "no bind: fields are not key/value pairs"
        ) {
            _ = try await self.verify(oddFields)
        }
    }

    func test_rejectsThePre83PositionalBindAsNoBind() async throws {
        let identity = try key(7003)
        let lock = try await signedLock(identity, [identity.publicKey.compressedBytes, utf8("Alice")])

        do {
            _ = try await verify(lock)
            XCTFail("expected no bind")
        } catch let error as OpnsBindError {
            XCTAssertTrue(error.wireMessage.hasPrefix("no bind"), error.wireMessage)
        }
    }

    func test_rejectsAScriptThatIsNotAPushDrop() async throws {
        let p2pkh = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        await assertThrows(
            .noBind("not a signed key/value PushDrop"),
            "no bind: not a signed key/value PushDrop"
        ) {
            _ = try await self.verify(p2pkh)
        }
    }

    func test_rejectsFieldsSignedBySomeoneElse() async throws {
        let signer = try key(7004)
        let claimed = try key(7005)
        let lock = try await signedLock(signer, publishFields(claimed.publicKey))

        await assertThrows(.lockKeyMismatch, "lock pubkey does not match bind derivation") {
            _ = try await self.verify(lock)
        }
    }

    func test_rejectsABindMadeForAnotherCreationInput() async throws {
        let identity = try key(7009)
        let lock = try await signedLock(identity, publishFields(identity.publicKey))
        let tx = try bindTransaction(lock: lock, spending: String(repeating: "9b", count: 32) + ".0")

        await assertThrows(.lockKeyMismatch, "lock pubkey does not match bind derivation") {
            _ = try await OpNS.verifyPushDropBind(transaction: tx, vout: 0, lockingScript: lock)
        }
    }

    func test_rejectsASignatureOverOtherFields() async throws {
        let identity = try key(7010)
        let signed = try publishFields(identity.publicKey, profile: OpnsFields.Profile(domain: "1sat.name"))
        let signedLock = try await signedLock(identity, signed)
        let signature = try XCTUnwrap(SignOrdinalInput.pushDrop(in: signedLock)?.fields.last)

        let swapped = try publishFields(identity.publicKey, profile: OpnsFields.Profile(domain: "evil.name"))
        let forged = try await unsignedLock(identity, swapped + [signature])
        await assertThrows(.invalidSignature, "invalid PushDrop field signature") {
            _ = try await self.verify(forged)
        }

        let garbage = try await unsignedLock(identity, signed + [[0x30, 0x01, 0x02]])
        await assertThrows(.invalidSignature, "invalid PushDrop field signature") {
            _ = try await self.verify(garbage)
        }
    }

    func test_aTransactionWithoutInputsHasNoCreationOutpoint() async throws {
        let identity = try key(7011)
        let lock = try await signedLock(identity, publishFields(identity.publicKey))
        let tx = Transaction(
            version: 1,
            inputs: [],
            outputs: [TransactionOutput(satoshis: 1, lockingScript: lock)],
            lockTime: 0
        )

        await assertThrows(.missingCreationInput, "missing creation input outpoint") {
            _ = try await OpNS.verifyPushDropBind(transaction: tx, vout: 0, lockingScript: lock)
        }
    }

    // MARK: resolvePaymailBind

    func test_resolveFollowsOriginToLatestAndVerifiesTheBind() async throws {
        let identity = try ActionVectors.identity()
        let tx = try bindTransaction(
            lock: try script(SignOrdinalInputTests.lockFull),
            spending: ActionVectors.outpoint,
            outputsBefore: 1
        )
        let txid = try tx.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let origin = String(repeating: "aa", count: 32) + "_0"
        let http = ScriptedHTTP(responses: [
            (200, json(#"{"name":"alice","outpoint":"\#(origin)"}"#)),
            (200, json(#"{"outpoint":"\#(txid)_1","origin":"\#(origin)","sequence":3,"contentType":"application/op-ns","contentLength":0}"#)),
        ])
        let beef = RecordingBeef(bytes: try beefBytes([tx]))

        let resolved = try await OpNS.resolveBind(
            name: "alice",
            opns: OpnsClient(baseURL: baseURL, transport: http),
            beef: beef
        )

        XCTAssertEqual(resolved, OpNS.ResolvedBind(
            identityKey: Hex.encode(identity.publicKey.compressedBytes),
            outpoint: "\(txid).1",
            domain: "1sat.name",
            profileName: "Alice",
            avatarOrigin: String(repeating: "ef", count: 32) + ".1"
        ))
        let calls = await http.urls()
        XCTAssertEqual(calls, [
            OpnsClient.originURL(name: "alice", baseURL: baseURL),
            OpnsClient.metadataURL(outpoint: origin, seq: -1, baseURL: baseURL),
        ])
        let asked = await beef.asked()
        XCTAssertEqual(asked, [txid])
    }

    func test_resolveRefusesAMissingOutput() async throws {
        let tx = try bindTransaction(
            lock: try script(SignOrdinalInputTests.lockFull),
            spending: ActionVectors.outpoint
        )
        let txid = try tx.transactionID(limits: WalletTransactionLimits.standard).displayHex
        let origin = String(repeating: "aa", count: 32) + "_0"

        await assertThrows(.noOutput(txid: txid, vout: 5), "no output at \(txid).5") {
            _ = try await OpNS.resolveBind(
                name: "alice",
                opns: OpnsClient(baseURL: self.baseURL, transport: ScriptedHTTP(responses: [
                    (200, self.json(#"{"name":"alice","outpoint":"\#(origin)"}"#)),
                    (200, self.json(#"{"outpoint":"\#(txid)_5"}"#)),
                ])),
                beef: RecordingBeef(bytes: try self.beefBytes([tx]))
            )
        }
    }

    func test_resolveRefusesBEEFWithoutTheLatestTransaction() async throws {
        let tx = try bindTransaction(
            lock: try script(SignOrdinalInputTests.lockFull),
            spending: ActionVectors.outpoint
        )
        let other = String(repeating: "cd", count: 32)

        await assertThrows(.noOutput(txid: other, vout: 0), "no output at \(other).0") {
            _ = try await OpNS.resolveBind(
                name: "alice",
                opns: OpnsClient(baseURL: self.baseURL, transport: ScriptedHTTP(responses: [
                    (200, self.json(#"{"name":"alice","outpoint":"\#(other)_0"}"#)),
                    (200, self.json(#"{"outpoint":"\#(other)_0"}"#)),
                ])),
                beef: RecordingBeef(bytes: try self.beefBytes([tx]))
            )
        }
    }

    func test_resolveSurfacesAnUnboundLatestRevision() async throws {
        let p2pkh = try ActionScript.payToPublicKeyHash(ActionVectors.templateAddress)
        let tx = try bindTransaction(lock: p2pkh, spending: ActionVectors.outpoint)
        let txid = try tx.transactionID(limits: WalletTransactionLimits.standard).displayHex

        await assertThrows(
            .noBind("not a signed key/value PushDrop"),
            "no bind: not a signed key/value PushDrop"
        ) {
            _ = try await OpNS.resolveBind(
                name: "alice",
                opns: OpnsClient(baseURL: self.baseURL, transport: ScriptedHTTP(responses: [
                    (200, self.json(#"{"name":"alice","outpoint":"\#(txid)_0"}"#)),
                    (200, self.json(#"{"outpoint":"\#(txid)_0"}"#)),
                ])),
                beef: RecordingBeef(bytes: try self.beefBytes([tx]))
            )
        }
    }

    func test_resolvePassesThroughAnOriginLookupFailure() async throws {
        do {
            _ = try await OpNS.resolveBind(
                name: "nobody",
                opns: OpnsClient(baseURL: baseURL, transport: ScriptedHTTP(responses: [(404, [])])),
                beef: RecordingBeef(bytes: [])
            )
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 404))
        }
    }

    // MARK: Helpers

    /// `["identity", key, "profile", cbor?]`: the layout `registerOpns` writes.
    private func publishFields(
        _ identityKey: PublicKey,
        profile: OpnsFields.Profile? = nil
    ) throws -> [[UInt8]] {
        var fields = [utf8(OpnsFields.identityField), identityKey.compressedBytes]
        if let profile {
            fields += [utf8(OpnsFields.profileField), try OpnsFields.encodeProfile(profile)]
        }
        return fields
    }

    /// TS `bindTx`: `PushDrop.lock(fields, P1SAT, opns:<source>_0, 'anyone', forSelf, sign)`.
    private func signedLock(_ identity: PrivateKey, _ fields: [[UInt8]]) async throws -> Script {
        try await lock(identity, fields, includeSignature: true)
    }

    private func unsignedLock(_ identity: PrivateKey, _ fields: [[UInt8]]) async throws -> Script {
        try await lock(identity, fields, includeSignature: false)
    }

    private func lock(
        _ identity: PrivateKey,
        _ fields: [[UInt8]],
        includeSignature: Bool
    ) async throws -> Script {
        try await PushDrop.lockingScript(
            fields: fields,
            using: ProtoWallet(rootKey: identity),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: WalletKeyID(OpNS.registerKeyID(try Outpoint(Self.sourceTxid + ".0"))),
            counterparty: .anyone,
            forSelf: true,
            includeSignature: includeSignature,
            lockPosition: .beforeCompatibility
        )
    }

    private func verify(_ lock: Script) async throws -> OpNS.Bind {
        let tx = try bindTransaction(lock: lock, spending: Self.sourceTxid + ".0")
        return try await OpNS.verifyPushDropBind(transaction: tx, vout: 0, lockingScript: lock)
    }

    private func bindTransaction(
        lock: Script,
        spending outpoint: String,
        outputsBefore: Int = 0
    ) throws -> Transaction {
        let filler = try Script(bytes: [0x51], maximumByteCount: 10_000)
        return Transaction(
            version: 1,
            inputs: [
                TransactionInput(
                    previousOutput: try Outpoint(outpoint),
                    unlockingScript: try Script(bytes: [], maximumByteCount: 10_000)
                ),
            ],
            outputs: Array(
                repeating: TransactionOutput(satoshis: 1, lockingScript: filler),
                count: outputsBefore
            ) + [TransactionOutput(satoshis: 1, lockingScript: lock)],
            lockTime: 0
        )
    }

    private func beefBytes(_ transactions: [Transaction]) throws -> [UInt8] {
        try BEEF(
            merklePaths: [],
            transactions: transactions.map { .raw($0) },
            limits: WalletBEEFLimits.standard
        ).serialized(limits: WalletBEEFLimits.standard)
    }

    /// TS `new PrivateKey(n)`.
    private func key(_ scalar: UInt16) throws -> PrivateKey {
        try PrivateKey([UInt8](repeating: 0, count: 30) + [UInt8(scalar >> 8), UInt8(scalar & 0xff)])
    }

    private func script(_ hex: String) throws -> Script {
        try Script(bytes: Hex.decode(hex, maximumDecodedByteCount: 10_000), maximumByteCount: 10_000)
    }

    private func utf8(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func json(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func assertThrows(
        _ expected: OpnsBindError,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(message)", file: file, line: line)
        } catch let error as OpnsBindError {
            XCTAssertEqual(error, expected, file: file, line: line)
            XCTAssertEqual(error.wireMessage, message, file: file, line: line)
        } catch {
            XCTFail("expected OpnsBindError, got \(error)", file: file, line: line)
        }
    }
}

private actor ScriptedHTTP: OneSatHTTPTransport {
    private var responses: [(status: Int, body: [UInt8])]
    private var calls: [URL] = []

    init(responses: [(status: Int, body: [UInt8])]) {
        self.responses = responses
    }

    func send(
        method: String,
        url: URL,
        headers _: [String: String],
        body _: [UInt8]?
    ) async throws -> (status: Int, body: [UInt8]) {
        calls.append(url)
        return responses.removeFirst()
    }

    func urls() -> [URL] { calls }
}

private actor RecordingBeef: ListingBeefSource {
    private let bytes: [UInt8]
    private var txids: [String] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func beef(forTxid txid: String) async throws -> [UInt8] {
        txids.append(txid)
        return bytes
    }

    func asked() -> [String] { txids }
}
