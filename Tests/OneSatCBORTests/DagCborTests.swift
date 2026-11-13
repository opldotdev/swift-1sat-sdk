import XCTest
@testable import OneSatCBOR

/// Port of the `DAG-CBOR (@ipld/dag-cbor as-is)` block of `OneColor.test.ts`, plus edge cases
/// whose expected results were checked against `@ipld/dag-cbor` 10.0.2 / cborg 6.2.1.
final class DagCborTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func decode(_ hex: String, options: DagCbor.DecodeOptions = .init()) throws -> DagCborValue {
        try DagCbor.decode(bytes(hex), options: options)
    }

    private let cid = "01711220" + String(repeating: "ab", count: 32) // CIDv1, dag-cbor, sha2-256

    // MARK: - Ported from OneColor.test.ts

    func test_acceptsCanonicalForms() throws {
        XCTAssertEqual(decodeDagCbor(bytes("a0")), .map(DagCborMap()))
        XCTAssertEqual(decodeDagCbor(bytes("a2616101616202")), .map(["a": .unsigned(1), "b": .unsigned(2)]))
        XCTAssertEqual(decodeDagCbor(bytes("a2616101626161f6")), .map(["a": .unsigned(1), "aa": .null]))
        XCTAssertEqual(decodeDagCbor(bytes("fb3ff8000000000000")), .float(1.5))
        let link = try XCTUnwrap(decodeDagCbor(bytes("d82a582500" + cid))?.linkValue)
        XCTAssertEqual(hex(link.cid), cid)
        let nested = try XCTUnwrap(decodeDagCbor(bytes("a1616cd82a582500" + cid))?.mapValue)
        XCTAssertNotNil(nested["l"]?.linkValue)
    }

    func test_encodesSpecExamplesByteForByte() throws {
        XCTAssertEqual(
            hex(try DagCbor.encode(.map(["sym": .text("GOLD"), "dec": .unsigned(8)]))),
            "a263646563086373796d64474f4c44"
        )
        XCTAssertEqual(
            hex(try DagCbor.encode(.map(["sym": .text("STABLE"), "dec": .unsigned(2)]))),
            "a263646563026373796d66535441424c45"
        )
    }

    func test_rejects() {
        let bad: [(String, String)] = [
            ("duplicate keys", "a2616101616102"),
            ("non-text key", "a10101"),
            ("non-minimal int", "1801"),
            ("non-minimal length", "7801" + "61"),
            ("indefinite map", "bf616101ff"),
            ("NaN", "fb7ff8000000000000"),
            ("Infinity", "fb7ff0000000000000"),
            ("tag other than 42", "c11a00000000"),
            ("tag 42 without 0x00 prefix", "d82a5825" + "01711220" + String(repeating: "ab", count: 33)),
            ("tag 42 holding a malformed CID", "d82a4400017112"),
            ("trailing bytes", "a000"),
            ("truncated", "a161"),
        ]
        for (name, value) in bad {
            XCTAssertNil(decodeDagCbor(bytes(value)), name)
        }
    }

    // MARK: - Library behaviour (checked against the JS)

    func test_decodeAcceptsUnsortedMapKeys() throws {
        let value = try decode("a2616201616102")
        XCTAssertEqual(value, .map(["b": .unsigned(1), "a": .unsigned(2)]))
        XCTAssertEqual(value.mapValue?.keys, ["a", "b"]) // held canonically
        XCTAssertThrowsError(try decode("a2616201616102", options: .init(requireCanonicalMapOrder: true))) {
            XCTAssertEqual($0 as? DagCborError, .unorderedMapKeys)
        }
        XCTAssertNoThrow(try decode("a2616101616202", options: .init(requireCanonicalMapOrder: true)))
    }

    func test_decodeUndefinedAsNull() throws {
        XCTAssertEqual(try decode("f7"), .null)
        XCTAssertEqual(try decode("a26161016162f7"), .map(["a": .unsigned(1), "b": .null]))
        XCTAssertEqual(try decode("f4"), .bool(false))
        XCTAssertEqual(try decode("f5"), .bool(true))
    }

    func test_decodeAcceptsHalfAndSingleFloats() throws {
        XCTAssertEqual(try decode("f93e00"), .float(1.5))
        XCTAssertEqual(try decode("fa3fc00000"), .float(1.5))
        XCTAssertEqual(try decode("f93c00"), .float(1.0))
        XCTAssertEqual(try decode("f97bff"), .float(65504))
        XCTAssertEqual(try decode("f90001"), .float(0x1p-24))
        let negativeZero = try XCTUnwrap({ if case .float(let x) = try decode("f98000") { return x }; return nil }())
        XCTAssertTrue(negativeZero == 0 && negativeZero.sign == .minus)
        for value in ["f97e00", "f97c00", "f9fc00", "fa7fc00000", "fa7f800000"] {
            XCTAssertThrowsError(try decode(value), value) { XCTAssertEqual($0 as? DagCborError, .nonFiniteFloat) }
        }
    }

    func test_decodeRepairsInvalidUTF8() throws {
        XCTAssertEqual(try decode("a161ff01"), .map(["\u{FFFD}": .unsigned(1)]))
        XCTAssertEqual(try decode("62c328"), .text("\u{FFFD}("))
        XCTAssertThrowsError(try decode("a161ff01", options: .init(strictUTF8: true))) {
            XCTAssertEqual($0 as? DagCborError, .invalidUTF8)
        }
        // NFC "é" and NFD "é" are different keys in JS, so both survive.
        let map = try XCTUnwrap(try decode("a26365cc810162c3a902").mapValue)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["\u{e9}"], .unsigned(2))
        XCTAssertEqual(map["e\u{301}"], .unsigned(1))
        // Two invalid keys that both repair to U+FFFD are duplicates, as in JS.
        XCTAssertThrowsError(try decode("a261ff0161fe02")) { XCTAssertEqual($0 as? DagCborError, .duplicateMapKey) }
    }

    func test_integerBoundaries() throws {
        for value in ["1817", "3817", "5817", "7817", "9817", "b817", "190001", "1a0000ffff", "1b00000000ffffffff"] {
            XCTAssertThrowsError(try decode(value + String(repeating: "00", count: 0)), value)
        }
        XCTAssertEqual(try decode("1818"), .unsigned(24))
        XCTAssertEqual(try decode("3818"), .negative(24))
        XCTAssertEqual(try decode("3818").int64Value, -25)
        XCTAssertEqual(try decode("1bffffffffffffffff"), .unsigned(.max))
        XCTAssertEqual(try decode("3bffffffffffffffff"), .negative(.max))
        XCTAssertNil(try decode("3bffffffffffffffff").int64Value)
        XCTAssertEqual(try decode("3b7fffffffffffffff").int64Value, .min)
        XCTAssertThrowsError(try decode("d9002a582500" + cid))
    }

    func test_rejectsSimpleAndIndefinite() {
        for value in ["e0", "f3", "f800", "f8ff", "fc", "fd", "fe", "5f4101ff", "7f6161ff", "9f01ff", "ff", "1c", "5c", "dc"] {
            XCTAssertThrowsError(try decode(value), value)
        }
        XCTAssertThrowsError(try DagCbor.decode([])) { XCTAssertEqual($0 as? DagCborError, .empty) }
    }

    func test_rejectsTruncation() {
        for value in ["19", "1a0000", "41", "4201", "6261", "82", "8201", "a1", "a16161", "d8", "d82a", "5bffffffffffffffff"] {
            XCTAssertThrowsError(try decode(value), value)
        }
    }

    func test_linkValidation() throws {
        XCTAssertNotNil(try decode("d82a450001550000").linkValue) // v1, raw, identity, empty digest
        XCTAssertNotNil(try decode("d82a44001201aa").linkValue) // v0, 1-byte digest
        // An explicit version-0 prefix is accepted; multiformats then reports the bare multihash.
        XCTAssertEqual(
            try decode("d82a582500007112" + String(cid.dropFirst(6))).linkValue?.cid,
            bytes("12" + String(cid.dropFirst(6)))
        )
        for value in [
            "d82a6100", // text, not bytes
            "d82a40", // empty
            "d82a8100", // array
            "d82a4400027112", // version 2
            "d82a46008100550000", // non-minimal varint
            "d82a4500120100aa", // v0 with a trailing extra byte
            "d82a4100", // 0x00 alone
        ] {
            XCTAssertThrowsError(try decode(value), value)
        }
        XCTAssertTrue(DagCbor.isValidCID(bytes(cid)))
        XCTAssertFalse(DagCbor.isValidCID(bytes(cid + "00")))
        XCTAssertFalse(DagCbor.isValidCID([]))
    }

    // MARK: - Encoder

    func test_encoderNormalizesExplicitCIDv0AndRoundTrips() throws {
        let multihash = "1220" + String(repeating: "ab", count: 32)
        let link = DagCborValue.link(DagCborLink(cid: bytes("0071" + multihash)))
        let encoded = try DagCbor.encode(link)
        XCTAssertEqual(hex(encoded), "d82a582300" + multihash)
        let decoded = try DagCbor.decode(encoded)
        XCTAssertEqual(decoded.linkValue?.cid, bytes(multihash))
        XCTAssertEqual(try DagCbor.encode(decoded), encoded)
    }


    func test_encoderKeyOrderIsLengthFirstByUTF8Bytes() throws {
        let map: DagCborMap = ["\u{e9}": .unsigned(1), "ab": .unsigned(2), "b": .unsigned(3), "aa": .unsigned(4)]
        XCTAssertEqual(hex(try DagCbor.encode(.map(map))), "a4616203626161046261620262c3a901")
    }

    func test_encoderMinimalHeadsAndTypes() throws {
        let cases: [(DagCborValue, String)] = [
            (.unsigned(0), "00"),
            (.unsigned(23), "17"),
            (.unsigned(24), "1818"),
            (.unsigned(256), "190100"),
            (.unsigned(65536), "1a00010000"),
            (.unsigned(1 << 32), "1b0000000100000000"),
            (.unsigned(.max), "1bffffffffffffffff"),
            (.negative(0), "20"),
            (.negative(24), "3818"),
            (.float(1.5), "fb3ff8000000000000"),
            (.float(0.1), "fb3fb999999999999a"),
            (.bytes([1, 2]), "420102"),
            (.text(""), "60"),
            (.array([.unsigned(1), .text("x")]), "82016178"),
            (.bool(false), "f4"),
            (.bool(true), "f5"),
            (.null, "f6"),
            (.link(DagCborLink(cid: bytes(cid))), "d82a582500" + cid),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(hex(try DagCbor.encode(value)), expected, expected)
        }
        XCTAssertThrowsError(try DagCbor.encode(.float(.nan)))
        XCTAssertThrowsError(try DagCbor.encode(.float(-.infinity)))
        XCTAssertThrowsError(try DagCbor.encode(.link(DagCborLink(cid: [1, 2, 3]))))
    }

    func test_roundTripCanonical() throws {
        for value in [
            "a0", "a2616101616202", "a2616101626161f6", "fb3ff8000000000000",
            "d82a582500" + cid, "a1616cd82a582500" + cid,
            "a263646563086373796d64474f4c44", "a4616203626161046261620262c3a901",
            "83010203", "3bffffffffffffffff", "4489504e47",
        ] {
            XCTAssertEqual(hex(try DagCbor.encode(try decode(value))), value, value)
        }
    }

    func test_nestingLimit() throws {
        XCTAssertThrowsError(try decode(String(repeating: "81", count: 129) + "01")) {
            XCTAssertEqual($0 as? DagCborError, .nestingTooDeep)
        }
        XCTAssertNoThrow(try decode(String(repeating: "81", count: 100) + "01"))
        XCTAssertNoThrow(try decode(String(repeating: "81", count: 129) + "01", options: .init(maximumNestingDepth: 200)))
    }

    func test_mapDuplicateInitThrows() {
        XCTAssertThrowsError(try DagCborMap([(key: "a", value: .null), (key: "a", value: .null)])) {
            XCTAssertEqual($0 as? DagCborError, .duplicateMapKey)
        }
    }

    func test_majorTypes() throws {
        XCTAssertEqual(try decode("00").majorType, 0)
        XCTAssertEqual(try decode("20").majorType, 1)
        XCTAssertEqual(try decode("40").majorType, 2)
        XCTAssertEqual(try decode("60").majorType, 3)
        XCTAssertEqual(try decode("80").majorType, 4)
        XCTAssertEqual(try decode("a0").majorType, 5)
        XCTAssertEqual(try decode("d82a582500" + cid).majorType, 6)
        XCTAssertEqual(try decode("f6").majorType, 7)
    }
}
