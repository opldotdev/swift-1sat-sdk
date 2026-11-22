import Foundation
import BSVCompat
import BSVCore
import BSVCrypto
import BSVKeys
import BSVTransaction
import ToolboxActions

/// Whether an inscription that names a collection is one of its members, by the collection rules
/// (docs.1satordinals.com/adding-metadata/collections): the collection is inscribed first, and its
/// signature matches the signature on its members.
///
/// Signatures are SIGMA, verified as TS `Sigma.verifyTransaction` (`@1sat/templates`
/// `bitcom/sigma.ts`) does: the input hash of the signature's `vin` and the hash of the script
/// before that SIGMA instance, signed with BSM by the address the signature names. A BRC-77
/// SIGMA signature or an AIP signature is noted as a signature but cannot be checked here, so it
/// never makes an item fail.
public enum CollectionMembership {
    /// `AIP_PREFIX` (`bitcom/aip.ts`).
    public static let aipPrefix = "15PciHG22SNLQJXMoSUaWVi7WSqc7hCfva"
    static let sigmaPrefix = "SIGMA"

    /// What one inscription's output says about who wrote it.
    public struct Authorship: Equatable, Sendable, Codable {
        /// Addresses whose BSM SIGMA signature over this output verifies, in script order.
        public let signers: [String]
        /// True when the output carries any SIGMA or AIP signature, checkable here or not.
        public let isSigned: Bool

        public init(signers: [String], isSigned: Bool) {
            self.signers = signers
            self.isSigned = isSigned
        }
    }

    /// Where a transaction sits in the chain: its block and its place in that block's
    /// transaction list. Within a block, a transaction comes after every one it spends, so the
    /// place orders two transactions in one block the way they were recorded.
    public struct BlockPosition: Equatable, Comparable, Sendable, Codable {
        public let height: UInt32
        public let index: UInt64

        public init(height: UInt32, index: UInt64) {
            self.height = height
            self.index = index
        }

        /// `txid`'s place in a BRC-74 proof (`BeefClient.getProof`); nil when the proof does not
        /// name it.
        public init?(proof: MerklePath, txid: TransactionID) {
            guard let leaf = proof.levels.first?.first(where: { $0.hash?.bytes == txid.wireBytes })
            else { return nil }
            self.init(height: proof.blockHeight, index: leaf.offset)
        }

