import BigInt
import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import OneSatActions
import OneSatColor
import OneSatSweep
import ToolboxActions

// Not in skein-amm: what a swap's staging spends, what each leg's funding BEEF carries to the
// validator, and why a leg failed, kept as the exchange said it.
//
// The validator checks the funding BEEF of every leg: the staging transaction and each of its
// unproven ancestors. The TS page stages from whatever change storage picks (wallet-toolbox
// 2.14.5 on: a plan from proven sources first, widened to unproven and sending ones when that
// cannot fund it or costs more bytes; 2.1.x: the smallest sufficient output, proven or not), so a
// wallet whose recent change is a long unproven chain can send the validator all of it. Here the
// staging is funded first from the change basket's
// confirmed outputs, chosen by the page: createAction `noSend` with `noSendChange` (storage
// spends those before any other change, the last listed first), then a send-only processAction
// (`sendWith`) broadcasts it (`ColorExecutor.executeFunded`).
//
// Every ranked coin is offered, not only enough for the payment: storage's change generation
// (wallet-toolbox generateChangeSdk) also funds new change outputs toward the basket's
// `numberOfDesiredUTXOs`, each `minimumDesiredUTXOValue`, and takes those inputs from
// `noSendChange` first, then from its own change. Offering the whole ranking keeps every input
// it adds to the order chosen here. A staging storage cannot fund throws
// `WERR_INSUFFICIENT_FUNDS` leaving no coin marked spent (`WalletShortfall`).

/// One output of the wallet's change basket, as a swap's staging ranks it.
public struct OpenExchangeFundingCoin: Equatable, Sendable {
    /// `<txid>.<vout>`.
    public let outpoint: String
    public let satoshis: UInt64
    /// Its transaction has a merkle path.
    public let proven: Bool
    /// The bytes of its transaction and that transaction's unproven ancestry (0 when proven).
    public let unprovenBytes: Int

    public init(outpoint: String, satoshis: UInt64, proven: Bool, unprovenBytes: Int) {
        self.outpoint = outpoint
        self.satoshis = satoshis
        self.proven = proven
        self.unprovenBytes = unprovenBytes
    }
}

public enum OpenExchangeSwapFunding {
    static let beefLimits = WalletBEEFLimits.standard

    /// Actions are read this many to a page.
    static let actionPageLimit: UInt32 = 1_000

    /// Every action with `labels` (none: every action), a page at a time until a short page.
    static func allActions(_ ctx: OneColorContext, labels: [String]) async throws -> [WalletAction] {
        var actions: [WalletAction] = []
        while true {
            let page = try await ctx.storage.colorListActions(ctx.auth, try WalletListActionsRequest(
                labels: labels, pagination: try WalletPagination(limit: actionPageLimit, offset: UInt32(actions.count))
            ))
            actions += page.actions
            if page.actions.count < Int(actionPageLimit) { return actions }
        }
    }

