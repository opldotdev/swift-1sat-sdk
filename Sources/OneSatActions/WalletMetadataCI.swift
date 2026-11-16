import Foundation
import BSVCrypto
import BSVWallet
import OneSatSweep

/// Best-effort plaintext view of WalletPermissionsManager-encrypted custom instructions.
public enum WalletMetadataCI {
    public struct Fields: Equatable, Sendable {
        public let plaintext: String
        public let name: String?
        public let collection: String?
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case ciphertextTooLarge(actual: Int, maximum: Int)
        case invalidBase64
        case plaintextTooLarge(actual: Int, maximum: Int)
        case invalidUTF8
        case invalidJSON
    }

    private static let maxPeel = 3

    /// Plaintext JSON passes through; WPM base64 ciphertext is peeled up to three times.
    /// Undecryptable metadata is returned unchanged, matching `ensurePlaintextCi`.
    public static func load(
        _ value: String?,
        decrypt: @Sendable (WalletDecryptRequest) async throws -> WalletDecryptResult
    ) async throws -> Fields? {
        guard var current = value, !current.isEmpty else { return nil }
        let limits = WalletCryptoLimits.standard

        for _ in 0..<maxPeel {
            if let fields = fields(from: current) { return fields }

            let encodedLimit = ((limits.maximumCiphertextByteCount + 2) / 3) * 4
            guard current.utf8.count <= encodedLimit else { return rawFields(current) }
            guard let data = Data(base64Encoded: current) else { return rawFields(current) }
            guard data.count <= limits.maximumCiphertextByteCount else { return rawFields(current) }

            let result: WalletDecryptResult
            do {
                result = try await decrypt(
                    WalletDecryptRequest(
                        protocolID: .walletMetadataEncryption,
                        keyID: try WalletKeyID("1"),
                        counterparty: .self,
                        ciphertext: Array(data)
                    )
                )
            } catch {
                // Plaintext that happens to read as base64 fails here on every listing, and that is
                // its normal path: it is read as it is, silently. Bytes long enough to be a WPM
                // envelope (nonce and tag) that still fail were encrypted for another key or are
                // damaged: said once per process, not once per output.
                if data.count >= SymmetricKey.minimumEnvelopeByteCount {
                    OneSatLog.noticeOnce(
                        "WalletMetadataCI.decrypt",
                        "encrypted custom instructions did not decrypt and are read as they are: \(OneSatLog.describe(error))",
                        category: "OneSatActions"
                    )
                }
                return rawFields(current)
            }
            guard result.plaintext.count <= limits.maximumPayloadByteCount else {
                return rawFields(current)
            }
            guard let plaintext = String(bytes: result.plaintext, encoding: .utf8),
                  plaintext != current
            else { return rawFields(current) }
            current = plaintext
        }

        return fields(from: current) ?? rawFields(current)
    }

    private static func fields(from plaintext: String) -> Fields? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(plaintext.utf8)),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return Fields(
            plaintext: plaintext,
            name: nonEmpty(dictionary["name"] as? String),
            collection: nonEmpty(dictionary["collection"] as? String)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func rawFields(_ value: String) -> Fields {
        Fields(plaintext: value, name: nil, collection: nil)
    }
}
