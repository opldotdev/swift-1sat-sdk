import BSVCore
import BSVTransaction
import ToolboxActions

/// BEEF bytes from a 1Sat service, read the way `@bsv/sdk` `Beef.fromBinary` reads them.
///
/// `GET /1sat/beef/:txid` (`BeefClient.getBeef`) answers Atomic BEEF (BRC-95): the
/// `0x01010101` prefix and the subject txid ahead of the BEEF itself. `Beef.fromBinary` takes
/// that envelope or plain BEEF (BRC-62/96) alike, so every TS caller of `getBeef` and
/// `getBeefForTxid` accepts both. Parsing the response with `BEEF(bytes:)` alone fails on the
/// prefix with `invalidVersion(0x01010101)`.
///
/// `Beef.fromBinary` does not hold an envelope to its subject: it keeps whatever transactions the
/// server sent, and `toBinaryAtomic(txid)` cuts them back when the BEEF is handed on. Swift's
/// `AtomicBEEF(bytes:)` refuses an envelope carrying anything outside the subject's ancestry, so
/// the envelope is read past its prefix here and the graph is trimmed only when it is wrapped.
public enum OneSatBEEF {
    /// BRC-95 prefix plus the 32-byte subject txid.
    static let atomicHeaderByteCount = 36

    /// Whether `bytes` open with the BRC-95 prefix.
    public static func isAtomic(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        let prefix = UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
        return prefix == AtomicBEEF.prefix
    }

    /// The transaction graph in `bytes`: the nested BEEF of an Atomic envelope, or plain BEEF.
    /// `Beef.fromBinary`: the envelope's subject and any extra transactions are not checked here.
    public static func graph(
        _ bytes: [UInt8],
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) throws -> BEEF {
        guard isAtomic(bytes) else {
            return try BEEF(bytes: bytes, limits: limits)
        }
        guard bytes.count >= atomicHeaderByteCount else {
            throw BEEFError.malformed(
                field: .atomicSubjectTransactionID,
                offset: 4,
                cause: .truncatedInput(expected: 32, remaining: bytes.count - 4)
            )
        }
        return try BEEF(bytes: Array(bytes[atomicHeaderByteCount...]), limits: limits)
    }

    /// `bytes` as Atomic BEEF for `subject`: `Beef.fromBinary(bytes).toBinaryAtomic(subject)`.
    ///
    /// The graph is cut to `subject` and exactly its ancestry, down to proven or txid-only
    /// records, with the BUMPs those use, so unrelated or newer transactions the server sent do
    /// not stop the read. `subject` itself must be in the graph.
    public static func atomic(
        _ bytes: [UInt8],
        subject: TransactionID,
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) throws -> AtomicBEEF {
        try atomic(subject, in: try graph(bytes, limits: limits), limits: limits)
    }

    /// `beef.toBinaryAtomic(subject)` over an already-read graph.
    public static func atomic(
        _ subject: TransactionID,
        in beef: BEEF,
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) throws -> AtomicBEEF {
        let txLimits = limits.transactionLimits
        var entries: [TransactionID: BEEFTransaction] = [:]
        for entry in beef.transactions {
            entries[try entry.transactionID(limits: txLimits)] = entry
        }
        guard entries[subject] != nil else {
            throw BEEFError.missingSubjectTransaction(subject)
        }

        var keep: Set<TransactionID> = []
        var pending = [subject]
        while let id = pending.popLast() {
            guard keep.insert(id).inserted, let entry = entries[id] else { continue }
            guard let transaction = entry.transaction, !isProven(id, entry: entry, in: beef) else {
                continue
            }
            for input in transaction.inputs where entries[input.previousOutput.transactionID] != nil {
                pending.append(input.previousOutput.transactionID)
            }
        }

        var paths: [MerklePath] = []
        var remap: [Int: Int] = [:]
        for (index, path) in beef.merklePaths.enumerated()
            where keep.contains(where: { contains(path, $0) })
        {
            remap[index] = paths.count
            paths.append(path)
        }
        var kept: [BEEFTransaction] = []
        for entry in beef.transactions where keep.contains(try entry.transactionID(limits: txLimits)) {
            if case .rawWithMerklePath(let transaction, let index) = entry, let mapped = remap[index] {
                kept.append(.rawWithMerklePath(transaction: transaction, merklePathIndex: mapped))
            } else {
                kept.append(entry)
            }
        }
        let trimmed = try BEEF(version: beef.version, merklePaths: paths, transactions: kept, limits: limits)
        return try AtomicBEEF(subjectTransactionID: subject, beef: trimmed, limits: limits)
    }

    private static func isProven(_ id: TransactionID, entry: BEEFTransaction, in beef: BEEF) -> Bool {
        if let index = entry.merklePathIndex, beef.merklePaths.indices.contains(index),
           contains(beef.merklePaths[index], id)
        {
            return true
        }
        return beef.merklePaths.contains(where: { contains($0, id) })
    }

    private static func contains(_ path: MerklePath, _ id: TransactionID) -> Bool {
        guard let hash = try? Hash256(id.wireBytes), let leaves = path.levels.first else { return false }
        return leaves.contains(where: { $0.hash == hash })
    }
}

extension ListingBeefSource {
    /// `OneSatServices.getBeefForTxid`: the BEEF for `txid`, Atomic or plain, as a graph.
    public func beefGraph(
        forTxid txid: String,
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) async throws -> BEEF {
        let bytes = try await beef(forTxid: txid)
        return try OneSatBEEF.graph(bytes, limits: limits)
    }
}
