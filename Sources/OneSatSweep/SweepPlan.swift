import ToolboxServices

/// What an address actually holds, categorised by whether a plain sweep can move it.
///
/// This is the gotcha every real sweep tool has to face, and Yours Wallet's migration flow makes
/// it explicit: a legacy address rarely holds only plain BSV. It may hold ordinals, BSV-21 tokens,
/// and time-locked outputs. A naive sweep that spent all of them would burn a collectible as a fee
/// or build an invalid transaction against a lock that has not matured.
///
/// So a sweep is **partial by nature**. Only the fundable BSV moves now. Everything else is
/// reported, the source keys are kept, and the wallet re-visits the address later — when a lock
/// unlocks, or with an asset-transfer action for the tokens and ordinals.
/// BSV-21 tokens the wallet no longer supports. MNEE left BSV and its outputs are
/// cosigner-locked, so a sweep could never move them. Reads and sweep plans leave them out:
/// they are never shown, counted or spent.
public enum RetiredTokens {
    public static let ids: Set<String> = [
        "ae59f3b898ec61acbdb6cc7a245fabeded0c094bf046f35206a3aec60ef88127_0",
    ]

    public static func contains(_ tokenID: String?) -> Bool {
        guard let tokenID else { return false }
        return ids.contains(tokenID)
    }

    /// True for a scanned output of a retired token.
    public static func contains(_ kind: AssetKind) -> Bool {
        if case .bsv21(let tokenID) = kind { return ids.contains(tokenID) }
        return false
    }
}

public enum AssetKind: Equatable, Sendable {
    /// Plain BSV. Safe to sweep.
    case fundable
    /// An inscribed output — an ordinal. Move it with an ordinals transfer, never as a fee input.
    case ordinal
    /// A BSV-21 token output, identified by its token id.
    case bsv21(tokenID: String)
    /// A time-locked output. `until` is the block height (or timestamp) it unlocks at; it cannot be
    /// spent before then, and even after, it needs a lock-specific unlocking script, not a sweep.
    case locked(until: UInt64)
    /// A tick-based BSV-20 token output (`tick:` event or `type:application/bsv-20`). `tick` is nil
    /// when only the MIME event marked it. Move it with a token transfer, never as a fee or a bare
    /// ordinal (`@1sat/actions` `scan.ts` `isBsv20Output` / `isTokenMime`).
    case bsv20(tick: String?)
    /// A plain-looking output whose source transaction carries a RUN protocol output. RUN tokens
    /// and jigs live on such outputs, so it is held back instead of spent as BSV (`scan.ts`
    /// `detectRunTransactions`).
    case run
    /// A 0-sat output. `scan.ts` drops it from every class; it is reported here instead.
    case unspendable
    /// A Twetch NFT (`twetch` event). Unlocking it needs a hash preimage as well as a signature,
    /// so it is never swept as BSV, and no sweep moves it (`scan.ts` `twetch`).
    case twetch
}

/// One categorised output from an indexer scan.
///
/// The categorisation comes from the indexer's event tags (`bsv21:`, `lock:`, an inscription
/// marker). A plain UTXO provider like WhatsOnChain cannot supply these — only the 1Sat / GorillaPool
/// indexer family can — which is why a safe sweep must read from that provider, not from a bare
/// UTXO list.
public struct ScannedOutput: Equatable, Sendable {
    public let txid: String
    public let vout: UInt32
    public let satoshis: UInt64
    public let lockingScript: [UInt8]
    /// The indexer's tags for this output, e.g. `["bsv21:<id>"]`, `["lock:830000"]`.
    public let events: [String]
    /// True when any output of this output's source transaction starts with the RUN prefix
    /// (``runPrefix``). Set by ``OneSatScanner`` from the source transaction it already reads.
    public let sourceHasRunOutput: Bool

