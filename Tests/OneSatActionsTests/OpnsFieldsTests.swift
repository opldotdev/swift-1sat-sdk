import BSVCore
import BSVKeys
import OneSatCBOR
import XCTest
@testable import OneSatActions

/// `packages/utils/test/fields.test.ts`. CBOR hex is `@ipld/dag-cbor` 10.0.2 `encode` output.
final class OpnsFieldsTests: XCTestCase {
    private let avatar = (0..<36).map { UInt8($0) }

    /// `encode({ domain: '1sat.name' })`.
    private static let domainOnlyHex = "a166646f6d61696e69317361742e6e616d65"
    /// `encode({ domain: '1sat.name', name: 'Alice', avatar: [0…35] })`.
    private static let allMembersHex =
        "a3646e616d6565416c696365666176617461725824000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222366646f6d61696e69317361742e6e616d65"

    func test_roundTripWithAllMembers() throws {
        let profile = OpnsFields.Profile(domain: "1sat.name", name: "Alice", avatar: avatar)
        let bytes = try OpnsFields.encodeProfile(profile)
        XCTAssertEqual(Hex.encode(bytes), Self.allMembersHex)
        XCTAssertEqual(try OpnsFields.decodeProfile(bytes), profile)
        let map = try XCTUnwrap(DagCbor.decode(bytes).mapValue)
        XCTAssertEqual(map[OpnsFields.ProfileKey.domain], .text("1sat.name"))
        XCTAssertEqual(map[OpnsFields.ProfileKey.name], .text("Alice"))
        XCTAssertEqual(map[OpnsFields.ProfileKey.avatar]?.bytesValue?.count, 36)
    }

    func test_absentOptionalsHaveNoKeysInTheMap() throws {
        let bytes = try OpnsFields.encodeProfile(OpnsFields.Profile(domain: "1sat.name", name: ""))
        XCTAssertEqual(Hex.encode(bytes), Self.domainOnlyHex)
        XCTAssertEqual(try DagCbor.decode(bytes).mapValue?.keys, [OpnsFields.ProfileKey.domain])
        XCTAssertEqual(try OpnsFields.decodeProfile(bytes), OpnsFields.Profile(domain: "1sat.name"))
        XCTAssertEqual(
            try OpnsFields.encodeProfile(OpnsFields.Profile(domain: "1sat.name", avatar: [])),
            bytes
        )
    }

    func test_encodingIsDeterministic() throws {
        let bytes = try OpnsFields.encodeProfile(OpnsFields.Profile(domain: "x.io", name: "A", avatar: avatar))
        XCTAssertEqual(
            Hex.encode(bytes),
            "a3646e616d656141666176617461725824000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f2021222366646f6d61696e64782e696f"
        )
    }

    func test_valuesAreWrittenAsGivenAndDomainIsRequired() throws {
        let odd = OpnsFields.Profile(domain: " Example.COM/x ", name: "  Spaced  ")
        let bytes = try OpnsFields.encodeProfile(odd)
        XCTAssertEqual(
            Hex.encode(bytes),
            "a2646e616d656a2020537061636564202066646f6d61696e6f204578616d706c652e434f4d2f7820"
        )
        XCTAssertEqual(try OpnsFields.decodeProfile(bytes), odd)
        assertThrows(.profileDomainRequired, "domain") {
            try OpnsFields.encodeProfile(OpnsFields.Profile(domain: ""))
        }
        // { name: 'x' }, { domain: 7 }, { domain: 'x', name: 1 }
        assertThrows(.profileMissingDomain, "domain") { try OpnsFields.decodeProfile(Self.bytes("a1646e616d656178")) }
        assertThrows(.profileMissingDomain, "domain") { try OpnsFields.decodeProfile(Self.bytes("a166646f6d61696e07")) }
        assertThrows(.profileNameNotString, "name") {
            try OpnsFields.decodeProfile(Self.bytes("a2646e616d650166646f6d61696e6178"))
        }
    }

    func test_avatarMustBe36Bytes() throws {
        assertThrows(.profileAvatarNotOutpoint, "36") {
            try OpnsFields.encodeProfile(OpnsFields.Profile(domain: "x.io", avatar: [1, 2]))
        }
        // { domain: 'x.io', avatar: new Uint8Array(3) }
        assertThrows(.profileAvatarNot36Bytes, "36") {
            try OpnsFields.decodeProfile(Self.bytes("a2666176617461724300000066646f6d61696e64782e696f"))
        }
    }

