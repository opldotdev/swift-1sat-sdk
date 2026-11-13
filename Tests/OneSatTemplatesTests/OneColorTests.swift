import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import Foundation
import OneSatCBOR
import XCTest
@testable import OneSatTemplates

/// Port of `@1sat/templates` `src/1color/OneColor.test.ts`. Hex literals are copied verbatim.
final class OneColorTests: XCTestCase {
    private let p2pkhHex = "76a914" + String(repeating: "ab", count: 20) + "88ac"
    private let txid = String(repeating: "01", count: 31) + "ff" // display order
    private var id0: String { txid + "_0" }
    private var id3: String { txid + "_3" }
    private var id0Bytes: [UInt8] { (try? Hex.decode(txid, maximumDecodedByteCount: 32))?.reversed() ?? [] }
    private var id3Bytes: [UInt8] { id0Bytes + [3, 0, 0, 0] }

    private func script(_ hex: String) throws -> Script {
        try TemplateScript.script(hex: hex)
    }

    private func hex(_ bytes: [UInt8]) -> String { Hex.encode(bytes) }

    private var p2pkh: OneColorLock {
        get throws { .script(try script(p2pkhHex)) }
    }

    // MARK: - Token ids

    func test_idWithVoutZeroIs32BytesNaturalOrder() throws {
        XCTAssertEqual(hex(try OneColor.idFromString(id0)), hex(id0Bytes))
        XCTAssertEqual(try OneColor.idToString(id0Bytes), id0)
    }

    func test_idWithNonZeroVoutIs36BytesLittleEndian() throws {
        XCTAssertEqual(hex(try OneColor.idFromString(id3)), hex(id3Bytes))
        XCTAssertEqual(try OneColor.idToString(id3Bytes), id3)
        let big = txid + "_4294967295"
        XCTAssertEqual(try OneColor.idToString(try OneColor.idFromString(big)), big)
    }

    func test_idRejectsVoutZero36BytesBadLengthsAndStrings() {
        XCTAssertThrowsError(try OneColor.idToString(id0Bytes + [0, 0, 0, 0]))
        XCTAssertThrowsError(try OneColor.idToString(Array(id0Bytes.dropFirst())))
        XCTAssertThrowsError(try OneColor.idFromString(txid))
        XCTAssertThrowsError(try OneColor.idFromString(txid + "_4294967296"))
    }

    func test_idFromStringAcceptsOnlyCanonicalForm() {
        for id in [
            txid + ".0",
            txid + ".3",
            txid.uppercased() + "_0",
            txid + "_03",
            txid + "_",
            txid + "v0",
            // Swift-only extras: sign and non-ASCII digits must not slip through.
            txid + "_+3",
            txid + "_٣",
        ] {
            XCTAssertThrowsError(try OneColor.idFromString(id), id)
        }
    }

    // MARK: - Lock / decode round trips

    func test_lockDecodeRoundTrips() throws {
        let lock = try p2pkh
        let cases: [(String, OneColor, OneColorRole, String?, UInt64)] = [
            ("deploy value", try OneColor.deployValue(amount: 21_000_000, lock: lock), .deploy, nil, 21_000_000),
            ("deploy authority", try OneColor.deployAuthority(lock: lock), .deploy, nil, 0),
            ("deploy(nil)", try OneColor.deploy(amount: nil, lock: lock), .deploy, nil, 0),
            ("value 32-byte id", try OneColor.value(tokenID: id0, amount: 5000, lock: lock), .value, id0, 5000),
            ("value 36-byte id", try OneColor.value(tokenID: id3, amount: 5000, lock: lock), .value, id3, 5000),
            ("authority 32-byte id", try OneColor.authority(tokenID: id0, lock: lock), .authority, id0, 0),
            ("authority 36-byte id", try OneColor.authority(tokenID: id3, lock: lock), .authority, id3, 0),
            ("value from id bytes", try OneColor.value(idBytes: id3Bytes, amount: 7, lock: lock), .value, id3, 7),
        ]
        for (name, token, role, id, amount) in cases {
            XCTAssertEqual(token.role, role, name)
            XCTAssertEqual(token.tokenID, id, name)
            let decoded = try XCTUnwrap(OneColor.decode(try token.lock()), name)
            XCTAssertEqual(decoded.role, role, name)
            XCTAssertEqual(decoded.tokenID, id, name)
            XCTAssertEqual(decoded.amount, amount, name)
            XCTAssertNil(decoded.payload, name)
            XCTAssertEqual(decoded.lock.hex, p2pkhHex, name)
            if let id {
                XCTAssertEqual(decoded.idBytes?.count, id.hasSuffix("_0") ? 32 : 36, name)
            }
        }
    }

