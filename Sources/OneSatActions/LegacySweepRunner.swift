import Foundation
import BSVKeys
import BSVTransaction
import OneSatClient
import OneSatSweep

/// Runs a legacy key's whole sweep one step at a time: BSV, ordinals, OpNS, BSV-20, BSV-21.
///
/// Mirrors `@1sat/sweep-ui` `sweeper.ts` `sweepAllClasses`: every step is caught on its own, a
/// failure is recorded and the later classes still run, and every broadcast txid is kept. Within
/// the ordinal and OpNS classes a failed batch stops that class, as TS does. The decisions live
/// here so they can be tested without a wallet; the network and wallet work is injected as
/// ``Steps``.
///
/// What is held back is reported, never dropped: every scanned outpoint that was not spent ends up
/// in ``Report/leftovers`` with its reason, and locks in ``Report/locked``.
public enum LegacySweepRunner {
    /// The class an outpoint belongs to, in the order the runner sweeps them.
    public enum SweepClass: String, Equatable, Hashable, Sendable {
        case bsv
        case ordinals
        case opns
        case bsv20
        case bsv21
        /// An output of a RUN transaction, never spent as BSV.
        case run
        /// A 0-sat output.
        case unspendable
        /// A Twetch NFT. No sweep moves it.
        case twetch

        /// The classes a sweep can move, in run order (`sweeper.ts` `SweepClass`).
        public static let transferable: [SweepClass] = [.bsv, .ordinals, .opns, .bsv20, .bsv21]
    }

    /// Sweep is disabled only when every class available now is skipped (`sweeper.ts`
    /// `isSweepAllDisabled`). Comparing counts would strand the button on a stale skip after a
    /// rescan drops a class.
    public static func isSweepAllDisabled(available: [SweepClass], skipped: Set<SweepClass>) -> Bool {
        available.allSatisfy { skipped.contains($0) }
    }

    /// Show the class skip toggles when there is a choice, or a skip to clear (`sweeper.ts`
    /// `showClassSkips`).
    public static func showClassSkips(available: [SweepClass], skipped: Set<SweepClass>) -> Bool {
        available.count > 1 || !skipped.isEmpty
    }

    /// Why an outpoint was not swept.
    public enum LeftoverReason: Equatable, Hashable, Sendable {
        /// Its step, or the batch it was in, failed (see ``Report/failures``).
        case stepFailed
        /// An earlier batch of its class failed, so this batch was not attempted (TS stops the
        /// class there).
        case notAttempted
        /// An inscription that is not exactly 1 sat; the ordinal transfer moves 1-sat outputs only.
        case notOneSat
        /// A token output whose amount could not be read.
        case unreadableTokenAmount
        /// The token listing could not be read, so no token, ordinal or OpNS output is moved:
        /// without it a token could be moved as a bare ordinal.
        case tokenListingUnavailable
        /// The BSV-21 overlay did not report it valid, so the transfer left it.
        case notValidOnOverlay
        /// The token listing names it, but the scan did not return it.
        case notInScan
        /// An ordinal or OpNS output the token listing did not return, so it was never checked
        /// for inscription token data and is not moved as a bare ordinal.
        case notInTokenListing
        /// The action returned a txid together with an error: it may be on chain. Check the txid
        /// (kept in the report) before sweeping these again.
        case broadcastUnconfirmed
        /// The source transaction carries a RUN output.
        case runTransaction
        /// 0 sats.
        case zeroSatoshis
        /// A Twetch NFT: unlocking it needs a hash preimage as well as the key, and sending one
        /// is not supported.
        case twetchNotSupported
        /// Its class was skipped for this run (`sweeper.ts` `SweepClassSelection`). It stays on
        /// the key for a later run.
        case skipped
    }

    public struct Leftover: Equatable, Hashable, Sendable {
        public let sweepClass: SweepClass
        public let outpoint: OutputRef
        public let reason: LeftoverReason

