import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatAddresses
import ToolboxActions

public protocol ActionInternalizer: Sendable {
    @discardableResult
    func internalizeAction(_ request: WalletInternalizeActionRequest) async throws
        -> WalletInternalizeActionResult
}

/// Money subset of `@1sat/actions` `syncAddresses`.
public enum SyncAddresses {
    public struct Request: Equatable, Sendable {
        public var prefix: String
        public var startIndex: Int
        public var count: Int

        public init(
            prefix: String = DepositAddresses.defaultPrefix,
            startIndex: Int = 0,
            count: Int = 1
        ) {
            self.prefix = prefix
            self.startIndex = startIndex
            self.count = count
        }
    }

    /// One transaction the sync could not take in, and why. TS logs these with `console.error`;
    /// here they come back in ``Result`` so the caller can show a stalled sync.
    public struct Failure: Equatable, Sendable {
        public let txid: String
        public let message: String

        public init(txid: String, message: String) {
            self.txid = txid
            self.message = message
        }
    }

    public struct Result: Equatable, Sendable {
        public let processed: Int
        public let failed: Int
        public let lastScore: Double
        public let addresses: [String]
        /// One entry per failed transaction, in sync order; `failed == failures.count`.
        public let failures: [Failure]
        /// Why the closing `sweepDeposit` failed, if it did. The deposits stay in the basket for
        /// the next sync.
        public let sweepError: String?

        public init(
            processed: Int,
            failed: Int,
            lastScore: Double,
            addresses: [String],
            failures: [Failure] = [],
            sweepError: String? = nil
        ) {
            self.processed = processed
            self.failed = failed
            self.lastScore = lastScore
            self.addresses = addresses
            self.failures = failures
            self.sweepError = sweepError
        }
    }

    private static let reorgSafeDepth = 6

    /// `SYNC_PROTOCOLS`: deposits are derived under `ONESAT_PROTOCOL` and, for addresses handed
    /// out before the rename, `LEGACY_ONESAT_PROTOCOL` (`[0, "p 1sat"]`).
    public static func syncProtocols() throws -> [WalletProtocolID] {
        [
            try OneSatConstants.p1satProtocolID,
            try WalletProtocolID(
                securityLevel: .silent,
                name: OneSatConstants.legacyP1SatProtocolName
            ),
        ]
    }

    public static func execute(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        beef: any ListingBeefSource,
        syncSource: any OwnerSyncSource,
        assets: any DepositAssetSource,
        store: any ProcessedTxStore,
        request: Request
    ) async throws -> Result {
        guard let services = ctx.services else {
            throw OneSatActionError.servicesRequired
        }

        // TS: every protocol, then every index under it, so `addresses` lists the ONESAT set
        // first and the legacy set after it.
        var derived: [DepositDerivation] = []
        if request.count > 0 {
            let deriver = ctx.deriver
            for protocolID in try syncProtocols() {
                for index in request.startIndex..<(request.startIndex + request.count) {
                    let suffix = String(index)
                    let publicKey = try deriver.derivePublicKey(
                        protocolID: protocolID,
                        keyID: WalletKeyID("\(request.prefix) \(suffix)"),
                        counterparty: .self,
                        forSelf: true
                    )
                    let address = Address(publicKey: publicKey, network: ctx.chain.network)
                    derived.append(
                        DepositDerivation(
                            address: address.description,
                            publicKeyHash: address.publicKeyHash.bytes,
                            prefix: request.prefix,
                            suffix: suffix,
                            protocolID: protocolID
                        )
                    )
                }
            }
        }
        let addresses = derived.map(\.address)

        let height = try await services.currentHeight()
        let last = try await store.lastScore()
        let outputs = try await syncSource.syncOutputs(
            owners: addresses,
            from: last > 0 ? last : nil
        )

        var order: [String] = []
        var outputsByTxid: [String: [SyncOutput]] = [:]
        var maxSafeScore = last
        for output in outputs {
            let txid = String(output.outpoint.prefix(64))
            if outputsByTxid[txid] == nil {
                order.append(txid)
                outputsByTxid[txid] = []
            }
            outputsByTxid[txid, default: []].append(output)
            let outputHeight = output.score.rounded(.down)
            if Double(height) - outputHeight >= Double(reorgSafeDepth), output.score > maxSafeScore {
                maxSafeScore = output.score
            }
        }

        var processed = 0
        var failures: [Failure] = []
        for txid in order {
            guard let txOutputs = outputsByTxid[txid] else { continue }
            if try await store.has(txid) { continue }
            do {
                try await processTxid(
                    txid,
                    outputs: txOutputs,
                    derived: derived,
                    network: ctx.chain.network,
                    internalizer: internalizer,
                    beef: beef,
                    assets: assets
                )
                try await store.add(txid)
                processed += 1
            } catch {
                failures.append(Failure(txid: txid, message: String(describing: error)))
            }
        }

        // TS advances the cursor only when every transaction succeeded. The cursor is the only
        // record of what is left, so moving it past a failure loses that deposit once it is
        // deeper than the reorg window. Holding it back re-fetches the range next sync, and
        // `store.has` skips what is already done.
        if failures.isEmpty, maxSafeScore > last {
            try await store.setLastScore(maxSafeScore)
        }

        // A failed sweep leaves deposits in the basket for the next sync.
        var sweepError: String?
        do {
            _ = try await SweepDeposit.execute(ctx)
        } catch {
            sweepError = String(describing: error)
        }

        return Result(
            processed: processed,
            failed: failures.count,
            lastScore: maxSafeScore,
            addresses: addresses,
            failures: failures,
            sweepError: sweepError
        )
    }

