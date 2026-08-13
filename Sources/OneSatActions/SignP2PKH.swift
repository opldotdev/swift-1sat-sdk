import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions

/// P2PKH unlock for a P1SAT-derived key. Matches `utils/signP2PKH.ts`.
///
/// Sighash is `SIGHASH_ALL | SIGHASH_FORKID`. The child key is `forSelf: true`
/// against `counterparty`, which is the key the sender locked to.
public enum SignP2PKH {
    public static func unlockingScript(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        hashType: ForkIDSignatureHashType = .all,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.inputs.indices.contains(inputIndex) else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }
        guard transaction.inputs[inputIndex].sourceOutput != nil else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }

        let spendingKey = try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: protocolID,
            keyID: WalletKeyID(keyID),
            counterparty: counterparty
        )
        return try unlockingScript(
            privateKey: spendingKey,
            transaction: transaction,
            inputIndex: inputIndex,
            hashType: hashType,
            limits: limits
        )
    }

    public static func unlockingScript(
        privateKey: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        hashType: ForkIDSignatureHashType = .all,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.inputs.indices.contains(inputIndex) else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }
        let digest = try transaction.forkIDSignatureHash(
            inputIndex: inputIndex,
            hashType: hashType,
            limits: limits
        )
        let signature = try privateKey.sign(digest: digest)
        let scriptMaximum = Int(limits.maximumScriptByteCount)
        var script = try Script(bytes: [], maximumByteCount: scriptMaximum)
        try script.appendPushData(
            signature.derBytes + [hashType.rawValue],
            maximumScriptByteCount: scriptMaximum
        )
        try script.appendPushData(
            privateKey.publicKey.serialized(as: .compressed),
            maximumScriptByteCount: scriptMaximum
        )
        return script
    }
}
