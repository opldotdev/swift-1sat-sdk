import BSVCore
import BSVKeys
import BSVScript

/// Owner + approver cosign lock. Matches `@1sat/templates` cosign.ts.
/// Lock: OP_DUP OP_HASH160 <20-byte pkhash> OP_EQUALVERIFY OP_CHECKSIGVERIFY <33-byte approver pubkey> OP_CHECKSIG
/// Byte layout of `lock`: `76 a9 14 <20 bytes> 88 ad 21 <33 bytes> ac`.
public struct Cosign: Equatable, Sendable {
    public let address: Address
    public let cosigner: [UInt8]

    public init(address: Address, cosigner: [UInt8]) {
        self.address = address
        self.cosigner = cosigner
    }

    public static func lock(address: Address, cosigner: [UInt8]) throws -> Script {
        guard cosigner.count == 33 else {
            throw CosignError.invalidCosignerPubKey(byteCount: cosigner.count)
        }
        var script = try TemplateScript.empty()
        try TemplateScript.append(.dup, to: &script)
        try TemplateScript.append(.hash160, to: &script)
        try TemplateScript.appendPush(address.publicKeyHash.bytes, to: &script)
        try TemplateScript.append(.equalVerify, to: &script)
        try TemplateScript.append(.checkSigVerify, to: &script)
        try TemplateScript.appendPush(cosigner, to: &script)
        try TemplateScript.append(.checkSig, to: &script)
        return script
    }

    /// Window-scans chunks so the pattern is found after an inscription envelope.
    public static func decode(_ script: Script, network: BitcoinNetwork = .mainnet) -> Cosign? {
        guard let operations = try? TemplateScript.operations(script) else { return nil }
        guard operations.count >= 7 else { return nil }
        for index in 0...(operations.count - 7) {
            guard operations[index] == .opcode(.dup),
                  operations[index + 1] == .opcode(.hash160),
                  let hash = operations[index + 2].pushedData, hash.count == 20,
                  operations[index + 3] == .opcode(.equalVerify),
                  operations[index + 4] == .opcode(.checkSigVerify),
                  let cosigner = operations[index + 5].pushedData, cosigner.count == 33,
                  operations[index + 6] == .opcode(.checkSig),
                  let publicKeyHash = try? Hash160(hash)
            else { continue }
            return Cosign(
                address: Address(publicKeyHash: publicKeyHash, network: network),
                cosigner: cosigner
            )
        }
        return nil
    }

    public static func isCosign(_ script: Script) -> Bool {
        decode(script) != nil
    }

    /// Owner half of the unlock: <ownerSigDER + sigHashFlag byte> <owner compressed pubkey>.
    /// The MNEE proxy prepends the approver signature; approverUnlock is NOT ported.
    public static func ownerUnlock(
        ownerSigDER: [UInt8],
        sigHashFlag: UInt8,
        ownerPublicKey: PublicKey
    ) throws -> Script {
        var script = try TemplateScript.empty()
        try TemplateScript.appendPush(ownerSigDER + [sigHashFlag], to: &script)
        try TemplateScript.appendPush(ownerPublicKey.serialized(as: .compressed), to: &script)
        return script
    }
}

public enum CosignError: Error, Equatable, Sendable {
    case invalidCosignerPubKey(byteCount: Int)
}
