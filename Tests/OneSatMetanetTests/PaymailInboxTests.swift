import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
import ToolboxWallet
@testable import OneSatMetanet

/// `syncMessages` paymail handling, against vectors made by running the TypeScript action itself
/// (`Fixtures/paymail-inbox-vectors.json`, see its `generator`): each case is the body a message
/// box hands over and the exact `internalizeAction` arguments the TS wallet received.
final class PaymailInboxTests: XCTestCase {

    struct Vectors: Decodable {
        struct Output: Decodable, Equatable {
            struct Remittance: Decodable, Equatable {
                let derivationPrefix: String
                let derivationSuffix: String
                let senderIdentityKey: String
            }
            let outputIndex: UInt32
            let `protocol`: String
            let paymentRemittance: Remittance
        }
        struct Case: Decodable {
            let name: String
            let swiftBody: String
            let processed: Int
            let failed: Int
            let acknowledged: [String]
            let tx: String?
            let descriptionUTF16: [UInt16]?
            let outputs: [Output]?
            let argumentKeys: [String]?
        }
        let recipientPrivateKey: String
        let recipientKey: String
        let anyoneKey: String
        let prefix: String
        let suffix: String
        let parentTxid: String
        let paymentTxid: String
        let paymentScript: String
        let plainHex: String
        let atomicHex: String
        let trailingHex: String
        let cases: [Case]
    }

