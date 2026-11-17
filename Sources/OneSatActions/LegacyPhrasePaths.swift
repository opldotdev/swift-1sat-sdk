import BSVCompat
import BSVKeys

/// The fixed BIP-32 paths Yours, RelayX and Twetch derive their keys on from a recovery phrase.
///
/// The paths are `@1sat/utils` `packages/utils/src/keys.ts` (`YOURS_WALLET_PATH`, `YOURS_ORD_PATH`,
/// `RELAYX_ORD_PATH`, `YOURS_ID_PATH`, `TWETCH_WALLET_PATH`, `RELAYX_SWEEP_PATH`), the same values
/// as yours-wallet `src/utils/constants.ts` (`DEFAULT_WALLET_PATH`, `DEFAULT_ORD_PATH`,
/// `DEFAULT_RELAYX_ORD_PATH`, `DEFAULT_IDENTITY_PATH`, `DEFAULT_TWETCH_WALLET_PATH`, `SWEEP_PATH`).
/// Each key is plain BIP-32 on the BIP-39 seed with no passphrase, as yours-wallet
/// `src/utils/keys.ts` `getWifAndDerivation` does: `HD.fromSeed(Mnemonic.fromString(m).toSeed())
/// .derive(path)`.
///
/// Pure: deriving a key reads nothing and stores nothing.
public enum LegacyPhrasePaths {
    /// What the wallet that uses the path keeps there.
    public enum Role: String, Equatable, Hashable, Sendable {
        case pay
        case ordinals
        case identity
    }

    public struct Path: Equatable, Hashable, Sendable {
        /// Who uses the path, for a screen, e.g. "Yours or RelayX payment".
        public let name: String
        public let path: String
        public let role: Role

        public init(name: String, path: String, role: Role) {
            self.name = name
            self.path = path
            self.role = role
        }
    }

    /// Yours and RelayX payment and change (`DEFAULT_WALLET_PATH`).
    public static let yoursPay = Path(name: "Yours or RelayX payment", path: "m/44'/236'/0'/1/0", role: .pay)
    /// Yours and Twetch ordinals (`DEFAULT_ORD_PATH`).
    public static let yoursOrdinals = Path(name: "Yours or Twetch ordinals", path: "m/44'/236'/1'/0/0", role: .ordinals)
    /// RelayX ordinals (`DEFAULT_RELAYX_ORD_PATH`).
    public static let relayxOrdinals = Path(name: "RelayX ordinals", path: "m/44'/236'/0'/2/0", role: .ordinals)
    /// Yours, RelayX and Twetch identity (`DEFAULT_IDENTITY_PATH`).
    public static let identity = Path(name: "Yours identity", path: "m/0'/236'/0'/0/0", role: .identity)
    /// Twetch payment (`DEFAULT_TWETCH_WALLET_PATH`).
    public static let twetchPay = Path(name: "Twetch payment", path: "m/0/0", role: .pay)
    /// The old default path Yours sweeps on every phrase restore (`SWEEP_PATH`, `RELAYX_SWEEP_PATH`).
    public static let oldDefault = Path(name: "Old Yours or RelayX default", path: "m/44'/236'/0'/0/0", role: .pay)

    /// Every path, in the order a lookup prefers them for a role.
    public static let all: [Path] = [yoursPay, yoursOrdinals, identity, relayxOrdinals, twetchPay, oldDefault]

    public struct DerivedKey: Sendable {
        public let path: Path
        public let key: PrivateKey
    }

    /// The key on every path in ``all``, in that order. Throws a phrase error for a phrase that
    /// is not valid BIP-39.
    public static func derive(phrase: String) throws -> [DerivedKey] {
        try derive(seed: try Mnemonic(phrase).seed().bytes)
    }

    /// The key on every path in ``all`` from a BIP-39 seed.
    public static func derive(seed: [UInt8]) throws -> [DerivedKey] {
        // The network only changes how an extended key serializes, never the derived keys.
        let master = try ExtendedPrivateKey(seed: seed, network: .mainnet)
        return try all.map { DerivedKey(path: $0, key: try master.derived(path: $0.path).key) }
    }
}
