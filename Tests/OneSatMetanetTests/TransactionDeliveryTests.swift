import XCTest
import BSVCore
import BSVCrypto
import OneSatCBOR
@testable import OneSatMetanet

/// BRC-232 against the vectors the TS tests use (BRCs PR #300), and the TS schema rejections.
final class TransactionDeliveryTests: XCTestCase {

    struct Vectors: Decodable {
        struct Fixture: Decodable {
            let name: String
            let txid: String
            let bodyCborHex: String
            let mimeHex: String
            let contentHash: String
        }
        let fixtures: [Fixture]
    }

    static func vector(_ name: String) throws -> Vectors.Fixture {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "brc232-vectors", withExtension: "json", subdirectory: "Fixtures"
        ))
        let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
        return try XCTUnwrap(vectors.fixtures.first { $0.name == name })
    }

    static func bytes(_ hex: String) throws -> [UInt8] {
        try Hex.decode(hex, maximumDecodedByteCount: 64 << 20)
    }

    func test_vectorsDecodeAndReencodeByteForByte() throws {
        for name in ["ordinary-payment", "token-value", "token-authority"] {
            let v = try Self.vector(name)
            let body = try TransactionDelivery.body(ofEntity: try Self.bytes(v.mimeHex))
            XCTAssertEqual(Hex.encode(body), v.bodyCborHex, name)
            let decoded = try TransactionDelivery.decode(body)
            XCTAssertEqual(Hex.encode(decoded.txid), v.txid, name)
            XCTAssertEqual(Hex.encode(try decoded.encoded()), v.bodyCborHex, name)
            XCTAssertEqual(Hex.encode(try decoded.mime()), v.mimeHex, name)
            XCTAssertEqual(
                Hex.encode(BSVHashing.sha256(try Self.bytes(v.mimeHex)).bytes), v.contentHash, name
            )
        }
    }

    func test_tokenValueVectorReadsAsABasketInsertion() throws {
        let v = try Self.vector("token-value")
        let decoded = try TransactionDelivery.decode(try Self.bytes(v.bodyCborHex))
        guard case let .basketInsertion(index, basket, instructions, tags) = decoded.outputs[0] else {
            return XCTFail("expected a basket insertion")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(basket, "p color ff06c6f0fc808f4945b37e9fdb9eab22cd7ff0b28be0f2661dfec58fa4dcf92cv0")
        XCTAssertTrue(instructions.hasPrefix(#"{"version":1,"assetId":"ff06"#))
        XCTAssertNil(tags)
    }

    // MARK: - Schema

    private func base() throws -> DagCborMap {
        let v = try Self.vector("token-value")
        guard case .map(let map) = try DagCbor.decode(try Self.bytes(v.bodyCborHex)) else {
            throw XCTSkip("not a map")
        }
        return map
    }

    private func replacing(_ map: DagCborMap, _ key: String, with value: DagCborValue?) throws -> [UInt8] {
        var entries = map.entries.filter { $0.key != key }
        if let value { entries.append((key, value)) }
        return try DagCbor.encode(.map(try DagCborMap(entries)))
    }

    private func reject(_ body: [UInt8], _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TransactionDelivery.decode(body), file: file, line: line) { error in
            XCTAssertTrue(
                (error as? MetanetError)?.errorDescription?.contains(message) == true,
                "\(error) does not say \(message)", file: file, line: line
            )
        }
    }

    func test_unknownTopLevelMembersFail() throws {
        reject(try replacing(try base(), "extra", with: .unsigned(1)),
               "BRC-232: the body has an unknown member extra")
    }

    func test_requiredMembersAreTyped() throws {
        let map = try base()
        reject(try replacing(map, "version", with: .unsigned(2)), "BRC-232: version must be 1")
        reject(try replacing(map, "txid", with: .bytes([UInt8](repeating: 0, count: 31))),
               "BRC-232: txid must be a byte string of 32 bytes")
        reject(try replacing(map, "outputs", with: .array([])),
               "BRC-232: outputs must be a nonempty array")
        reject(try replacing(map, "lifecycles", with: nil), "BRC-232: the body lacks lifecycles")
    }

    func test_outputsStrictlyIncrease() throws {
        let map = try base()
        let output = try XCTUnwrap(map["outputs"]?.arrayValue?.first)
        reject(try replacing(map, "outputs", with: .array([output, output])),
               "BRC-232: outputs must be strictly increasing by outputIndex")
    }

    func test_outputEntriesHaveNoOtherMembers() throws {
        let map = try base()
        let output = try XCTUnwrap(map["outputs"]?.arrayValue?.first?.mapValue)
        let extended = try DagCborMap(output.entries + [("keyID", .text("x"))])
        reject(try replacing(map, "outputs", with: .array([.map(extended)])),
               "BRC-232: outputs[0] has an unknown member keyID")
    }

    func test_memoIsAtMost2000Bytes() throws {
        let map = try base()
        reject(try replacing(map, "memo", with: .text(String(repeating: "é", count: 1001))),
               "BRC-232: memo exceeds 2000 UTF-8 bytes")
        let accepted = try TransactionDelivery.decode(
            try replacing(map, "memo", with: .text(String(repeating: "é", count: 1000)))
        )
        XCTAssertEqual(accepted.memo?.count, 1000)
    }

    func test_encodingRefusesWhatDecodingRefuses() throws {
        let delivery = TransactionDelivery(
            txid: [UInt8](repeating: 1, count: 32), beef: [1],
            outputs: [
                .basketInsertion(outputIndex: 1, basket: "b", customInstructions: "c", tags: nil),
                .basketInsertion(outputIndex: 0, basket: "b", customInstructions: "c", tags: nil),
            ]
        )
        XCTAssertThrowsError(try delivery.encoded())
    }

    func test_mimeHeadersAreStrict() throws {
        let v = try Self.vector("token-value")
        let body = try Self.bytes(v.bodyCborHex)
        func mime(_ head: String) -> [UInt8] { Array(head.utf8) + body }
        let ct = "Content-Type: application/vnd.metanet.transaction+cbor\r\n"
        let te = "Content-Transfer-Encoding: binary\r\n"
        XCTAssertEqual(try TransactionDelivery.body(ofEntity: mime("\(ct)\(te)\r\n")), body)
        XCTAssertEqual(try TransactionDelivery.body(ofEntity: mime("content-type:application/vnd.metanet.transaction+cbor \r\n\(te)\r\n")), body)
        func rejects(_ head: String, _ message: String) {
            XCTAssertThrowsError(try TransactionDelivery.body(ofEntity: mime(head))) { error in
                XCTAssertTrue((error as? MetanetError)?.errorDescription?.contains(message) == true,
                              "\(error)")
            }
        }
        rejects("\(ct)\(ct)\(te)\r\n", "BRC-232: duplicate MIME header")
        rejects("\(ct)\(te) folded\r\n\r\n", "BRC-232: malformed MIME header")
        rejects("Content-Type: application/vnd.metanet.transaction+cbor; x=1\r\n\(te)\r\n",
                "with no parameters")
        rejects("\(ct)Content-Transfer-Encoding: base64\r\n\r\n", "must be binary")
        rejects(String(repeating: "X", count: 9000), "no MIME header block")
    }
}
