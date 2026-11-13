import BSVCore
import BSVTransaction
import ToolboxStorage

/// BEEF helpers the TypeScript `Beef` class provides.
public enum MetanetBEEF {
    static let limits = StorageLimits.beef

    /// `toBinaryAtomic(txid)`: the subject with exactly its ancestry, down to proven or
    /// transaction-ID-only records, and the BUMPs those use. The BEEF's version and order are kept.
    public static func atomic(_ txid: TransactionID, in beef: BEEF) throws -> AtomicBEEF {
        let txLimits = limits.transactionLimits
        var entries: [TransactionID: BEEFTransaction] = [:]
        for entry in beef.transactions { entries[try entry.transactionID(limits: txLimits)] = entry }
        var keep: Set<TransactionID> = []
        func visit(_ id: TransactionID) {
            guard !keep.contains(id), let entry = entries[id] else { return }
            keep.insert(id)
            guard case .raw(let transaction) = entry else { return }
            for input in transaction.inputs { visit(input.previousOutput.transactionID) }
        }
        visit(txid)
        var paths: [MerklePath] = []
        var remap: [Int: Int] = [:]
        var kept: [BEEFTransaction] = []
        for entry in beef.transactions where keep.contains(try entry.transactionID(limits: txLimits)) {
            if case .rawWithMerklePath(let transaction, let index) = entry {
                if remap[index] == nil {
                    remap[index] = paths.count
                    paths.append(beef.merklePaths[index])
                }
                kept.append(.rawWithMerklePath(transaction: transaction, merklePathIndex: remap[index]!))
            } else {
                kept.append(entry)
            }
        }
        let trimmed = try BEEF(version: beef.version, merklePaths: paths, transactions: kept, limits: limits)
        return try AtomicBEEF(subjectTransactionID: txid, beef: trimmed, limits: limits)
    }
}
