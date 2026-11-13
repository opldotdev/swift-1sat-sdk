import XCTest
import BSVCore
import BSVKeys
import BSVWallet
import OneSatCBOR
@testable import OneSatMetanet

/// BRC-169 envelopes against Appendix A.7, as `envelope.test.ts` checks them, plus BRC-78
/// framing, the DAG-CBOR relay, and handle resolution.
final class EnvelopeTests: XCTestCase {

    static let crumbsPrivate = "cf94a849be462a110807900e45a909515c38a2d17b9a8e9753c9475bfd220848"
    static let crumbsPublic = "0375b162a37d8794cfdcf72938d9467931e8586885b93c0da97051ecb512f46646"
    static let a7Preimage = "a76673656e646572a366646f6d61696e6d6e657875732e6578616d706c656668616e646c65666372756d62736b6964656e746974794b657958210375b162a37d8794cfdcf72938d9467931e8586885b93c0da97051ecb512f46646676372656174656474323032362d30372d33305430393a31353a30305a677061796d656e74a56462656566406870726f746f636f6c6c333234313634353136316438687361746f736869731954297064657269766174696f6e507265666978500f5bcc8d7c345d512595d55982b5a4e37064657269766174696f6e537566666978509c42b65554891520ae960a7fb477759e6771756f746549647820306433346362333963316336666530366364346133343638363765316533333469726563697069656e74a36374616768636f6e663230333666646f6d61696e686c6b75702e6e65746668616e646c656664656767656e6b636f6e74656e7448617368582076f88073e3498f542c57fb9a2133743d6f0c1f9c4632e786116568ccd393e35c6e6d6574616e657448616e646c657363312e30"
    static let a7Signature = "304402206a2bf0b0628386870202789d718001580279cc1add7b3dc3ff81e08858e22f8c022051d6e6d5756bf2bd1d06ea5199af080e721bb1f5dddefe9a36884796d5d04cf7"

    static func hex(_ text: String) throws -> [UInt8] {
        try Hex.decode(text, maximumDecodedByteCount: 1 << 20)
    }

    /// Appendix A.7 as printed, with `payment.protocol` as text.
    static func a7() throws -> MetanetEnvelope.Unsigned {
        MetanetEnvelope.Unsigned(
            recipient: .init(handle: "deggen", tag: "conf2036", domain: "lkup.net"),
            senderIdentityKey: try hex(crumbsPublic),
            senderHandle: "crumbs",
            senderDomain: "nexus.example",
            created: "2026-07-30T09:15:00Z",
            quoteID: "0d34cb39c1c6fe06cd4a346867e1e334",
            payment: .map(try DagCborMap([
                ("derivationPrefix", .bytes(Array(Data(base64Encoded: "D1vMjXw0XVElldVZgrWk4w==")!))),
                ("derivationSuffix", .bytes(Array(Data(base64Encoded: "nEK2VVSJFSCulgp/tHd1ng==")!))),
                ("protocol", .text("3241645161d8")),
                ("satoshis", .unsigned(21545)),
                ("beef", .bytes([])),
            ])),
            contentHash: try hex("76f88073e3498f542c57fb9a2133743d6f0c1f9c4632e786116568ccd393e35c")
        )
    }

    func test_preimageMatchesAppendixA7() throws {
        XCTAssertEqual(Hex.encode(try Self.a7().signingPreimage()), Self.a7Preimage)
    }

    func test_appendixA7SignatureVerifies() async throws {
        let received = MetanetEnvelope.Received(
            map: try Self.a7().map(), senderIdentityKey: try Self.hex(Self.crumbsPublic),
            content: [], signature: try Self.hex(Self.a7Signature)
        )
        let valid = await MetanetEnvelope.verify(received)
        XCTAssertTrue(valid)
    }

