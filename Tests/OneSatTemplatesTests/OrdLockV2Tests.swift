import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import XCTest
@testable import OneSatTemplates

/// Port of `@1sat/templates` `ordlock/ordlockV2.test.ts` (artifact, lock, decode).
final class OrdLockV2Tests: XCTestCase {
    /// TS harness `VECTOR_HEX`: seller PKH 0x11×20, payout 1000 sats to P2PKH(0x22×20).
    static let vectorHex = """
        76009c637576ab76aa517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f51
        7f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c
        7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e8100011f80517e93
        21414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff007d97785296789f527952798d9495
        937776927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76
        927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f7c
        7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c
        7e7c7e7c7e7c7e7c7e7c7e7c7e827c7e23022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16
        f81798027c7e827c7e01307c7e01c37e2102b405d7f0322a89d0f9f3a98e6f938fdc1c969a8d1382a2bf66a71ae74a1e
        83b0ad6922e8030000000000001976a914222222222222222222222222222222222222222288acaa7c820128947f7701
        207f758767519d7b0a6f6c323a63616e63656c8876a914111111111111111111111111111111111111111188ac68
        """

    /// A retired v1 listing (`OrdLock.lock` at 50_000 sats, the former Swift frozen vector).
    static let v1ListingHex = """
        2097dfd76851bf465e8f715593b217714858bbe9570ff3bd5e33840a34e20ff0262102ba79df5f8ae7604a9830f03c79
        33028186aede0675a16f025dc4f8be8eec0382201008ce7480da41702918d1ec8e6849ba32b4d65b1e40dc669c31a1e6
        306b266c00001477bff20c60e522dfaa3350c39b030a5d004e839a2250c30000000000001976a91462e907b15cbf27d5
        425399ebf6f0fb50ebb88f1888ac615179547a75537a537a537a0079537a75527a527a7575615579008763567901c161
        517957795779210ac407f0e4bd44bfc207355a778b046225a7068fc59ee7eda43ad905aadbffc800206c266b30e6a131
        9c66dc401e5bd6b432ba49688eecd118297041da8074ce081059795679615679aa0079610079517f517f517f517f517f
        517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f
        517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e
        7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e81517a756157795679567956795679615379567954795779959395
        21414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff00517951796151795179970079009f
        63007952799367007968517a75517a75517a7561527a75517a517951795296a0630079527994527a75517a6853798277
        527982775379012080517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f51
        7f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c
        7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01205279947f7754537993
        527993013051797e527e54797e58797e527e53797e52797e57797e0079517a75517a75517a75517a75517a75517a7551
        7a75517a75517a75517a75517a75517a75517a756100795779ac517a75517a75517a75517a75517a75517a75517a7551
        7a75517a7561517a75517a756169587951797e58797eaa577961007982775179517958947f7551790128947f77517a75
        517a75618777777777777777777767557951876351795779a9876957795779ac777777777777777767006868
        """

    private let sellerPKH = [UInt8](repeating: 0x11, count: 20)
    private let payPKH = [UInt8](repeating: 0x22, count: 20)

    private func script(_ hex: String) throws -> Script {
        try Script(bytes: Array(hex: hex), maximumByteCount: 100_000)
    }

    private var payP2PKH: [UInt8] { [0x76, 0xa9, 0x14] + payPKH + [0x88, 0xac] }

    func test_artifactIsTheFrozenB3f08f2Build() {
        XCTAssertEqual(OrdLockV2.template.count, 472)
        XCTAssertEqual(
            BSVHashing.sha256(OrdLockV2.template).bytes,
            Array(hex: "629c4c60d1ab45d087cae67eefecdad91dc453b58f1ba757a0363194ff05a8b7")
        )
        XCTAssertEqual(
            OrdLockV2.slots,
            [
                OrdLockV2.ConstructorSlot(paramIndex: 1, byteOffset: 436),
                OrdLockV2.ConstructorSlot(paramIndex: 0, byteOffset: 468),
            ]
        )
        XCTAssertEqual(OrdLockV2.codeSeparatorIndex, 6)
        XCTAssertEqual(OrdLockV2.template[OrdLockV2.codeSeparatorIndex], 0xab)
        XCTAssertEqual(OrdLockV2.prefix.count, 436)
        XCTAssertEqual(OrdLockV2.cancelMarker, Array("ol2:cancel".utf8))
    }

    func test_lockMatchesTheHarnessVector() throws {
        let lock = try OrdLockV2.lockRaw(
            sellerPublicKeyHash: sellerPKH,
            payout: OrdLockV2.buildOutput(satoshis: 1_000, scriptBytes: payP2PKH)
        )
        XCTAssertEqual(lock.bytes, Array(hex: Self.vectorHex))
        XCTAssertEqual(lock.bytes.count, 526)

        let seller = Address(publicKeyHash: try Hash160(sellerPKH), network: .mainnet)
        let pay = Address(publicKeyHash: try Hash160(payPKH), network: .mainnet)
        XCTAssertEqual(
            try OrdLockV2.lock(cancelAddress: seller.description, payAddress: pay.description, price: 1_000)
                .bytes,
            Array(hex: Self.vectorHex)
        )
    }

