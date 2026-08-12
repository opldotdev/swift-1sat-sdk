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

    public init(
        txid: String, vout: UInt32, satoshis: UInt64, lockingScript: [UInt8], events: [String]
    ) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.lockingScript = lockingScript
        self.events = events
    }

    /// What kind of asset this output is, from its tags.
    public var kind: AssetKind {
        if let token = events.first(where: { $0.hasPrefix("bsv21:") }) {
            return .bsv21(tokenID: String(token.dropFirst("bsv21:".count)))
        }
        if let lock = events.first(where: { $0.hasPrefix("lock:") }) {
            let until = UInt64(lock.dropFirst("lock:".count)) ?? 0
            return .locked(until: until)
        }
        if events.contains(where: { $0.hasPrefix("ord") || $0.hasPrefix("insc") }) {
            return .ordinal
        }
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

        for output in scan {
            switch output.kind {
            case .fundable:
                fundable.append(output.spendable)
            case .ordinal:
                ordinals.append(OutputRef(txid: output.txid, vout: output.vout))
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
            }
        }

        return SweepPlan(
            fundable: fundable,
            remaining: RemainingAssets(ordinals: ordinals, bsv21: tokens, locked: locked)
        )
    }
}

/// What a plain sweep leaves behind — the reason the source keys are preserved and the account is
/// marked as still holding assets.
public struct RemainingAssets: Equatable, Sendable {
    public let ordinals: [OutputRef]
    public let bsv21: [TokenRef]
    public let locked: [LockedRef]

    public init(ordinals: [OutputRef], bsv21: [TokenRef], locked: [LockedRef]) {
        self.ordinals = ordinals
        self.bsv21 = bsv21
        self.locked = locked
    }

    /// True when the sweep took everything and the source keys can be discarded.
    public var isEmpty: Bool { ordinals.isEmpty && bsv21.isEmpty && locked.isEmpty }

    /// The earliest block height at which some locked output becomes spendable, if any. A wallet
    /// uses this to schedule a re-sweep rather than making the user remember.
    public var nextUnlockHeight: UInt64? {
        locked.map(\.until).filter { $0 > 0 }.min()
    }
}

public struct OutputRef: Equatable, Sendable {
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