    /// The change basket (`default`) with its source transactions, every page, ranked. Outputs
    /// of a transaction not yet broadcast (its action `nosend` or `sending`, every action read)
    /// are left out, as storage's own allocation leaves them.
    public static func coins(_ ctx: OneColorContext) async throws -> [OpenExchangeFundingCoin] {
        var outputs: [WalletOutput] = []
        var beef = try BEEF(version: .v2, merklePaths: [], transactions: [], limits: beefLimits)
        while true {
            let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
                basket: OneSatConstants.fundingBasket, include: .entireTransactions,
                pagination: try WalletPagination(limit: OneColorConstants.listPageLimit, offset: UInt32(outputs.count))
            ))
            outputs += page.outputs
            if let pageBEEF = page.beef { beef = try beef.merging(pageBEEF, limits: beefLimits) }
            if page.outputs.count < Int(OneColorConstants.listPageLimit) { break }
        }
        guard !outputs.isEmpty else { return [] }
        let unsent = Set(try await allActions(ctx, labels: [])
            .filter { $0.status == .nosend || $0.status == .sending }.map(\.transactionID))
        return try rank(outputs.filter { !unsent.contains($0.outpoint.transactionID) }, beef: beef)
    }

    /// The spendable outputs with sats, best first: proven first, then the fewest bytes of
    /// unproven ancestry, then the most sats, then by outpoint. No size cap.
    public static func rank(_ outputs: [WalletOutput], beef: BEEF) throws -> [OpenExchangeFundingCoin] {
        let ancestry = try ColorBEEF.Ancestry(beef)
        var coins: [OpenExchangeFundingCoin] = []
        var seen: Set<String> = []
        for output in outputs where output.spendable && output.satoshis > 0 {
            let outpoint = output.outpoint.description
            guard seen.insert(outpoint).inserted else { continue }
            let a = try ancestry.of(output.outpoint.transactionID)
            coins.append(OpenExchangeFundingCoin(outpoint: outpoint, satoshis: output.satoshis, proven: a.proven, unprovenBytes: a.unprovenBytes))
        }
        return coins.sorted(by: better)
    }

    static func better(_ a: OpenExchangeFundingCoin, _ b: OpenExchangeFundingCoin) -> Bool {
        if a.proven != b.proven { return a.proven }
        if a.unprovenBytes != b.unprovenBytes { return a.unprovenBytes < b.unprovenBytes }
        if a.satoshis != b.satoshis { return a.satoshis > b.satoshis }
        return a.outpoint < b.outpoint
    }

    /// The best coins, in rank order, until they cover `need`; all of them when they do not
    /// (storage then adds what it picks itself, and the report logs it).
    public static func pick(_ ranked: [OpenExchangeFundingCoin], need: UInt64) -> [OpenExchangeFundingCoin] {
        var picked: [OpenExchangeFundingCoin] = []
        var total: UInt64 = 0
        for coin in ranked {
            if total >= need { break }
            picked.append(coin)
            let (sum, overflow) = total.addingReportingOverflow(coin.satoshis)
            total = overflow ? .max : sum
        }
        return picked
    }

    /// What the chosen change must cover: the outputs less the caller's inputs, the miner fee
    /// allowance (`legMinerFeeSats`, a ~13 kB transaction: far more than a staging), and one sat
    /// of change.
    public static func need(outputs: UInt64, callerInputs: UInt64, feeRateSatsPerKb: Double) -> UInt64 {
        let fee = (try? OpenExchangeQuotes.legMinerFeeSats(feeRateSatsPerKb)).flatMap { UInt64(exactly: $0) } ?? 0
        let net = outputs > callerInputs ? outputs - callerInputs : 0
        let (sum, overflow) = net.addingReportingOverflow(fee + 1)
        return overflow ? .max : sum
    }

    /// The funding of a staging action: the whole ranked change basket, best spent first (the
    /// picks for `need` are logged as what covers the payment; storage may spend more of the
    /// ranking for the change outputs it adds). Nil when the basket holds no coin, or cannot be
    /// read (logged; the staging then goes as the TS sends it, storage choosing the change).
    static func funding(
        _ ctx: OneColorContext, need: UInt64, what: String, onFunding: (@Sendable (ColorFundingReport) -> Void)?
    ) async -> ColorFunding? {
        let ranked: [OpenExchangeFundingCoin]
        do {
            ranked = try await coins(ctx)
        } catch {
            OneSatLog.error(error, "OpenExchange \(what): the change basket could not be read to choose its coins; storage chooses them", category: OpenExchange.logCategory)
            return nil
        }
        guard !ranked.isEmpty else {
            OneSatLog.notice("OpenExchange \(what): the change basket lists no coin to choose; storage chooses them", category: OpenExchange.logCategory)
            return nil
        }
        let picked = pick(ranked, need: need)
        let text = picked.map { "\($0.outpoint) (\($0.satoshis) sats, \($0.proven ? "proven" : "unproven \($0.unprovenBytes) bytes"))" }
        OneSatLog.notice("OpenExchange \(what): \(need) sats covered by the change basket's best coins [\(text.joined(separator: ", "))]; all \(ranked.count) offered in rank order", category: OpenExchange.logCategory)
        var coins: [ColorFundingCoin] = []
        for coin in ranked {
            guard let outpoint = try? Outpoint(coin.outpoint) else { continue }
            coins.append(ColorFundingCoin(outpoint: outpoint, satoshis: coin.satoshis))
        }
        guard !coins.isEmpty else { return nil }
        return ColorFunding(coins: coins) { report in
            if report.fellBack != nil {
                OneSatLog.error("OpenExchange \(what): \(report.text)", category: OpenExchange.logCategory)
            } else {
                OneSatLog.notice("OpenExchange \(what): \(report.text)", category: OpenExchange.logCategory)
            }
            onFunding?(report)
        }
    }
}