    func test_decodeIsTheInverseOfLock() throws {
        let listing = try script(Self.vectorHex)
        let data = try XCTUnwrap(OrdLockV2.decode(listing))
        XCTAssertEqual(
            data.seller,
            Address(publicKeyHash: try Hash160(sellerPKH), network: .mainnet).description
        )
        XCTAssertEqual(data.sellerPublicKeyHash, sellerPKH)
        XCTAssertEqual(data.price, 1_000)
        XCTAssertEqual(data.offset, 0)
        XCTAssertEqual(data.end, 526)
        XCTAssertEqual(data.payout, Array(hex: "e80300000000000019") + payP2PKH)
        let payout = try OrdLockV2.payoutOutput(listing)
        XCTAssertEqual(payout.satoshis, 1_000)
        XCTAssertEqual(payout.script.bytes, payP2PKH)
    }

    func test_decodeToleratesTrailingMAPData() throws {
        let withMap = try Script(
            bytes: Array(hex: Self.vectorHex) + [0x6a, 0x05] + Array("hello".utf8),
            maximumByteCount: 100_000
        )
        let data = try XCTUnwrap(OrdLockV2.decode(withMap))
        XCTAssertEqual(data.price, 1_000)
        XCTAssertEqual(data.end, 526)
        XCTAssertTrue(OrdLockV2.isOrdLockV2(withMap))
        // The scriptCode keeps the trailing data, so the estimate grows with it.
        XCTAssertEqual(
            try OrdLockV2.estimatePurchaseUnlockLength(withMap),
            try OrdLockV2.estimatePurchaseUnlockLength(try script(Self.vectorHex)) + 7
        )
    }

    func test_v1ListingsAndCorruptedV2ScriptsAreNotRecognized() throws {
        let v1 = try script(Self.v1ListingHex)
        XCTAssertFalse(OrdLockV2.isOrdLockV2(v1))
        XCTAssertNil(OrdLockV2.decode(v1))

        var bytes = Array(hex: Self.vectorHex)
        bytes[bytes.count - 1] ^= 0xff
        XCTAssertNil(OrdLockV2.decode(try Script(bytes: bytes, maximumByteCount: 100_000)))
        bytes[bytes.count - 1] ^= 0xff
        bytes[100] ^= 0x01
        XCTAssertNil(OrdLockV2.decode(try Script(bytes: bytes, maximumByteCount: 100_000)))
    }

    func test_largePayoutUsesAPushData1Slot() throws {
        let payout = OrdLockV2.buildOutput(satoshis: 5, scriptBytes: [UInt8](repeating: 0xab, count: 200))
        let lock = try OrdLockV2.lockRaw(sellerPublicKeyHash: sellerPKH, payout: payout)
        XCTAssertEqual(Array(lock.bytes[436..<438]), [0x4c, UInt8(payout.count)])
        let data = try XCTUnwrap(OrdLockV2.decode(lock))
        XCTAssertEqual(data.price, 5)
        XCTAssertEqual(data.payout, payout)
    }

    func test_lockRawRejectsMalformedArguments() {
        XCTAssertThrowsError(
            try OrdLockV2.lockRaw(sellerPublicKeyHash: [0x11], payout: [UInt8](repeating: 0, count: 9))
        ) { XCTAssertEqual($0 as? OrdLockV2Error, .invalidSellerHash) }
        XCTAssertThrowsError(
            try OrdLockV2.lockRaw(sellerPublicKeyHash: sellerPKH, payout: [0x01])
        ) { XCTAssertEqual($0 as? OrdLockV2Error, .payoutTooShort) }
    }

    /// `<preimage> OP_0`: preimage = 156 fixed bytes + CompactSize(scriptCode) + scriptCode,
    /// scriptCode = the 519 bytes after the OP_CODESEPARATOR.
    func test_purchaseUnlockLengthIsExact() throws {
        let listing = try script(Self.vectorHex)
        XCTAssertEqual(try OrdLockV2.purchaseScriptCode(listing).bytes, Array(Array(hex: Self.vectorHex)[7...]))
        XCTAssertEqual(try OrdLockV2.estimatePurchaseUnlockLength(listing), 682)
        XCTAssertEqual(OrdLockV2.cancelUnlockLength, 120)
    }

    func test_unlockShapes() throws {
        var cancel = try Script(bytes: [], maximumByteCount: 1_000)
        try cancel.appendPushData(OrdLockV2.cancelMarker, maximumScriptByteCount: 1_000)
        try cancel.appendPushData([UInt8](repeating: 0x30, count: 71), maximumScriptByteCount: 1_000)
        try cancel.appendPushData([UInt8](repeating: 0x02, count: 33), maximumScriptByteCount: 1_000)
        try cancel.append(.one, maximumScriptByteCount: 1_000)
        XCTAssertTrue(OrdLockV2.isCancel(cancel))
        XCTAssertFalse(OrdLockV2.isPurchase(cancel))

        var purchase = try Script(bytes: [], maximumByteCount: 1_000)
        try purchase.appendPushData([UInt8](repeating: 0x01, count: 200), maximumScriptByteCount: 1_000)
        try purchase.append(.zero, maximumScriptByteCount: 1_000)
        XCTAssertTrue(OrdLockV2.isPurchase(purchase))
        XCTAssertFalse(OrdLockV2.isCancel(purchase))
    }
}