        public init(sweepClass: SweepClass, outpoint: OutputRef, reason: LeftoverReason) {
            self.sweepClass = sweepClass
            self.outpoint = outpoint
            self.reason = reason
        }
    }

    /// One failed step. `message` is the full error text, for the log; a screen shows `label`.
    public struct StepFailure: Equatable, Sendable {
        public let sweepClass: SweepClass
        /// e.g. `BSV`, `Ordinals batch 2/3`, `BSV-20 PEPE`.
        public let label: String
        public let message: String

        public init(sweepClass: SweepClass, label: String, message: String) {
            self.sweepClass = sweepClass
            self.label = label
            self.message = message
        }
    }

    public struct Report: Equatable, Sendable {
        public var bsvTxids: [String] = []
        public var ordinalTxids: [String] = []
        public var opnsTxids: [String] = []
        public var bsv20Txids: [String] = []
        public var bsv21Txids: [String] = []
        public var failures: [StepFailure] = []
        public var leftovers: [Leftover] = []
        /// Locked outputs: never swept here (they need a lock-specific unlock).
        public var locked: [LockedRef] = []
        /// Every outpoint a broadcast transaction spent.
        public var sweptOutpoints: [OutputRef] = []
        /// Swept outpoints that were marketplace listings, cancelled into the wallet.
        public var cancelledListings: [OutputRef] = []
        /// Satoshis of the BSV inputs that were swept, before the fee.
        public var sweptSatoshis: UInt64 = 0
        /// BSV-21 sweeps that went on chain but were not filed with the overlay.
        public var unfiledTokenSweeps = 0

        public init() {}

        /// Every txid, in sweep order.
        public var txids: [String] { bsvTxids + ordinalTxids + opnsTxids + bsv20Txids + bsv21Txids }

        /// This report followed by `other` (another key's run).
        public func merging(_ other: Report) -> Report {
            var merged = self
            merged.bsvTxids += other.bsvTxids
            merged.ordinalTxids += other.ordinalTxids
            merged.opnsTxids += other.opnsTxids
            merged.bsv20Txids += other.bsv20Txids
            merged.bsv21Txids += other.bsv21Txids
            merged.failures += other.failures
            merged.leftovers += other.leftovers
            merged.locked += other.locked
            merged.sweptOutpoints += other.sweptOutpoints
            merged.cancelledListings += other.cancelledListings
            let (sum, overflow) = merged.sweptSatoshis.addingReportingOverflow(other.sweptSatoshis)
            merged.sweptSatoshis = overflow ? .max : sum
            merged.unfiledTokenSweeps += other.unfiledTokenSweeps
            return merged
        }
    }

    /// The token listing for the key's address, from ``OneSatClient/tokenOutputs(forAddress:)``
    /// and ``OneSatClient/unreadableTokenOutputs(forAddress:)``.
    public enum TokenListing: Sendable {
        /// `listed` is every unspent outpoint the listing read returned, token or not.
        case listed(outputs: [TokenOutput], unreadable: [OutputRef], listed: Set<OutputRef>)
        /// The listing request failed. `reason` is recorded as a step failure.
        case unavailable(reason: String)
        /// The listing from one ``OneSatClient/tokenInventory(forAddress:)`` read.
        public static func listed(_ inventory: TokenInventory) -> TokenListing {
            .listed(outputs: inventory.outputs, unreadable: inventory.unreadable, listed: inventory.listed)
        }
    }

    /// One legacy key and what was read for its address.
    public struct KeyInput: Sendable {
        public let key: PrivateKey
        /// ``OneSatScanner/scan(address:)`` of the key's address.
        public let scanned: [ScannedOutput]
        /// ``OneSatClient/ordinals(forAddress:)``: content types for the destination tags. May be
        /// empty; the scan's own `type:` events are used first.
        public let ordinalMetadata: [OrdinalOutput]
        public let tokens: TokenListing

        public init(key: PrivateKey, scanned: [ScannedOutput], ordinalMetadata: [OrdinalOutput], tokens: TokenListing) {
            self.key = key
            self.scanned = scanned
            self.ordinalMetadata = ordinalMetadata
            self.tokens = tokens
        }
    }