    func test_signedEnvelopeIsCanonicalAndVerifies() async throws {
        let wallet = ProtoWallet(rootKey: try PrivateKey(try Self.hex(Self.crumbsPrivate)))
        let content = Array("opaque content".utf8)
        let (envelope, signature) = try await MetanetEnvelope.sign(
            try Self.a7(), content: content, wallet: wallet
        )
        XCTAssertEqual(try DagCbor.encode(try DagCbor.decode(envelope)), envelope)
        let received = try MetanetEnvelope.decode(envelope)
        XCTAssertEqual(received.content, content)
        XCTAssertEqual(received.signature, signature)
        XCTAssertEqual(Hex.encode(try received.signingPreimage()), Self.a7Preimage)
        let valid = await MetanetEnvelope.verify(received)
        XCTAssertTrue(valid)
    }

    func test_aTamperedEnvelopeDoesNotVerify() async throws {
        let wallet = ProtoWallet(rootKey: try PrivateKey(try Self.hex(Self.crumbsPrivate)))
        var unsigned = try Self.a7()
        let (envelope, _) = try await MetanetEnvelope.sign(unsigned, content: [1], wallet: wallet)
        let received = try MetanetEnvelope.decode(envelope)
        unsigned.created = "2026-07-30T09:15:01Z"
        let tampered = MetanetEnvelope.Received(
            map: try DagCborMap(try unsigned.map().entries + [
                ("content", .bytes([1])), ("signature", .bytes(received.signature)),
            ]),
            senderIdentityKey: received.senderIdentityKey, content: [1],
            signature: received.signature
        )
        let valid = await MetanetEnvelope.verify(tampered)
        XCTAssertFalse(valid)
    }

    func test_timestampHasWholeSeconds() {
        XCTAssertEqual(
            MetanetEnvelope.timestamp(Date(timeIntervalSince1970: 1_785_402_900.789)),
            "2026-07-30T09:15:00Z"
        )
    }

    // MARK: - BRC-78

    func test_brc78RoundTripsAndFramesAsTheReference() async throws {
        let alice = try PrivateKey([UInt8](repeating: 0, count: 31) + [1])
        let bob = try PrivateKey([UInt8](repeating: 0, count: 31) + [2])
        let keyID = [UInt8](repeating: 7, count: 32)
        let message = try await BRC78.encrypt(
            Array("hello".utf8), to: bob.publicKey, wallet: try BRC78.wallet(for: alice), keyID: keyID
        )
        XCTAssertEqual(Array(message[0..<4]), [0x42, 0x42, 0x10, 0x33])
        XCTAssertEqual(Array(message[4..<37]), alice.publicKey.compressedBytes)
        XCTAssertEqual(Array(message[37..<70]), bob.publicKey.compressedBytes)
        XCTAssertEqual(Array(message[70..<102]), keyID)
        let plaintext = try await BRC78.decrypt(message, from: alice.publicKey, wallet: try BRC78.wallet(for: bob))
        XCTAssertEqual(plaintext, Array("hello".utf8))
    }

    func test_brc78TakesMoreThanOneMebibyte() async throws {
        let alice = try PrivateKey([UInt8](repeating: 0, count: 31) + [1])
        let bob = try PrivateKey([UInt8](repeating: 0, count: 31) + [2])
        let big = [UInt8](repeating: 9, count: 2 << 20)
        let message = try await BRC78.encrypt(big, to: bob.publicKey, wallet: try BRC78.wallet(for: alice))
        let plaintext = try await BRC78.decrypt(message, from: alice.publicKey, wallet: try BRC78.wallet(for: bob))
        XCTAssertEqual(plaintext.count, big.count)
    }

    func test_brc78RefusesAnotherVersion() async throws {
        let bob = try PrivateKey([UInt8](repeating: 0, count: 31) + [2])
        do {
            _ = try await BRC78.decrypt([UInt8](repeating: 0, count: 120), from: bob.publicKey,
                                        wallet: try BRC78.wallet(for: bob))
            XCTFail("expected a refusal")
        } catch {}
    }

    // MARK: - Relay

    actor RecordingTransport: MetanetTransport {
        var requests: [(URL, String, [UInt8])] = []
        var reply: DagCborValue

        init(reply: DagCborValue) { self.reply = reply }

        func post(host: URL, path: String, body: [UInt8]) async throws -> [UInt8] {
            requests.append((host, path, body))
            return try DagCbor.encode(reply)
        }
    }

