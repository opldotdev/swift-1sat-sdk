import BSVCompat
import BSVKeys
import BSVScript

/// AIP message buffer and compact BSM signature from `signing/aip.ts`.
enum AIPSign {
    /// `0x6a` plus every non-empty push after `OP_RETURN`.
    ///
    /// Trailing `|` is part of the AIP signed message. Every AIP validator requires it.
    /// Append it only when at least one data byte followed `OP_RETURN`.
    static func messageBuffer(_ script: Script) throws -> [UInt8] {
        var buffer: [UInt8] = []
        var foundOpReturn = false
        var hasContent = false
        for operation in try script.operations(maximumPushDataByteCount: ActionScript.maximumByteCount) {
            if operation.opcode == .return, operation.pushedData == nil {
                buffer.append(Opcode.return.rawValue)
                foundOpReturn = true
                continue
            }
            if !foundOpReturn { continue }
            if let data = operation.pushedData, !data.isEmpty {
                buffer.append(contentsOf: data)
                hasContent = true
            }
        }
        if hasContent {
            buffer.append(0x7c)
        }
        return buffer
    }

    /// Appends `|`, AIP prefix, `BITCOIN_ECDSA`, the signer address, and a 65-byte compact signature.
    static func apply(to script: Script, signingKey: PrivateKey) throws -> Script {
        let message = try messageBuffer(script)
        let signature = try BitcoinSignedMessage.sign(message, using: signingKey, compressed: true)
        let address = Address(
            publicKey: signingKey.publicKey,
            network: .mainnet,
            compressed: true
        ).description
        var signed = script
        try signed.appendPushData(
            Array("|".utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try signed.appendPushData(
            Array(OneSatConstants.aipPrefix.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try signed.appendPushData(
            Array(OneSatConstants.aipAlgorithm.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try signed.appendPushData(
            Array(address.utf8),
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        try signed.appendPushData(
            signature.bytes,
            maximumScriptByteCount: ActionScript.maximumByteCount
        )
        return signed
    }
}
