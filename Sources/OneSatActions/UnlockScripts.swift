import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// Spend-side scripts for TimeLock and OrdLock v2. These live in actions, not templates.
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

    /// `OrdLockV2.cancelWithWallet` in `@1sat/templates` `ordlock/ordlockV2.ts`.
    ///
    /// `<"ol2:cancel"> <sig> <pubkey> OP_1`, signed under
    /// `SIGHASH_ALL | ANYONECANPAY | FORKID` over the whole locking script.
    public static func ordLockV2Cancel(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: WalletCounterparty = .self,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        let key = try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: protocolID,
            keyID: WalletKeyID(keyID),
            counterparty: counterparty
        )
        return try ordLockV2Cancel(
            privateKey: key, transaction: transaction, inputIndex: inputIndex, limits: limits
        )
    }

    /// Raw-key `OrdLockV2.cancelListing(key, "all", true)`, used by legacy-key sweeps.
    public static func ordLockV2Cancel(
        privateKey: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.inputs.indices.contains(inputIndex),
              let source = transaction.inputs[inputIndex].sourceOutput else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }
        guard let listing = OrdLockV2.decode(source.lockingScript) else {
            throw OneSatActionError.notAnOrdLockListing
        }
        guard listing.sellerPublicKeyHash
            == Address(publicKey: privateKey.publicKey, network: .mainnet).publicKeyHash.bytes else {
            throw OneSatActionError.invalidCustomInstructions
        }
        let scriptMaximum = Int(limits.maximumScriptByteCount)
        let signature = try SignP2PKH.unlockingScript(
            privateKey: privateKey,
            transaction: transaction,
            inputIndex: inputIndex,
            hashType: ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true),
            limits: limits
        )
        var script = try Script(bytes: [], maximumByteCount: scriptMaximum)
        try script.appendPushData(OrdLockV2.cancelMarker, maximumScriptByteCount: scriptMaximum)
        script = try Script(bytes: script.bytes + signature.bytes, maximumByteCount: scriptMaximum)
        try script.append(OrdLockV2.cancelSelector, maximumScriptByteCount: scriptMaximum)
        return script
    }

    /// `OrdLockV2.purchaseListing(..., { deliveries })` in `ordlock/ordlockV2.ts`.
    ///
    /// `<preimage> OP_0`. The preimage is built under
    /// `SIGHASH_SINGLE | ANYONECANPAY | FORKID` over the scriptCode after the
    /// purchase branch's OP_CODESEPARATOR. Refuses to sign unless output
    /// `inputIndex` is the listing's payout and the listed satoshi lands on a
    /// 1-sat receive output (one of `deliveries` when given).
    public static func ordLockV2Purchase(
        transaction: Transaction,
        inputIndex: Int,
        deliveries: [OrdLockV2Spend.DeliveryTarget]? = nil,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.inputs.indices.contains(inputIndex),
              let source = transaction.inputs[inputIndex].sourceOutput else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }
        guard let listing = OrdLockV2.decode(source.lockingScript) else {
            throw OneSatActionError.ordLockV2Refused("OrdLockV2: input is not a v2 listing")
        }
        guard transaction.outputs.indices.contains(inputIndex) else {
            throw OneSatActionError.ordLockV2Refused(
                "OrdLockV2: no output at index \(inputIndex); SIGHASH_SINGLE binds listing input \(inputIndex) to output \(inputIndex)"
            )
        }
        let bound = transaction.outputs[inputIndex]
        guard OrdLockV2.buildOutput(satoshis: bound.satoshis, script: bound.lockingScript)
            == listing.payout else {
            throw OneSatActionError.ordLockV2Refused(
                "OrdLockV2: output \(inputIndex) must be the listing payout (\(listing.price) sats to the seller's payout script)"
            )
        }
        _ = try OrdLockV2Spend.assertDelivery(
            transaction: transaction, inputIndex: inputIndex, deliveries: deliveries
        )
        let preimage = try transaction.forkIDSignaturePreimage(
            inputIndex: inputIndex,
            hashType: ForkIDSignatureHashType(outputs: .single, anyoneCanPay: true),
            scriptCode: try OrdLockV2.purchaseScriptCode(source.lockingScript),
            limits: limits
        )
        let scriptMaximum = Int(limits.maximumScriptByteCount)
        var script = try Script(bytes: [], maximumByteCount: scriptMaximum)
        try script.appendPushData(preimage, maximumScriptByteCount: scriptMaximum)
        try script.append(OrdLockV2.purchaseSelector, maximumScriptByteCount: scriptMaximum)
        return script
    }

    private static func pushData(_ data: [UInt8], limits: TransactionLimits) throws -> Script {
        var script = try Script(bytes: [], maximumByteCount: Int(limits.maximumScriptByteCount))
        try script.appendPushData(data, maximumScriptByteCount: Int(limits.maximumScriptByteCount))
        return script
    }
}