    /// Records every request and accepts it.
    actor RecordingWallet: PaymailPaymentWallet {
        private(set) var requests: [WalletInternalizeActionRequest] = []
        func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
            requests.append(request)
            return WalletInternalizeActionResult(accepted: true)
        }
    }

    /// Storage behind a real `RemoteWallet`: records each JSON-RPC body and accepts internalize.
    actor RecordingStorage: AuthenticatedTransport {
        private(set) var bodies: [[UInt8]] = []
        func send(
            method: String, path: String, query: String?, headers: [String: String], body: [UInt8]?
        ) async throws -> AuthenticatedResponse {
            bodies.append(body ?? [])
            let call = try JSONSerialization.jsonObject(with: Data(body ?? [])) as? [String: Any]
            let reply: [String: Any] = ["jsonrpc": "2.0", "id": call?["id"] ?? NSNull(), "result": ["accepted": true]]
            return AuthenticatedResponse(
                statusCode: 200, headers: [:], body: Array(try JSONSerialization.data(withJSONObject: reply))
            )
        }
    }

    static func vectors() throws -> Vectors {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "paymail-inbox-vectors", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    static func bytes(_ hex: String) throws -> [UInt8] {
        try Hex.decode(hex, maximumDecodedByteCount: 1 << 20)
    }

    /// The description Swift sends for a TS one: the same UTF-16 units, except that a lone lead
    /// surrogate left by `.slice(0, 50)` is dropped.
    static func expectedDescription(_ ts: [UInt16]) -> [UInt16] {
        guard let last = ts.last, UTF16.isLeadSurrogate(last) else { return ts }
        return Array(ts.dropLast())
    }

    func test_tsVectorsInternalizeTheExactRequest() async throws {
        let v = try Self.vectors()
        let succeeding = v.cases.filter { $0.tx != nil }
        XCTAssertEqual(succeeding.map(\.name), ["plain", "atomic", "trailingTxidOnly", "stringBody"])
        for c in succeeding {
            XCTAssertEqual(c.processed, 1, c.name)
            XCTAssertEqual(c.acknowledged, ["m-\(c.name)"], c.name)
            // TS passes tx, outputs and description only: no labels, no seekPermission.
            XCTAssertEqual(c.argumentKeys, ["description", "outputs", "tx"], c.name)

            let wallet = RecordingWallet()
            let receipt = try await PaymailInbox.internalize(body: c.swiftBody, wallet: wallet)
            let requests = await wallet.requests
            XCTAssertEqual(requests.count, 1, c.name)
            let request = try XCTUnwrap(requests.first)

            XCTAssertEqual(try request.transaction.serialized(limits: StorageLimits.beef), try Self.bytes(c.tx!), c.name)
            XCTAssertEqual(request.transaction.subjectTransactionID.displayHex, v.paymentTxid, c.name)
            XCTAssertEqual(Array(request.description.utf16), Self.expectedDescription(c.descriptionUTF16!), c.name)
            XCTAssertEqual(request.labels, [], c.name)
            XCTAssertNil(request.seekPermission, c.name)

            let expected = try XCTUnwrap(c.outputs, c.name)
            XCTAssertEqual(request.outputs.count, expected.count, c.name)
            for (output, want) in zip(request.outputs, expected) {
                XCTAssertEqual(want.protocol, "wallet payment", c.name)
                XCTAssertEqual(output.outputIndex, want.outputIndex, c.name)
                guard case .walletPayment(let payment) = output.remittance else {
                    XCTFail("\(c.name): not a wallet payment")
                    continue
                }
                XCTAssertEqual(payment.derivationPrefix.base64, want.paymentRemittance.derivationPrefix, c.name)
                XCTAssertEqual(payment.derivationSuffix.base64, want.paymentRemittance.derivationSuffix, c.name)
                XCTAssertEqual(
                    Hex.encode(payment.senderIdentityKey.compressedBytes), want.paymentRemittance.senderIdentityKey, c.name
                )
            }

            XCTAssertEqual(receipt.txid, v.paymentTxid, c.name)
            XCTAssertEqual(receipt.outputIndex, 1, c.name)
            XCTAssertEqual(receipt.satoshis, 3000, c.name)
            XCTAssertTrue(receipt.accepted, c.name)
        }
    }

    func test_tsFailuresInternalizeNothing() async throws {
        let v = try Self.vectors()
        let failing = v.cases.filter { $0.tx == nil }
        XCTAssertEqual(failing.map(\.name), ["notJSON", "emptyBeef"])
        // A body that is not JSON, either as raw text or as a JSON string, is refused like TS.
        for body in failing.map(\.swiftBody) + ["\"not json\""] {
            let wallet = RecordingWallet()
            do {
                try await PaymailInbox.internalize(body: body, wallet: wallet)
                XCTFail("internalized \(body)")
            } catch is PaymailInboxError {
            }
            let requests = await wallet.requests
            XCTAssertTrue(requests.isEmpty, body)
        }
        for c in failing {
            XCTAssertEqual(c.processed, 0, c.name)
            XCTAssertEqual(c.failed, 1, c.name)
            XCTAssertEqual(c.acknowledged, [], c.name)
        }
    }

    func test_subjectIsTheLastEntryCarryingATransaction() throws {
        let v = try Self.vectors()

        let trailing = try PaymailInbox.readBEEF(try Self.bytes(v.trailingHex))
        XCTAssertEqual(trailing.transactions.count, 3)
        XCTAssertNil(trailing.transactions.last?.transaction)
        XCTAssertEqual(try PaymailInbox.subjectTransactionID(of: trailing).displayHex, v.paymentTxid)

        let plain = try PaymailInbox.readBEEF(try Self.bytes(v.plainHex))
        XCTAssertEqual(try PaymailInbox.subjectTransactionID(of: plain).displayHex, v.paymentTxid)

        // `Beef.fromBinary` reads past an Atomic prefix and ignores the subject it names.
        var atomic = try Self.bytes(v.atomicHex)
        let parent = try TransactionID(displayHex: v.parentTxid)
        atomic.replaceSubrange(4..<36, with: parent.wireBytes)
        XCTAssertEqual(
            try PaymailInbox.subjectTransactionID(of: try PaymailInbox.readBEEF(atomic)).displayHex, v.paymentTxid
        )

        // The Atomic BEEF sent holds the subject's ancestry only: the trailing txid-only entry goes.
        let sent = try MetanetBEEF.atomic(try PaymailInbox.subjectTransactionID(of: trailing), in: trailing)
        XCTAssertEqual(sent.beef.transactions.count, 2)
        XCTAssertEqual(try sent.beef.transactions[0].transactionID(limits: StorageLimits.beef.transactionLimits).displayHex, v.parentTxid)

        let empty = try PaymailInbox.readBEEF([0x02, 0x00, 0xbe, 0xef, 0x00, 0x00])
        XCTAssertThrowsError(try PaymailInbox.subjectTransactionID(of: empty))
    }

    func test_descriptionIsCutToFiftyUTF16Units() {
        XCTAssertEqual(PaymailInbox.description(alias: "luke"), "Paymail payment to luke")
        let fits = String(repeating: "a", count: 31)
        XCTAssertEqual(PaymailInbox.description(alias: fits), "Paymail payment to \(fits)")
        XCTAssertEqual(PaymailInbox.description(alias: fits).utf16.count, 50)
        XCTAssertEqual(
            PaymailInbox.description(alias: fits + "bcdef"), "Paymail payment to \(fits)"
        )
        // A pair that ends at unit 50 stays whole; one cut through is dropped.
        let pairEnds = String(repeating: "b", count: 29) + "\u{1F600}"
        XCTAssertEqual(PaymailInbox.description(alias: pairEnds), "Paymail payment to \(pairEnds)")
        let pairCut = String(repeating: "b", count: 30) + "\u{1F600}"
        XCTAssertEqual(
            PaymailInbox.description(alias: pairCut), "Paymail payment to \(String(repeating: "b", count: 30))"
        )
        // Units, not characters: a two-unit character counts twice.
        let wide = String(repeating: "\u{1F600}", count: 20)
        XCTAssertEqual(PaymailInbox.description(alias: wide).utf16.count, 49)
    }

    func test_bodyDecoding() throws {
        let v = try Self.vectors()
        let plain = try XCTUnwrap(v.cases.first { $0.name == "plain" })
        let message = try PaymailInbox.decode(plain.swiftBody)
        XCTAssertEqual(message.beef, try Self.bytes(v.plainHex))
        XCTAssertEqual(message.outputIndex, 1)
        XCTAssertEqual(message.derivationPrefix, v.prefix)
        XCTAssertEqual(message.derivationSuffix, v.suffix)
        XCTAssertEqual(message.senderIdentityKey, v.anyoneKey)
        XCTAssertEqual(message.satoshis, 3000)
        XCTAssertEqual(message.alias, "luke")

        // Double-encoded (a JSON string holding the object) decodes to the same message.
        let quoted = String(decoding: try JSONEncoder().encode(plain.swiftBody), as: UTF8.self)
        XCTAssertEqual(try PaymailInbox.decode(quoted), message)

        func body(_ edit: (inout [String: Any]) -> Void) throws -> String {
            var object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(plain.swiftBody.utf8)) as? [String: Any]
            )
            edit(&object)
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        // `satoshis` is never read, so its shape does not matter.
        XCTAssertNil(try PaymailInbox.decode(try body { $0["satoshis"] = "many" }).satoshis)
        XCTAssertNil(try PaymailInbox.decode(try body { _ = $0.removeValue(forKey: "satoshis") }).satoshis)

        XCTAssertThrowsError(try PaymailInbox.decode(try body { _ = $0.removeValue(forKey: "alias") }), "no alias")
        XCTAssertThrowsError(try PaymailInbox.decode(try body { $0["outputIndex"] = -1 }), "negative index")
        XCTAssertThrowsError(try PaymailInbox.decode(try body { $0["outputIndex"] = "1" }), "index as text")
        XCTAssertThrowsError(try PaymailInbox.decode(try body { $0["beef"] = "zz" }), "beef not hex")
        XCTAssertThrowsError(
            try PaymailInbox.decode(try body { _ = $0.removeValue(forKey: "derivationPrefix") }), "no prefix"
        )
        XCTAssertThrowsError(try PaymailInbox.decode("[1,2]"))
    }

    func test_remittanceThatIsNotAKeyOrBase64IsRefused() throws {
        let v = try Self.vectors()
        let message = try PaymailInbox.decode(try XCTUnwrap(v.cases.first { $0.name == "plain" }).swiftBody)
        func with(prefix: String? = nil, sender: String? = nil) -> PaymailInbox.Message {
            PaymailInbox.Message(
                beef: message.beef, outputIndex: message.outputIndex,
                derivationPrefix: prefix ?? message.derivationPrefix, derivationSuffix: message.derivationSuffix,
                senderIdentityKey: sender ?? message.senderIdentityKey, satoshis: message.satoshis, alias: message.alias
            )
        }
        XCTAssertThrowsError(try PaymailInbox.internalizeRequest(for: with(prefix: "not base64!")))
        XCTAssertThrowsError(try PaymailInbox.internalizeRequest(for: with(sender: "02abcd")))
        XCTAssertNoThrow(try PaymailInbox.internalizeRequest(for: message))
    }

    /// Through a real `RemoteWallet`: the TS-derived output is the recipient's BRC-29 key, and
    /// storage receives exactly the arguments TS gave the wallet.
    func test_remoteWalletSendsStorageTheTSArguments() async throws {
        let v = try Self.vectors()
        XCTAssertEqual(v.anyoneKey, Hex.encode(try PrivateKey(try Self.bytes(String(repeating: "0", count: 63) + "1")).publicKey.compressedBytes))
        let recipient = try PrivateKey(try Self.bytes(v.recipientPrivateKey))
        XCTAssertEqual(Hex.encode(recipient.publicKey.compressedBytes), v.recipientKey)

        for name in ["plain", "atomic"] {
            let c = try XCTUnwrap(v.cases.first { $0.name == name })
            let storage = RecordingStorage()
            let wallet = RemoteWallet(
                storage: StorageClient(endpoint: URL(string: "https://storage.example.invalid")!, transport: storage),
                identityKey: recipient,
                auth: AuthID(identityKey: v.recipientKey)
            )
            let receipt = try await PaymailInbox.internalize(body: c.swiftBody, wallet: wallet)
            XCTAssertTrue(receipt.accepted, name)

            let bodies = await storage.bodies
            XCTAssertEqual(bodies.count, 1, name)
            let call = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(bodies.first))) as? [String: Any])
            XCTAssertEqual(call["method"] as? String, "internalizeAction", name)
            let params = try XCTUnwrap(call["params"] as? [Any], name)
            XCTAssertEqual((params.first as? [String: Any])?["identityKey"] as? String, v.recipientKey, name)
            let args = try XCTUnwrap(params.last as? [String: Any], name)
            let tx = try XCTUnwrap(args["tx"] as? [NSNumber], name).map { $0.uint8Value }
            XCTAssertEqual(tx, try Self.bytes(c.tx!), name)
            XCTAssertEqual(args["description"] as? String, String(decoding: c.descriptionUTF16!, as: UTF16.self), name)
            XCTAssertEqual((args["labels"] as? [Any])?.count, 0, name)
            let outputs = try XCTUnwrap(args["outputs"] as? [[String: Any]], name)
            XCTAssertEqual(outputs.count, 1, name)
            let want = try XCTUnwrap(c.outputs?.first, name)
            XCTAssertEqual((outputs[0]["outputIndex"] as? NSNumber)?.uint32Value, want.outputIndex, name)
            XCTAssertEqual(outputs[0]["protocol"] as? String, want.protocol, name)
            let remittance = try XCTUnwrap(outputs[0]["paymentRemittance"] as? [String: String], name)
            XCTAssertEqual(remittance, [
                "derivationPrefix": want.paymentRemittance.derivationPrefix,
                "derivationSuffix": want.paymentRemittance.derivationSuffix,
                "senderIdentityKey": want.paymentRemittance.senderIdentityKey,
            ], name)
        }
    }

    /// The wallet refuses an output that is not its key before storage is called.
    func test_remoteWalletRefusesAnOutputThatIsNotTheRecipients() async throws {
        let v = try Self.vectors()
        let message = try PaymailInbox.decode(try XCTUnwrap(v.cases.first { $0.name == "plain" }).swiftBody)
        let wrongIndex = PaymailInbox.Message(
            beef: message.beef, outputIndex: 0, derivationPrefix: message.derivationPrefix,
            derivationSuffix: message.derivationSuffix, senderIdentityKey: message.senderIdentityKey,
            satoshis: message.satoshis, alias: message.alias
        )
        let storage = RecordingStorage()
        let wallet = RemoteWallet(
            storage: StorageClient(endpoint: URL(string: "https://storage.example.invalid")!, transport: storage),
            identityKey: try PrivateKey(try Self.bytes(v.recipientPrivateKey)),
            auth: AuthID(identityKey: v.recipientKey)
        )
        do {
            try await PaymailInbox.internalize(wrongIndex, wallet: wallet)
            XCTFail("internalized an output that is not the recipient's")
        } catch {}
        let bodies = await storage.bodies
        XCTAssertTrue(bodies.isEmpty)
    }
}
