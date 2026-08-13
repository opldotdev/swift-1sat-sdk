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

    public struct Result: Equatable, Sendable {
        public let processed: Int
        public let failed: Int
        public let lastScore: Double
        public let addresses: [String]

        public init(processed: Int, failed: Int, lastScore: Double, addresses: [String]) {
            self.processed = processed
            self.failed = failed
            self.lastScore = lastScore
            self.addresses = addresses
        }
    }

    private static let reorgSafeDepth = 6

    public static func execute(
        _ ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        beef: any ListingBeefSource,
        syncSource: any OwnerSyncSource,
        store: any ProcessedTxStore,
        request: Request
    ) async throws -> Result {
        guard let services = ctx.services else {
            throw OneSatActionError.servicesRequired
        }

        var derived: [DerivedDeposit] = []
        if request.count > 0 {
            derived.reserveCapacity(request.count)
            for index in request.startIndex..<(request.startIndex + request.count) {
                let address = try DepositAddresses.address(
                    identity: ctx.identity,
                    index: index,
                    prefix: request.prefix,
                    network: ctx.chain.network
                )
                let lockingScript = try Script.payToPublicKeyHash(
                    address,
                    maximumByteCount: Int(WalletTransactionLimits.standard.maximumScriptByteCount)
                )
                derived.append(
                    DerivedDeposit(
                        address: address.description,
                        prefix: request.prefix,
                        suffix: String(index),
                        lockingScript: lockingScript
                    )
                )
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
        var failed = 0
        for txid in order {
            guard let txOutputs = outputsByTxid[txid] else { continue }
            if try await store.has(txid) { continue }
            do {
                try await processTxid(
                    txid,
                    outputs: txOutputs,
                    derived: derived,
                    internalizer: internalizer,
                    beef: beef
                )
                try await store.add(txid)
                processed += 1
            } catch {
                failed += 1
            }
        }

        if maxSafeScore > last {
            try await store.setLastScore(maxSafeScore)
        }

        // A failed sweep leaves deposits in the basket for the next sync.
        do {
            _ = try await SweepDeposit.execute(ctx)
        } catch {}

        return Result(
            processed: processed,
            failed: failed,
            lastScore: maxSafeScore,
            addresses: addresses
        )
    }

    private static func processTxid(
        _ txid: String,
        outputs: [SyncOutput],
        derived: [DerivedDeposit],
        internalizer: any ActionInternalizer,
        beef: any ListingBeefSource
    ) async throws {
        if outputs.allSatisfy({ $0.spendTxid?.isEmpty == false }) {
            return
        }

        let bytes = try await beef.beef(forTxid: txid)
        let parsed = try BEEF(bytes: bytes, limits: WalletBEEFLimits.standard)
        let subjectID = try TransactionID(displayHex: txid)
        let atomic = try AtomicBEEF(
            subjectTransactionID: subjectID,
            beef: parsed,
            limits: WalletBEEFLimits.standard
        )
        guard let subject = try parsed.transaction(
            for: subjectID,
            limits: WalletBEEFLimits.standard.transactionLimits
        ) else {
            throw OneSatActionError.noBeefAvailable
        }

        let actionID = TrackedAction.randomActionID()
        var money: [WalletInternalizeOutput] = []
        var sats: UInt64 = 0
        for (vout, output) in subject.outputs.enumerated() {
            guard let deposit = derived.first(where: { $0.lockingScript == output.lockingScript }),
                  output.satoshis >= 2
            else { continue }
            let instructions = try CustomInstructions(
                protocolID: try OneSatConstants.p1satProtocolID,
                keyID: "\(deposit.prefix) \(deposit.suffix)",
                counterparty: .self
            ).encoded(includeSelfCounterparty: true)
            money.append(
                WalletInternalizeOutput(
                    outputIndex: UInt32(vout),
                    remittance: .basketInsertion(
                        try WalletBasketInsertion(
                            basket: OneSatConstants.depositBasket,
                            customInstructions: instructions,
                            tags: ["id:\(actionID)_\(vout)"]
                        )
                    )
                )
            )
            sats += output.satoshis
        }

        if money.isEmpty { return }

        let request = try WalletInternalizeActionRequest(
            transaction: atomic,
            description: buildDescription(sats: sats),
            outputs: money
        )
        _ = try await internalizer.internalizeAction(request)
    }

    /// TS `buildDescription` money branch, truncated to 50 characters.
    static func buildDescription(sats: UInt64) -> String {
        let desc = "Received \(sats) sats"
        if desc.count <= 50 { return desc }
        return "\(desc.prefix(47))..."
    }
}

private struct DerivedDeposit: Sendable {
    let address: String
    let prefix: String
    let suffix: String
    let lockingScript: Script
}
