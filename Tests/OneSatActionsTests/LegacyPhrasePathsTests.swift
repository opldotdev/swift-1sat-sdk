import BSVKeys
import XCTest
@testable import OneSatActions

/// Fixed vectors from `@bsv/sdk` 4.1.1, the library yours-wallet `src/utils/keys.ts` and
/// `@1sat/utils` `keys.ts` derive with: `HD.fromSeed(Mnemonic.fromString(m).toSeed()).derive(path)`,
/// then `privKey.toWif()` and `toAddress('main')`, for the BIP-39 test phrase "abandon … about".
final class LegacyPhrasePathsTests: XCTestCase {
    private let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private let vectors: [(path: String, wif: String, address: String)] = [
        ("m/44'/236'/0'/1/0", "KzMZ3P4wSxNoJwx8biNQEbcKhUJrXRD8AhE3qPa1ep99V3U3Dunm", "125GFsvYsDtyzGkExfsX8DoHuXu2UsMUEZ"),
        ("m/44'/236'/1'/0/0", "L5SbNymNJPRU3K7AKjAk98WMjtM7FLtFPwMiQGw7ockhHCx1cogs", "18pBoqRpHUYf9udsab5G9LT3vQUPxEyMFf"),
        ("m/0'/236'/0'/0/0", "Kz1pQ6LuzQue8gDtCj3bt8h7ZxmZaoLV4hssoWHtg5YVyqKgZ3Fu", "16UeyS7TvuQDwYreJpZqZceEKWbjzt4JW4"),
        ("m/44'/236'/0'/2/0", "KznERFg6yZStKzfiuUXYBcLBrEapA5n5G1SHtbVqGgkGR5QpDSAR", "12wS3tzuTkyZsDMAE6XCFGxZke6SaaYAHJ"),
        ("m/0/0", "KxDTisYSXy8fwZBtxiXKNRCkipFviJLosSceTf7BXmC79xAqzDBW", "13iX7DteNj1gV7zhe4t6o9FX9CArR5wZxz"),
        ("m/44'/236'/0'/0/0", "KxU83MzcLXP1WJtoFJXMDMcN3z5ykAa9xLdFTDY5XpV4e6Zit9BA", "1K6LZdwpKT5XkEZo2T2kW197aMXYbYMc4f"),
    ]

    func test_everyPathMatchesTheTypeScriptDerivation() throws {
        let derived = try LegacyPhrasePaths.derive(phrase: phrase)
        XCTAssertEqual(derived.map(\.path.path), vectors.map(\.path))
        for (key, vector) in zip(derived, vectors) {
            XCTAssertEqual(WIF(privateKey: key.key, network: .mainnet, isCompressed: true).encoded, vector.wif, key.path.path)
            XCTAssertEqual(Address(publicKey: key.key.publicKey, network: .mainnet).description, vector.address, key.path.path)
        }
    }

    func test_thePathsAreTheYoursRelayXAndTwetchConstants() {
        XCTAssertEqual(LegacyPhrasePaths.yoursPay.path, "m/44'/236'/0'/1/0")
        XCTAssertEqual(LegacyPhrasePaths.yoursOrdinals.path, "m/44'/236'/1'/0/0")
        XCTAssertEqual(LegacyPhrasePaths.relayxOrdinals.path, "m/44'/236'/0'/2/0")
        XCTAssertEqual(LegacyPhrasePaths.identity.path, "m/0'/236'/0'/0/0")
        XCTAssertEqual(LegacyPhrasePaths.twetchPay.path, "m/0/0")
        XCTAssertEqual(LegacyPhrasePaths.oldDefault.path, "m/44'/236'/0'/0/0")
        XCTAssertEqual(Set(LegacyPhrasePaths.all.map(\.role)), [.pay, .ordinals, .identity])
    }

    func test_anInvalidPhraseThrows() {
        XCTAssertThrowsError(try LegacyPhrasePaths.derive(phrase: "abandon abandon abandon"))
    }
}
