import BSVKeys
import ToolboxWallet
import XCTest
@testable import OneSatAddresses

/// Vectors from the same phrase the toolbox receive-address tests use. They must stay equal
/// to `@1sat/actions` `deriveDepositAddresses` under prefix `"1sat"`.
final class DepositAddressesTests: XCTestCase {
    private let phrase =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    private func identity() throws -> PrivateKey {
        try MnemonicRestore.identityKey(fromPhrase: phrase)
    }

    func test_defaultAddressesMatchThe1SatReference() throws {
        let identity = try identity()
        XCTAssertEqual(
            try DepositAddresses.address(identity: identity, index: 0).description,
            "18Dg5KjZsS4fTPZYTvNP9z76WySuB8XSLc"
        )
        XCTAssertEqual(
            try DepositAddresses.address(identity: identity, index: 1).description,
            "1JKT82gZGUCMo9PU7Hjrqa9rKBtcj9khPz"
        )
        XCTAssertEqual(
            try DepositAddresses.address(identity: identity, index: 2).description,
            "1BdMVZzcu9G67hrfQFMnae6EFkrzJCDC9y"
        )
    }

    func test_aRunOfAddressesMatchesTheSingleIndexForm() throws {
        let identity = try identity()
        XCTAssertEqual(
            try DepositAddresses.addresses(identity: identity, startIndex: 0, count: 3).map(\.description),
            [
                "18Dg5KjZsS4fTPZYTvNP9z76WySuB8XSLc",
                "1JKT82gZGUCMo9PU7Hjrqa9rKBtcj9khPz",
                "1BdMVZzcu9G67hrfQFMnae6EFkrzJCDC9y",
            ]
        )
    }

    func test_invoiceNumberMatchesThe1SatKeyID() {
        XCTAssertEqual(DepositAddresses.invoiceNumber(index: 0), "0-p 1sat-1sat 0")
        XCTAssertEqual(DepositAddresses.invoiceNumber(prefix: "mcp", index: 4), "0-p 1sat-mcp 4")
    }
}
