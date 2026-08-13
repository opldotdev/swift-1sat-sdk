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

    /// The owner and the toolbox copy must emit the same bytes for the same identity.
    ///
    /// `RemoteWallet.receiveAddress` is `OneSatDeposit` (fixed prefix `"1sat"`). This suite
    /// compiles against the toolbox revision `Package.swift` pins, so a byte change in either
    /// copy fails here.
    func test_ownerAndToolboxCopyProduceTheSameAddresses() throws {
        let identity = try identity()
        let wallet = try RemoteWallet.restore(fromPhrase: phrase)
        let owner = try (0...4).map {
            try DepositAddresses.address(identity: identity, index: $0).description
        }
        let copy = try (0...4).map { try wallet.receiveAddress(index: $0) }

        XCTAssertEqual(owner, copy)
        XCTAssertEqual(owner[0], "18Dg5KjZsS4fTPZYTvNP9z76WySuB8XSLc")
        XCTAssertEqual(owner[1], "1JKT82gZGUCMo9PU7Hjrqa9rKBtcj9khPz")
        XCTAssertEqual(owner[2], "1BdMVZzcu9G67hrfQFMnae6EFkrzJCDC9y")
    }
}