        public static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.height, lhs.index) < (rhs.height, rhs.index)
        }
    }

    /// An inscription's authorship and where it was mined (nil: not yet).
    public struct Evidence: Equatable, Sendable, Codable {
        public let authorship: Authorship
        public let mined: BlockPosition?

        public init(authorship: Authorship, mined: BlockPosition?) {
            self.authorship = authorship
            self.mined = mined
        }
    }

    public enum Verdict: String, Equatable, Sendable, Codable {
        /// Signed by a key that signed the collection, and inscribed after it.
        case member
        /// Nothing here can show it is not a member: the collection is unsigned, or a signature
        /// is of a kind this code does not check.
        case unverified
        /// The collection is signed and the item is not.
        case unsigned
        /// Signed, but by none of the keys that signed the collection.
        case notSignedByCreator
        /// Recorded on chain before the collection was.
        case inscribedBeforeCollection

        /// Whether the item stays with its collection. Only a verdict the rules decide against it
        /// takes it out.
        public var isMember: Bool { self == .member || self == .unverified }
    }

    /// The inscription at `origin` (`txid_vout`), read from a 1sat-stack host: its transaction
    /// (`/1sat/beef/<txid>/tx`) for the signature and its proof (`/1sat/beef/<txid>/proof`) for
    /// where it was mined. Throws when either read fails, the transaction is not the one asked
    /// for, or the proof cannot be read; a transaction that is not mined yet has no position.
    public static func evidence(
        origin: String,
        services: OneSatDepositAssets = OneSatDepositAssets()
    ) async throws -> Evidence {
        let outpoint = try Outpoint(ordinal: origin)
        let txid = outpoint.transactionID
        let raw = try await services.rawTransaction(txid: txid.displayHex)
        let transaction = try Transaction(bytes: raw, limits: WalletTransactionLimits.standard)
        let readID = try transaction.transactionID(limits: WalletTransactionLimits.standard)
        guard readID == txid else {
            throw CollectionMembershipError.wrongTransaction(asked: txid.displayHex, got: readID.displayHex)
        }
        let authorship = authorship(of: transaction, vout: Int(outpoint.outputIndex))
        guard let proofBytes = try await services.proof(txid: txid.displayHex) else {
            return Evidence(authorship: authorship, mined: nil)
        }
        let proof = try MerklePath(bytes: proofBytes, limits: WalletBEEFLimits.standard.merklePathLimits)
        guard let position = BlockPosition(proof: proof, txid: txid) else {
            throw CollectionMembershipError.proofWithoutTransaction(txid.displayHex)
        }
        return Evidence(authorship: authorship, mined: position)
    }

    /// The SIGMA signatures on output `vout` of `transaction`, checked.
    public static func authorship(of transaction: Transaction, vout: Int) -> Authorship {
        guard transaction.outputs.indices.contains(vout) else {
            return Authorship(signers: [], isSigned: false)
        }
        let script = transaction.outputs[vout].lockingScript.bytes
        let inputs = transaction.inputs.map(\.previousOutput)
        return authorship(lockingScript: script, inputs: inputs)
    }

    /// The same, from the output's script and the transaction's inputs in order.
    public static func authorship(lockingScript bytes: [UInt8], inputs: [Outpoint]) -> Authorship {
        var signers: [String] = []
        var signed = false
        for found in signatures(in: bytes) {
            switch found {
            case .aip:
                signed = true
            case .sigma(let sigma):
                signed = true
                guard sigma.algorithm == "BSM",
                      let address = try? Address(sigma.address),
                      let signature = try? BitcoinMessageSignature(sigma.signature)
                else { continue }
                let inputHash = inputHash(inputs: inputs, vin: sigma.vin)
                let message = Sigma.getMessageHash(inputHash: inputHash, dataHash: sigma.dataHash)
                if (try? signature.verifies(message: message, address: address)) == true,
                   !signers.contains(sigma.address) {
                    signers.append(sigma.address)
                }
            }
        }
        return Authorship(signers: signers, isSigned: signed)
    }

    /// The rules applied to one item and its collection.
    public static func verdict(item: Evidence, collection: Evidence) -> Verdict {
        if recordedBefore(item.mined, collection.mined) { return .inscribedBeforeCollection }
        let creators = collection.authorship.signers
        // An unsigned collection, or one signed only in a way not checked here, names no creator.
        guard !creators.isEmpty else { return .unverified }
        guard item.authorship.isSigned else { return .unsigned }
        if item.authorship.signers.contains(where: creators.contains) { return .member }
        // Signed, but nothing here verified: an AIP or BRC-77 signature, or a BSM one that failed.
        guard !item.authorship.signers.isEmpty else { return .unverified }
        return .notSignedByCreator
    }

    /// True only when the item is known to be recorded before the collection: mined earlier, or
    /// mined while the collection still waits for a block. Unknown order is not "before".
    static func recordedBefore(_ item: BlockPosition?, _ collection: BlockPosition?) -> Bool {
        switch (item, collection) {
        case let (item?, collection?): item < collection
        case (.some, nil): true
        default: false
        }
    }

    // MARK: - Script reading (`Sigma.computeDataHash`, `Sigma.parseFromScript`)

    struct SigmaSignature: Equatable {
        let algorithm: String
        let address: String
        let signature: [UInt8]
        let vin: Int
        /// SHA256 of the script bytes before this instance's separator.
        let dataHash: [UInt8]
    }

    enum Found: Equatable {
        case sigma(SigmaSignature)
        case aip
    }

    /// Every SIGMA and AIP instance, in script order. A separator is `OP_RETURN` or a one-byte
    /// push of `|`; the push after it names the protocol.
    static func signatures(in bytes: [UInt8]) -> [Found] {
        var found: [Found] = []
        var previous = 0
        var position = 0
        while position < bytes.count {
            guard let op = readOp(bytes, at: position) else { break }
            position = op.next
            let isSeparator = op.code == 0x6A || (op.code == 1 && op.data.first == 0x7C)
            if isSeparator {
                let separatorAt = previous
                guard let next = readOp(bytes, at: position) else { break }
                position = next.next
                let name = String(decoding: next.data, as: UTF8.self)
                if name == sigmaPrefix {
                    if let sigma = sigmaFields(bytes, at: position, dataEnd: separatorAt) {
                        found.append(.sigma(sigma))
                    }
                } else if name == aipPrefix {
                    found.append(.aip)
                }
            }
            previous = position
        }
        return found
    }

    /// `tryParseSigAt`: algorithm, address, signature and vin, the four pushes after `SIGMA`.
    private static func sigmaFields(_ bytes: [UInt8], at start: Int, dataEnd: Int) -> SigmaSignature? {
        var fields: [[UInt8]] = []
        var position = start
        while fields.count < 4, let op = readOp(bytes, at: position), !op.data.isEmpty {
            fields.append(op.data)
            position = op.next
        }
        guard fields.count == 4,
              let vin = Int(String(decoding: fields[3], as: UTF8.self))
        else { return nil }
        return SigmaSignature(
            algorithm: String(decoding: fields[0], as: UTF8.self),
            address: String(decoding: fields[1], as: UTF8.self),
            signature: fields[2],
            vin: vin,
            dataHash: BSVHashing.sha256(Array(bytes[0..<dataEnd])).bytes
        )
    }

    /// `computeInputHash(tx, vin)`: SHA256 of the input's txid as written and its index, little
    /// endian; SHA256 of 32 zero bytes when the transaction has no such input.
    static func inputHash(inputs: [Outpoint], vin: Int) -> [UInt8] {
        guard inputs.indices.contains(vin) else {
            return BSVHashing.sha256([UInt8](repeating: 0, count: 32)).bytes
        }
        let input = inputs[vin]
        return (try? Sigma.getInputHash(
            txid: input.transactionID.displayHex,
            vout: input.outputIndex
        )) ?? BSVHashing.sha256([UInt8](repeating: 0, count: 32)).bytes
    }

    /// One script operation: its opcode, its pushed data and where the next one starts. Nil for a
    /// push that runs past the end.
    private static func readOp(_ bytes: [UInt8], at start: Int) -> (code: UInt8, data: [UInt8], next: Int)? {
        guard start < bytes.count else { return nil }
        let code = bytes[start]
        var dataStart = start + 1
        var length = 0
        switch code {
        case 1...75:
            length = Int(code)
        case 0x4C:
            guard dataStart < bytes.count else { return nil }
            length = Int(bytes[dataStart])
            dataStart += 1
        case 0x4D:
            guard dataStart + 1 < bytes.count else { return nil }
            length = Int(bytes[dataStart]) | Int(bytes[dataStart + 1]) << 8
            dataStart += 2
        case 0x4E:
            guard dataStart + 3 < bytes.count else { return nil }
            length = Int(bytes[dataStart]) | Int(bytes[dataStart + 1]) << 8
                | Int(bytes[dataStart + 2]) << 16 | Int(bytes[dataStart + 3]) << 24
            dataStart += 4
        default:
            length = 0
        }
        let next = dataStart + length
        guard next <= bytes.count else { return nil }
        return (code, Array(bytes[dataStart..<next]), next)
    }
}

public enum CollectionMembershipError: Error, Equatable, Sendable, LocalizedError {
    /// The indexer answered a different transaction from the one asked for.
    case wrongTransaction(asked: String, got: String)
    /// The indexer's proof does not name the transaction it was asked about.
    case proofWithoutTransaction(String)

    public var errorDescription: String? {
        switch self {
        case .wrongTransaction(let asked, let got):
            "The 1Sat indexer sent transaction \(got) when asked for \(asked)."
        case .proofWithoutTransaction(let txid):
            "The 1Sat indexer's proof for \(txid) does not include it."
        }
    }
}