    public init(
        txid: String, vout: UInt32, satoshis: UInt64, lockingScript: [UInt8], events: [String],
        sourceHasRunOutput: Bool = false
    ) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.lockingScript = lockingScript
        self.events = events
        self.sourceHasRunOutput = sourceHasRunOutput
    }

    /// RUN protocol OP_RETURN prefix: OP_FALSE OP_RETURN OP_PUSH3 "run" (`scan.ts` `RUN_PREFIX`).
    public static let runPrefix: [UInt8] = [0x00, 0x6a, 0x03, 0x72, 0x75, 0x6e]

    /// `scan.ts` `hasRunPrefix`.
    public static func hasRunPrefix(_ script: [UInt8]) -> Bool {
        script.starts(with: runPrefix)
    }

    /// A Twetch NFT script: `OP_HASH160 <20> OP_EQUALVERIFY`, a P2PKH, then `OP_RETURN`.
    /// Checked as well as the `twetch` event, so a twonk is never swept as funds even when the
    /// indexer didn't tag it.
    public static func hasTwetchShape(_ s: [UInt8]) -> Bool {
        s.count > 48
            && s[0] == 0xa9 && s[1] == 0x14 && s[22] == 0x88
            && s[23] == 0x76 && s[24] == 0xa9 && s[25] == 0x14
            && s[46] == 0x88 && s[47] == 0xac && s[48] == 0x6a
    }

    /// What kind of asset this output is, from its tags.
    ///
    /// Order follows `@1sat/actions` `scan.ts` `categorizeOutputs`: BSV-21, Twetch, lock, BSV-20, then
    /// by satoshis. Two deliberate differences: a tagged inscription above 1 sat stays an ordinal
    /// (TS spends it as BSV), and a 0-sat output is reported as `.unspendable` (TS drops it).
    public var kind: AssetKind {
        if let token = events.first(where: { $0.hasPrefix("bsv21:") }) {
            return .bsv21(tokenID: String(token.dropFirst("bsv21:".count)))
        }
        if events.contains("twetch") || Self.hasTwetchShape(lockingScript) { return .twetch }
        if let lock = events.first(where: { $0.hasPrefix("lock:") }) {
            let until = UInt64(lock.dropFirst("lock:".count)) ?? 0
            return .locked(until: until)
        }
        if events.contains("lock") { return .locked(until: 0) }
        // `isBsv20Output` (`tick:` event) or `isTokenMime`, after the lock check as in TS.
        let tick = events.first(where: { $0.hasPrefix("tick:") }).map { String($0.dropFirst("tick:".count)) }
        if let tick, !tick.isEmpty { return .bsv20(tick: tick) }
        if events.contains("type:application/bsv-20") { return .bsv20(tick: nil) }
        if events.contains(where: {
            $0 == "1sat" || $0.hasPrefix("origin:") || $0.hasPrefix("ord") || $0.hasPrefix("insc")
        }) {
            return .ordinal
        }
        // `scan.ts`: 1 sat is always an ordinal (or OpNS); funding is only above 1 sat.
        if satoshis == 1 { return .ordinal }
        if satoshis == 0 { return .unspendable }
        if sourceHasRunOutput { return .run }
        return .fundable
    }

    var spendable: SpendableUTXO {
        SpendableUTXO(txid: txid, vout: vout, satoshis: satoshis, lockingScript: lockingScript)
    }
}

/// Reads an address's categorised outputs from the 1Sat indexer.
///
/// The one adapter that matters is `api.1sat.app` (the GorillaPool / 1Sat-stack family). WhatsOnChain
/// deliberately does not conform: it cannot tell an ordinal from a coin, so it must never be the
/// source for a sweep that could hold assets.
public protocol AssetScanner: Sendable {
    func scan(address: String) async throws -> [ScannedOutput]
    /// Twetch NFTs held by `address`, which the indexer keeps out of ``scan(address:)``.
    func twetchNFTs(address: String) async throws -> [ScannedOutput]
}

extension AssetScanner {
    /// A scanner that can't list Twetch NFTs reports none; ``OneSatScanner`` lists them.
    public func twetchNFTs(address: String) async throws -> [ScannedOutput] { [] }
}

/// The split a sweep produces: what moves now, and what stays.
public struct SweepPlan: Equatable, Sendable {
    /// Plain BSV, ready to sweep.
    public let fundable: [SpendableUTXO]
    /// What the plain sweep cannot move. The source keys must be kept while any of this remains.
    public let remaining: RemainingAssets

    public init(fundable: [SpendableUTXO], remaining: RemainingAssets) {
        self.fundable = fundable
        self.remaining = remaining
    }