    /// The step about to run, for a progress line (`sweeper.ts` `onProgress`). `label` is the one a
    /// failure of the step carries, e.g. `BSV`, `Ordinals batch 2/3`, `BSV-21 PEPE`.
    public struct Stage: Equatable, Sendable {
        public let sweepClass: SweepClass
        public let label: String
        /// How many outputs the step spends.
        public let outputs: Int

        public init(sweepClass: SweepClass, label: String, outputs: Int) {
            self.sweepClass = sweepClass
            self.label = label
            self.outputs = outputs
        }
    }

    /// The wallet and network work, injected. ``standard(_:beef:checkpoint:progress:)`` wires the
    /// SDK's own actions.
    public struct Steps: Sendable {
        /// The merged BEEF for the source transactions of these `txid.vout` outpoints.
        public var beef: @Sendable (_ outpoints: [String]) async throws -> BEEF
        public var fundBsv: @Sendable (_ inputs: [AssetSweep.FundingInput], _ beef: BEEF) async -> ActionResult
        public var moveOrdinals: @Sendable (_ inputs: [AssetSweep.OrdinalInput], _ beef: BEEF) async -> ActionResult
        public var moveBsv20: @Sendable (_ inputs: [AssetSweep.TokenInput], _ beef: BEEF, _ decimals: Int) async -> ActionResult
        /// Throws when the token's details cannot be read; the batch is then recorded as failed.
        public var moveBsv21: @Sendable (
            _ tokenID: String, _ inputs: [AssetSweep.TokenInput], _ beef: BEEF, _ symbol: String?
        ) async throws -> AssetSweep.SweepBsv21Result
        /// Called before every broadcasting step. A throw stops the run (``Interrupted``).
        public var checkpoint: @Sendable () throws -> Void
        /// Called as each step starts, before its BEEF is read.
        public var progress: @Sendable (_ stage: Stage) async -> Void

        public init(
            beef: @escaping @Sendable (_ outpoints: [String]) async throws -> BEEF,
            fundBsv: @escaping @Sendable (_ inputs: [AssetSweep.FundingInput], _ beef: BEEF) async -> ActionResult,
            moveOrdinals: @escaping @Sendable (_ inputs: [AssetSweep.OrdinalInput], _ beef: BEEF) async -> ActionResult,
            moveBsv20: @escaping @Sendable (_ inputs: [AssetSweep.TokenInput], _ beef: BEEF, _ decimals: Int) async -> ActionResult,
            moveBsv21: @escaping @Sendable (
                _ tokenID: String, _ inputs: [AssetSweep.TokenInput], _ beef: BEEF, _ symbol: String?
            ) async throws -> AssetSweep.SweepBsv21Result,
            checkpoint: @escaping @Sendable () throws -> Void = {},
            progress: @escaping @Sendable (_ stage: Stage) async -> Void = { _ in }
        ) {
            self.beef = beef
            self.fundBsv = fundBsv
            self.moveOrdinals = moveOrdinals
            self.moveBsv20 = moveBsv20
            self.moveBsv21 = moveBsv21
            self.checkpoint = checkpoint
            self.progress = progress
        }

