import BSVCore
import Foundation
import XCTest
@testable import OneSatActions

/// xdelta3 interoperability for the pure-Swift VCDIFF codec.
///
/// The committed fixtures were produced by xdelta3 3.0.11 (`-e -A -S none`, with and without
/// `-n`); the Swift goldens were checked to decode with `xdelta3 -d`. When an `xdelta3` binary is
/// on `PATH`, the live tests also run both directions; otherwise they skip.
final class VcdiffInteropTests: XCTestCase {
    // MARK: Inputs (mirrored by the fixture generator)

    /// `vcdiff.test.ts` "we decode xdelta3 -e -n -S none -A".
    static let base1 = Array("BBBB base content for testing, with enough length to hash and match".utf8)
    static let target1 = base1 + Array(" THEN SOME NEW TAIL".utf8)

    /// 300 lines with an insert, an edit, a deletion and an appended block.
    static let base2: [UInt8] = Array((0..<300).map { "line \($0) of the base\n" }.joined().utf8)
    static let target2: [UInt8] = {
        var lines = (0..<300).map { "line \($0) of the base\n" }
        lines[100] = "line 100 EDITED\n"
        lines.removeSubrange(200..<210)
        lines += Array(repeating: "NEW BLOCK\n", count: 5)
        lines.insert(String(repeating: "x", count: 40) + "\n", at: 50)
        return Array(lines.joined().utf8)
    }()

    /// Self-referential target with no source, ending in a zero run.
    static let target3: [UInt8] = Array((0..<200).map {
        String(repeating: "abcdefgh", count: $0 % 3 + 1) + "-\($0 % 7);"
    }.joined().utf8) + [UInt8](repeating: 0, count: 100)

    // MARK: xdelta3 output decoded by Swift

    /// `xdelta3 -e -n -S none -A -s base1 target1`: no checksum.
    static let xdelta1 = hex([
        "d6c3c400000143001d5600130401205448454e20534f4d45204e4557205441494c1343011300",
    ])

    /// `xdelta3 -e -S none -A -s base2 target2`: VCD_ADLER32, near/same address modes,
    /// combined opcodes.
    static let xdelta2 = hex([
        "d6c3c4000005b02e00822eaf32004481144b0952628a780a6c696e652035353135353535353936363633363636373637",
        "37373737373737383838383838383939393939393939313030204544495445444e455720424c4f434b0a13875e002808",
        "131303131343136314024313035313531323140253130362028313431402831303620273132314027313036202931343",
        "140283130223130283132314027313025313027313431402931302531302831323140283130253130273134314027313",
        "0253130293132314028313025313028313631402731302531302731323140293130253130b139012438e700b2328008f",
        "4d8765852083388378008a389019891000cd88586d00c590111d00758858cd83106d9009c5501d88587550cd90016d50",
        "c588581d50758f79cd506d8a00c5501d8f7175508f5a90490a",
    ])

    /// `xdelta3 -e -A -S none target3`: no source, VCD_ADLER32, target self-copies and a run.
    static let xdelta3 = hex([
        "d6c3c4000004709e34001630201df85e7a61626364656667682d303b312d322d333435362d33000c1819021d1c031903",
        "2202131a021a022222191a1a1a22291a021a2922291a1313631329022a2a2962293a139a39006400000a221d0a1d3843",
        "09721c362d421b5570397b1b091b382e397d720b1b1308",
    ])

    func test_decodesXdelta3WithoutChecksum() throws {
        XCTAssertEqual(Self.xdelta1[4], 0x00)
        XCTAssertEqual(try Vcdiff.decode(Self.xdelta1, source: Self.base1), Self.target1)
    }

    func test_decodesXdelta3WithAdler32AndCacheModes() throws {
        XCTAssertEqual(Self.xdelta2[5] & 0x04, 0x04)
        XCTAssertEqual(try Vcdiff.decode(Self.xdelta2, source: Self.base2), Self.target2)
    }

    func test_decodesXdelta3WithoutSource() throws {
        XCTAssertEqual(try Vcdiff.decode(Self.xdelta3), Self.target3)
    }

    func test_rejectsXdelta3WindowWithCorruptedChecksum() throws {
        var corrupt = Self.xdelta2
        // Win_Indicator, src size (2), src pos, encoding length (2), target size (2), Delta_Indicator,
        // three section lengths (1 + 2 + 1), then the four checksum bytes.
        corrupt[5 + 1 + 2 + 1 + 2 + 2 + 1 + 4] ^= 0x01
        XCTAssertThrowsError(try Vcdiff.decode(corrupt, source: Self.base2)) { error in
            XCTAssertTrue((error as? VcdiffError)?.message.contains("adler32") == true, "\(error)")
        }
    }