/// The funding report of one staging, kept for its `OpenExchangeStaged`.
final class OpenExchangeFundingReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: ColorFundingReport?

    func set(_ report: ColorFundingReport) { lock.lock(); self.report = report; lock.unlock() }

    var value: ColorFundingReport? { lock.lock(); defer { lock.unlock() }; return report }
}

// MARK: - The funding BEEF a leg sends

/// What a leg's funding BEEF carries to the validator (not in the TS): its size, its
/// transactions, how many are proven, and the unproven ones the swap basket's rows spend from.
public struct OpenExchangeFundingStats: Equatable, Sendable {
    /// The Atomic BEEF's bytes.
    public let bytes: Int
    /// Every record, transaction-ID-only ones included.
    public let txCount: Int
    public let provenCount: Int
    /// Raw records with no merkle path, the rows' own transactions included.
    public let unprovenCount: Int
    public let unprovenBytes: Int
    /// The unproven records that are not the rows' own transactions: their unproven ancestry.
    public let unprovenAncestors: Int
    public let largestUnprovenTxid: String?
    public let largestUnprovenBytes: Int

    public init(
        bytes: Int, txCount: Int, provenCount: Int, unprovenCount: Int, unprovenBytes: Int, unprovenAncestors: Int,
        largestUnprovenTxid: String?, largestUnprovenBytes: Int
    ) {
        self.bytes = bytes
        self.txCount = txCount
        self.provenCount = provenCount
        self.unprovenCount = unprovenCount
        self.unprovenBytes = unprovenBytes
        self.unprovenAncestors = unprovenAncestors
        self.largestUnprovenTxid = largestUnprovenTxid
        self.largestUnprovenBytes = largestUnprovenBytes
    }

    /// The stats of an Atomic funding BEEF whose rows' transactions are `rows`.
    public static func of(atomicBEEF bytes: [UInt8], rows: [String]) throws -> OpenExchangeFundingStats {
        // Read as the plain BEEF it wraps (after the Atomic prefix and subject txid): the stats
        // count every record sent, whether or not it is the subject's ancestor.
        let body = bytes.starts(with: [0x01, 0x01, 0x01, 0x01]) && bytes.count > 36 ? Array(bytes.dropFirst(36)) : bytes
        let beef = try BEEF(bytes: body, limits: OpenExchangeSwapLeg.beefLimits, transactionOrder: .any)
        let ancestry = try ColorBEEF.Ancestry(beef)
        let own = Set(rows)
        var proven = 0, unproven = 0, unprovenBytes = 0, ancestors = 0
        var largest: (txid: String, bytes: Int)?
        for entry in beef.transactions {
            guard let tx = entry.transaction else { continue }
            let id = try tx.transactionID(limits: OpenExchangeSwapLeg.txLimits)
            if ancestry.proven(id) {
                proven += 1
                continue
            }
            let size = try tx.serializedByteCount(limits: OpenExchangeSwapLeg.txLimits)
            unproven += 1
            unprovenBytes += size
            if !own.contains(id.displayHex) { ancestors += 1 }
            if size > largest?.bytes ?? -1 { largest = (id.displayHex, size) }
        }
        return OpenExchangeFundingStats(
            bytes: bytes.count, txCount: beef.transactions.count, provenCount: proven, unprovenCount: unproven,
            unprovenBytes: unprovenBytes, unprovenAncestors: ancestors, largestUnprovenTxid: largest?.txid,
            largestUnprovenBytes: largest?.bytes ?? 0
        )
    }

    /// One line for the log.
    public var text: String {
        "\(bytes) bytes, \(txCount) transactions (\(provenCount) proven, \(unprovenCount) unproven of \(unprovenBytes) bytes, \(unprovenAncestors) of them ancestors)"
            + (largestUnprovenTxid.map { ", largest unproven \($0) (\(largestUnprovenBytes) bytes)" } ?? "")
    }
}

