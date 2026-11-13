import Foundation
import BSVWallet

/// String constants from `1sat-sdk/packages/types/src/constants.ts`.
public enum OneSatConstants {
    /// `FUNDING_BASKET`
    public static let fundingBasket = "default"
    /// `DEPOSIT_BASKET`
    public static let depositBasket = "1sat-deposit"
    /// `ONESAT_BASKET` / `ORDINALS_BASKET`. Collectable inventory (BRC-147).
    public static let onesatBasket = "1sat"
    /// `ORDINALS_BASKET` — alias of `onesatBasket`.
    public static let ordinalsBasket = onesatBasket
    /// `BSV21_BASKET`
    public static let bsv21Basket = "bsv21"
    /// Tick-based BSV-20 after a token-transfer sweep. `@1sat/actions` has no BSV-20 basket.
    public static let bsv20Basket = "bsv20"
    /// `LOCK_BASKET`
    public static let lockBasket = "lock"
    /// `OPNS_BASKET`
    public static let opnsBasket = "opns"
    /// `SIGMA_BASKET`
    public static let sigmaBasket = "sigma"
    /// `HOSTING_BASKET`
    public static let hostingBasket = "hosting"
    /// `BSOCIAL_BASKET`
    public static let bsocialBasket = "bsocial"
    /// `P1SAT_LABEL` = `p 1sat action`
    public static let p1satLabel = "p 1sat action"
    /// `P1SAT_BASKET_PREFIX` — leftover P-basket spelling, migration source only.
    public static let p1satBasketPrefix = "p 1sat "
    /// `BSV21_TOKEN_LABEL_PREFIX`
    public static let p1satTokenLabelPrefix = "p bsv21 token "
    /// `MAP_PREFIX`
    public static let mapPrefix = "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"
    /// Upper bound on inscription *content*. The envelope, MAP, and SIGMA
    /// suffix sit on top of this. Storage script limit is 1 MiB, so this
    /// leaves room for that wrapper.
    public static let maxInscriptionBytes = 900_000
    /// `ONESAT_PROTOCOL` / `P1SAT_PROTOCOL` security level.
    public static let p1satProtocolSecurityLevel: UInt8 = 0
    /// Preferred default protocol name (`ONESAT_PROTOCOL`). BRC-100 names must
    /// be at least 5 characters, so this is `"onesat"` not `"1sat"`.
    public static let p1satProtocolName = "onesat"
    /// Legacy protocol name recorded on outputs filed before the onesat rename.
    /// Spends must honor customInstructions that still say this.
    public static let legacyP1SatProtocolName = "p 1sat"
    /// `locks/index.ts` `LOCK_KEY_ID`.
    public static let lockKeyID = "lock"
    /// P2PKH unlocking length used by ordinals transfer, list, cancel, and BSV-21 send.
    public static let p2pkhUnlockingScriptLength: UInt32 = 108
    /// `unlockBsv` `unlockingScriptLength`.
    public static let timeLockUnlockingScriptLength: UInt32 = 1_205
    /// `ORDLOCK_V2_TAG`: basket tag and junglebus output type of OrdLock v2 listings.
    public static let ordlockV2Tag = "ordlock2"
    /// `ORDLOCK_FUNDING_TAG`: deposit-basket outputs prepared as OrdLock v2 front funding.
    public static let ordlockFundingTag = "ordlock-funding"
    /// `ORDLOCK_FUNDING_KEY_PREFIX`: P1SAT keyID prefix (counterparty self) of funding outputs.
    public static let ordlockFundingKeyPrefix = "ordlock-funding"
    /// `ORDLOCK_FUNDING_HOLD_MS`: how long front funding and its cushion stay out of `sweepDeposit`.
    public static let ordlockFundingHoldMilliseconds: UInt64 = 5 * 60_000
    /// `DEPOSIT_HOLD_TAG_PREFIX`: `hold:<absolute unix ms>` on deposit outputs not to sweep yet.
    public static let depositHoldTagPrefix = "hold:"

    /// `depositHoldTag(untilMs)`.
    public static func depositHoldTag(untilMilliseconds: UInt64) -> String {
        "\(depositHoldTagPrefix)\(untilMilliseconds)"
    }

    /// `depositHoldUntil(tags)`: the latest `hold:` expiry, or nil when there is none.
    public static func depositHoldUntil(_ tags: [String]?) -> UInt64? {
        var until: UInt64?
        for tag in tags ?? [] where tag.hasPrefix(depositHoldTagPrefix) {
            guard let value = UInt64(tag.dropFirst(depositHoldTagPrefix.count)) else { continue }
            if until.map({ value > $0 }) ?? true { until = value }
        }
        return until
    }

    /// `isDepositHeld(tags, nowMs)`: true while a `hold:` tag has not lapsed.
    public static func isDepositHeld(_ tags: [String]?, nowMilliseconds: UInt64) -> Bool {
        guard let until = depositHoldUntil(tags) else { return false }
        return until > nowMilliseconds
    }

    /// Wallet clock in unix milliseconds, as `Date.now()` reads it.
    public static func nowMilliseconds() -> UInt64 {
        UInt64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }

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

    /// Permission scheme id for a preferred storage basket, if any.
    /// `schemeForBasket` from `packages/types/src/constants.ts`.
    public static func permissionScheme(forBasket basket: String) -> String? {
        switch basket {
        case onesatBasket, opnsBasket, bsv21Basket, lockBasket:
            return basket
        default:
            return nil
        }
    }

    /// `buildInputAssetLabel` from `packages/types/src/constants.ts`.
    /// Held-row form: `p <scheme> input id <key>`.
    public static func inputAssetLabel(basket: String, id: String) -> String {
        let scheme = permissionScheme(forBasket: basket) ?? basket
        return "p \(scheme) input id \(id)"
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
