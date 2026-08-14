import Foundation
import BSVCompat
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVWallet

/// SIGMA authorship from `packages/actions/src/signing/sigma.ts`.
public enum Sigma {
    /// `resolveCurrentKeyId` (`aip.ts:37-67`). Highest `seq:N` in the BAP basket.
    public static func resolveCurrentKeyId(_ ctx: OneSatContext) async throws -> String {
        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.bapBasket,
                tags: ["type:id"],
                includeCustomInstructions: true,
                includeTags: true,
                pagination: try WalletPagination(limit: 100)
            )
        )
        var maxSeq = -1
        var keyID: String?
        for output in listed.outputs {
            guard let seqTag = output.tags?.first(where: { $0.hasPrefix("seq:") }) else { continue }
            guard let seq = Int(seqTag.dropFirst(4)) else { continue }
            guard seq > maxSeq, let instructions = output.customInstructions else { continue }
            maxSeq = seq
            let parsed = try JSONSerialization.jsonObject(with: Data(instructions.utf8))
            keyID = (parsed as? [String: Any])?["keyID"] as? String
        }
        guard let keyID else { throw OneSatActionError.noBapIdentity }
        return keyID
    }

    /// `applySigma` (`sigma.ts:66-118`). Appends `SIGMA BSM <address> <compactSig> <vin>`.
    public static func apply(
        _ ctx: OneSatContext,
        to lockingScript: Script,
        inputTxid: String,
        inputVout: UInt32,
        targetVout: Int = 0,
        refVin: Int = 0
    ) async throws -> Script {
        let vin = refVin == -1 ? targetVout : refVin
        let inputHash = try getInputHash(txid: inputTxid, vout: inputVout)
        let dataHash = BSVHashing.sha256(lockingScript.bytes).bytes
        let messageHash = BSVHashing.sha256(inputHash + dataHash).bytes

        let keyID = try await resolveCurrentKeyId(ctx)
        let key = try WalletKeyDeriver(rootKey: ctx.identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID(keyID),
            counterparty: .self
        )
        let signature = try BitcoinSignedMessage.sign(messageHash, using: key, compressed: true)
        let address = Address(
            publicKey: key.publicKey,
            network: .mainnet,
            compressed: true
        ).description

        var out = try Script(
            bytes: lockingScript.bytes,
            maximumByteCount: ActionScript.maximumByteCount
        )
        if try hasOpReturn(lockingScript) {
            try out.appendPushData(
                Array("|".utf8),
                maximumScriptByteCount: ActionScript.maximumByteCount
            )
        } else {
            try out.append(.return, maximumScriptByteCount: ActionScript.maximumByteCount)
        }
        try out.appendPushData(
            Array("SIGMA".utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try out.appendPushData(
            Array("BSM".utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try out.appendPushData(
            Array(address.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try out.appendPushData(
            signature.bytes,
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try out.appendPushData(
            Array(String(vin).utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        return out
    }

    /// SHA256(txid-hex-as-written ‖ vout LE4). The txid bytes are not reversed.
    static func getInputHash(txid: String, vout: UInt32) throws -> [UInt8] {
        let txidBytes = try Hex.decode(txid, maximumDecodedByteCount: 32)
        return BSVHashing.sha256(
            txidBytes + [
                UInt8(truncatingIfNeeded: vout),
                UInt8(truncatingIfNeeded: vout >> 8),
                UInt8(truncatingIfNeeded: vout >> 16),
                UInt8(truncatingIfNeeded: vout >> 24),
            ]
        ).bytes
    }

    static func getDataHash(_ lockingScript: Script) -> [UInt8] {
        BSVHashing.sha256(lockingScript.bytes).bytes
    }

    static func getMessageHash(inputHash: [UInt8], dataHash: [UInt8]) -> [UInt8] {
        BSVHashing.sha256(inputHash + dataHash).bytes
    }

    private static func hasOpReturn(_ script: Script) throws -> Bool {
        try script.operations(maximumPushDataByteCount: ActionScript.maximumByteCount)
            .contains { $0.opcode == .return }
    }
}
