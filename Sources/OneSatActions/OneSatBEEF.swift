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
public enum OneSatBEEF {
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
    /// `Beef.fromBinary`.
    public static func graph(
        _ bytes: [UInt8],
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) throws -> BEEF {
        if isAtomic(bytes) {
            return try AtomicBEEF(bytes: bytes, limits: limits).beef
        }
        return try BEEF(bytes: bytes, limits: limits)
    }

    /// `bytes` as Atomic BEEF for `subject`: `Beef.fromBinary(bytes).toBinaryAtomic(subject)`.
    ///
    /// An envelope already naming `subject` is kept as it is; anything else is rewrapped, which
    /// fails unless `subject` and its ancestry are exactly what the graph holds.
    public static func atomic(
        _ bytes: [UInt8],
        subject: TransactionID,
        limits: BEEFLimits = WalletBEEFLimits.standard
    ) throws -> AtomicBEEF {
        if isAtomic(bytes) {
            let envelope = try AtomicBEEF(bytes: bytes, limits: limits)
            if envelope.subjectTransactionID == subject {
                return envelope
            }
            return try AtomicBEEF(subjectTransactionID: subject, beef: envelope.beef, limits: limits)
        }
        return try AtomicBEEF(
            subjectTransactionID: subject,
            beef: try BEEF(bytes: bytes, limits: limits),
            limits: limits
        )
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