        /// `AssetSweep.bsv`, `.ordinals`, `.bsv20` and `.bsv21` on `ctx`. BSV-21 reads the token's
        /// fee details from `ctx.bsv21` (fresh) and does not move a token the overlay reports
        /// inactive: sweep-ui leaves those out because they cannot be validated.
        public static func standard(
            _ ctx: OneSatContext,
            beef: @escaping @Sendable (_ outpoints: [String]) async throws -> BEEF,
            checkpoint: @escaping @Sendable () throws -> Void = {},
            progress: @escaping @Sendable (_ stage: Stage) async -> Void = { _ in }
        ) -> Steps {
            Steps(
                beef: beef,
                fundBsv: { await AssetSweep.bsv(ctx, inputs: $0, inputBEEF: $1) },
                moveOrdinals: { await AssetSweep.ordinals(ctx, inputs: $0, inputBEEF: $1) },
                moveBsv20: { await AssetSweep.bsv20(ctx, inputs: $0, inputBEEF: $1, decimals: $2) },
                moveBsv21: { tokenID, inputs, beef, symbol in
                    guard let overlay = ctx.bsv21 else { throw OneSatActionError.servicesRequired }
                    let details = try await overlay.tokenDetails(tokenId: tokenID, fresh: true)
                    guard details.isActive else { throw RunnerError.inactiveToken(tokenID) }
                    return await AssetSweep.bsv21(
                        ctx, inputs: inputs, inputBEEF: beef,
                        feeAddress: details.feeAddress, feePerOutput: details.feePerOutput,
                        symbol: details.symbol ?? symbol, decimals: details.decimals
                    )
                },
                checkpoint: checkpoint,
                progress: progress
            )
        }
    }

    /// The checkpoint stopped the run. `report` holds everything done before it.
    public struct Interrupted: Error, CustomDebugStringConvertible {
        public let report: Report
        public let underlying: any Error

        public var debugDescription: String {
            "LegacySweepRunner.Interrupted after \(report.txids.count) transaction(s): \(String(reflecting: underlying))"
        }
    }

    enum RunnerError: LocalizedError, Equatable {
        case noTransactionID
        case inactiveToken(String)

        var errorDescription: String? {
            switch self {
            case .noTransactionID: "Sweep returned no transaction ID"
            case .inactiveToken(let id): "Token \(id) is not active on the overlay, so its outputs cannot be validated"
            }
        }
    }

    // MARK: - Plan

    /// What the runner will do with one key's outputs, before any step runs.
    public struct Plan: Equatable, Sendable {
        public var funding: [ScannedOutput] = []
        public var ordinals: [ScannedOutput] = []
        public var opns: [ScannedOutput] = []
        /// BSV-20 outputs by tick, in first-seen order.
        public var bsv20: [TokenGroup] = []
        /// BSV-21 outputs by token id, in first-seen order.
        public var bsv21: [TokenGroup] = []
        public var leftovers: [Leftover] = []
        public var locked: [LockedRef] = []
        /// Set when the token listing was unavailable.
        public var tokenListingFailure: String?
    }

    public struct TokenGroup: Equatable, Sendable {
        public let tokenID: String
        public let decimals: Int
        public let symbol: String?
        public var outputs: [TokenItem]
    }

    public struct TokenItem: Equatable, Sendable {
        public let output: ScannedOutput
        public let amount: UInt64
    }

