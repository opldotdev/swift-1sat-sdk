import Foundation
import BSVCore
import BSVKeys
import BSVWallet

/// BRC-78 framing over wallet encryption, as `actions/src/metanet/brc78.ts` does it:
///
///     42421033 ‖ sender (33) ‖ recipient (33) ‖ keyID (32) ‖ ciphertext
///
/// The ciphertext is the wallet's `encrypt` under `[2, "message encryption"]` with key ID
/// `base64(keyID)` and the other party as counterparty. Going through the wallet rather than a
/// message codec keeps the size limit at the caller's, since a BEEF body can exceed a codec's
/// default cap.
public enum BRC78 {
    public static let version: [UInt8] = [0x42, 0x42, 0x10, 0x33]

    public static func encryptionProtocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: "message encryption")
    }

    public static func encrypt(
        _ plaintext: [UInt8], to recipient: PublicKey, wallet: ProtoWallet,
        keyID: [UInt8]? = nil
    ) async throws -> [UInt8] {
        let id = keyID ?? randomBytes(32)
        guard id.count == 32 else { throw MetanetError.brc78("BRC-78: key ID must be 32 bytes") }
        let encrypted = try await wallet.encrypt(WalletEncryptRequest(
            protocolID: try encryptionProtocol(),
            keyID: try WalletKeyID(Data(id).base64EncodedString()),
            counterparty: .publicKey(recipient),
            plaintext: plaintext
        ))
        let sender = try await wallet.getPublicKey(WalletGetPublicKeyRequest(selection: .identity))
        return version + sender.publicKey.compressedBytes + recipient.compressedBytes + id
            + encrypted.ciphertext
    }

    public static func decrypt(
        _ message: [UInt8], from sender: PublicKey, wallet: ProtoWallet
    ) async throws -> [UInt8] {
        guard message.count >= 4 + 33 + 33 + 32, Array(message.prefix(4)) == version else {
            throw MetanetError.brc78("BRC-78: unsupported version")
        }
        let keyID = Array(message[(4 + 33 + 33)..<(4 + 33 + 33 + 32)])
        let decrypted = try await wallet.decrypt(WalletDecryptRequest(
            protocolID: try encryptionProtocol(),
            keyID: try WalletKeyID(Data(keyID).base64EncodedString()),
            counterparty: .publicKey(sender),
            ciphertext: Array(message[(4 + 33 + 33 + 32)...])
        ))
        return decrypted.plaintext
    }

    /// The entity cap BRC-232 allows, plus room for the MIME header.
    public static let maximumPlaintextByteCount = 32 * 1024 * 1024 + 8 * 1024

    /// A wallet over `identity` whose payload cap fits a BRC-232 entity. The default cap is 1 MiB,
    /// which a BEEF carrying a few ancestors can pass.
    public static func wallet(for identity: PrivateKey) throws -> ProtoWallet {
        ProtoWallet(
            rootKey: identity,
            limits: try WalletCryptoLimits(maximumPayloadByteCount: maximumPlaintextByteCount)
        )
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
    }
}
