import BSVKeys

/// Deposit addresses for a 1Sat identity, matching `@1sat/actions` `deriveDepositAddresses`.
///
/// Protocol `[0, "p 1sat"]`, key identifier `"<prefix> <index>"`. The default prefix is `"1sat"`
/// so every wallet that binds the same identity key derives the same default addresses.
public enum DepositAddresses {
    public static let defaultPrefix = "1sat"

    /// BRC-43 invoice number for a deposit index: `0-p 1sat-<prefix> <index>`.
    public static func invoiceNumber(prefix: String = defaultPrefix, index: Int) -> String {
        "0-p 1sat-\(prefix) \(index)"
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