    /// Sorts a key's outputs into classes. Pure: no step runs.
    public static func plan(_ input: KeyInput) -> Plan {
        var plan = Plan()
        let rows: [OutputRef: TokenOutput]
        let unreadable: Set<OutputRef>
        let listingAvailable: Bool
        let listedRefs: Set<OutputRef>
        switch input.tokens {
        case .listed(let outputs, let unreadableRefs, let listed):
            listedRefs = listed
            var byRef: [OutputRef: TokenOutput] = [:]
            for row in outputs { byRef[OutputRef(txid: row.txid, vout: row.vout)] = row }
            rows = byRef
            unreadable = Set(unreadableRefs)
            listingAvailable = true
        case .unavailable(let reason):
            listedRefs = []
            rows = [:]
            unreadable = []
            listingAvailable = false
            plan.tokenListingFailure = reason
        }

        var bsv20Index: [String: Int] = [:]
        var bsv21Index: [String: Int] = [:]
        var scannedRefs = Set<OutputRef>()

        for output in input.scanned {
            let ref = OutputRef(txid: output.txid, vout: output.vout)
            scannedRefs.insert(ref)
            let kind = output.kind
            if case .locked(let until) = kind {
                plan.locked.append(LockedRef(txid: output.txid, vout: output.vout, satoshis: output.satoshis, until: until))
                continue
            }
            // The token listing reads inscription data the scan's events may lack (`scan.ts`
            // `isBsv21Output` / `isBsv20Output`), so a token it names never moves as BSV or as a
            // bare ordinal.
            if let row = rows[ref] {
                let item = TokenItem(output: output, amount: row.amount)
                switch row.kind {
                case .bsv20:
                    append(item, row: row, to: &plan.bsv20, index: &bsv20Index)
                case .bsv21:
                    append(item, row: row, to: &plan.bsv21, index: &bsv21Index)
                }
                continue
            }
            if unreadable.contains(ref) {
                plan.leftovers.append(Leftover(
                    sweepClass: tokenClass(kind), outpoint: ref, reason: .unreadableTokenAmount
                ))
                continue
            }
            switch kind {
            case .bsv20, .bsv21:
                plan.leftovers.append(Leftover(
                    sweepClass: tokenClass(kind), outpoint: ref,
                    reason: listingAvailable ? .unreadableTokenAmount : .tokenListingUnavailable
                ))
            case .fundable:
                plan.funding.append(output)
            case .run:
                plan.leftovers.append(Leftover(sweepClass: .run, outpoint: ref, reason: .runTransaction))
            case .unspendable:
                plan.leftovers.append(Leftover(sweepClass: .unspendable, outpoint: ref, reason: .zeroSatoshis))
            case .twetch:
                plan.leftovers.append(Leftover(sweepClass: .twetch, outpoint: ref, reason: .twetchNotSupported))
            case .ordinal:
                // `scan.ts`: a 1-sat `type:application/op-ns` output is OpNS.
                let sweepClass: SweepClass = output.events.contains("type:application/op-ns") ? .opns : .ordinals
                if !listingAvailable {
                    plan.leftovers.append(Leftover(sweepClass: sweepClass, outpoint: ref, reason: .tokenListingUnavailable))
                } else if !listedRefs.contains(ref) {
                    plan.leftovers.append(Leftover(sweepClass: sweepClass, outpoint: ref, reason: .notInTokenListing))
                } else if output.satoshis != 1 {
                    // `AssetSweep.ordinals` moves 1-sat outputs only; one such output must not
                    // block the rest of the class.
                    plan.leftovers.append(Leftover(sweepClass: sweepClass, outpoint: ref, reason: .notOneSat))
                } else if sweepClass == .opns {
                    plan.opns.append(output)
                } else {
                    plan.ordinals.append(output)
                }
            case .locked:
                break
            }
        }

        for (ref, row) in rows where !scannedRefs.contains(ref) {
            plan.leftovers.append(Leftover(
                sweepClass: row.kind == .bsv20 ? .bsv20 : .bsv21, outpoint: ref, reason: .notInScan
            ))
        }
        for ref in unreadable where !scannedRefs.contains(ref) {
            plan.leftovers.append(Leftover(sweepClass: .bsv21, outpoint: ref, reason: .notInScan))
        }
        plan.leftovers.sort { ($0.outpoint.txid, $0.outpoint.vout) < ($1.outpoint.txid, $1.outpoint.vout) }
        return plan
    }

    private static func tokenClass(_ kind: AssetKind) -> SweepClass {
        if case .bsv20 = kind { return .bsv20 }
        return .bsv21
    }

    private static func append(_ item: TokenItem, row: TokenOutput, to groups: inout [TokenGroup], index: inout [String: Int]) {
        if let position = index[row.tokenID] {
            groups[position].outputs.append(item)
        } else {
            index[row.tokenID] = groups.count
            groups.append(TokenGroup(tokenID: row.tokenID, decimals: row.decimals, symbol: row.symbol, outputs: [item]))
        }
    }

    // MARK: - Run