    func test_relayBodiesAreTheReferenceShapes() async throws {
        let transport = RecordingTransport(reply: .map([
            "status": .text("success"), "messageId": .text("m1"),
        ]))
        let relay = CborRelay(transport: transport)
        let host = URL(string: "https://box.example")!
        let sent = try await relay.send(host: host, recipient: [2, 3], messageBox: "transaction-delivery", body: [9])
        XCTAssertEqual(sent.messageID, "m1")
        try await relay.acknowledge(host: host, messageIDs: ["m1"])
        let requests = await transport.requests
        XCTAssertEqual(requests[0].1, "/sendMessage")
        XCTAssertEqual(try DagCbor.decode(requests[0].2), .map([
            "message": .map([
                "recipient": .bytes([2, 3]), "messageBox": .text("transaction-delivery"),
                "body": .bytes([9]),
            ]),
        ]))
        XCTAssertEqual(requests[1].1, "/acknowledgeMessage")
        XCTAssertEqual(try DagCbor.decode(requests[1].2), .map(["messageIds": .array([.text("m1")])]))
    }

    func test_relayListsMessages() async throws {
        let transport = RecordingTransport(reply: .map([
            "status": .text("success"),
            "messages": .array([.map([
                "messageId": .text("m1"), "body": .bytes([1, 2]), "sender": .bytes([3]),
            ])]),
        ]))
        let messages = try await CborRelay(transport: transport)
            .list(host: URL(string: "https://box.example")!, messageBox: "transaction-delivery")
        XCTAssertEqual(messages, [.init(messageID: "m1", body: [1, 2], sender: [3])])
        let requests = await transport.requests
        XCTAssertEqual(try DagCbor.decode(requests[0].2), .map(["messageBox": .text("transaction-delivery")]))
    }

    // MARK: - Handles

    func test_handlesParseAsTheReference() throws {
        let parsed = try HandleResolver.parse(" @Alice+Shop@Example.COM ")
        XCTAssertEqual(parsed.handle, "alice")
        XCTAssertEqual(parsed.tag, "shop")
        XCTAssertEqual(parsed.domain, "example.com")
        XCTAssertNil(try HandleResolver.parse("bob@lkup.net").tag)
        XCTAssertThrowsError(try HandleResolver.parse("bob"))
        XCTAssertThrowsError(try HandleResolver.parse("bob@metanet"))
    }

    func test_resolveChecksTheManifestAndTheCertificate() async throws {
        let key = "02" + String(repeating: "ab", count: 32)
        let resolver = HandleResolver { url in
            switch url.absoluteString {
            case "https://lkup.net/manifest.json":
                return (200, Array(#"{"metanet":{"handles":{"version":"1.2"}}}"#.utf8))
            case "https://lkup.net/.well-known/metanet-handles/resolve?handle=deggen":
                return (200, Array(#"{"metanetHandles":"1.0","handle":"deggen","domain":"lkup.net","identityKey":"\#(key)","certificate":{"subject":"\#(key)"},"messagebox":"https://messagebox.1sat.app","ttl":60,"revoked":false}"#.utf8))
            default:
                return (404, [])
            }
        }
        let resolution = try await resolver.resolve("deggen+conf@lkup.net")
        XCTAssertEqual(resolution.identityKey, key)
        XCTAssertEqual(resolution.tag, "conf")
        XCTAssertEqual(resolution.messagebox, "https://messagebox.1sat.app")

        let mismatched = HandleResolver { url in
            url.path.hasSuffix("manifest.json")
                ? (200, Array(#"{"metanet":{"handles":{"version":"1.0","resolve":"https://r.example/x"}}}"#.utf8))
                : (200, Array(#"{"identityKey":"\#(key)","certificate":{"subject":"03ff"},"messagebox":"m"}"#.utf8))
        }
        do {
            _ = try await mismatched.resolve("deggen@lkup.net")
            XCTFail("expected a refusal")
        } catch {}

        let wrongVersion = HandleResolver { _ in
            (200, Array(#"{"metanet":{"handles":{"version":"2.0"}}}"#.utf8))
        }
        do {
            _ = try await wrongVersion.resolve("deggen@lkup.net")
            XCTFail("expected a refusal")
        } catch {}
    }
}
