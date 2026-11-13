import BSVCore
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/vcdiff.test.ts` and adds strict-decode cases for the pure-Swift
/// codec that the wasm wrapper delegated to xdelta3.
final class VcdiffTests: XCTestCase {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: Round trips (vcdiff.test.ts "vcdiff roundtrip")

    func test_appendDeltaIsSmallAndRoundTrips() throws {
        let base = bytes("hello world, this is the base file with some content")
        let target = bytes("hello world, this is the base file with some content AND AN APPEND")
        let delta = Vcdiff.encode(target, source: base)
        XCTAssertEqual(delta[0], 0xd6)
        XCTAssertEqual(delta[3], 0x00)
        XCTAssertEqual(delta[4], 0x00)
        XCTAssertLessThan(delta.count, target.count)
        XCTAssertEqual(try Vcdiff.decode(delta, source: base), target)
    }

    func test_editInTheMiddle() throws {
        let parts = (0..<500).map { "line \($0) of the base\n" }
        let base = bytes(parts.joined())
        var edited = parts
        edited[250] = "line 250 of the BASE, EDITED\n"
        let target = bytes(edited.joined())
        let delta = Vcdiff.encode(target, source: base)
        XCTAssertLessThan(delta.count, target.count / 4)
        XCTAssertEqual(try Vcdiff.decode(delta, source: base), target)
    }

    func test_fromScratchWithoutDictionary() throws {
        let target = bytes(String(repeating: "fresh file with no base", count: 10))
        let delta = Vcdiff.encode(target)
        XCTAssertEqual(try Vcdiff.decode(delta), target)
    }

    func test_emptyTarget() throws {
        let delta = Vcdiff.encode([], source: bytes("base"))
        XCTAssertEqual(try Vcdiff.decode(delta, source: bytes("base")), [])
    }

    func test_binaryDataWithLongRunsAndRepeatedBlocks() throws {
        let base = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 31) }
        var target = base
        for i in 1000..<40_000 { target[i] = 0xab }
        target.replaceSubrange(50_000..<55_000, with: base[0..<5000])
        let delta = Vcdiff.encode(target, source: base)
        XCTAssertLessThan(delta.count, base.count / 4)
        XCTAssertEqual(try Vcdiff.decode(delta, source: base), target)
    }

    func test_multiWindowTargetRoundTrips() throws {
        var state: UInt32 = 0x1234_5678
        let base = (0..<(Vcdiff.encoderWindowByteCount / 4)).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var target: [UInt8] = []
        while target.count <= Vcdiff.encoderWindowByteCount {
            target += base
            target += bytes("seam \(target.count)")
        }
        let delta = Vcdiff.encode(target, source: base)
        XCTAssertLessThan(delta.count, target.count / 100)
        XCTAssertEqual(try Vcdiff.decode(delta, source: base), target)
    }

    func test_encoderWritesWholeSourceSegment() {
        let delta = Vcdiff.encode(bytes("abcdefghij0123456789"), source: bytes("0123456789abcdefghij"))
        // [header][Win_Indicator VCD_SOURCE][src 20][pos 0]...
        XCTAssertEqual(Array(delta[0..<8]), [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x01, 20, 0])
    }

    // MARK: Strict decode (vcdiff.test.ts "vcdiff strict decode")

    func test_rejectsBadMagic() {
        XCTAssertThrowsError(try Vcdiff.decode(bytes("not a delta!!"))) { error in
            XCTAssertTrue(error is VcdiffError)
        }
    }

    func test_rejectsNonZeroVersionByte() throws {
        let base = bytes("AAAA base content for testing")
        var bad = Vcdiff.encode(bytes("AAAA base content for testing PLUS"), source: base)
        bad[3] = 0x53
        XCTAssertThrowsError(try Vcdiff.decode(bad, source: base)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("version") == true, "\(error)")
        }
    }

    func test_rejectsNonZeroHdrIndicator() throws {
        let base = bytes("AAAA base content for testing")
        var bad = Vcdiff.encode(bytes("AAAA base content for testing PLUS"), source: base)
        bad[4] = 0x01
        XCTAssertThrowsError(try Vcdiff.decode(bad, source: base)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("Hdr_Indicator") == true, "\(error)")
        }
    }

    func test_rejectsTruncatedSections() throws {
        XCTAssertThrowsError(try Vcdiff.decode([0xd6, 0xc3, 0xc4, 0x00], source: bytes("x")))
        let base = bytes("AAAA base content for testing")
        let delta = Vcdiff.encode(bytes("AAAA base content for testing PLUS"), source: base)
        for cut in 6..<delta.count {
            XCTAssertThrowsError(try Vcdiff.decode(Array(delta[0..<cut]), source: base), "cut \(cut)")
        }
    }

    // MARK: Further strictness

    func test_headerWithoutWindowsDecodesToEmpty() throws {
        XCTAssertEqual(try Vcdiff.decode([0xd6, 0xc3, 0xc4, 0x00, 0x00]), [])
    }

    func test_rejectsTrailingBytesAndUnknownWindowBits() throws {
        let base = bytes("AAAA base content for testing")
        let delta = Vcdiff.encode(bytes("AAAA base content for testing PLUS"), source: base)
        XCTAssertThrowsError(try Vcdiff.decode(delta + [0x00], source: base))
        var unknown = delta
        unknown[5] = 0x09
        XCTAssertThrowsError(try Vcdiff.decode(unknown, source: base))
    }

    func test_rejectsVcdTargetWindows() {
        // VCD_TARGET, segment 1 at 0, then an empty encoding.
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x02, 0x01, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try Vcdiff.decode(delta)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("VCD_TARGET") == true, "\(error)")
        }
    }

    func test_rejectsNonZeroDeltaIndicator() {
        // No source; target 0; Delta_Indicator 1.
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0x00, 0x00, 0x00]
        XCTAssertThrowsError(try Vcdiff.decode(delta)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("Delta_Indicator") == true, "\(error)")
        }
    }

    func test_rejectsSourceSegmentOutsideSource() throws {
        let base = bytes("AAAA base content for testing")
        let delta = Vcdiff.encode(bytes("AAAA base content for testing PLUS"), source: base)
        XCTAssertThrowsError(try Vcdiff.decode(delta, source: Array(base.dropLast())))
    }

    func test_rejectsCopyAddressAtOrBeyondHere() {
        // No source; target 4; data 0; one COPY size 4 mode 0 (index 20) from address 0 == here.
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00, 0x07, 0x04, 0x00, 0x00, 0x01, 0x01, 20, 0x00]
        XCTAssertThrowsError(try Vcdiff.decode(delta))
    }

    func test_rejectsInstructionsThatOverrunTheTargetWindow() {
        // No source; target 2; ADD 3 (index 4) with 3 data bytes.
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00, 0x09, 0x02, 0x00, 0x03, 0x01, 0x00, 0x61, 0x62, 0x63, 4]
        XCTAssertThrowsError(try Vcdiff.decode(delta))
    }

    func test_rejectsShortWindowOutput() {
        // No source; target 4; ADD 3 (index 4).
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00, 0x09, 0x04, 0x00, 0x03, 0x01, 0x00, 0x61, 0x62, 0x63, 4]
        XCTAssertThrowsError(try Vcdiff.decode(delta))
    }

    func test_rejectsTargetWindowsAboveTheOutputCap() {
        var delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00]
        var body: [UInt8] = []
        Vcdiff.appendSize(Vcdiff.maximumOutputByteCount + 1, to: &body)
        body += [0x00, 0x00, 0x00, 0x00]
        Vcdiff.appendSize(body.count, to: &delta)
        delta += body
        XCTAssertThrowsError(try Vcdiff.decode(delta)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("exceeds") == true, "\(error)")
        }
    }

    func test_overlappingSelfCopyActsAsARun() throws {
        // No source; target 6; ADD 1 "z" (index 2), COPY size 5 via explicit size (index 19) from 0.
        let delta: [UInt8] = [0xd6, 0xc3, 0xc4, 0x00, 0x00, 0x00, 0x0a, 0x06, 0x00, 0x01, 0x03, 0x01, 0x7a, 2, 19, 5, 0x00]
        XCTAssertEqual(try Vcdiff.decode(delta), Array("zzzzzz".utf8))
    }

    func test_adler32MatchesKnownValues() {
        XCTAssertEqual(Vcdiff.adler32([UInt8]()), 1)
        XCTAssertEqual(Vcdiff.adler32(Array("Wikipedia".utf8)), 0x11e6_0398)
        let big = [UInt8](repeating: 0xff, count: 100_000)
        var a: UInt64 = 1
        var b: UInt64 = 0
        for byte in big {
            a = (a + UInt64(byte)) % 65521
            b = (b + a) % 65521
        }
        XCTAssertEqual(Vcdiff.adler32(big), UInt32(b << 16 | a))
    }
}
