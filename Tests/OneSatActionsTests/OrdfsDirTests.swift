import BSVCore
import BSVTransaction
import XCTest
@testable import OneSatActions

/// Ports `packages/actions/test/ordfsDir.test.ts`.
final class OrdfsDirTests: XCTestCase {
    private static let licenseTxid = String(repeating: "aa", count: 32)

    private func hex(_ text: String) throws -> [UInt8] {
        try Hex.decode(text, maximumDecodedByteCount: text.utf8.count / 2)
    }

    private func outpoint(_ txid: String, _ vout: UInt32) throws -> Outpoint {
        Outpoint(transactionID: try TransactionID(displayHex: txid), outputIndex: vout)
    }

    /// The worked example from docs/plans/ordfs-formats.html.
    private func example() throws -> OrdfsDirManifest {
        OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("README.md"), isDirectory: false, ref: .sameTx(vout: 1)),
            OrdfsDirEntry(
                name: try OrdfsDir.name("LICENSE"),
                isDirectory: false,
                ref: .outpoint(try outpoint(Self.licenseTxid, 3))
            ),
            OrdfsDirEntry(name: try OrdfsDir.name("package.json"), isDirectory: false, ref: .sameTx(vout: 6)),
            OrdfsDirEntry(name: try OrdfsDir.name("src"), isDirectory: true, ref: .sameTx(vout: 11)),
        ])
    }

    private func exampleBytes() throws -> [UInt8] {
        try hex(
            "01000408074c4943454e5345\(Self.licenseTxid)030000000009524541444d452e6d6401000c7061636b6167652e6a736f6e0601037372630b"
        )
    }

    // MARK: encode

    func test_matchesTheSpecWorkedExampleByteForByte() throws {
        XCTAssertEqual(Hex.encode(try OrdfsDir.encode(example())), Hex.encode(try exampleBytes()))
    }

    func test_sortsEntriesRegardlessOfInputOrder() throws {
        var shuffled = try example()
        shuffled.entries.reverse()
        XCTAssertEqual(try OrdfsDir.encode(shuffled), try OrdfsDir.encode(example()))
    }

    func test_encodesExecAndSymlinkFlags() throws {
        let out = try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("run.sh"), isDirectory: false, exec: true, ref: .sameTx(vout: 0)),
            OrdfsDirEntry(name: try OrdfsDir.name("link"), isDirectory: false, symlink: true, ref: .sameTx(vout: 1)),
        ]))
        // Canonical order: "link" < "run.sh"; flags: symlink 0x04, exec 0x02.
        XCTAssertEqual(out[3], 0x04)
        XCTAssertEqual(out[3 + 2 + 4 + 1], 0x02)
    }

    func test_rejectsDuplicateNamesSlashesNULsOversizedNames() throws {
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("a"), isDirectory: false, ref: .sameTx(vout: 0)),
            OrdfsDirEntry(name: try OrdfsDir.name("a"), isDirectory: true, ref: .sameTx(vout: 1)),
        ]))) { XCTAssertTrue($0 is OrdfsDirFormatError) }
        XCTAssertThrowsError(try OrdfsDir.name("bad/name")) { XCTAssertTrue($0 is OrdfsDirFormatError) }
        XCTAssertThrowsError(try OrdfsDir.name("bad\0name")) { XCTAssertTrue($0 is OrdfsDirFormatError) }
        XCTAssertThrowsError(try OrdfsDir.name(String(repeating: "x", count: 256))) {
            XCTAssertTrue($0 is OrdfsDirFormatError)
        }
        XCTAssertThrowsError(try OrdfsDir.name(""))
        // Raw names bypassing the helper are validated by the encoder too.
        for bad: [UInt8] in [[], [0x61, 0x2f], [0x00], [UInt8](repeating: 0x61, count: 256)] {
            XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: [
                OrdfsDirEntry(name: bad, isDirectory: false, ref: .sameTx(vout: 0)),
            ])))
        }
    }

    func test_rejectsSameTxVoutsAbove255() throws {
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("a"), isDirectory: false, ref: .sameTx(vout: 256)),
        ]))) { XCTAssertTrue($0 is OrdfsDirFormatError) }
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(name: try OrdfsDir.name("a"), isDirectory: false, ref: .sameTx(vout: -1)),
        ])))
    }

    func test_rejectsSymlinkExecFilesUnsupportedVersionAndTooManyEntries() throws {
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: [
            OrdfsDirEntry(
                name: try OrdfsDir.name("a"),
                isDirectory: false,
                exec: true,
                symlink: true,
                ref: .sameTx(vout: 0)
            ),
        ])))
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(version: 2, entries: [])))
        let many = (0...OrdfsDir.maximumEntryCount).map {
            OrdfsDirEntry(name: Array("f\($0)".utf8), isDirectory: false, ref: .sameTx(vout: 0))
        }
        XCTAssertThrowsError(try OrdfsDir.encode(OrdfsDirManifest(entries: many))) { error in
            XCTAssertTrue((error as? OrdfsDirFormatError)?.message.contains("uint16") == true)
        }
    }

    // MARK: decode

    func test_decodesTheSpecWorkedExample() throws {
        let manifest = try OrdfsDir.decode(exampleBytes())
        XCTAssertEqual(manifest.version, OrdfsDir.version)
        XCTAssertEqual(
            manifest.entries.map { OrdfsDir.nameString($0.name) },
            ["LICENSE", "README.md", "package.json", "src"]
        )
        XCTAssertEqual(manifest.entries[0].ref, .outpoint(try outpoint(Self.licenseTxid, 3)))
        XCTAssertTrue(manifest.entries[3].isDirectory)
    }

    func test_roundTrips() throws {
        XCTAssertEqual(try OrdfsDir.decode(OrdfsDir.encode(example())), try OrdfsDir.decode(exampleBytes()))
    }

    func test_rejectsNonCanonicalUnsortedInput() throws {
        let swapped = try hex(
            "0100040009524541444d452e6d640108074c4943454e5345\(Self.licenseTxid)03000000000c7061636b6167652e6a736f6e0601037372630b"
        )
        XCTAssertThrowsError(try OrdfsDir.decode(swapped)) { XCTAssertTrue($0 is OrdfsDirFormatError) }
    }

    func test_rejectsDuplicateNamesOnDecode() throws {
        XCTAssertThrowsError(try OrdfsDir.decode([0x01, 0x00, 0x02, 0x00, 0x01, 0x61, 0x00, 0x00, 0x01, 0x61, 0x01]))
    }

    func test_rejectsReservedBitsBadVersionTrailingBytesTruncation() throws {
        let bytes = try exampleBytes()
        var reserved = bytes
        reserved[3] |= 0x10
        XCTAssertThrowsError(try OrdfsDir.decode(reserved)) { XCTAssertTrue($0 is OrdfsDirFormatError) }

        var badVersion = bytes
        badVersion[0] = 0x02
        XCTAssertThrowsError(try OrdfsDir.decode(badVersion)) { XCTAssertTrue($0 is OrdfsDirFormatError) }

        XCTAssertThrowsError(try OrdfsDir.decode(Array(bytes[0..<10]))) { XCTAssertTrue($0 is OrdfsDirFormatError) }
        for cut in 0..<bytes.count {
            XCTAssertThrowsError(try OrdfsDir.decode(Array(bytes[0..<cut])), "cut \(cut)")
        }

        XCTAssertThrowsError(try OrdfsDir.decode(bytes + [0x00])) { XCTAssertTrue($0 is OrdfsDirFormatError) }
    }

    func test_rejectsNamesWithNULOrSlashOrEmptyOnDecode() {
        XCTAssertThrowsError(try OrdfsDir.decode([0x01, 0x00, 0x01, 0x00, 0x01, 0x2f, 0x00]))
        XCTAssertThrowsError(try OrdfsDir.decode([0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]))
        XCTAssertThrowsError(try OrdfsDir.decode([0x01, 0x00, 0x01, 0x00, 0x00, 0x00]))
    }

    func test_emptyEntryListIsValid() throws {
        let empty = try OrdfsDir.encode(OrdfsDirManifest(entries: []))
        XCTAssertEqual(empty, [0x01, 0x00, 0x00])
        XCTAssertEqual(try OrdfsDir.decode(empty).entries, [])
    }

    func test_defaultEntryPrefersDotThenIndexHTML() throws {
        let index = OrdfsDirEntry(name: try OrdfsDir.name("index.html"), isDirectory: false, ref: .sameTx(vout: 1))
        let dot = OrdfsDirEntry(name: try OrdfsDir.name("."), isDirectory: false, ref: .sameTx(vout: 0))
        XCTAssertEqual(OrdfsDir.defaultEntry(OrdfsDirManifest(entries: [index, dot])).map {
            OrdfsDir.nameString($0.name)
        }, ".")
        XCTAssertEqual(OrdfsDir.defaultEntry(OrdfsDirManifest(entries: [index])).map {
            OrdfsDir.nameString($0.name)
        }, "index.html")
        XCTAssertNil(OrdfsDir.defaultEntry(OrdfsDirManifest(entries: [])))
    }

    func test_contentTypes() {
        XCTAssertEqual(OrdfsDir.contentType, "ordfs/dir")
        XCTAssertEqual(OrdfsDir.legacyJSONContentType, "ord-fs/json")
    }
}
