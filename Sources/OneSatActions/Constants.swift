import BSVWallet

/// String constants from `1sat-sdk/packages/types/src/constants.ts`.
public enum OneSatConstants {
    /// `FUNDING_BASKET`
    public static let fundingBasket = "default"
    /// `DEPOSIT_BASKET`
    public static let depositBasket = "1sat-deposit"
    /// `ORDINALS_BASKET`
    public static let ordinalsBasket = "p 1sat ordinals"
    /// `BSV21_BASKET`
    public static let bsv21Basket = "p 1sat bsv21"
    /// Tick-based BSV-20 after a token-transfer sweep. `@1sat/actions` has no BSV-20 basket.
    public static let bsv20Basket = "p 1sat bsv20"
    /// `LOCK_BASKET`
    public static let lockBasket = "p 1sat lock"
    /// `OPNS_BASKET`
    public static let opnsBasket = "p 1sat opns"
    /// `SIGMA_BASKET`
    public static let sigmaBasket = "p 1sat sigma"
    /// `P1SAT_LABEL`
    public static let p1satLabel = "p 1sat action"
    /// `P1SAT_BASKET_PREFIX`
    public static let p1satBasketPrefix = "p 1sat "
    /// `P1SAT_INPUT_LABEL_PREFIX`
    public static let p1satInputLabelPrefix = "p 1sat input "
    /// `P1SAT_TOKEN_LABEL_PREFIX`
    public static let p1satTokenLabelPrefix = "p 1sat bsv21 "
    /// `MAP_PREFIX`
    public static let mapPrefix = "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
    /// Upper bound on inscription *content*. The envelope, MAP, and SIGMA
    /// suffix sit on top of this. Storage script limit is 1 MiB, so this
    /// leaves room for that wrapper.
    public static let maxInscriptionBytes = 900_000
    /// `P1SAT_PROTOCOL` security level. The name is `p1satProtocolName`.
    public static let p1satProtocolSecurityLevel: UInt8 = 0
    /// `P1SAT_PROTOCOL` name.
    public static let p1satProtocolName = "p 1sat"
    /// `locks/index.ts` `LOCK_KEY_ID`.
    public static let lockKeyID = "lock"
    /// P2PKH unlocking length used by ordinals transfer, list, cancel, and BSV-21 send.
    public static let p2pkhUnlockingScriptLength: UInt32 = 108
    /// `unlockBsv` `unlockingScriptLength`.
    public static let timeLockUnlockingScriptLength: UInt32 = 1_205
    /// `purchaseOrdinal` `unlockingScriptLength`.
    public static let purchaseUnlockingScriptLength: UInt32 = 1_368

    public static var p1satProtocolID: WalletProtocolID {
        get throws {
            try WalletProtocolID(
                securityLevel: .silent,
                name: p1satProtocolName
            )
        }
    }

    /// `BAP_BASKET`
    public static let bapBasket = "bap"
    /// `BAP_PROTOCOL_ID` name. Security level is `everyApp` (1).
    public static let bapProtocolName = "sigma"
    /// `BAP_KEY_ID`. Key IDs are `identity-<N>`.
    public static let bapKeyID = "identity"
    /// `BAP_BITCOM_ADDRESS`
    public static let bapBitcomAddress = "1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT"
    /// `AIP_PREFIX`
    public static let aipPrefix = "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"
    /// AIP algorithm `BITCOIN_ECDSA`
    public static let aipAlgorithm = "BITCOIN_ECDSA"

    /// `BAP_PROTOCOL_ID` = `[1, "sigma"]`.
    public static var bapProtocolID: WalletProtocolID {
        get throws {
            try WalletProtocolID(
                securityLevel: .everyApp,
                name: bapProtocolName
            )
        }
    }

    /// `buildInputAssetLabel` from `packages/types/src/constants.ts`.
    public static func inputAssetLabel(basket: String, id: String) -> String {
        let suffix: String
        if basket.hasPrefix(p1satBasketPrefix) {
            suffix = String(basket.dropFirst(p1satBasketPrefix.count))
        } else {
            suffix = basket
        }
        return "\(p1satInputLabelPrefix)\(suffix) \(id)"
    }

    /// `buildTokenLabel` from `packages/types/src/constants.ts`.
    public static func tokenLabel(_ tokenID: String) -> String {
        "\(p1satTokenLabelPrefix)\(tokenID)"
    }

    /// `readAssetIdTag` from `packages/types/src/constants.ts`.
    public static func assetID(in tags: [String]?) -> String? {
        guard let tags else { return nil }
        for tag in tags where tag.hasPrefix("id:") {
            return String(tag.dropFirst(3))
        }
        return nil
    }
}
