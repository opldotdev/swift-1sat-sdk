import BSVKeys
import BSVWallet

/// P1SAT BRC-42/43 derivation.
///
/// Invoice `0-onesat-<keyID>` is `WalletKeyDeriver.invoice` for `ONESAT_PROTOCOL`.
/// The deposit module uses the same invoice shape with `keyID = "<prefix> <index>"`.
/// Spends of older outputs use the protocolID recorded in customInstructions.
public enum P1SATKey {
    public static func invoiceNumber(keyID: String) -> String {
        "\(OneSatConstants.p1satProtocolSecurityLevel)-\(OneSatConstants.p1satProtocolName)-\(keyID)"
    }

    public static func protocolID() throws -> WalletProtocolID {
        try OneSatConstants.p1satProtocolID
    }

    public static func privateKey(
        identity: PrivateKey,
        keyID: String,
        counterparty: WalletCounterparty = .self
    ) throws -> PrivateKey {
        try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try protocolID(),
            keyID: WalletKeyID(keyID),
            counterparty: counterparty
        )
    }

    public static func publicKey(
        identity: PrivateKey,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        forSelf: Bool
    ) throws -> PublicKey {
        try WalletKeyDeriver(rootKey: identity).derivePublicKey(
            protocolID: try protocolID(),
            keyID: WalletKeyID(keyID),
            counterparty: counterparty,
            forSelf: forSelf
        )
    }

    public static func address(
        identity: PrivateKey,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        forSelf: Bool,
        network: BitcoinNetwork = .mainnet
    ) throws -> Address {
        Address(
            publicKey: try publicKey(
                identity: identity,
                keyID: keyID,
                counterparty: counterparty,
                forSelf: forSelf
            ),
            network: network
        )
    }
}
