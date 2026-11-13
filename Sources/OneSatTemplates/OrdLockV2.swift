import BSVCore
import BSVKeys
import BSVScript

/// OrdLock v2: the batch-capable marketplace listing (Rúnar `OrdLockV2Batch`).
///
/// Matches `@1sat/templates` `ordlock/ordlockV2.ts` and the compiled artifact
/// vendored in `@1sat/types` (`contracts/OrdLockV2Batch.json`, Rúnar b3f08f2).
/// A v2 listing is spent one of two ways:
///
/// - **purchase**: no signature. The listing at input `i` requires output `i`
///   of the spending transaction to equal the seller's embedded payout
///   (SIGHASH_SINGLE). Unlock: `<preimage> OP_0`.
/// - **cancel**: signed by the seller key. Unlock:
///   `<"ol2:cancel"> <sig> <pubkey> OP_1`.
///
/// The locking script is the compiled template with its two `OP_0`
/// constructor placeholders replaced by minimal pushes; ``decode(_:network:)``
/// is the exact inverse. Spend-side signing lives in `OneSatActions`.
///
/// OrdLock v1 is retired here: `@1sat/actions` 8fb809d5 (2026-10-27) removed v1
/// detection and the v1 sweep cancel after the v1 listing inventory was cancelled.
/// TS buy/cancel keep a vestigial v1 fallback; Swift drops it. v1 scripts do not decode here.
public enum OrdLockV2 {
    /// Compiled template, OP_0 placeholders at the constructor slots (472 bytes).
    public static let template = Array(hex: """
        76009c637576ab76aa517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f517f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e01007e8100011f80517e9321414136d08c5ed2bf3ba048afe6dcaebafeffffffffffffffffffffffffffffff007d97785296789f527952798d9495937776927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f76927f7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e7c7e827c7e23022079be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798027c7e827c7e01307c7e01c37e2102b405d7f0322a89d0f9f3a98e6f938fdc1c969a8d1382a2bf66a71ae74a1e83b0ad6900aa7c820128947f7701207f758767519d7b0a6f6c323a63616e63656c8876a90088ac68
        """)

    /// One constructor slot of the artifact: which argument fills the OP_0 at `byteOffset`.
    public struct ConstructorSlot: Equatable, Sendable {
        public let paramIndex: Int
        public let byteOffset: Int
    }

    /// Artifact `constructorSlots`. Params: 0 = seller PKH, 1 = serialized payout output.
    public static let slots: [ConstructorSlot] = [
        ConstructorSlot(paramIndex: 1, byteOffset: 436),
        ConstructorSlot(paramIndex: 0, byteOffset: 468),
    ]

    /// Artifact `codeSeparatorIndex`: the OP_CODESEPARATOR inside the purchase branch.
    /// It precedes both slots, so the offset is the same in every deployed listing.
    public static let codeSeparatorIndex = 6

    /// Recognizer prefix: template bytes before the first slot, identical for every listing.
    public static let prefix = Array(template[0..<436])

    /// Enforced cancel marker: ASCII `ol2:cancel`.
    public static let cancelMarker: [UInt8] = Array("ol2:cancel".utf8)

    /// ABI selector pushed last by a purchase unlock (`purchase` is method 0).
    public static let purchaseSelector = Opcode.zero
    /// ABI selector pushed last by a cancel unlock (`cancel` is method 1).
    public static let cancelSelector = Opcode.one

    /// Sighash byte of the purchase preimage: SINGLE | ANYONECANPAY | FORKID.
    public static let purchaseSighashByte: UInt8 = 0xc3
    /// Sighash byte of a cancel signature: ALL | ANYONECANPAY | FORKID.
    public static let cancelSighashByte: UInt8 = 0xc1

    /// Upper bound of a cancel unlock: `<marker> <sig> <pubkey> OP_1` with a 73-byte DER signature.
    public static let cancelUnlockLength = 1 + 10 + 1 + 73 + 1 + 33 + 1

    /// BIP-143 preimage bytes other than the scriptCode and its varint.
    static let preimageFixedLength = 156

    public struct Data: Equatable, Sendable {
        /// Seller (cancel) address.
        public let seller: String
        /// Seller (cancel) public-key hash.
        public let sellerPublicKeyHash: [UInt8]
        /// Listing price: the payout output's satoshis.
        public let price: UInt64
        /// Serialized payout output: 8-byte LE satoshis || varint || script.
        public let payout: [UInt8]
        /// Byte offset of the v2 script inside the examined locking script.
        public let offset: Int
        /// Byte offset one past the v2 script; trailing data such as MAP starts here.
        public let end: Int
    }

    // MARK: - Lock

    /// `OrdLockV2.lock(cancelAddress, payAddress, price)`.
    public static func lock(
        cancelAddress: String,
        payAddress: String,
        price: UInt64
    ) throws -> Script {
        let cancel = try Address(cancelAddress)
        let pay = try Address(payAddress)
        let payScript = try Script.payToPublicKeyHash(
            pay,
            maximumByteCount: TemplateScript.maximumByteCount
        )
        return try lockRaw(
            sellerPublicKeyHash: cancel.publicKeyHash.bytes,
            payout: buildOutput(satoshis: price, script: payScript)
        )
    }

