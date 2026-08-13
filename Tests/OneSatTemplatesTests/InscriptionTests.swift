import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import XCTest
@testable import OneSatTemplates

final class InscriptionTests: XCTestCase {
    private let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    func test_plainTextMatchesTheTypeScriptEnvelope() throws {
        let inscription = try Inscription.fromText("Hello, BSV!", contentType: "text/plain")
        XCTAssertEqual(
            try inscription.lock().hex,
            "0063036f7264510a746578742f706c61696e000b48656c6c6f2c204253562168"
        )
        XCTAssertEqual(
            Hex.encode(inscription.contentHash.bytes),
            "b194e2edd2e49265f4615e5d95480bad2ad3ca474222c19c87cbdcf98f384762"
        )
        XCTAssertTrue(inscription.verify())
    }

    func test_aP2PKHPrefixSitsBeforeTheEnvelope() throws {
        let prefix = try Script.payToPublicKeyHash(
            Address(address),
            maximumByteCount: TemplateScript.maximumByteCount
        )
        let inscription = try Inscription.fromText("hi", contentType: "text/plain", scriptPrefix: prefix)
        XCTAssertEqual(
            try inscription.lock().hex,
            "76a91477bff20c60e522dfaa3350c39b030a5d004e839a88ac0063036f7264510a746578742f706c61696e0002686968"
        )
    }

    func test_aParentOutpointIsFieldThree() throws {
        let parent = Array(repeating: UInt8(0xaa), count: 32) + [0, 0, 0, 0]
        let inscription = try Inscription.create(
            content: [1, 2, 3],
            contentType: "application/octet-stream",
            parent: parent
        )
        XCTAssertEqual(
            try inscription.lock().hex,
            "0063036f726451186170706c69636174696f6e2f6f637465742d73747265616d5324aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa00000000000301020368"
        )
    }

    func test_decodeRoundTripsPrefixTypeAndContent() throws {
        let prefix = try Script.payToPublicKeyHash(
            Address(address),
            maximumByteCount: TemplateScript.maximumByteCount
        )
        let locked = try Inscription.fromText(
            "Hello, BSV!",
            contentType: "text/plain",
            scriptPrefix: prefix
        ).lock()

        let decoded = try XCTUnwrap(Inscription.decode(locked))
        XCTAssertEqual(decoded.contentType, "text/plain")
        XCTAssertEqual(String(bytes: decoded.content, encoding: .utf8), "Hello, BSV!")
        XCTAssertEqual(decoded.scriptPrefix?.hex, prefix.hex)
        XCTAssertTrue(Inscription.isInscription(locked))
    }

    func test_aScriptWithoutAnEnvelopeIsNotAnInscription() throws {
        let p2pkh = try Script.payToPublicKeyHash(
            Address(address),
            maximumByteCount: TemplateScript.maximumByteCount
        )
        XCTAssertNil(Inscription.decode(p2pkh))
        XCTAssertFalse(Inscription.isInscription(p2pkh))
    }
}
