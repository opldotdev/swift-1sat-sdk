import BSVCore
import BSVKeys
import BSVScript
import XCTest
@testable import OneSatTemplates

final class CosignTests: XCTestCase {
    private let ownerAddress = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
    private let tokenID = String(repeating: "aa", count: 32) + "_0"

    func test_lockBytesMatchThePinnedSkeleton() throws {
        let address = try Address(ownerAddress)
        let cosigner = try compressedCosigner()
        let script = try Cosign.lock(address: address, cosigner: cosigner)
        let expected =
            [UInt8(0x76), 0xa9, 0x14]
            + address.publicKeyHash.bytes
            + [0x88, 0xad, 0x21]
            + cosigner
            + [0xac]
        XCTAssertEqual(script.bytes, expected)
        XCTAssertTrue(script.hex.hasPrefix("76a914"))
        XCTAssertTrue(script.hex.contains("88ad21"))
        XCTAssertTrue(script.hex.hasSuffix("ac"))
    }

    func test_lockThrowsOnA32ByteCosigner() {
        XCTAssertThrowsError(
            try Cosign.lock(
                address: try Address(ownerAddress),
                cosigner: Array(repeating: 0x02, count: 32)
            )
        ) { error in
            XCTAssertEqual(error as? CosignError, .invalidCosignerPubKey(byteCount: 32))
        }
    }

    func test_decodeRoundTripsLock() throws {
        let address = try Address(ownerAddress)
        let cosigner = try compressedCosigner()
        let script = try Cosign.lock(address: address, cosigner: cosigner)
        let decoded = try XCTUnwrap(Cosign.decode(script))
        XCTAssertEqual(decoded.address, address)
        XCTAssertEqual(decoded.cosigner, cosigner)
        XCTAssertTrue(Cosign.isCosign(script))
    }

    func test_decodeFindsTheWindowBehindAnInscriptionEnvelope() throws {
        let address = try Address(ownerAddress)
        let cosigner = try compressedCosigner()
        let cosignLock = try Cosign.lock(address: address, cosigner: cosigner)
        let inscribed = try BSV21.transfer(tokenID: tokenID, amount: "500")
            .lock(lockingScript: cosignLock)
        let decoded = try XCTUnwrap(Cosign.decode(inscribed))
        XCTAssertEqual(decoded.address, address)
        XCTAssertEqual(decoded.cosigner, cosigner)
        let token = try XCTUnwrap(BSV21.decode(inscribed))
        XCTAssertEqual(token.tokenData.tokenID, tokenID)
        XCTAssertEqual(token.tokenData.amount, "500")
        XCTAssertEqual(token.tokenData.operation, .transfer)
    }

    func test_decodeOfPlainP2PKHIsNil() throws {
        let p2pkh = try Script.payToPublicKeyHash(
            try Address(ownerAddress),
            maximumByteCount: TemplateScript.maximumByteCount
        )
        XCTAssertNil(Cosign.decode(p2pkh))
        XCTAssertFalse(Cosign.isCosign(p2pkh))
    }

    func test_ownerUnlockPushesSigWith0xC1Then33BytePubkey() throws {
        let key = try identityKey()
        let der: [UInt8] = [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]
        let flag: UInt8 = 0x01 | 0x80 | 0x40
        XCTAssertEqual(flag, 0xC1)
        let script = try Cosign.ownerUnlock(
            ownerSigDER: der,
            sigHashFlag: flag,
            ownerPublicKey: key.publicKey
        )
        let operations = try script.operations(
            maximumPushDataByteCount: TemplateScript.maximumByteCount
        )
        XCTAssertEqual(operations.count, 2)
        XCTAssertEqual(operations[0].pushedData, der + [0xC1])
        XCTAssertEqual(operations[0].pushedData?.last, 0xC1)
        XCTAssertEqual(operations[1].pushedData?.count, 33)
        XCTAssertEqual(operations[1].pushedData, key.publicKey.serialized(as: .compressed))
    }

    private func identityKey() throws -> PrivateKey {
        try PrivateKey(
            Hex.decode(
                "ffbd04ccf50e9822ac4387cc180d1a5021c16c89b288013fc8b9a2111dfa2da2",
                maximumDecodedByteCount: 32
            )
        )
    }

    private func compressedCosigner() throws -> [UInt8] {
        try identityKey().publicKey.serialized(as: .compressed)
    }
}