    /// Categorises a scan into a plan. Locks are never swept here — even a matured lock needs a
    /// lock-specific unlocking script — so all of them, and every ordinal and token, land in
    /// `remaining`, matching how Yours Wallet reports them.
    public static func from(scan: [ScannedOutput]) -> SweepPlan {
        var fundable: [SpendableUTXO] = []
        var ordinals: [OutputRef] = []
        var tokens: [TokenRef] = []
        var locked: [LockedRef] = []
        var bsv20: [OutputRef] = []
        var run: [OutputRef] = []
        var skipped: [OutputRef] = []
        var twetch: [OutputRef] = []

        for output in scan where !RetiredTokens.contains(output.kind) {
            let ref = OutputRef(txid: output.txid, vout: output.vout)
            switch output.kind {
            case .fundable:
                fundable.append(output.spendable)
            case .ordinal:
                ordinals.append(ref)
            case .bsv21(let tokenID):
                tokens.append(
                    TokenRef(tokenID: tokenID, txid: output.txid, vout: output.vout,
                             amount: output.satoshis)
                )
            case .locked(let until):
                locked.append(
                    LockedRef(txid: output.txid, vout: output.vout, satoshis: output.satoshis,
                              until: until)
                )
            case .bsv20:
                bsv20.append(ref)
            case .run:
                run.append(ref)
            case .unspendable:
                skipped.append(ref)
            case .twetch:
                twetch.append(ref)
            }
        }

        return SweepPlan(
            fundable: fundable,
            remaining: RemainingAssets(
                ordinals: ordinals, bsv21: tokens, locked: locked,
                bsv20: bsv20, run: run, skipped: skipped, twetch: twetch
            )
        )
    }
}

/// What a plain sweep leaves behind — the reason the source keys are preserved and the account is
/// marked as still holding assets.
public struct RemainingAssets: Equatable, Sendable {
    public let ordinals: [OutputRef]
    public let bsv21: [TokenRef]
    public let locked: [LockedRef]
    /// Tick-based BSV-20 token outputs.
    public let bsv20: [OutputRef]
    /// Outputs of a RUN transaction, held back so RUN tokens are not spent as BSV.
    public let run: [OutputRef]
    /// 0-sat outputs. Nothing to sweep, but they are reported rather than hidden.
    public let skipped: [OutputRef]
    /// Twetch NFTs. No sweep can move them, so they stay on the key.
    public let twetch: [OutputRef]

    public init(
        ordinals: [OutputRef], bsv21: [TokenRef], locked: [LockedRef],
        bsv20: [OutputRef] = [], run: [OutputRef] = [], skipped: [OutputRef] = [],
        twetch: [OutputRef] = []
    ) {
        self.ordinals = ordinals
        self.bsv21 = bsv21
        self.locked = locked
        self.bsv20 = bsv20
        self.run = run
        self.skipped = skipped
        self.twetch = twetch
    }

    /// True when the sweep took everything and the source keys can be discarded.
    public var isEmpty: Bool {
        ordinals.isEmpty && bsv21.isEmpty && locked.isEmpty && bsv20.isEmpty && run.isEmpty
            && skipped.isEmpty && twetch.isEmpty
    }

    /// The earliest block height at which some locked output becomes spendable, if any. A wallet
    /// uses this to schedule a re-sweep rather than making the user remember.
    public var nextUnlockHeight: UInt64? {
        locked.map(\.until).filter { $0 > 0 }.min()
    }
}

public struct OutputRef: Hashable, Sendable {
    public let txid: String
    public let vout: UInt32
    public init(txid: String, vout: UInt32) { self.txid = txid; self.vout = vout }
}

public struct TokenRef: Equatable, Sendable {
    public let tokenID: String
    public let txid: String
    public let vout: UInt32
    public let amount: UInt64
    public init(tokenID: String, txid: String, vout: UInt32, amount: UInt64) {
        self.tokenID = tokenID
        self.txid = txid
        self.vout = vout
        self.amount = amount
    }
}

public struct LockedRef: Equatable, Sendable {
    public let txid: String
    public let vout: UInt32
    public let satoshis: UInt64
    /// Block height (or timestamp) the lock releases at. `0` when the indexer did not report it.
    public let until: UInt64
    public init(txid: String, vout: UInt32, satoshis: UInt64, until: UInt64) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.until = until
    }
}