    /// The plan with every output of a `skipped` class moved to the leftovers as ``LeftoverReason/skipped``.
    /// `sweeper.ts` `sweepAllClasses` with a `selection`: a skipped class sweeps nothing. Here what
    /// it leaves is reported, so the key is kept for it.
    public static func skipping(_ skipped: Set<SweepClass>, in plan: Plan) -> Plan {
        guard !skipped.isEmpty else { return plan }
        var plan = plan
        func skip(_ sweepClass: SweepClass, _ outputs: [ScannedOutput]) {
            plan.leftovers += outputs.map { Leftover(sweepClass: sweepClass, outpoint: ref($0), reason: .skipped) }
        }
        if skipped.contains(.bsv) { skip(.bsv, plan.funding); plan.funding = [] }
        if skipped.contains(.ordinals) { skip(.ordinals, plan.ordinals); plan.ordinals = [] }
        if skipped.contains(.opns) { skip(.opns, plan.opns); plan.opns = [] }
        if skipped.contains(.bsv20) { skip(.bsv20, plan.bsv20.flatMap { $0.outputs.map(\.output) }); plan.bsv20 = [] }
        if skipped.contains(.bsv21) { skip(.bsv21, plan.bsv21.flatMap { $0.outputs.map(\.output) }); plan.bsv21 = [] }
        plan.leftovers.sort { ($0.outpoint.txid, $0.outpoint.vout) < ($1.outpoint.txid, $1.outpoint.vout) }
        return plan
    }