    /// `processTxid` + `internalizeBeef` in address mode.
    private static func processTxid(
        _ txid: String,
        outputs: [SyncOutput],
        derived: [DepositDerivation],
        network: BitcoinNetwork,
        internalizer: any ActionInternalizer,
        beef: any ListingBeefSource,
        assets: any DepositAssetSource
    ) async throws {
        if outputs.allSatisfy({ $0.spendTxid?.isEmpty == false }) {
            return
        }

        // `/1sat/beef/:txid` answers Atomic BEEF; TS reads it with `Beef.fromBinary`, which also
        // takes plain BEEF, and hands the wallet `toBinaryAtomic(txid)`.
        let graph = try OneSatBEEF.graph(try await beef.beef(forTxid: txid))
        let subjectID = try TransactionID(displayHex: txid)
        guard let subject = try graph.transaction(
            for: subjectID,
            limits: WalletBEEFLimits.standard.transactionLimits
        ) else {
            throw OneSatActionError.noBeefAvailable
        }

        let indexed = try await DepositIndex.classify(
            subject,
            txid: txid,
            graph: graph,
            derived: derived,
            network: network,
            assets: assets
        )
        if indexed.outputs.isEmpty { return }

        let request = try WalletInternalizeActionRequest(
            transaction: try OneSatBEEF.atomic(subjectID, in: graph),
            description: indexed.description,
            labels: indexed.labels,
            outputs: indexed.outputs
        )
        _ = try await internalizer.internalizeAction(request)
    }

    /// TS `buildDescription` money branch, truncated to 50 characters.
    static func buildDescription(sats: UInt64) -> String {
        buildDescription(parts: [], sats: sats)
    }

    /// TS `buildDescription`: asset parts in output order, then the plain-sats total.
    static func buildDescription(parts: [String], sats: UInt64) -> String {
        var parts = parts
        if sats > 0 { parts.append("\(sats) sats") }
        if parts.isEmpty { return "Received via sync" }
        let desc = "Received \(parts.joined(separator: " + "))"
        let units = Array(desc.utf16)
        if units.count <= 50 { return desc }
        var cut = units.prefix(47)
        if let last = cut.last, UTF16.isLeadSurrogate(last) { cut = cut.dropLast() }
        return String(decoding: cut, as: UTF16.self) + "..."
    }
}

/// One deposit address and how its key was derived (`SyncedDerivation`).
struct DepositDerivation: Sendable {
    let address: String
    let publicKeyHash: [UInt8]
    let prefix: String
    let suffix: String
    let protocolID: WalletProtocolID

    var keyID: String { "\(prefix) \(suffix)" }
}