    /// `OrdLockV2.lockRaw(sellerPkh, payout)`.
    public static func lockRaw(sellerPublicKeyHash: [UInt8], payout: [UInt8]) throws -> Script {
        guard sellerPublicKeyHash.count == 20 else { throw OrdLockV2Error.invalidSellerHash }
        guard payout.count >= 9 else { throw OrdLockV2Error.payoutTooShort }
        return try TemplateScript.script(
            bytes: try fillSlots(args: [sellerPublicKeyHash, payout])
        )
    }

    /// 8-byte little-endian satoshis + CompactSize script length + script.
    public static func buildOutput(satoshis: UInt64, script: Script) -> [UInt8] {
        buildOutput(satoshis: satoshis, scriptBytes: script.bytes)
    }

    public static func buildOutput(satoshis: UInt64, scriptBytes: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: satoshis >> ($0 * 8)) }
        bytes.append(contentsOf: CompactSize.encode(UInt64(scriptBytes.count)))
        bytes.append(contentsOf: scriptBytes)
        return bytes
    }

    // MARK: - Decode

    /// Decodes a v2 listing. Trailing data after the contract (MAP metadata) is tolerated.
    public static func decode(_ script: Script, network: BitcoinNetwork = .mainnet) -> Data? {
        let bytes = script.bytes
        guard let offset = TemplateScript.indexOf(bytes, prefix),
              let read = readSlots(bytes, offset: offset),
              read.args.count == 2
        else { return nil }
        let sellerHash = read.args[0]
        let payout = read.args[1]
        guard sellerHash.count == 20, payout.count >= 9,
              let publicKeyHash = try? Hash160(sellerHash)
        else { return nil }
        var price: UInt64 = 0
        for index in 0..<8 {
            price |= UInt64(payout[index]) << (index * 8)
        }
        return Data(
            seller: Address(publicKeyHash: publicKeyHash, network: network).description,
            sellerPublicKeyHash: sellerHash,
            price: price,
            payout: payout,
            offset: offset,
            end: read.end
        )
    }

    public static func isOrdLockV2(_ script: Script) -> Bool {
        decode(script) != nil
    }

    /// The payout output a listing demands: satoshis and locking script.
    public static func payoutOutput(_ lockingScript: Script) throws -> (satoshis: UInt64, script: Script) {
        guard let data = decode(lockingScript) else { throw OrdLockV2Error.notAListing }
        return try parseOutput(data.payout)
    }

    /// Parses a serialized output (8-byte LE satoshis || CompactSize || script).
    public static func parseOutput(_ bytes: [UInt8]) throws -> (satoshis: UInt64, script: Script) {
        guard bytes.count >= 9 else { throw OrdLockV2Error.payoutTooShort }
        var satoshis: UInt64 = 0
        for index in 0..<8 {
            satoshis |= UInt64(bytes[index]) << (index * 8)
        }
        let rest = Array(bytes[8...])
        let length: UInt64
        let consumed: Int
        switch rest[0] {
        case 0x00...0xfc:
            length = UInt64(rest[0])
            consumed = 1
        case 0xfd:
            guard rest.count >= 3 else { throw OrdLockV2Error.payoutTooShort }
            length = UInt64(rest[1]) | UInt64(rest[2]) << 8
            consumed = 3
        case 0xfe:
            guard rest.count >= 5 else { throw OrdLockV2Error.payoutTooShort }
            var value: UInt64 = 0
            for index in 0..<4 { value |= UInt64(rest[1 + index]) << (index * 8) }
            length = value
            consumed = 5
        default:
            guard rest.count >= 9 else { throw OrdLockV2Error.payoutTooShort }
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(rest[1 + index]) << (index * 8) }
            length = value
            consumed = 9
        }
        guard length <= UInt64(rest.count - consumed) else { throw OrdLockV2Error.payoutTooShort }
        let script = try TemplateScript.script(
            bytes: Array(rest[consumed..<(consumed + Int(length))])
        )
        return (satoshis, script)
    }

    // MARK: - Unlock shapes

    /// True when an unlocking script is a v2 cancel: `<marker> <sig> <pubkey> OP_1`.
    public static func isCancel(_ unlockingScript: Script) -> Bool {
        guard let operations = try? TemplateScript.operations(unlockingScript),
              operations.count == 4,
              operations[0].pushedData == cancelMarker
        else { return false }
        return operations[3].opcode == cancelSelector
    }

    /// True when an unlocking script is a v2 purchase: `<preimage> OP_0`.
    public static func isPurchase(_ unlockingScript: Script) -> Bool {
        guard let operations = try? TemplateScript.operations(unlockingScript),
              operations.count == 2,
              let preimage = operations[0].pushedData,
              preimage.count >= preimageFixedLength
        else { return false }
        return operations[1].opcode == purchaseSelector
    }

    /// The scriptCode a purchase preimage commits to: everything after the
    /// OP_CODESEPARATOR in the purchase branch (trailing data included).
    public static func purchaseScriptCode(_ lockingScript: Script) throws -> Script {
        guard let data = decode(lockingScript) else { throw OrdLockV2Error.notAListing }
        let start = data.offset + codeSeparatorIndex + 1
        return try TemplateScript.script(bytes: Array(lockingScript.bytes[start...]))
    }

    /// Exact length of a purchase unlock (`<preimage> OP_0`) for a listing.
    /// The preimage size depends only on the scriptCode, so later fee inputs
    /// and change outputs cannot change it.
    public static func estimatePurchaseUnlockLength(_ lockingScript: Script) throws -> Int {
        guard let data = decode(lockingScript) else { throw OrdLockV2Error.notAListing }
        let scriptCodeLength = lockingScript.byteCount - (data.offset + codeSeparatorIndex + 1)
        let preimageLength = preimageFixedLength
            + CompactSize.encodedLength(of: UInt64(scriptCodeLength))
            + scriptCodeLength
        return pushLength(preimageLength) + 1
    }

    // MARK: - Rúnar slots

    /// Minimal push of `data`: OP_0 for empty, direct push, PUSHDATA1/2/4.
    static func encodePush(_ data: [UInt8]) -> [UInt8] {
        let count = data.count
        if count == 0 { return [0x00] }
        if count <= 0x4b { return [UInt8(count)] + data }
        if count <= 0xff { return [0x4c, UInt8(count)] + data }
        if count <= 0xffff {
            return [0x4d, UInt8(count & 0xff), UInt8(count >> 8)] + data
        }
        return [
            0x4e,
            UInt8(count & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 24) & 0xff),
        ] + data
    }

    static func pushLength(_ count: Int) -> Int {
        count + (count <= 0x4b ? 1 : count <= 0xff ? 2 : count <= 0xffff ? 3 : 5)
    }

    /// Reads one push at `offset`: the pushed data and the bytes consumed.
    static func readPush(_ bytes: [UInt8], at offset: Int) -> (data: [UInt8], size: Int)? {
        guard bytes.indices.contains(offset) else { return nil }
        let op = bytes[offset]
        let count: Int
        let header: Int
        switch op {
        case 0x00:
            return ([], 1)
        case 0x01...0x4b:
            count = Int(op)
            header = 1
        case 0x4c:
            guard offset + 1 < bytes.count else { return nil }
            count = Int(bytes[offset + 1])
            header = 2
        case 0x4d:
            guard offset + 2 < bytes.count else { return nil }
            count = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
            header = 3
        case 0x4e:
            guard offset + 4 < bytes.count else { return nil }
            count = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3]) << 16 | Int(bytes[offset + 4]) << 24
            header = 5
        default:
            return nil
        }
        guard offset + header + count <= bytes.count else { return nil }
        return (Array(bytes[(offset + header)..<(offset + header + count)]), header + count)
    }

    /// Fills the template's constructor slots with `args[slot.paramIndex]`.
    static func fillSlots(args: [[UInt8]]) throws -> [UInt8] {
        let ordered = slots.sorted { $0.byteOffset < $1.byteOffset }
        var out: [UInt8] = []
        var cursor = 0
        for slot in ordered {
            guard template[slot.byteOffset] == 0x00 else { throw OrdLockV2Error.templateMismatch }
            guard args.indices.contains(slot.paramIndex) else { throw OrdLockV2Error.templateMismatch }
            out.append(contentsOf: template[cursor..<slot.byteOffset])
            out.append(contentsOf: encodePush(args[slot.paramIndex]))
            cursor = slot.byteOffset + 1
        }
        out.append(contentsOf: template[cursor...])
        return out
    }

    /// Inverse of ``fillSlots(args:)``: walks the template and `deployed` in
    /// lockstep from `offset`. Every non-slot byte must match; one push is
    /// read at each slot. Returns args by paramIndex and the end offset.
    static func readSlots(_ deployed: [UInt8], offset: Int) -> (args: [[UInt8]], end: Int)? {
        let ordered = slots.sorted { $0.byteOffset < $1.byteOffset }
        var args = [[UInt8]](repeating: [], count: slots.count)
        var templateIndex = 0
        var deployedIndex = offset
        var slotIndex = 0
        while templateIndex < template.count {
            if slotIndex < ordered.count, templateIndex == ordered[slotIndex].byteOffset {
                guard let push = readPush(deployed, at: deployedIndex) else { return nil }
                args[ordered[slotIndex].paramIndex] = push.data
                templateIndex += 1
                deployedIndex += push.size
                slotIndex += 1
                continue
            }
            guard deployed.indices.contains(deployedIndex),
                  deployed[deployedIndex] == template[templateIndex]
            else { return nil }
            templateIndex += 1
            deployedIndex += 1
        }
        return (args, deployedIndex)
    }
}

public enum OrdLockV2Error: Error, Equatable, Sendable {
    case invalidSellerHash
    case payoutTooShort
    case notAListing
    case templateMismatch
}