    func test_writesExactPrefixBytes() throws {
        XCTAssertEqual(try OneColor.deployAuthority(lock: try p2pkh).lock().hex, "00006d" + p2pkhHex)
        XCTAssertEqual(
            try OneColor.value(tokenID: id0, amount: 5000, lock: try p2pkh).lock().hex,
            "20" + hex(id0Bytes) + "0288136d" + p2pkhHex
        )
        XCTAssertEqual(
            try OneColor.authority(tokenID: id3, lock: try p2pkh).lock().hex,
            "24" + hex(id3Bytes) + "006d" + p2pkhHex
        )
    }

    func test_buildsP2PKHFromAddressOrPublicKeyHash() throws {
        // TS uses a random key; any valid address exercises the same path.
        let key = try PrivateKey([UInt8](repeating: 0, count: 31) + [7])
        let address = Address(publicKey: key.publicKey, network: .mainnet)
        let expected = try Script.payToPublicKeyHash(address, maximumByteCount: 1_000).hex
        XCTAssertEqual(
            try OneColor.value(tokenID: id0, amount: 1, lock: .address(address.description)).inner.hex,
            expected
        )
        XCTAssertEqual(
            try OneColor.value(tokenID: id0, amount: 1, lock: .publicKeyHash(address.publicKeyHash.bytes)).inner.hex,
            expected
        )
        XCTAssertThrowsError(try OneColor.value(tokenID: id0, amount: 1, lock: .publicKeyHash([1, 2, 3])))
    }

    func test_acceptsAnyInnerScriptIncludingEmpty() throws {
        let inner = try script("51") // OP_TRUE
        XCTAssertEqual(
            OneColor.decode(try OneColor.value(tokenID: id0, amount: 2, lock: .script(inner)).lock())?.lock.hex,
            "51"
        )
        let empty = OneColor.decode(
            try OneColor.value(tokenID: id0, amount: 2, lock: .script(try TemplateScript.empty())).lock()
        )
        XCTAssertEqual(empty?.lock.hex, "")
    }

    func test_builderRejectsInvalidAmountsAndIDs() throws {
        XCTAssertThrowsError(try OneColor.value(tokenID: id0, amount: 0, lock: try p2pkh))
        // TS also rejects -1n and 2^64; with UInt64 amounts those are unrepresentable.
        XCTAssertThrowsError(try OneColor.deployValue(amount: 0, lock: try p2pkh))
        XCTAssertThrowsError(try OneColor.authority(idBytes: id0Bytes + [0, 0, 0, 0], lock: try p2pkh)) {
            XCTAssertEqual($0 as? OneColorError, .nonCanonicalTokenID)
        }
    }

    // MARK: - Amounts

    func test_amountsUseMinimalPushes() throws {
        let cases: [(UInt64, String)] = [
            (1, "51"),
            (16, "60"),
            (17, "0111"),
            (127, "017f"),
            (128, "028000"),
            (255, "02ff00"),
            (256, "020001"),
            (1 << 31, "050000008000"),
            (UInt64(Int64.max), "08ffffffffffffff7f"),
            (1 << 63, "09000000000000008000"),
            (OneColor.maxAmount, "09ffffffffffffffff00"),
        ]
        for (amount, push) in cases {
            let lock = try OneColor.value(tokenID: id0, amount: amount, lock: try p2pkh).lock()
            XCTAssertEqual(lock.hex, "20" + hex(id0Bytes) + push + "6d" + p2pkhHex, "\(amount)")
            XCTAssertEqual(OneColor.decode(lock)?.amount, amount, "\(amount)")
        }
    }

    func test_authorityAmountIsOpZero() throws {
        XCTAssertEqual(
            try OneColor.authority(tokenID: id0, lock: try p2pkh).lock().hex,
            "20" + hex(id0Bytes) + "006d" + p2pkhHex
        )
    }

