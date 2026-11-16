import BSVCore
import BSVCrypto
import BSVKeys
import BSVWallet

/// The pool's derived keys (lib/keys.ts): the "anyone" deriver's BRC-42 children of an identity,
/// so anyone can compute them and only the identity's holder can sign with them.
public enum OpenExchangeKeys {
    /// `AMM_POOL_PROTOCOL`: `[1, "amm pool"]`.
    static func poolProtocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyApp, name: "amm pool")
    }

    /// `AMM_COMMISSION_PROTOCOL`: `[1, "amm commission"]`.
    static func commissionProtocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyApp, name: "amm commission")
    }

    /// `validatorKeyId`: `<txid>_<vout>`.
    static func keyID(txid: String, vout: Int) -> String { "\(txid)_\(vout)" }

    static func child(_ protocolID: WalletProtocolID, keyID: String, identity: String) throws -> PublicKey {
        try WalletKeyDeriver.anyone().derivePublicKey(
            protocolID: protocolID, keyID: try WalletKeyID(keyID),
            counterparty: .publicKey(try PublicKey(try Hex.decode(identity, maximumDecodedByteCount: 33))),
            forSelf: false
        )
    }

    /// `deriveValidatorPubKey`: the validator key of the pool output `txid`:`vout` (its
    /// continuation's ValidatorPubKey), compressed hex.
    public static func validatorPubKey(validatorIdentity: String, txid: String, vout: Int) throws -> String {
        Hex.encode(try child(poolProtocol(), keyID: keyID(txid: txid, vout: vout), identity: validatorIdentity).compressedBytes)
    }

    /// `deriveFirstValidatorPubKey`: a deploy's validator key, keyed by its nonce (lowercased).
    public static func firstValidatorPubKey(validatorIdentity: String, nonce: String) throws -> String {
        Hex.encode(try child(poolProtocol(), keyID: nonce.lowercased(), identity: validatorIdentity).compressedBytes)
    }

    /// `deriveCommissionPkh`: hash160 of the market's commission key for the pool output
    /// `txid`:`vout`, hex (the leg's commission destination).
    public static func commissionPkh(marketIdentity: String, txid: String, vout: Int) throws -> String {
        let key = try child(commissionProtocol(), keyID: keyID(txid: txid, vout: vout), identity: marketIdentity)
        return Hex.encode(BSVHashing.hash160(key.compressedBytes).bytes)
    }
}