    /// Sweeps one key, leaving every class in `skipped` where it is. Throws only ``Interrupted``,
    /// when `steps.checkpoint` throws; every other failure is in the returned report.
    public static func run(_ input: KeyInput, steps: Steps, skipping skipped: Set<SweepClass> = []) async throws -> Report {
        let plan = skipping(skipped, in: plan(input))
        var report = Report()
        report.leftovers = plan.leftovers
        report.locked = plan.locked
        if let reason = plan.tokenListingFailure {
            report.failures.append(StepFailure(sweepClass: .bsv21, label: "Token listing", message: reason))
        }

        // Everything the run would spend, so an interruption can report what it never reached.
        var planned: [(SweepClass, OutputRef)] = plan.funding.map { (.bsv, ref($0)) }
            + plan.ordinals.map { (.ordinals, ref($0)) } + plan.opns.map { (.opns, ref($0)) }
        planned += plan.bsv20.flatMap { $0.outputs.map { (.bsv20, ref($0.output)) } }
        planned += plan.bsv21.flatMap { $0.outputs.map { (.bsv21, ref($0.output)) } }
        let allPlanned = planned

        func checkpoint() throws {
            do {
                try steps.checkpoint()
            } catch {
                var partial = report
                let accounted = Set(partial.sweptOutpoints).union(partial.leftovers.map(\.outpoint))
                partial.leftovers += allPlanned.filter { !accounted.contains($0.1) }.map {
                    Leftover(sweepClass: $0.0, outpoint: $0.1, reason: .notAttempted)
                }
                throw Interrupted(report: partial, underlying: error)
            }
        }

        // BSV (`sweepFundingStep`): one action for every funding output.
        if !plan.funding.isEmpty {
            let refs = plan.funding.map(ref)
            await steps.progress(Stage(sweepClass: .bsv, label: "BSV", outputs: refs.count))
            do {
                let beef = try await steps.beef(plan.funding.map(outpoint))
                try checkpoint()
                let inputs = plan.funding.map {
                    AssetSweep.FundingInput(
                        outpoint: outpoint($0), satoshis: $0.satoshis, lockingScript: $0.lockingScript, key: input.key
                    )
                }
                let txid = try transactionID(await steps.fundBsv(inputs, beef))
                report.bsvTxids.append(txid)
                record(swept: refs, of: plan.funding, in: &report)
                for output in plan.funding {
                    let (sum, overflow) = report.sweptSatoshis.addingReportingOverflow(output.satoshis)
                    report.sweptSatoshis = overflow ? .max : sum
                }
            } catch let interrupted as Interrupted {
                throw interrupted
            } catch {
                fail(.bsv, label: "BSV", error: error, outpoints: refs, in: &report)
            }
        }

        // Ordinals then OpNS (`sweepOrdinalBatches`): 25 per transaction, BEEF per batch, a
        // failed batch stops the class.
        for (sweepClass, outputs) in [(SweepClass.ordinals, plan.ordinals), (.opns, plan.opns)] where !outputs.isEmpty {
            let name = sweepClass == .opns ? "OpNS" : "Ordinals"
            let batches = AssetSweep.batches(outputs)
            for (index, batch) in batches.enumerated() {
                let label = batches.count == 1 ? name : "\(name) batch \(index + 1)/\(batches.count)"
                let refs = batch.map(ref)
                await steps.progress(Stage(sweepClass: sweepClass, label: label, outputs: refs.count))
                do {
                    let beef = try await steps.beef(batch.map(outpoint))
                    try checkpoint()
                    let inputs = batch.map { ordinalInput($0, metadata: input.ordinalMetadata, key: input.key) }
                    let txid = try transactionID(await steps.moveOrdinals(inputs, beef))
                    keep(txid, sweepClass, in: &report)
                    record(swept: refs, of: batch, in: &report)
                } catch let interrupted as Interrupted {
                    throw interrupted
                } catch {
                    fail(sweepClass, label: label, error: error, outpoints: refs, in: &report)
                    for later in batches[(index + 1)...] {
                        report.leftovers += later.map {
                            Leftover(sweepClass: sweepClass, outpoint: ref($0), reason: .notAttempted)
                        }
                    }
                    break
                }
            }
        }

        // BSV-20 (`sweepBsv20Token` with `splitListed`): listed outputs one per transaction.
        for group in plan.bsv20 {
            for batch in AssetSweep.listedBatches(group.outputs, events: { $0.output.events }) {
                let refs = batch.map { ref($0.output) }
                await steps.progress(Stage(sweepClass: .bsv20, label: "BSV-20 \(group.tokenID)", outputs: refs.count))
                do {
                    let beef = try await steps.beef(batch.map { outpoint($0.output) })
                    try checkpoint()
                    let txid = try transactionID(
                        await steps.moveBsv20(tokenInputs(batch, tokenID: group.tokenID, key: input.key), beef, group.decimals)
                    )
                    report.bsv20Txids.append(txid)
                    record(swept: refs, of: batch.map(\.output), in: &report)
                } catch let interrupted as Interrupted {
                    throw interrupted
                } catch {
                    fail(.bsv20, label: "BSV-20 \(group.tokenID)", error: error, outpoints: refs, in: &report)
                }
            }
        }

        // BSV-21 (`sweepBsv21Token`): listed outputs one per transaction; only what the overlay
        // reported valid is spent.
        for group in plan.bsv21 {
            let name = group.symbol ?? String(group.tokenID.prefix(8))
            for batch in AssetSweep.listedBatches(group.outputs, events: { $0.output.events }) {
                let refs = batch.map { ref($0.output) }
                await steps.progress(Stage(sweepClass: .bsv21, label: "BSV-21 \(name)", outputs: refs.count))
                do {
                    let beef = try await steps.beef(batch.map { outpoint($0.output) })
                    try checkpoint()
                    let moved = try await steps.moveBsv21(
                        group.tokenID, tokenInputs(batch, tokenID: group.tokenID, key: input.key), beef, group.symbol
                    )
                    let txid = try transactionID(moved.result)
                    report.bsv21Txids.append(txid)
                    if moved.submitError != nil { report.unfiledTokenSweeps += 1 }
                    let spent = Set(moved.spentOutpoints ?? [])
                    let sweptItems = batch.filter { spent.contains(outpoint($0.output)) }
                    record(swept: sweptItems.map { ref($0.output) }, of: sweptItems.map(\.output), in: &report)
                    for item in batch where !spent.contains(outpoint(item.output)) {
                        report.leftovers.append(Leftover(sweepClass: .bsv21, outpoint: ref(item.output), reason: .notValidOnOverlay))
                    }
                } catch let interrupted as Interrupted {
                    throw interrupted
                } catch {
                    fail(.bsv21, label: "BSV-21 \(name)", error: error, outpoints: refs, in: &report)
                }
            }
        }
        return report
    }