    func test_unknownMembersAreIgnoredAndNonMapsRejected() throws {
        // { domain: 'x.io', future: 1 }
        XCTAssertEqual(
            try OpnsFields.decodeProfile(Self.bytes("a266646f6d61696e64782e696f6666757475726501")),
            OpnsFields.Profile(domain: "x.io")
        )
        // [1, 2]
        assertThrows(.profileNotAMap, "map") { try OpnsFields.decodeProfile(Self.bytes("820102")) }
        assertThrows(.profileNotAMap, "map") { try OpnsFields.decodeProfile(Self.bytes("f6")) }
        // A byte string is a JS object, so it reaches the domain check.
        assertThrows(.profileMissingDomain, "domain") { try OpnsFields.decodeProfile(Self.bytes("43010203")) }
    }

    func test_isIdentityKeyAcceptsCompressedKeysOnly() throws {
        let key = try PrivateKey(Hex.decode(String(repeating: "00", count: 31) + "2a", maximumDecodedByteCount: 32))
            .publicKey
        XCTAssertTrue(OpnsFields.isIdentityKey(key.compressedBytes))
        XCTAssertFalse(OpnsFields.isIdentityKey(key.serialized(as: .uncompressed)))
        XCTAssertFalse(OpnsFields.isIdentityKey([1, 2, 3]))
    }

    func test_fieldPairsSplitsAndRejectsOddCounts() throws {
        let pairs = try OpnsFields.fieldPairs([Array("a".utf8), [1], Array("b".utf8), [2, 3]])
        XCTAssertEqual(pairs.map(\.key), ["a", "b"])
        XCTAssertEqual(pairs.map(\.value), [[1], [2, 3]])
        XCTAssertTrue(try OpnsFields.fieldPairs([]).isEmpty)
        assertThrows(.fieldsNotPairs, "pairs") { try OpnsFields.fieldPairs([Array("dangling".utf8)]) }
    }

    func test_publishFieldsNeedOneIdentityAndAtMostOneProfile() throws {
        let identity = try ActionVectors.identity().publicKey.compressedBytes
        let profile = try OpnsFields.encodeProfile(OpnsFields.Profile(domain: "1sat.name"))
        let id = Array(OpnsFields.identityField.utf8)
        let pr = Array(OpnsFields.profileField.utf8)
        XCTAssertNoThrow(try OpnsFields.assertPublishFields([id, identity, pr, profile]))
        XCTAssertNoThrow(try OpnsFields.assertPublishFields([id, identity, Array("future".utf8), [1]]))
        assertThrows(.publishFieldCount, "identity") { try OpnsFields.assertPublishFields([pr, profile]) }
        assertThrows(.publishFieldCount, "identity") {
            try OpnsFields.assertPublishFields([id, identity, id, identity])
        }
        assertThrows(.publishFieldCount, "profile") {
            try OpnsFields.assertPublishFields([id, identity, pr, profile, pr, profile])
        }
        assertThrows(.identityNotCompressedKey, "compressed") {
            try OpnsFields.assertPublishFields([id, Array(identity.dropFirst())])
        }
        // Pre-#83 positional draft: [identity key] once the signature is popped.
        assertThrows(.fieldsNotPairs, "key/value pairs") { try OpnsFields.assertPublishFields([identity]) }
    }

    func test_outpointWireIsReversedTxidAndLittleEndianVout() throws {
        let wire = try OpnsFields.outpointWire(String(repeating: "ef", count: 32) + "_1")
        XCTAssertEqual(wire, [UInt8](repeating: 0xef, count: 32) + [1, 0, 0, 0])
        let dotted = try OpnsFields.outpointWire("00" + String(repeating: "11", count: 30) + "ff.258")
        XCTAssertEqual(dotted.first, 0xff)
        XCTAssertEqual(dotted[31], 0x00)
        XCTAssertEqual(Array(dotted[32...]), [2, 1, 0, 0])
        for bad in ["xyz", String(repeating: "ef", count: 32) + ":1", String(repeating: "ef", count: 32) + "_x"] {
            XCTAssertThrowsError(try OpnsFields.outpointWire(bad)) { error in
                XCTAssertEqual(error as? OpnsFieldError, .invalidOutpoint(bad))
            }
        }
    }

    private static func bytes(_ hex: String) throws -> [UInt8] {
        try Hex.decode(hex, maximumDecodedByteCount: hex.count / 2)
    }

    private func assertThrows<T>(
        _ expected: OpnsFieldError,
        _ fragment: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> T
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? OpnsFieldError, expected, file: file, line: line)
            XCTAssertTrue(
                expected.wireMessage.contains(fragment),
                "\(expected.wireMessage) mentions \(fragment)",
                file: file,
                line: line
            )
        }
    }
}
