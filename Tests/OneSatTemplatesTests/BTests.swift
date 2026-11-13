import BSVScript
import XCTest
@testable import OneSatTemplates

final class BTests: XCTestCase {
    func test_lockWritesPrefixDataMediaTypeEncoding() throws {
        let script = try BTemplate.lock(Array("hi".utf8), mediaType: "text/plain", encoding: .binary)
        var expected: [UInt8] = [0x6a, 0x22]
        expected += Array(BTemplate.prefix.utf8)
        expected += [0x02]
        expected += Array("hi".utf8)
        expected += [0x0a]
        expected += Array("text/plain".utf8)
        expected += [0x06]
        expected += Array("binary".utf8)
        XCTAssertEqual(script.bytes, expected)
    }

    func test_roundTripsWithFilename() throws {
        let script = try BTemplate.lock([0x00, 0xff], mediaType: "image/png", encoding: .binary, filename: "a.png")
        XCTAssertEqual(
            BTemplate.decode(script),
            BData(data: [0x00, 0xff], mediaType: "image/png", encoding: "binary", filename: "a.png")
        )
    }

    func test_emptyDataIsAnOpZeroAndDecodesEmpty() throws {
        let script = try BTemplate.lock([], mediaType: "text/plain")
        XCTAssertEqual(script.bytes[36], Opcode.zero.rawValue)
        XCTAssertEqual(BTemplate.decode(script)?.data, [])
        XCTAssertEqual(BTemplate.decode(script)?.encoding, "utf-8")
    }

    func test_decodeRequiresTheBPrefixAndThreeFields() throws {
        XCTAssertNil(BTemplate.decode(try MAPTemplate.set([("app", "x")])))
        let short = try BitCom.lock(protocols: [
            BitComProtocolEntry(protocol: BTemplate.prefix, script: [0x01, 0x61, 0x01, 0x62]),
        ])
        XCTAssertNil(BTemplate.decode(short))
    }
}
