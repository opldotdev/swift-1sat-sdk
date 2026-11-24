import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxStorage
import ToolboxStorageClient
import OneSatMetanet

/// The storage calls the 1Color actions make. `StorageClient` provides them; tests stand in.
/// The BRC-177 calls come from `NoSendExpiryStorage`.
public protocol ColorWalletStorage: NoSendExpiryStorage {
    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult
    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult
    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult
    /// The wallet's actions (`listActions`): an AMM swap reads its labelled staging actions back.
    /// Real storage implements it (`StorageClient` does); the default throws
    /// `ColorStorageCallUnimplemented`, so a conformer that predates it (a test stand-in) still
    /// compiles and fails loudly if it is ever called.
    func colorListActions(_ auth: AuthID, _ request: WalletListActionsRequest) async throws -> WalletListActionsResult
}

/// A `ColorWalletStorage` call the conformer does not implement.
public struct ColorStorageCallUnimplemented: Error, Equatable, Sendable, LocalizedError {
    /// The conformer's type.
    public let storage: String
    /// The requirement it lacks.
    public let call: String

    public init(storage: String, call: String) {
        self.storage = storage
        self.call = call
    }

    public var errorDescription: String? {
        "\(storage) does not implement ColorWalletStorage.\(call): real wallet storage must implement it"
    }
}

extension ColorWalletStorage {
    /// Not implemented by this conformer: throws, never answers an empty list (an empty answer
    /// would read as "no staged tokens" and hide them).
    public func colorListActions(_ auth: AuthID, _ request: WalletListActionsRequest) async throws -> WalletListActionsResult {
        throw ColorStorageCallUnimplemented(storage: String(describing: Self.self), call: "colorListActions")
    }
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

    public func colorListActions(_ auth: AuthID, _ request: WalletListActionsRequest) async throws -> WalletListActionsResult {
        try await listActions(auth, request)
    }
}

/// BEEF graph helpers the module's `Beef` class provides in TypeScript.
public enum ColorBEEF {
    static let limits = WalletBEEFLimits.standard

    /// `toBinaryAtomic(txid)`: the subject with exactly its ancestry, down to proven or
    /// transaction-ID-only records, and the BUMPs those use.
    public static func atomic(_ txid: TransactionID, in beef: BEEF) throws -> AtomicBEEF {
        try MetanetBEEF.atomic(txid, in: beef)
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

    /// How far transactions in a BEEF are from confirmation. Not in the TS: a wallet's own
    /// preference for which coins to spend (an Open Exchange swap's staging, whose ancestry the
    /// exchange's validator checks).
    package struct Ancestry {
        let beef: BEEF
        let entries: [TransactionID: BEEFTransaction]

        package init(_ beef: BEEF) throws {
            self.beef = beef
            var entries: [TransactionID: BEEFTransaction] = [:]
            for entry in beef.transactions {
                let id = try entry.transactionID(limits: ColorBEEF.limits.transactionLimits)
                if entries[id] == nil { entries[id] = entry }
            }
            self.entries = entries
        }

        /// The BEEF carries a merkle path for `id`.
        package func proven(_ id: TransactionID) -> Bool {
            entries[id]?.merklePathIndex != nil || beef.merklePath(for: id) != nil
        }

        /// Whether `id` is proven, and the bytes of it and its unproven ancestry (each transaction
        /// once), walked down to proven or transaction-ID-only records: 0 for a proven
        /// transaction, and for one the BEEF does not carry raw.
        package func of(_ id: TransactionID) throws -> (proven: Bool, unprovenBytes: Int) {
            var seen: Set<TransactionID> = []
            var bytes = 0
            var stack = [id]
            while let next = stack.popLast() {
                guard seen.insert(next).inserted, !proven(next), let tx = entries[next]?.transaction else { continue }
                bytes += try tx.serializedByteCount(limits: ColorBEEF.limits.transactionLimits)
                stack.append(contentsOf: tx.inputs.map(\.previousOutput.transactionID))
            }
            return (proven(id), bytes)
        }
    }

    /// The transaction of an Atomic BEEF and its plain BEEF.
    package static func open(_ atomicBytes: [UInt8]) throws -> (txid: TransactionID, beef: BEEF, transaction: Transaction) {
        let atomic = try AtomicBEEF(bytes: atomicBytes, limits: limits, transactionOrder: .any)
        guard let transaction = try atomic.beef.transaction(for: atomic.subjectTransactionID, limits: limits.transactionLimits) else {
            throw ColorError.custody("Atomic BEEF lacks its subject")
        }
        return (atomic.subjectTransactionID, atomic.beef, transaction)
    }
}
