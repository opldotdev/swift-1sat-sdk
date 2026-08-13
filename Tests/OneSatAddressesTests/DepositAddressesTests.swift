import BSVKeys
import ToolboxWallet
import XCTest
@testable import OneSatAddresses

/// Vectors from the same phrase the toolbox receive-address tests use. They must stay equal
/// to `@1sat/actions` `deriveDepositAddresses` under prefix `"1sat"`.
final class DepositAddressesTests: XCTestCase {
    private let phrase =
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"

    /// bun `@bsv/sdk` KeyDeriver protocol `[0, "p 1sat"]` keyID `"1sat <i>"` counterparty self forSelf; abandon identity `5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1`; 2026-08-13.
    private let depositAddresses = [
        "18Dg5KjZsS4fTPZYTvNP9z76WySuB8XSLc",
        "1JKT82gZGUCMo9PU7Hjrqa9rKBtcj9khPz",
        "1BdMVZzcu9G67hrfQFMnae6EFkrzJCDC9y",
        "1Ao2nLUR9r1gyfwWVtex5SbRpEkPUo147C",
        "13UNnQTCcRsSRjTSTX27CUZ1PZBQyee14o",
        "1P52KZuMLJhXYLc8rmULvf3swsY1h24pea",
        "19A5k4UXqaqwzhY4qmbk5SCZh8MHsD6p9E",
        "197U2wbdyaTb2i8MkCgeCJmsffgbASaj61",
        "18YComjX76MyjgnnsrHUixgvT3m3DbEPjU",
        "18r2S3wm1UA1rxTWW1DfmHXfiJUtHYFrz5",
    ]

    /// bun `@bsv/sdk` KeyDeriver protocol `[0, "p 1sat"]` keyID `"1sat <i>"` counterparty self forSelf; abandon identity `5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1`; 2026-08-13.
    private let depositPublicKeys = [
        "027f3c674f462912e89eacddce2c8133b7be63d2f647375dcab7c03033a43e8b21",
        "0333d3b568e30466cc10b6ba0fd565af4eafe80a96806b228b80cebd01a820349a",
        "0254b40ff590e454a57a95493e17eb15d4aff99541ca4c1b42f5942f26bbb0f394",
        "03468d8a6d1668e0075f965ba9b6c208af577be5e12f71debfcf4e0646924cd7df",
        "0383e328e4d9872c513e4fae240861e22003240f8de30359343f224204a98abdff",
        "02e2d77735ab93a531ee81586e20ed924fd4708c2d69360aaf8ffe3c5586636ff2",
        "02ffa998d4d1248cad42692e656ee6ee3c358858c143f4ec61832b1750da6dee78",
        "036c315cdf1c552b8b15a6f10267131efa6d223371691ca85ed2604ac62fc0c0a6",
        "03a8fa6014017b92e2b0cc21962872d42df353bd72060a1d95c298b28f0428f90c",
        "038dffb81fd25c697e773e65c6a62726ef42242487fd27667a2c57af791ab7a13d",
    ]

    private func identity() throws -> PrivateKey {
        try MnemonicRestore.identityKey(fromPhrase: phrase)
    }

    func test_defaultAddressesMatchThe1SatReference() throws {
        let identity = try identity()
        for index in 0..<10 {
            XCTAssertEqual(
                try DepositAddresses.address(identity: identity, index: index).description,
                depositAddresses[index]
            )
            XCTAssertEqual(
                try DepositAddresses.key(identity: identity, index: index).publicKey.compressedBytes,
                try hexBytes(depositPublicKeys[index])
            )
        }
    }

    func test_aRunOfAddressesMatchesTheSingleIndexForm() throws {
        let identity = try identity()
        XCTAssertEqual(
            try DepositAddresses.addresses(identity: identity, startIndex: 0, count: 10)
                .map(\.description),
            depositAddresses
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
        let owner = try (0...9).map {
            try DepositAddresses.address(identity: identity, index: $0).description
        }
        let copy = try (0...9).map { try wallet.receiveAddress(index: $0) }

        XCTAssertEqual(owner, copy)
        XCTAssertEqual(owner, depositAddresses)
        for index in 0..<10 {
            XCTAssertEqual(
                try DepositAddresses.key(identity: identity, index: index).publicKey.compressedBytes,
                try hexBytes(depositPublicKeys[index])
            )
        }
    }

    private func hexBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(hex[index..<next], radix: 16)))
            index = next
        }
        return bytes
    }
}