    func test_minimalScriptNumberUInt64() {
        XCTAssertEqual(TemplateScript.minimalScriptNumber(0), [])
        XCTAssertEqual(hex(TemplateScript.minimalScriptNumber(17)), "11")
        XCTAssertEqual(hex(TemplateScript.minimalScriptNumber(128)), "8000")
        XCTAssertEqual(hex(TemplateScript.minimalScriptNumber(1 << 63)), "000000000000008000")
        XCTAssertEqual(hex(TemplateScript.minimalScriptNumber(.max)), "ffffffffffffffff00")
    }

    // MARK: - Decode rejects

    func test_decodeRejects() throws {
        let id = "20" + hex(id0Bytes)
        let bad: [(String, String)] = [
            ("empty script", ""),
            ("plain P2PKH", p2pkhHex),
            ("no OP_2DROP", "\(id)51\(p2pkhHex)"),
            ("truncated after amount", "\(id)51"),
            ("OP_DROP instead of OP_2DROP", "\(id)5175"),
            ("id of 31 bytes", "1f\(hex(Array(id0Bytes.dropFirst())))516d"),
            ("id of 33 bytes", "21\(hex(id0Bytes))00516d"),
            ("36-byte id with vout 0", "24\(hex(id0Bytes))00000000516d"),
            ("32-byte id via PUSHDATA1", "4c20\(hex(id0Bytes))516d"),
            ("36-byte id via PUSHDATA2", "4d2400\(hex(id3Bytes))516d"),
            ("id as OP_1", "51516d"),
            ("amount 0 as direct push", "\(id)01006d"),
            ("amount 1 as direct push", "\(id)01016d"),
            ("amount 16 as direct push", "\(id)01106d"),
            ("amount 17 via PUSHDATA1", "\(id)4c01116d"),
            ("amount non-minimal (17 padded)", "\(id)0211006d"),
            ("amount negative (0x91 = -17)", "\(id)01916d"),
            ("amount negative zero", "\(id)01806d"),
            ("amount OP_1NEGATE", "\(id)4f6d"),
            ("amount above 2^64-1", "\(id)09\(String(repeating: "00", count: 8))016d"),
            ("amount of 10 bytes", "\(id)0a\(String(repeating: "ff", count: 9))006d"),
            ("truncated id push", "20\(hex(Array(id0Bytes.dropFirst(2))))"),
            ("id is a non-push opcode", "76516d"),
        ]
        for (name, scriptHex) in bad {
            XCTAssertNil(OneColor.decode(try script(scriptHex)), name)
        }
    }

    // MARK: - Payload

    func test_payloadRoundTripsDisplayFieldsOnDeploy() throws {
        let icon = OneColorIcon(mediaType: "image/png", bytes: [0x89, 0x50, 0x4e, 0x47])
        let token = try OneColor.deployValue(
            amount: 21_000_000,
            lock: try p2pkh,
            payload: .metadata(OneColorMetadata(symbol: "GOLD", decimals: 8, icon: icon))
        )
        // length-first key order: dec, sym, icon; icon = ["image/png", h'89504e47']
        let cbor = "a36364656308" + "6373796d64474f4c44" + "6469636f6e8269" + "696d6167652f706e67" + "4489504e47"
        XCTAssertEqual(hex(token.payload ?? []), cbor)
        XCTAssertEqual(cbor.count / 2, 0x24)
        let lock = try token.lock()
        XCTAssertEqual(lock.hex, "0004406f40016d24\(cbor)75\(p2pkhHex)")
        let decoded = try XCTUnwrap(OneColor.decode(lock))
        XCTAssertEqual(decoded.role, .deploy)
        XCTAssertEqual(decoded.amount, 21_000_000)
        XCTAssertEqual(hex(decoded.payload ?? []), cbor)
        XCTAssertEqual(decoded.payloadMap?["sym"], .text("GOLD"))
        XCTAssertEqual(decoded.metadata, OneColorMetadata(symbol: "GOLD", decimals: 8, icon: icon))
        XCTAssertEqual(decoded.lock.hex, p2pkhHex)
    }

