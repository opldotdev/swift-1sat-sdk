import BSVCore
import BSVTransaction
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/ordfsPatch.test.ts`.
final class OrdfsPatchTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func base() throws -> Outpoint {
        Outpoint(
            transactionID: try TransactionID(displayHex: String(repeating: "ab", count: 32)),
            outputIndex: 7
        )
    }

    func test_roundTripsVersionOutpointDelta() throws {
        let encoded = try OrdfsPatch.fromContent(
            base: base(),
            source: bytes("hello world, this is the base file"),
            target: bytes("hello world, this is the base file PLUS")
        )
        XCTAssertEqual(Int(encoded[0]), OrdfsPatch.version)
        let record = try OrdfsPatch.decode(encoded)
        XCTAssertEqual(record.base, try base())
        XCTAssertEqual(record.delta[0], 0xd6)
        XCTAssertEqual(record.delta[4], 0x00)
        XCTAssertEqual(Hex.encode(try OrdfsPatch.encode(record)), Hex.encode(encoded))
    }

    func test_appliesAgainstSourceBytes() throws {
        let source = bytes("the quick brown fox")
        let target = bytes("the quick brown fox jumps")
        let record = try OrdfsPatch.decode(OrdfsPatch.fromContent(base: base(), source: source, target: target))
        XCTAssertEqual(try OrdfsPatch.apply(record, source: source), target)
    }

    func test_refusesIdenticalContent() throws {
        let body = bytes("same")
        XCTAssertThrowsError(try OrdfsPatch.fromContent(base: base(), source: body, target: body)) {
            XCTAssertTrue($0 is OrdfsPatchFormatError)
        }
    }

    func test_rejectsEmptyDeltaAndBadVersion() throws {
        XCTAssertThrowsError(try OrdfsPatch.encode(OrdfsPatchRecord(base: base(), delta: []))) {
            XCTAssertTrue($0 is OrdfsPatchFormatError)
        }
        XCTAssertThrowsError(try OrdfsPatch.decode([UInt8](repeating: 0, count: 40))) {
            XCTAssertTrue($0 is OrdfsPatchFormatError)
        }
        XCTAssertThrowsError(try OrdfsPatch.decode([UInt8](repeating: 0, count: 37))) {
            XCTAssertTrue($0 is OrdfsPatchFormatError)
        }
        XCTAssertThrowsError(try OrdfsPatch.encode(OrdfsPatchRecord(
            version: 1,
            base: base(),
            delta: Vcdiff.magic + [0x00]
        )))
        var badVersion = [UInt8](repeating: 0, count: OrdfsPatch.minimumByteCount)
        badVersion[0] = 0x01
        XCTAssertThrowsError(try OrdfsPatch.decode(badVersion))
    }

    func test_encodeRejectsNonPlainVcdiffHeaders() throws {
        var delta = Vcdiff.magic + [0x00]
        delta[4] = 0x04
        XCTAssertThrowsError(try OrdfsPatch.encode(OrdfsPatchRecord(base: base(), delta: delta))) { error in
            XCTAssertTrue((error as? OrdfsPatchFormatError)?.message.contains("Hdr_Indicator") == true)
        }
    }

    func test_applyMapsVcdiffErrors() throws {
        let source = bytes("the quick brown fox")
        let record = try OrdfsPatch.decode(
            OrdfsPatch.fromContent(base: base(), source: source, target: bytes("the quick brown fox jumps"))
        )
        XCTAssertThrowsError(try OrdfsPatch.apply(record, source: Array(source.prefix(3)))) {
            XCTAssertTrue($0 is OrdfsPatchFormatError)
        }
    }

    func test_minimumPatchIsAHeaderOnlyDelta() throws {
        let bytes = [UInt8(0)] + (try base()).wireBytes + Vcdiff.magic + [0x00]
        XCTAssertEqual(bytes.count, OrdfsPatch.minimumByteCount)
        let record = try OrdfsPatch.decode(bytes)
        XCTAssertEqual(try OrdfsPatch.apply(record, source: Array("ignored".utf8)), [])
    }

    func test_contentType() {
        XCTAssertEqual(OrdfsPatch.contentType, "ordfs/patch")
    }
}