    // MARK: - Helpers

    /// The txid of a successful action. A failed one throws its error, carrying any txid that came
    /// with it so the report still lists that broadcast.
    private static func transactionID(_ result: ActionResult) throws -> String {
        let txid = result.txid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let error = result.error {
            throw StepError(message: error, diagnostic: result.diagnostic, txid: txid.isEmpty ? nil : txid)
        }
        guard !txid.isEmpty else { throw RunnerError.noTransactionID }
        return txid
    }

    private struct StepError: LocalizedError {
        let message: String
        let diagnostic: String?
        let txid: String?
        var errorDescription: String? { message }
    }

    private static func keep(_ txid: String, _ sweepClass: SweepClass, in report: inout Report) {
        switch sweepClass {
        case .bsv: report.bsvTxids.append(txid)
        case .ordinals: report.ordinalTxids.append(txid)
        case .opns: report.opnsTxids.append(txid)
        case .bsv20: report.bsv20Txids.append(txid)
        case .bsv21: report.bsv21Txids.append(txid)
        case .run, .unspendable, .twetch: break
        }
    }

    private static func fail(
        _ sweepClass: SweepClass, label: String, error: any Error, outpoints: [OutputRef], in report: inout Report
    ) {
        var message = OneSatLog.localizedMessage(error)
        var reason = LeftoverReason.stepFailed
        if let step = error as? StepError {
            if let diagnostic = step.diagnostic { message += " (\(diagnostic))" }
            if let txid = step.txid {
                keep(txid, sweepClass, in: &report)
                reason = .broadcastUnconfirmed
            }
        }
        OneSatLog.error(error, "LegacySweepRunner: \(label) failed; \(outpoints.count) output(s) stay", category: "OneSatActions")
        report.failures.append(StepFailure(sweepClass: sweepClass, label: label, message: message))
        report.leftovers += outpoints.map { Leftover(sweepClass: sweepClass, outpoint: $0, reason: reason) }
    }

    private static func record(swept refs: [OutputRef], of outputs: [ScannedOutput], in report: inout Report) {
        report.sweptOutpoints += refs
        report.cancelledListings += outputs.filter { AssetSweep.isListed(events: $0.events) }.map(ref)
    }

    private static func ref(_ output: ScannedOutput) -> OutputRef {
        OutputRef(txid: output.txid, vout: output.vout)
    }

    private static func outpoint(_ output: ScannedOutput) -> String {
        "\(output.txid).\(output.vout)"
    }

    private static func tokenInputs(_ batch: [TokenItem], tokenID: String, key: PrivateKey) -> [AssetSweep.TokenInput] {
        batch.map {
            AssetSweep.TokenInput(
                outpoint: outpoint($0.output), satoshis: $0.output.satoshis, lockingScript: $0.output.lockingScript,
                tokenID: tokenID, amount: $0.amount, key: key
            )
        }
    }

    /// The scan's last `type:` event, else the indexer's content type; the first `origin:` event
    /// (or a bare `origin`, meaning this outpoint); the first `name:` event.
    static func ordinalInput(_ output: ScannedOutput, metadata: [OrdinalOutput], key: PrivateKey) -> AssetSweep.OrdinalInput {
        let point = outpoint(output)
        let contentType = output.events.last(where: { $0.hasPrefix("type:") }).map { String($0.dropFirst("type:".count)) }
            ?? metadata.first(where: { $0.txid == output.txid && $0.vout == output.vout })?.contentType
        var origin: String?
        for event in output.events where origin == nil {
            if event == "origin" { origin = point } else if event.hasPrefix("origin:") { origin = String(event.dropFirst("origin:".count)) }
        }
        let name = output.events.first(where: { $0.hasPrefix("name:") }).map { String($0.dropFirst("name:".count)) }
        return AssetSweep.OrdinalInput(
            outpoint: point, satoshis: output.satoshis, lockingScript: output.lockingScript,
            contentType: contentType, origin: origin ?? point, name: name, key: key
        )
    }
}