// MARK: - Why a leg failed

/// Why a leg did not fill, as the exchange said it (not in the TS, whose page keeps only the
/// pool's exclusion). `detail` is one line; `raw` is the outcome's reason in full.
public struct OpenExchangeLegFailure: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// The validator (or the host's own rule) refused the swap: `code` is its reason.
        case refused
        /// The host answered with an error, not a swap reply: `code` is its error code.
        case hostError
        /// The validator could not check the swap (it answered no frame): `code` is its verdict.
        case validatorFailed
        /// No answer in time, or the host could not reach the validator.
        case noAnswer
    }

    public let kind: Kind
    public let code: String
    public let detail: String
    /// The pool's outpoint, `<txid>_<vout>`.
    public let pool: String
    public let raw: String
    /// The leg's funding BEEF, as it was sent.
    public let funding: OpenExchangeFundingStats?

    public init(kind: Kind, code: String, detail: String, pool: String, raw: String, funding: OpenExchangeFundingStats? = nil) {
        self.kind = kind
        self.code = code
        self.detail = detail
        self.pool = pool
        self.raw = raw
        self.funding = funding
    }

    /// The failure an outcome reports; nil for an accepted leg. Reads the reasons as
    /// `relayLeg` writes them.
    public init?(_ outcome: OpenExchangeLegOutcome, pool: String, funding: OpenExchangeFundingStats? = nil) {
        guard let parsed = Self.parse(outcome) else { return nil }
        self.init(kind: parsed.0, code: parsed.1, detail: Self.oneLine(parsed.2), pool: pool, raw: parsed.3, funding: funding)
    }

    static func parse(_ outcome: OpenExchangeLegOutcome) -> (Kind, String, String, String)? {
        func split(_ text: String) -> (String, String) {
            guard let colon = text.range(of: ": ") else { return (text, text) }
            return (String(text[..<colon.lowerBound]), String(text[colon.upperBound...]))
        }
        switch outcome {
        case .accepted:
            return nil
        case .refused(_, let reason, _):
            let (code, detail) = split(reason)
            return (.refused, code, detail, reason)
        case .failed(let reason):
            let (code, detail) = split(reason.hasPrefix("swap: ") ? String(reason.dropFirst("swap: ".count)) : reason)
            return (.hostError, code, detail, reason)
        case .unknown(_, let reason):
            let (kind, code, detail) = noAnswer(reason)
            return (kind, code, detail, reason)
        }
    }

    /// `unknown`'s reason: the host's `unreachable` detail, a validator that answered no frame
    /// (`this node's validator answered no frame (<verdict>: <reason>)`, skein's relay), or no
    /// answer at all.
    static func noAnswer(_ reason: String) -> (Kind, String, String) {
        let unreachable = "\(OpenExchange.noAnswerYet): the host could not reach the validator ("
        guard reason.hasPrefix(unreachable), reason.hasSuffix(")") else {
            let prefix = "\(OpenExchange.noAnswerYet): "
            return (.noAnswer, "", reason.hasPrefix(prefix) ? String(reason.dropFirst(prefix.count)) : reason)
        }
        let inner = String(reason.dropFirst(unreachable.count).dropLast())
        let why = inner.hasPrefix("unreachable: ") ? String(inner.dropFirst("unreachable: ".count)) : inner == "unreachable" ? "" : inner
        let noFrame = "answered no frame ("
        if let at = why.range(of: noFrame), why.hasSuffix(")") {
            let verdict = String(why[at.upperBound...].dropLast())
            if let colon = verdict.range(of: ": ") {
                return (.validatorFailed, String(verdict[..<colon.lowerBound]), String(verdict[colon.upperBound...]))
            }
            return (.validatorFailed, verdict, verdict)
        }
        let host = "the validator's host: "
        if why.hasPrefix(host) { return (.validatorFailed, "host", String(why.dropFirst(host.count))) }
        return (.noAnswer, "unreachable", why.isEmpty ? "the host could not reach the validator" : why)
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
