import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxStorage
import ToolboxStorageClient

/// The storage calls the 1Color actions make. `StorageClient` provides them; tests stand in.
/// The BRC-177 calls come from `NoSendExpiryStorage`.
public protocol ColorWalletStorage: NoSendExpiryStorage {
    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult
    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult
    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult
}

extension StorageClient: ColorWalletStorage {
    public func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult {
        try await createAction(auth, request, includeAllSourceTransactions: false)
    }

    public func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult {
        try await listOutputs(auth, request)
    }

    public func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        try await internalizeAction(auth, request)
    }
}

/// BEEF graph helpers the module's `Beef` class provides in TypeScript.
public enum ColorBEEF {
    static let limits = WalletBEEFLimits.standard

    /// The last transaction of a BEEF, which is the subject of an overlay answer.
    static func subject(of beef: BEEF) throws -> Transaction {
        guard let transaction = beef.transactions.last?.transaction else {
            throw ColorError.overlay("BEEF has no transaction")
        }
        return transaction
    }

    /// `toBinaryAtomic(txid)`: the subject with exactly its ancestry, down to proven or
    /// transaction-ID-only records, and the BUMPs those use.
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

    /// The source transactions of the given outpoints, each with its ancestry, merged.
    static func sources(_ outpoints: [String], from beef: BEEF) throws -> BEEF {
        var merged = try BEEF(version: .v2, merklePaths: [], transactions: [], limits: limits)
        for txid in Set(outpoints.compactMap { $0.split(separator: ".").first.map(String.init) }) {
            let id = try TransactionID(displayHex: txid)
            guard try beef.entry(for: id, limits: limits.transactionLimits) != nil else {
                throw ColorError.custody("the wallet returned no source transaction for \(txid)")
            }
            merged = try merged.merging(try atomic(id, in: beef).beef, limits: limits)
        }
        return merged
    }

    /// The transaction of an Atomic BEEF and its plain BEEF.
    static func open(_ atomicBytes: [UInt8]) throws -> (txid: TransactionID, beef: BEEF, transaction: Transaction) {
        let atomic = try AtomicBEEF(bytes: atomicBytes, limits: limits)
        guard let transaction = try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: limits.transactionLimits) else {
            throw ColorError.custody("Atomic BEEF lacks its subject")
        }
        return (atomic.subjectTransactionID, atomic.beef, transaction)
    }
}
