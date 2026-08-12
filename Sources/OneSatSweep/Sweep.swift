import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import ToolboxServices

/// Sweeping every coin at one key into a destination address.
///
/// A sweep is how a wallet takes in money that was held under a foreign or legacy key — a Yours
/// backup, a paper key, a bare WIF — and consolidates it into an address it controls. This builds
/// and signs the transaction; broadcasting is the caller's step, so the same signed sweep can go to
/// whichever broadcaster the wallet has configured.
///
/// It is generic over both ends. The source is any key; the destination is any address; the UTXOs
/// come from any `UTXOSource` the wallet chose in its settings. The one thing it is **not** is
/// asset-aware: it sweeps standard P2PKH outputs only. An ordinal or a token has a non-standard
/// script and must be handled by the asset layer, which knows not to spend a collectible as a fee.
/// Point this at a plain-BSV key, or at the BSV outputs an asset scan already separated out.
public enum Sweep {

    /// Builds and signs a sweep of every P2PKH output at `wif`'s address to `destination`.
    ///
    /// - Parameters:
    ///   - wif: the key holding the coins. Its address is where the source outputs are read from.
    ///   - destination: a P2PKH address to send everything to, less the fee.
    ///   - source: where to read the spendable outputs from — the wallet's configured provider.
    ///   - satoshisPerKilobyte: the fee rate. The whole balance minus this fee goes to the
    ///     destination; a sweep keeps no change.
    public static func build(
        fromWIF wif: String,
        toAddress destination: String,
        source: any UTXOSource,
        satoshisPerKilobyte: UInt64 = 10,
        limits: TransactionLimits = defaultLimits
    ) async throws -> SweepResult {
        let key = try WIF(wif).privateKey
        let sourceAddress = Address(publicKey: key.publicKey, network: .mainnet).description
        let destinationScript = try Script.payToPublicKeyHash(
            try Address(destination).publicKeyHash,
            maximumByteCount: Int(limits.maximumScriptByteCount)
        )

        let utxos = try await source.spendableOutputs(forAddress: sourceAddress)
        guard !utxos.isEmpty else { throw SweepError.nothingToSweep(address: sourceAddress) }

        var total: UInt64 = 0
        let inputs = try utxos.map { utxo -> TransactionInput in
            let (sum, overflow) = total.addingReportingOverflow(utxo.satoshis)
            guard !overflow else { throw SweepError.amountsOverflow }
            total = sum
            return TransactionInput(
                previousOutput: Outpoint(
                    transactionID: try TransactionID(displayHex: utxo.txid),
                    outputIndex: utxo.vout
                ),
                unlockingScript: try Script(
                    bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount)
                ),
                sequence: 0xffff_ffff,
                sourceOutput: TransactionOutput(
                    satoshis: utxo.satoshis,
                    lockingScript: try Script(
                        bytes: utxo.lockingScript,
                        maximumByteCount: Int(limits.maximumScriptByteCount)
                    )
                ),
                // A signed P2PKH unlocking script is about 107 bytes; the fee is estimated against
                // that so the broadcast transaction weighs what it was funded for.
                estimatedUnlockingScriptByteCount: 107
            )
        }

        // A provisional output paying the whole balance, so the fee model measures the real size.
        var transaction = Transaction(
            version: 1,
            inputs: inputs,
            outputs: [TransactionOutput(satoshis: total, lockingScript: destinationScript)],
            lockTime: 0
        )

        let fee = try SatoshisPerKilobyteFeeModel(satoshisPerKilobyte: satoshisPerKilobyte)
            .fee(for: transaction, limits: limits)
        guard total > fee else { throw SweepError.dustAfterFee(total: total, fee: fee) }
        let paid = total - fee
        transaction.outputs = [
            TransactionOutput(satoshis: paid, lockingScript: destinationScript)
        ]

        for index in transaction.inputs.indices {
            do {
                try transaction.signPayToPublicKeyHashInput(at: index, with: key, limits: limits)
            } catch {
                throw SweepError.inputNotOwned(index: index)
            }
        }

        return SweepResult(transaction: transaction, swept: total, fee: fee, paid: paid)
    }

    /// Generous bounds for a sweep transaction. A consolidation of many small outputs can have a
    /// lot of inputs, so the input cap is high; everything else is ordinary.
    public static let defaultLimits: TransactionLimits = {
        try! TransactionLimits(
            maximumTransactionByteCount: 8 << 20,
            maximumInputCount: 100_000,
            maximumOutputCount: 100_000,
            maximumScriptByteCount: 1 << 20
        )
    }()
}

/// The result of building a sweep: the signed transaction and where the money went.
public struct SweepResult: Sendable {
    public let transaction: Transaction
    /// Total swept from the source, before fee.
    public let swept: UInt64
    public let fee: UInt64
    /// What the destination receives.
    public let paid: UInt64

    public init(transaction: Transaction, swept: UInt64, fee: UInt64, paid: UInt64) {
        self.transaction = transaction
        self.swept = swept
        self.fee = fee
        self.paid = paid
    }
}

public enum SweepError: Error, Equatable, Sendable {
    /// The source address holds no spendable outputs.
    case nothingToSweep(address: String)
    /// The fee would leave nothing to send.
    case dustAfterFee(total: UInt64, fee: UInt64)
    /// An input at the source address is not a P2PKH output this key unlocks — a non-standard
    /// script that the asset-aware layer must handle, not the plain sweep.
    case inputNotOwned(index: Int)
    case amountsOverflow
}