    func test_payloadSpecExampleOnAuthorityDeploy() throws {
        let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] + [UInt8](repeating: 7, count: 200)
        let icon = OneColorIcon(mediaType: "image/png", bytes: png)
        let token = try OneColor.deployAuthority(
            lock: try p2pkh,
            payload: .metadata(OneColorMetadata(symbol: "GOLD", decimals: 8, icon: icon))
        )
        let decoded = try XCTUnwrap(OneColor.decode(try token.lock()))
        XCTAssertEqual(decoded.metadata, OneColorMetadata(symbol: "GOLD", decimals: 8, icon: icon))
        XCTAssertEqual(decoded.payloadMap?["icon"], .array([.text("image/png"), .bytes(png)]))
    }

    func test_shortPayloadUsesDirectPush() throws {
        let token = try OneColor.deployAuthority(lock: try p2pkh, payload: .metadata(OneColorMetadata(symbol: "X")))
        XCTAssertEqual(try token.lock().hex, "00006d07a16373796d615875" + p2pkhHex)
    }

    func test_emptyDisplayFieldsOmitPayload() throws {
        XCTAssertNil(try OneColor.deployAuthority(lock: try p2pkh, payload: .metadata(OneColorMetadata())).payload)
    }

    func test_builderRejectsInvalidDisplayFields() throws {
        XCTAssertThrowsError(
            try OneColor.deploy(amount: 1, lock: try p2pkh, payload: .metadata(OneColorMetadata(decimals: 19)))
        ) { XCTAssertEqual($0 as? OneColorError, .invalidDecimals(19)) }
        XCTAssertThrowsError(
            try OneColor.deploy(amount: 1, lock: try p2pkh, payload: .metadata(OneColorMetadata(decimals: -1)))
        )
        // The TS also rejects icons that are not { mediaType: string, bytes: Uint8Array };
        // `OneColorIcon` makes those shapes unrepresentable.
    }

    func test_rawPayloadMinimalPushesForEverySize() throws {
        let sizes: [([UInt8], String)] = [
            ([], "00"),
            ([0x05], "55"),
            ([0x10], "60"),
            ([0x81], "4f"),
            ([0x11], "0111"),
            ([0x00], "0100"),
            ([UInt8](repeating: 7, count: 75), "4b" + String(repeating: "07", count: 75)),
            ([UInt8](repeating: 7, count: 76), "4c4c" + String(repeating: "07", count: 76)),
            ([UInt8](repeating: 7, count: 256), "4d0001" + String(repeating: "07", count: 256)),
        ]
        for (bytes, push) in sizes {
            let lock = try OneColor.value(tokenID: id0, amount: 17, lock: try p2pkh, payload: .bytes(bytes)).lock()
            XCTAssertEqual(lock.hex, "20\(hex(id0Bytes))01116d\(push)75\(p2pkhHex)", push)
            let decoded = try XCTUnwrap(OneColor.decode(lock))
            XCTAssertEqual(decoded.payload, bytes, push)
            XCTAssertNil(decoded.metadata, push)
            XCTAssertEqual(decoded.lock.hex, p2pkhHex, push)
        }
    }

    func test_valueOutputWithCborPayloadHasMapButNoMetadata() throws {
        let lock = try OneColor.value(
            tokenID: id0,
            amount: 17,
            lock: try p2pkh,
            payload: .metadata(OneColorMetadata(symbol: "X"))
        ).lock()
        let decoded = try XCTUnwrap(OneColor.decode(lock))
        XCTAssertEqual(decoded.payloadMap, ["sym": .text("X")])
        XCTAssertNil(decoded.metadata)
    }

    func test_rejectedOrNonMapPayloadHasNoMapOrMetadata() throws {
        for payload in [
            "83010203", // array, not a map
            "6158", // text, not a map
            "a26373796d6158", // truncated
            "bf6373796d6158ff", // indefinite-length map
            "a1636465631808", // non-minimal integer
            "b8016373796d6158", // non-minimal map length
            "a16373796dc16158", // tag 1
            "c1a16373796d6158", // tagged map, tag 1
        ] {
            let bytes = try Hex.decode(payload, maximumDecodedByteCount: 64)
            let lock = try OneColor.deployAuthority(lock: try p2pkh, payload: .bytes(bytes)).lock()
            let decoded = try XCTUnwrap(OneColor.decode(lock), payload)
            XCTAssertEqual(decoded.role, .deploy, payload)
            XCTAssertNotNil(decoded.payload, payload)
            XCTAssertNil(decoded.payloadMap, payload)
            XCTAssertNil(decoded.metadata, payload)
        }
    }

    func test_attributeTypesCheckedMalformedOnesAbsent() throws {
        let symG = "6373796d6147" // "sym": "G"
        let iconKey = "6469636f6e" // "icon"
        let png = "69696d6167652f706e67" // "image/png"
        let icon1 = "\(iconKey)82\(png)4101" // "icon": ["image/png", h'01']
        let icon = OneColorIcon(mediaType: "image/png", bytes: [1])
        func noIcon(_ name: String, _ value: String) -> (String, String, OneColorMetadata) {
            (name, "a36364656302\(symG)\(iconKey)\(value)", OneColorMetadata(symbol: "G", decimals: 2))
        }
        let cases: [(String, String, OneColorMetadata)] = [
            ("dec as f64 1.0", "a363646563fb3ff0000000000000\(symG)\(icon1)", OneColorMetadata(symbol: "G", icon: icon)),
            ("dec negative", "a36364656320\(symG)\(icon1)", OneColorMetadata(symbol: "G", icon: icon)),
            ("dec as text", "a3636465636131\(symG)\(icon1)", OneColorMetadata(symbol: "G", icon: icon)),
            ("dec above 18", "a36364656313\(symG)\(icon1)", OneColorMetadata(symbol: "G", icon: icon)),
            noIcon("icon as a 4-byte vout pointer (removed form)", "4401000000"),
            noIcon(
                "icon as a 36-byte outpoint pointer (removed form)",
                "5824" + String(repeating: "11", count: 32) + "01000000"
            ),
            noIcon("icon as bytes", "4101"),
            noIcon("icon as text", "6461626364"),
            noIcon("icon as an empty array", "80"),
            noIcon("icon as a one-item array", "81\(png)"),
            noIcon("icon as a three-item array", "83\(png)410101"),
            noIcon("icon items reversed", "824101\(png)"),
            noIcon("icon as two text strings", "82\(png)6178"),
            noIcon("icon as two byte strings", "8241014101"),
            noIcon("icon as a map", "a1696d6564696154797065\(png)"),
            ("sym as bytes", "a363646563026373796d4147\(icon1)", OneColorMetadata(decimals: 2, icon: icon)),
            ("every attribute well-typed", "a36364656302\(symG)\(icon1)", OneColorMetadata(symbol: "G", decimals: 2, icon: icon)),
            (
                "icon with an empty media type and no bytes is still the shape",
                "a36364656302\(symG)\(iconKey)826040",
                OneColorMetadata(symbol: "G", decimals: 2, icon: OneColorIcon(mediaType: "", bytes: []))
            ),
        ]
        for (name, payload, metadata) in cases {
            let bytes = try Hex.decode(payload, maximumDecodedByteCount: 1_000)
            let decoded = try XCTUnwrap(
                OneColor.decode(try OneColor.deployAuthority(lock: try p2pkh, payload: .bytes(bytes)).lock()),
                name
            )
            XCTAssertEqual(decoded.role, .deploy, name)
            XCTAssertNotNil(decoded.payloadMap, name)
            XCTAssertEqual(decoded.metadata, metadata, name)
        }
    }

    func test_malformedDisplayFieldsDroppedDeployStaysValid() throws {
        let payload = try DagCbor.encode(.map(["sym": .text("OK"), "dec": .unsigned(19), "icon": .bytes([1, 2, 3])]))
        XCTAssertEqual(hex(payload), "a363646563136373796d624f4b6469636f6e43010203")
        let decoded = try XCTUnwrap(
            OneColor.decode(try OneColor.deployAuthority(lock: try p2pkh, payload: .bytes(payload)).lock())
        )
        XCTAssertEqual(decoded.role, .deploy)
        XCTAssertEqual(decoded.metadata, OneColorMetadata(symbol: "OK"))
    }

    func test_pushDropAtStartOfLockIsReadAsPayload() throws {
        let decoded = try XCTUnwrap(OneColor.decode(try script("00516d010275" + p2pkhHex)))
        XCTAssertEqual(decoded.payload, [0x02])
        XCTAssertEqual(decoded.lock.hex, p2pkhHex)
    }

    func test_emptyPayloadRuleForInnerPushDrop() throws {
        // inner: <02> OP_DROP, then P2PKH
        let inner = try script("010275" + p2pkhHex)
        let token = try OneColor.value(tokenID: id0, amount: 17, lock: .script(inner))
        XCTAssertEqual(try token.prefix().hex, "20\(hex(id0Bytes))01116d0075")
        let decoded = try XCTUnwrap(OneColor.decode(try token.lock()))
        XCTAssertEqual(decoded.payload, [])
        XCTAssertEqual(token.payload, [])
        XCTAssertEqual(token.payload, decoded.payload)
        XCTAssertNil(decoded.payloadMap)
        XCTAssertNil(decoded.metadata)
        XCTAssertEqual(decoded.lock.hex, inner.hex)
    }

    func test_emptyPayloadRuleForEveryPushForm() throws {
        for push in ["00", "4f", "51", "60", "0102", "4c01ff"] {
            let inner = try script("\(push)75\(p2pkhHex)")
            let token = try OneColor.deployAuthority(lock: .script(inner))
            XCTAssertEqual(try token.prefix().hex, "00006d0075", push)
            let decoded = try XCTUnwrap(OneColor.decode(try token.lock()), push)
            XCTAssertEqual(decoded.payload, [], push)
            XCTAssertEqual(token.payload, decoded.payload, push)
            XCTAssertNil(decoded.payloadMap, push)
            XCTAssertNil(decoded.metadata, push)
            XCTAssertEqual(decoded.lock.hex, inner.hex, push)
        }
    }

    func test_givenPayloadWrittenAsIsBeforeInnerPushDrop() throws {
        let inner = try script("010275" + p2pkhHex)
        let token = try OneColor.value(tokenID: id0, amount: 17, lock: .script(inner), payload: .bytes([0xaa]))
        XCTAssertEqual(try token.prefix().hex, "20\(hex(id0Bytes))01116d01aa75")
        let decoded = try XCTUnwrap(OneColor.decode(try token.lock()))
        XCTAssertEqual(decoded.payload, [0xaa])
        XCTAssertEqual(decoded.lock.hex, inner.hex)
    }

    func test_noPayloadWithP2PKHInnerLock() throws {
        let token = try OneColor.value(tokenID: id0, amount: 17, lock: try p2pkh)
        XCTAssertEqual(try token.prefix().hex, "20\(hex(id0Bytes))01116d")
        let decoded = try XCTUnwrap(OneColor.decode(try token.lock()))
        XCTAssertNil(decoded.payload)
        XCTAssertNil(token.payload)
        XCTAssertEqual(decoded.lock.hex, p2pkhHex)
    }

    func test_acceptsNonMinimalPayloadPush() throws {
        let decoded = OneColor.decode(try script("00516d4c010275" + p2pkhHex))
        XCTAssertEqual(decoded?.payload, [0x02])
    }

    // MARK: - amm-poc fixtures

    private func fixture(_ name: String) throws -> Transaction {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let text = try String(contentsOf: root.appendingPathComponent("\(name).hex"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try Transaction(
            bytes: try Hex.decode(text, maximumDecodedByteCount: Self.limits.maximumTransactionByteCount),
            limits: Self.limits
        )
    }

    private static let limits = try! TransactionLimits(
        maximumTransactionByteCount: 1_000_000,
        maximumInputCount: 1_000,
        maximumOutputCount: 1_000,
        maximumScriptByteCount: 1_000_000
    )

    private func txid(_ transaction: Transaction) throws -> String {
        try transaction.transactionID(limits: Self.limits).displayHex
    }

    func test_fixtureTokenDeploy() throws {
        let out = try fixture("token_deploy").outputs[0].lockingScript
        let decoded = try XCTUnwrap(OneColor.decode(out))
        XCTAssertEqual(decoded.role, .deploy)
        XCTAssertEqual(decoded.amount, 10_000_000)
        XCTAssertNil(decoded.tokenID)
        XCTAssertNil(decoded.payload)
        XCTAssertEqual(decoded.lock.hex, "76a9140ed3fb307701a6a39ed8ac47f8e0fc1858d19a5088ac")
        // byte-exact rebuild
        XCTAssertEqual(try OneColor.deployValue(amount: 10_000_000, lock: .script(decoded.lock)).lock().hex, out.hex)
    }

    func test_fixturePoolDeploy() throws {
        let deployTXID = try txid(try fixture("token_deploy"))
        let tokenID = deployTXID + "_0"
        let transaction = try fixture("pool_deploy")
        let expected: [(Int, UInt64)] = [(0, 5_000_000), (1, 50_000), (2, 4_950_000)]
        for (vout, amount) in expected {
            let out = transaction.outputs[vout].lockingScript
            let decoded = try XCTUnwrap(OneColor.decode(out), "\(vout)")
            XCTAssertEqual(decoded.role, .value)
            XCTAssertEqual(decoded.tokenID, tokenID)
            XCTAssertEqual(
                hex(decoded.idBytes ?? []),
                hex(try Hex.decode(deployTXID, maximumDecodedByteCount: 32).reversed())
            )
            XCTAssertEqual(decoded.amount, amount)
            XCTAssertNil(decoded.payload)
            XCTAssertEqual(
                try OneColor.value(tokenID: tokenID, amount: amount, lock: .script(decoded.lock)).lock().hex,
                out.hex
            )
        }
        // the pool contract follows the prefix unchanged (OP_NOP OP_CODESEPARATOR ...)
        XCTAssertEqual(OneColor.decode(transaction.outputs[0].lockingScript)?.lock.hex.prefix(4), "61ab")
        XCTAssertNil(OneColor.decode(transaction.outputs[3].lockingScript))
    }

    func test_fixtureSwapTokensIn() throws {
        let tokenID = try txid(try fixture("token_deploy")) + "_0"
        let transaction = try fixture("swap_tokens_in")
        let a = OneColor.decode(transaction.outputs[2].lockingScript)
        let b = OneColor.decode(transaction.outputs[3].lockingScript)
        XCTAssertEqual(a?.tokenID, tokenID)
        XCTAssertEqual(a?.amount, 150)
        XCTAssertEqual(b?.tokenID, tokenID)
        XCTAssertEqual(b?.amount, 25)
        XCTAssertEqual(OneColor.decode(transaction.outputs[0].lockingScript)?.role, .value)
        XCTAssertNil(OneColor.decode(transaction.outputs[1].lockingScript))
    }

    func test_fixtureLegacyMigrate() throws {
        let deploy = try fixture("legacy_deploy1")
        let out = try fixture("legacy_migrate1").outputs[0].lockingScript
        let decoded = try XCTUnwrap(OneColor.decode(out))
        let tokenID = try txid(deploy) + "_1"
        XCTAssertEqual(decoded.role, .value)
        XCTAssertEqual(decoded.tokenID, tokenID)
        XCTAssertEqual(decoded.idBytes?.count, 36)
        XCTAssertEqual(decoded.amount, 500_000)
        XCTAssertEqual(
            try OneColor.value(tokenID: tokenID, amount: 500_000, lock: .script(decoded.lock)).lock().hex,
            out.hex
        )
    }

    func test_fixtureLegacyTransferIsNotOneColor() throws {
        let outputs = try fixture("legacy_transfer").outputs
        XCTAssertFalse(outputs.isEmpty)
        for output in outputs {
            XCTAssertNil(OneColor.decode(output.lockingScript))
        }
    }

    // MARK: - Binary wins over a BRC-161 inscription

    func test_binaryWinsOverBSV21Inscription() throws {
        let json = try BSV21.transfer(tokenID: String(repeating: "aa", count: 32) + "_0", amount: "999")
            .lock(lockingScript: try script(p2pkhHex))
        let lock = try OneColor.value(tokenID: id0, amount: 5000, lock: .script(json)).lock()
        let decoded = try XCTUnwrap(OneColor.decode(lock))
        XCTAssertEqual(decoded.role, .value)
        XCTAssertEqual(decoded.tokenID, id0)
        XCTAssertEqual(decoded.amount, 5000)
        // the inscription is just part of the lock
        XCTAssertEqual(decoded.lock.hex, json.hex)
        XCTAssertEqual(BSV21.decode(decoded.lock)?.tokenData.amount, "999")
    }
}
