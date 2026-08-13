import BSVKeys
import BSVScript
import XCTest
@testable import OneSatTemplates

final class OrdLockTests: XCTestCase {
    private let seller = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"
    private let pay = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"

    func test_buildOutputIsEightBytePricePlusThePayScript() throws {
        let payScript = try Script.payToPublicKeyHash(
            Address(pay),
            maximumByteCount: TemplateScript.maximumByteCount
        )
        XCTAssertEqual(
            OrdLock.buildOutput(satoshis: 50_000, script: payScript).hex,
            "50c30000000000001976a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac"
        )
    }

    func test_lockMatchesTheTypeScriptScript() throws {
        XCTAssertEqual(
            try OrdLock.lock(cancelAddress: seller, payAddress: pay, price: 50_000).hex,
            OrdLockVectors.lock50k
        )
    }

    func test_decodeReadsTheSellerAndPrice() throws {
        let script = try OrdLock.lock(cancelAddress: seller, payAddress: pay, price: 50_000)
        let decoded = try XCTUnwrap(OrdLock.decode(script))
        XCTAssertEqual(decoded.seller, seller)
        XCTAssertEqual(decoded.price, 50_000)
        XCTAssertTrue(OrdLock.isOrdLock(script))
    }
}

private extension Array where Element == UInt8 {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

enum OrdLockVectors {
    static let lock50k =
        "2097dfd76851bf465e8f715593b217714858bbe9570ff3bd5e33840a34e20ff0262102ba79df5f8ae7604a9830f03c7933028186aede0675a16f025dc4f8be8eec0382201008ce7480da41702918d1ec8e6849ba32b4d65b1e40dc669c31a1e6306b266c00001477bff20c60e522dfaa3350c39b030a5d004e839a2250c30000000000001976a91462e907b15cbf27d5425399ebf6f0fb50ebb88f1888ac615179547a75537a537a537a0079537a75527a527a7575615579008763567901c161517957795779210ac407f0e4bd44bfc207355a778b046225a7068fc59ee7eda43ad905aadbffc800206c266b30e6a1319c66dc401e5bd6b432ba49688eecd118297041da8074ce081059795679615679aa0079610079517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e81517a75615779567956795679567961537956795479577995939521414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff00517951796151795179970079009f63007952799367007968517a75517a75517a7561527a75517a517951795296a0630079527994527a75517a6853798277527982775379012080517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01205279947f7754537993527993013051797e527e54797e58797e527e53797e52797e57797e0079517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a75517a756100795779ac517a75517a75517a75517a75517a75517a75517a75517a75517a7561517a75517a756169587951797e58797eaa577961007982775179517958947f7551790128947f77517a75517a75618777777777777777777767557951876351795779a9876957795779ac777777777777777767006868"
}
