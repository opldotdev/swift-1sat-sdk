import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions

/// Ordinal input unlock. Port of `utils/signOrdinalInput.ts`: the source script's shape
/// decides PushDrop vs P2PKH; customInstructions supply key material only.
///
/// A PushDrop source (an OpNS published bind) unlocks with a single
/// `<DER signature ‖ SIGHASH_ALL|FORKID>` push; anything else is a P1SAT P2PKH unlock.
public enum SignOrdinalInput {
    /// The PushDrop lock at the head of `script`, if it has one.
    ///
    /// Lock-before (`<pubkey> OP_CHECKSIG <fields> <drops>`) may be followed by anything, such as
    /// the inscription envelope ``OpNS/register(_:_:)`` appends; `@bsv/sdk` `PushDrop.decode`
    /// reads only the chunks it needs. swift-sdk `PushDrop.decode` rejects trailing bytes, so the
    /// PushDrop prefix is cut out first and decoded strictly. A lock-after PushDrop must be the
    /// whole script.
    public static func pushDrop(in script: Script) -> PushDropDecoded? {
        if let length = lockBeforePrefixLength(script.bytes),
           let prefix = try? Script(bytes: Array(script.bytes[0..<length]), maximumByteCount: length),
           let decoded = try? PushDrop.decode(prefix, lockPosition: .beforeCompatibility) {
            return decoded
        }
        return try? PushDrop.decode(script, lockPosition: .after)
    }

    /// Unlocking script for `transaction.inputs[inputIndex]`.
    ///
    /// `counterparty` nil takes the TS default for the shape: `anyone` for PushDrop, `self`
    /// for P2PKH.
    public static func unlockingScript(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        protocolID: WalletProtocolID,
        keyID: String,
        counterparty: WalletCounterparty? = nil,
        limits: TransactionLimits = WalletTransactionLimits.standard
    ) throws -> Script {
        guard transaction.inputs.indices.contains(inputIndex),
              let source = transaction.inputs[inputIndex].sourceOutput
        else {
            throw OneSatActionError.missingSourceLockingScript(inputIndex: inputIndex)
        }
        guard let decoded = pushDrop(in: source.lockingScript) else {
            return try SignP2PKH.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: inputIndex,
                protocolID: protocolID,
                keyID: keyID,
                counterparty: counterparty ?? .self,
                limits: limits
            )
        }

        let key = try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: protocolID,
            keyID: WalletKeyID(keyID),
            counterparty: counterparty ?? .anyone
        )
        guard key.publicKey == decoded.publicKey else {
            throw PushDropError.privateKeyDoesNotMatchPublicKey(inputIndex: inputIndex)
        }
        // Same steps as swift-sdk `signPushDropInput`, which cannot be used directly because its
        // strict decode refuses a source script with an envelope after the PushDrop.
        let hashType = ForkIDSignatureHashType.all
        let digest = try transaction.forkIDSignatureHash(
            inputIndex: inputIndex,
            hashType: hashType,
            limits: limits
        )
        let signature = try key.sign(digest: digest)
        let maximum = Int(limits.maximumScriptByteCount)
        var script = try Script(bytes: [], maximumByteCount: maximum)
        try script.appendPushData(
            signature.derBytes + [hashType.rawValue],
            maximumScriptByteCount: maximum
        )
        return script
    }

    /// Unlock from a stored customInstructions JSON. An absent `counterparty` takes the shape
    /// default, as `ci.counterparty ?? …` does in TS.
    public static func unlockingScript(
        identity: PrivateKey,
        transaction: Transaction,
        inputIndex: Int,
        customInstructions: String
    ) throws -> Script {
        let parsed = try CustomInstructions.parse(customInstructions)
        let object = try? JSONSerialization.jsonObject(with: Data(customInstructions.utf8))
        let explicit = (object as? [String: Any])?["counterparty"] != nil
        return try unlockingScript(
            identity: identity,
            transaction: transaction,
            inputIndex: inputIndex,
            protocolID: parsed.protocolID,
            keyID: parsed.keyID,
            counterparty: explicit ? parsed.counterparty : nil
        )
    }

    /// Byte length of `<33-byte key> OP_CHECKSIG <pushes> <OP_2DROP…> [OP_DROP]` at the head of
    /// `bytes`, or nil when the head is not that shape. Strictness is left to `PushDrop.decode`.
    static func lockBeforePrefixLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 35, bytes[0] == 33, bytes[34] == Opcode.checkSig.rawValue else {
            return nil
        }
        var offset = 35
        var fieldCount = 0
        while offset < bytes.count {
            let op = bytes[offset]
            if op == Opcode.drop.rawValue || op == Opcode.twoDrop.rawValue { break }
            let length: Int
            var header = 1
            switch op {
            case 0x00, 0x4f, 0x51...0x60:
                length = 0
            case 0x01...0x4b:
                length = Int(op)
            case Opcode.pushData1.rawValue:
                guard offset + 1 < bytes.count else { return nil }
                length = Int(bytes[offset + 1])
                header = 2
            case Opcode.pushData2.rawValue:
                guard offset + 2 < bytes.count else { return nil }
                length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
                header = 3
            case Opcode.pushData4.rawValue:
                guard offset + 4 < bytes.count else { return nil }
                length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
                    | Int(bytes[offset + 3]) << 16 | Int(bytes[offset + 4]) << 24
                header = 5
            default:
                return nil
            }
            guard bytes.count - offset - header >= length else { return nil }
            offset += header + length
            fieldCount += 1
        }
        let drops = fieldCount / 2 + fieldCount % 2
        guard fieldCount > 0, bytes.count - offset >= drops else { return nil }
        return offset + drops
    }
}
