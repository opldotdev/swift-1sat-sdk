import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatMetanet
import OneSatTemplates
@testable import OneSatColor

final class ColorUnitTests: XCTestCase {
    let identity = try! PrivateKey([UInt8](repeating: 0, count: 31) + [0x0c])

    // MARK: - MIME entity

    func test_mimeEntityParsesHeadersAndBody() throws {
        let entity = try MimeEntity.parse(Array("Content-Type: Application/Vnd.Metanet.Transaction+CBOR; v=1\r\nX-Note: one\r\n two\r\n\r\nBODY".utf8))
        XCTAssertEqual(entity.contentType, "Application/Vnd.Metanet.Transaction+CBOR; v=1")
        XCTAssertEqual(MimeEntity.mediaType(entity.contentType), "application/vnd.metanet.transaction+cbor")
        XCTAssertEqual(entity.headers["x-note"], "one two")
        XCTAssertEqual(entity.body, Array("BODY".utf8))
    }

    func test_contentWithoutAHeaderBlockIsPlainText() throws {
        for text in ["hello", "not a header\r\n\r\nbody", "a b: c\r\n\r\nx"] {
            let entity = try MimeEntity.parse(Array(text.utf8))
            XCTAssertEqual(entity.contentType, "text/plain", text)
            XCTAssertEqual(entity.body, Array(text.utf8), text)
        }
    }

    func test_aHeaderBlockWithoutContentTypeFails() {
        XCTAssertThrowsError(try MimeEntity.parse(Array("X-Note: one\r\n\r\nbody".utf8)))
    }

    // MARK: - Custody

    func test_metadataEncryptionRoundTripsAndPlainJSONPassesThrough() async throws {
        let custody = try ColorCustody(
            asset: .issue, derivationPrefix: "cA==", derivationSuffix: "cw==",
            senderIdentityKey: Hex.encode(identity.publicKey.compressedBytes)
        )
        let stored = try await ColorMetadata.encrypt(custody.json, identity: identity)
        XCTAssertNotEqual(stored, custody.json)
        let decrypted = await ColorMetadata.decrypt(stored, identity: identity)
        XCTAssertEqual(decrypted, custody.json)
        let passthrough = await ColorMetadata.decrypt(custody.json, identity: identity)
        XCTAssertEqual(passthrough, custody.json)
        let other = try PrivateKey([UInt8](repeating: 0, count: 31) + [0x0d])
        let unreadable = await ColorMetadata.decrypt(stored, identity: other)
        XCTAssertNil(unreadable)
    }

    func test_custodyParseIsStrict() throws {
        let key = Hex.encode(identity.publicKey.compressedBytes)
        let good = #"{"version":1,"assetId":"ISSUE","derivationPrefix":"cA==","derivationSuffix":"cw==","senderIdentityKey":"\#(key)"}"#
        XCTAssertEqual(try ColorCustody.parse(good).asset, .issue)
        XCTAssertNoThrow(try ColorCustody.parse(String(good.dropLast()) + #","profileData":{}}"#))
        XCTAssertThrowsError(try ColorCustody.parse(String(good.dropLast()) + #","profileData":{"x":1}}"#))
        XCTAssertThrowsError(try ColorCustody.parse(String(good.dropLast()) + #","extra":1}"#))
        XCTAssertThrowsError(try ColorCustody.parse(good.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)))
        XCTAssertThrowsError(try ColorCustody.parse(good, maxBytes: 10))
    }

    func test_withSuffixTagAddsTheTagOnce() throws {
        let custody = try ColorCustody(
            asset: .issue, derivationPrefix: "cA==", derivationSuffix: "cw==",
            senderIdentityKey: Hex.encode(identity.publicKey.compressedBytes)
        )
        XCTAssertEqual(ColorModule.withSuffixTag(nil, custody), [custody.suffixTag])
        XCTAssertEqual(ColorModule.withSuffixTag(["a", custody.suffixTag, "a"], custody), ["a", custody.suffixTag])
    }

    // MARK: - Overlay answers

    private func tokenTransaction(amount: UInt64) throws -> (Transaction, String) {
        let asset = try ColorAssetID(String(repeating: "ab", count: 32) + "_0")
        let script = try OneColor.value(tokenID: asset.description, amount: amount, lock: .publicKeyHash([UInt8](repeating: 1, count: 20))).lock()
        let transaction = Transaction(version: 1, inputs: [], outputs: [TransactionOutput(satoshis: 1, lockingScript: script)], lockTime: 0)
        return (transaction, try transaction.transactionID(limits: harnessTxLimits).displayHex)
    }

    func test_readOutputListMatchesQueriedOutpointsOnly() throws {
        let (transaction, txid) = try tokenTransaction(amount: 5)
        let beef = try graph([transaction]).serialized(limits: harnessBEEFLimits)
        let item = ColorOutputList.Item(beef: beef, outputIndex: 0)

        let listed = try ColorOverlay.readOutputList(ColorOutputList(outputs: [item]), queried: ["\(txid).0"])
        XCTAssertEqual(listed["\(txid).0"]?.satoshis, 1)

        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [item]), queried: ["\(txid).1"]))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(ColorOutputList(outputs: [item, item]), queried: ["\(txid).0"]))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: beef, outputIndex: 3)]), queried: ["\(txid).3"]
        ))
        XCTAssertThrowsError(try ColorOverlay.readOutputList(
            ColorOutputList(outputs: [.init(beef: [1, 2, 3], outputIndex: 0)]), queried: ["\(txid).0"]
        ))
    }

    func test_httpOverlaySubmitsBEEFWithTopicsAndReadsTheSteak() async throws {
        actor Seen { var request: URLRequest?; func set(_ r: URLRequest) { request = r } }
        let seen = Seen()
        let overlay = HTTPColorOverlay(
            baseURL: URL(string: "https://overlay.example.com/")!,
            lookup: { _, _, _ in ColorOutputList(outputs: []) },
            post: { request in
                await seen.set(request)
                return (200, Array(#"{"tm_color_x":{"outputsToAdmit":[0,2],"coinsToRetain":[1]},"tm_color":{"outputsToAdmit":[]}}"#.utf8))
            }
        )
        let steak = try await overlay.submit(topics: ["tm_color", "tm_color_x"], beef: [9, 9])
        XCTAssertEqual(steak["tm_color_x"], ColorAdmittance(outputsToAdmit: [0, 2], coinsToRetain: [1]))
        XCTAssertEqual(steak["tm_color"], ColorAdmittance(outputsToAdmit: []))
        let captured = await seen.request
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://overlay.example.com/submit")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Topics"), "tm_color,tm_color_x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.httpBody, Data([9, 9]))

        let failing = HTTPColorOverlay(baseURL: URL(string: "https://o.example.com")!, lookup: { _, _, _ in ColorOutputList(outputs: []) },
                                       post: { _ in (500, []) })
        do {
            _ = try await failing.submit(topics: ["tm_color"], beef: [])
            XCTFail("expected a failure")
        } catch {}
        XCTAssertThrowsError(try HTTPColorOverlay.readSteak(Array("[]".utf8)))
    }
}
