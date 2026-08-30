import BSVKeys

/// Deposit addresses for a 1Sat identity. This type is the Swift protocol owner.
///
/// It matches `@1sat/actions` `deriveDepositAddresses`: protocol `[0, "onesat"]`, key identifier
/// `"<prefix> <index>"`. The default prefix is `"1sat"` so every wallet that binds the same
/// identity key derives the same default addresses. `"1sat"` is 4 characters; BRC-100 protocol
/// names must be at least 5, so the protocol string is `"onesat"`.
///
/// `ToolboxBRC29.OneSatDeposit` is a byte-identical copy of the default-prefix case. The toolbox
/// cannot import this module: `swift-1sat-sdk` depends on `swift-wallet-toolbox`, so the reverse
/// edge would cycle. Change this type first; the copy and `RemoteWallet.receiveAddress` must stay
/// equal, and `DepositAddressesTests` fails if they drift.
public enum DepositAddresses {
    public static let defaultPrefix = "1sat"

    /// BRC-43 invoice number for a deposit index: `0-onesat-<prefix> <index>`.
    public static func invoiceNumber(prefix: String = defaultPrefix, index: Int) -> String {
        "0-onesat-\(prefix) \(index)"
    }

    public static func key(
        identity: PrivateKey,
        index: Int,
        prefix: String = defaultPrefix
    ) throws -> PrivateKey {
        try identity.derivedChild(
            with: identity.publicKey,
            invoiceNumber: invoiceNumber(prefix: prefix, index: index)
        )
    }

    public static func address(
        identity: PrivateKey,
        index: Int,
        prefix: String = defaultPrefix,
        network: BitcoinNetwork = .mainnet
    ) throws -> Address {
        Address(
            publicKey: try key(identity: identity, index: index, prefix: prefix).publicKey,
            network: network
        )
    }

    /// A run of deposit addresses, `startIndex` inclusive.
    public static func addresses(
        identity: PrivateKey,
        startIndex: Int = 0,
        count: Int = 1,
        prefix: String = defaultPrefix,
        network: BitcoinNetwork = .mainnet
    ) throws -> [Address] {
        try (startIndex..<(startIndex + count)).map {
            try address(identity: identity, index: $0, prefix: prefix, network: network)
        }
    }
}