    // MARK: Live xdelta3, both directions

    func test_liveXdelta3DecodesSwiftDeltas() throws {
        guard let xdelta = Self.xdelta3Path() else { throw XCTSkip("xdelta3 not on PATH") }
        let cases: [(source: [UInt8], target: [UInt8])] = [
            (Self.base1, Self.target1),
            (Self.base2, Self.target2),
            ([], Self.target3),
            (Array("AAAA base content for testing, with enough length to hash".utf8),
             Array("AAAA base content for testing, with enough length to hash AND MORE APPENDED CONTENT HERE".utf8)),
            (Array("base".utf8), []),
        ]
        for (index, item) in cases.enumerated() {
            let delta = Vcdiff.encode(item.target, source: item.source)
            let decoded = try Self.run(xdelta, decode: delta, source: item.source)
            XCTAssertEqual(decoded, item.target, "case \(index)")
        }
    }

    func test_liveSwiftDecodesXdelta3Deltas() throws {
        guard let xdelta = Self.xdelta3Path() else { throw XCTSkip("xdelta3 not on PATH") }
        let base = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 31) }
        var target = base
        for i in 1000..<40_000 { target[i] = 0xab }
        target.replaceSubrange(50_000..<55_000, with: base[0..<5000])
        for checksum in [false, true] {
            let delta = try Self.run(xdelta, encode: target, source: base, checksum: checksum)
            XCTAssertEqual(delta[4], 0x00)
            XCTAssertEqual(try Vcdiff.decode(delta, source: base), target, "checksum \(checksum)")
        }
    }

    // MARK: Swift output decoded by xdelta3

    /// Swift's delta for (base2, target2); `xdelta3 -d -s base2` reproduces target2.
    static let swiftGolden2 = hex([
        "d6c3c4000001b02e003eaf3200101a0e784544495445444e455720424c4f434b13875e002813877201061308131313900b",
        "1314138e480109132900875d813d188f758143a166df2d",
    ])

    func test_swiftEncoderIsDeterministicAndXdelta3Compatible() throws {
        // For the simple append the Swift encoder writes exactly what xdelta3 -n writes.
        XCTAssertEqual(Vcdiff.encode(Self.target1, source: Self.base1), Self.xdelta1)
        XCTAssertEqual(Vcdiff.encode(Self.target2, source: Self.base2), Self.swiftGolden2)
        XCTAssertEqual(try Vcdiff.decode(Self.swiftGolden2, source: Self.base2), Self.target2)
        XCTAssertEqual(try Vcdiff.decode(Vcdiff.encode(Self.target3)), Self.target3)
    }

    // MARK: Helpers

    static func hex(_ lines: [String]) -> [UInt8] {
        let text = lines.joined()
        return (try? Hex.decode(text, maximumDecodedByteCount: text.utf8.count / 2)) ?? []
    }

    static func xdelta3Path() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/xdelta3"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func run(_ xdelta: String, decode delta: [UInt8], source: [UInt8]) throws -> [UInt8] {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deltaURL = dir.appendingPathComponent("delta")
        let outURL = dir.appendingPathComponent("out")
        try Data(delta).write(to: deltaURL)
        var arguments = ["-f", "-d"]
        if !source.isEmpty {
            let sourceURL = dir.appendingPathComponent("source")
            try Data(source).write(to: sourceURL)
            arguments += ["-s", sourceURL.path]
        }
        try execute(xdelta, arguments + [deltaURL.path, outURL.path])
        return [UInt8](try Data(contentsOf: outURL))
    }

    private static func run(
        _ xdelta: String,
        encode target: [UInt8],
        source: [UInt8],
        checksum: Bool
    ) throws -> [UInt8] {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = dir.appendingPathComponent("source")
        let targetURL = dir.appendingPathComponent("target")
        let deltaURL = dir.appendingPathComponent("delta")
        try Data(source).write(to: sourceURL)
        try Data(target).write(to: targetURL)
        var arguments = ["-f", "-e", "-A", "-S", "none"]
        if !checksum { arguments.append("-n") }
        try execute(xdelta, arguments + ["-s", sourceURL.path, targetURL.path, deltaURL.path])
        return [UInt8](try Data(contentsOf: deltaURL))
    }

    private static func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcdiff-interop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func execute(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw VcdiffError("xdelta3 exited \(process.terminationStatus)")
        }
    }
}
