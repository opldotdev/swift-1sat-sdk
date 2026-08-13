import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// Spend-side scripts for TimeLock and OrdLock. These live in actions, not templates.
public enum UnlockScripts {
    /// `Lock.unlock` / `Lock.unlockWithWallet` in `@1sat/templates` `lock/lock.ts`.
    ///
    /// P2PKH unlock plus the BIP-143 preimage. Default scope is `SIGHASH_ALL | FORKID`.
    public static func timeLock(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        let hashType = ForkIDSignatureHashType.all
        let signature = try SignP2PKH.unlockingScript(
            identity: identity,
            transaction: transaction,
            inputIndex: inputIndex,
            protocolID: protocolID,
            keyID: keyID,
            counterparty: counterparty,
            hashType: hashType,
            limits: limits
        )
        let preimage = try transaction.forkIDSignaturePreimage(
            inputIndex: inputIndex,
            hashType: hashType,
            limits: limits
        )
        return try ActionScript.appending(
            try pushData(preimage, limits: limits),
            to: signature
        )
    }

    /// `OrdLock.cancelWithWallet` in `@1sat/templates` `ordlock/ordlock.ts`.
    ///
    /// P2PKH unlock under `SIGHASH_ALL | ANYONECANPAY | FORKID`, then `OP_1`.
    public static func ordLockCancel(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        let hashType = ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true)
        let signature = try SignP2PKH.unlockingScript(
            identity: identity,
            transaction: transaction,
            inputIndex: inputIndex,
            protocolID: protocolID,
            keyID: keyID,
            counterparty: counterparty,
            hashType: hashType,
            limits: limits
        )
        var script = signature
        try script.append(Opcode.one, maximumScriptByteCount: Int(limits.maximumScriptByteCount))
        return script
    }

    /// `buildPurchaseUnlockingScript` in `ordinals/index.ts`.
    ///
    /// Output 0 bytes, then extra outputs or `OP_0`, then the ANYONECANPAY preimage, then `OP_0`.
    public static func ordLockPurchase(
        transaction: Transaction,
        inputIndex: Int,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.outputs.count >= 2 else {
            throw OneSatActionError.malformedPurchaseTransaction
        }
        let scriptMaximum = Int(limits.maximumScriptByteCount)
        var script = try Script(bytes: [], maximumByteCount: scriptMaximum)
        try script.appendPushData(
            OrdLock.buildOutput(
                satoshis: transaction.outputs[0].satoshis,
                script: transaction.outputs[0].lockingScript
            ),
            maximumScriptByteCount: scriptMaximum
        )
        if transaction.outputs.count > 2 {
            var extras: [UInt8] = []
            for output in transaction.outputs.dropFirst(2) {
                extras.append(contentsOf: OrdLock.buildOutput(
                    satoshis: output.satoshis,
                    script: output.lockingScript
                ))
            }
            try script.appendPushData(extras, maximumScriptByteCount: scriptMaximum)
        } else {
            try script.append(Opcode.zero, maximumScriptByteCount: scriptMaximum)
        }
        let preimage = try transaction.forkIDSignaturePreimage(
            inputIndex: inputIndex,
            hashType: ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true),
            limits: limits
        )
        try script.appendPushData(preimage, maximumScriptByteCount: scriptMaximum)
        try script.append(Opcode.zero, maximumScriptByteCount: scriptMaximum)
        return script
    }

    private static func pushData(_ data: [UInt8], limits: TransactionLimits) throws -> Script {
        var script = try Script(bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount))
        try script.appendPushData(data, maximumScriptByteCount: Int(limits.maximumScriptByteCount))
        return script
    }
}
