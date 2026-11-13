import BSVCore
import BSVKeys
import BSVScript
import OneSatCBOR

/// Role of a 1Color output, set only by the id and amount fields:
///
/// | id    | amount | role                                     |
/// |-------|--------|------------------------------------------|
/// | OP_0  | > 0    | `deploy` (fixed supply)                  |
/// | OP_0  | 0      | `deploy` (first authority)               |
/// | push  | 0      | `authority` (minting capability)         |
/// | push  | > 0    | `value` (spendable balance)              |
public enum OneColorRole: String, Equatable, Sendable {
    case deploy
    case value
    case authority
}

/// A token's display image, embedded in the deploy: on the wire the DAG-CBOR array
/// `[mediaType, bytes]`.
public struct OneColorIcon: Equatable, Sendable {
    /// Media type (RFC 6838), e.g. `image/png`.
    public let mediaType: String
    /// The image content.
    public let bytes: [UInt8]

    public init(mediaType: String, bytes: [UInt8]) {
        self.mediaType = mediaType
        self.bytes = bytes
    }
}

/// Deploy display fields, carried as a DAG-CBOR map payload (`sym`, `dec`, `icon` on the wire).
public struct OneColorMetadata: Equatable, Sendable {
    /// `sym`: ticker / name for UI. Not unique: key tokens by id.
    public var symbol: String?
    /// `dec`: decimal places, 0-18.
    public var decimals: Int?
    /// `icon`: the token's display image.
    public var icon: OneColorIcon?

    public init(symbol: String? = nil, decimals: Int? = nil, icon: OneColorIcon? = nil) {
        self.symbol = symbol
        self.decimals = decimals
        self.icon = icon
    }
}

/// Where an output's inner lock comes from: a script, or an address / pubkey hash for P2PKH.
public enum OneColorLock: Equatable, Sendable {
    case script(Script)
    case address(String)
    case publicKeyHash([UInt8])
}

/// An output's optional payload: display fields (encoded as DAG-CBOR) or raw bytes pushed as-is.
/// Display fields only carry protocol meaning on deploys.
public enum OneColorPayload: Equatable, Sendable {
    case metadata(OneColorMetadata)
    case bytes([UInt8])
}

/// A decoded 1Color output.
public struct OneColorToken: Equatable, Sendable {
    public let role: OneColorRole
    /// Asset id `<txid>_<vout>` (display-order txid); nil on deploys.
    public let tokenID: String?
    /// The id as written: 32 bytes (vout 0) or 36 bytes (legacy BRC-161, vout > 0); nil on deploys.
    public let idBytes: [UInt8]?
    /// 0 marks authority; otherwise the value carried.
    public let amount: UInt64
    /// The payload push, when present. `[]` is a present, empty payload.
    /// `OP_1`..`OP_16` / `OP_1NEGATE` give the byte the opcode pushes.
    public let payload: [UInt8]?
    /// The payload as a DAG-CBOR map, when it decodes to one.
    public let payloadMap: DagCborMap?
    /// Display fields read from `payloadMap`; deploys only. Malformed attributes are absent.
    public let metadata: OneColorMetadata?
    /// The rest of the script after the prefix (and payload).
    public let lock: Script
}

public enum OneColorError: Error, Equatable, Sendable {
    /// A value or fixed-supply deploy needs an amount above zero.
    case invalidAmount
    /// A wire id must be 32 or 36 bytes.
    case invalidTokenIDByteCount(Int)
    /// A 36-byte wire id with vout 0 is non-canonical (that token's id is 32 bytes).
    case nonCanonicalTokenID
    /// Not a canonical `<64 lowercase hex txid>_<vout>` asset id.
    case invalidTokenID(String)
    /// `dec` must be 0-18.
    case invalidDecimals(Int)
    /// A P2PKH lock needs a 20-byte public key hash.
    case invalidPublicKeyHash(byteCount: Int)
}

/// 1Color (BRC-162) token template: a stack-neutral prefix of pushes in front of any locking script.
///
/// ```
/// <push token id | OP_0> <push amount | OP_0> OP_2DROP [<push payload> OP_DROP] <lock>
/// ```
///
/// Byte-exact with `@1sat/templates` `OneColor` (the shipped TS code is the source of truth,
/// not the BRC-162 text). There is no tag and no op field: id and amount alone set the role.
///
/// - **Token id**: the deploy's txid in natural byte order (32 bytes), since 1Color deploys are
///   always output 0. Tokens first deployed under BRC-161 at a non-zero output use 36 bytes
///   (txid ‖ uint32 LE vout); a 36-byte id with vout 0 is invalid.
/// - **Amount**: minimal script number, 1 ... 2^64-1 for value; `OP_0` for authority.
/// - **Payload** (optional): any single push followed by `OP_DROP`.
/// - **Empty payload rule**: with no payload given and an inner lock that itself begins with a
///   push followed by `OP_DROP`, the prefix carries an explicit empty payload `OP_0 OP_DROP`.
///
/// Spending a P2PKH inner lock is the plain P2PKH unlock (see `SignP2PKH` in `OneSatActions`).
public struct OneColor: Equatable, Sendable {
    /// Largest amount: 2^64 - 1.
    public static let maxAmount: UInt64 = .max

    /// Wire id (32 or 36 bytes); nil on a deploy.
    public let idBytes: [UInt8]?
    /// 0 = authority, otherwise value.
    public let amount: UInt64
    /// Raw payload bytes, when present: the bytes given, or `[]` under the empty payload rule.
    /// Always equal to what `decode` reads from `lock()`.
    public let payload: [UInt8]?
    /// The locking script after the prefix.
    public let inner: Script

    public init(
        idBytes: [UInt8]? = nil,
        amount: UInt64 = 0,
        payload: [UInt8]? = nil,
        lock: OneColorLock
    ) throws {
        if let idBytes {
            _ = try Self.idToString(idBytes) // validates length and canonical form
        }
        self.idBytes = idBytes
        self.amount = amount
        self.inner = try Self.resolve(lock)
        if let payload {
            self.payload = payload
        } else if Self.startsWithPushDrop(inner.bytes) {
            // Otherwise a decoder would read the inner lock's first push as the payload.
            self.payload = []
        } else {
            self.payload = nil
        }
    }

    // MARK: - Builders

    /// A deploy output. Must be output 0 of its transaction; its outpoint becomes the token id.
    /// - Parameter amount: the fixed supply, or nil / 0 for an authority deploy.
    public static func deploy(
        amount: UInt64?,
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        try OneColor(amount: amount ?? 0, payload: try payloadBytes(payload), lock: lock)
    }

    /// A fixed-supply deploy: the whole supply in this output (output 0).
    public static func deployValue(
        amount: UInt64,
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        guard amount > 0 else { throw OneColorError.invalidAmount }
        return try deploy(amount: amount, lock: lock, payload: payload)
    }

    /// An authority deploy: the token's first minting authority (output 0).
    public static func deployAuthority(
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        try deploy(amount: 0, lock: lock, payload: payload)
    }

    /// A value output: a transfer, or a mint when the transaction also spends an authority.
    public static func value(
        tokenID: String,
        amount: UInt64,
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        try value(idBytes: try idFromString(tokenID), amount: amount, lock: lock, payload: payload)
    }

    /// A value output from wire id bytes.
    public static func value(
        idBytes: [UInt8],
        amount: UInt64,
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        guard amount > 0 else { throw OneColorError.invalidAmount }
        return try OneColor(idBytes: idBytes, amount: amount, payload: try payloadBytes(payload), lock: lock)
    }

    /// An authority output (minting capability). Valid only in a transaction that spends an
    /// authority of the same token.
    public static func authority(
        tokenID: String,
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        try authority(idBytes: try idFromString(tokenID), lock: lock, payload: payload)
    }

    /// An authority output from wire id bytes.
    public static func authority(
        idBytes: [UInt8],
        lock: OneColorLock,
        payload: OneColorPayload? = nil
    ) throws -> OneColor {
        try OneColor(idBytes: idBytes, amount: 0, payload: try payloadBytes(payload), lock: lock)
    }

    // MARK: - Ids

    /// Wire id → canonical BRC-207 asset id `<txid>_<vout>` (64 lowercase hex, display order).
    /// Throws on a length other than 32 or 36, or a 36-byte id with vout 0.
    public static func idToString(_ bytes: [UInt8]) throws -> String {
        guard bytes.count == 32 || bytes.count == 36 else {
            throw OneColorError.invalidTokenIDByteCount(bytes.count)
        }
        if bytes.count == 36 && readUInt32LE(bytes, at: 32) == 0 {
            throw OneColorError.nonCanonicalTokenID
        }
        return outpointString(bytes)
    }

    /// Canonical asset id `<txid>_<vout>` → wire id: 32 bytes when vout is 0, otherwise 36.
    /// Accepts exactly the form `idToString` produces: no `txid.vout`, no uppercase, no bare txid.
    public static func idFromString(_ string: String) throws -> [UInt8] {
        let text = Array(string.utf8)
        let invalid = OneColorError.invalidTokenID(string)
        guard text.count >= 66, text[64] == UInt8(ascii: "_") else { throw invalid }
        let hexDigits = text[0..<64]
        guard hexDigits.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw invalid
        }
        let voutDigits = Array(text[65...])
        guard voutDigits.count <= 10,
              voutDigits.allSatisfy({ (0x30...0x39).contains($0) }),
              voutDigits == [0x30] || voutDigits.first != 0x30
        else { throw invalid }
        let vout = voutDigits.reduce(UInt64(0)) { $0 * 10 + UInt64($1 - 0x30) }
        guard vout <= UInt64(UInt32.max) else { throw invalid }
        let txid = try Hex.decode(String(decoding: hexDigits, as: UTF8.self), maximumDecodedByteCount: 32)
        let natural = Array(txid.reversed())
        guard vout != 0 else { return natural }
        let v = UInt32(vout)
        return natural + [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]
    }

    /// The asset id; nil on a deploy (the id is that output's own outpoint).
    public var tokenID: String? {
        idBytes.map(Self.outpointString)
    }

    /// The output's role.
    public var role: OneColorRole {
        guard idBytes != nil else { return .deploy }
        return amount == 0 ? .authority : .value
    }

    // MARK: - Metadata

    /// Encodes display fields as a DAG-CBOR map payload; nil when there are none.
    public static func encodeMetadata(_ metadata: OneColorMetadata) throws -> [UInt8]? {
        var entries: [(key: String, value: DagCborValue)] = []
        if let symbol = metadata.symbol {
            entries.append((key: "sym", value: .text(symbol)))
        }
        if let decimals = metadata.decimals {
            guard (0...18).contains(decimals) else { throw OneColorError.invalidDecimals(decimals) }
            entries.append((key: "dec", value: .unsigned(UInt64(decimals))))
        }
        if let icon = metadata.icon {
            entries.append((key: "icon", value: .array([.text(icon.mediaType), .bytes(icon.bytes)])))
        }
        guard !entries.isEmpty else { return nil }
        return try DagCbor.encode(.map(try DagCborMap(entries)))
    }

    // MARK: - Script

    /// The prefix alone: id, amount, `OP_2DROP` and, when `payload` is set (including the empty
    /// payload rule), the payload push with `OP_DROP`.
    public func prefix() throws -> Script {
        var script = try TemplateScript.empty()
        if let idBytes {
            try TemplateScript.appendPush(idBytes, to: &script) // 32 / 36 bytes: always a direct push
        } else {
            try TemplateScript.append(.zero, to: &script)
        }
        try TemplateScript.appendMinimalNumber(amount, to: &script)
        try TemplateScript.append(.twoDrop, to: &script)
        if let payload {
            try TemplateScript.appendMinimalPush(payload, to: &script)
            try TemplateScript.append(.drop, to: &script)
        }
        return script
    }

    /// The full locking script: prefix followed by the inner lock.
    public func lock() throws -> Script {
        try TemplateScript.concatenating([try prefix().bytes, inner.bytes])
    }

    // MARK: - Decode

    /// Decodes a 1Color output, or nil when the script does not begin with a valid prefix.
    ///
    /// Follows the reference decoder (amm-poc `brc162.zig`) as the TS does: the id must be
    /// `OP_0` or a direct push of exactly 32 or 36 bytes; the amount must be `OP_0`,
    /// `OP_1`..`OP_16`, or a direct push of a minimal, non-negative script number above 16 and
    /// at most 2^64-1. The payload push is not checked for minimality. A valid prefix wins over
    /// any BRC-161 inscription that follows; that is just part of `lock`.
    public static func decode(_ script: Script) -> OneColorToken? {
        let s = script.bytes

        guard let idPush = readPush(s, at: 0) else { return nil }
        var idBytes: [UInt8]?
        switch idPush.op {
        case 0x20:
            idBytes = idPush.data
        case 0x24:
            guard readUInt32LE(idPush.data, at: 32) != 0 else { return nil }
            idBytes = idPush.data
        case 0x00:
            idBytes = nil
        default:
            return nil
        }

        guard let amountPush = readPush(s, at: idPush.next),
              let amount = amountOf(amountPush)
        else { return nil }
        var position = amountPush.next
        guard position < s.count, s[position] == opTwoDrop else { return nil }
        position += 1

        var payload: [UInt8]?
        if let push = readPush(s, at: position), push.next < s.count, s[push.next] == opDrop {
            payload = push.data
            position = push.next + 1
        }

        let role: OneColorRole = idBytes == nil ? .deploy : (amount == 0 ? .authority : .value)
        let rest = Array(s[position...])
        guard let lock = try? Script(bytes: rest, maximumByteCount: rest.count) else { return nil }

        var payloadMap: DagCborMap?
        var metadata: OneColorMetadata?
        if let payload, case .map(let map)? = decodeDagCbor(payload) {
            payloadMap = map
            if role == .deploy {
                metadata = metadataOf(map)
            }
        }

        return OneColorToken(
            role: role,
            tokenID: idBytes.map(outpointString),
            idBytes: idBytes,
            amount: amount,
            payload: payload,
            payloadMap: payloadMap,
            metadata: metadata,
            lock: lock
        )
    }

    // MARK: - Private

    private static let opTwoDrop: UInt8 = 0x6d
    private static let opDrop: UInt8 = 0x75

    private struct Push {
        let op: UInt8
        let data: [UInt8]
        let next: Int
    }

    /// The push operation at `position`, or nil when it is not a push or overruns the script.
    private static func readPush(_ s: [UInt8], at position: Int) -> Push? {
        guard position < s.count else { return nil }
        let op = s[position]
        var at = position + 1
        let length: Int
        switch op {
        case 0x00:
            length = 0
        case 0x01...0x4b:
            length = Int(op)
        case 0x4c:
            guard at + 1 <= s.count else { return nil }
            length = Int(s[at])
            at += 1
        case 0x4d:
            guard at + 2 <= s.count else { return nil }
            length = Int(s[at]) | Int(s[at + 1]) << 8
            at += 2
        case 0x4e:
            guard at + 4 <= s.count else { return nil }
            length = Int(readUInt32LE(s, at: at))
            at += 4
        case 0x4f:
            return Push(op: op, data: [0x81], next: at)
        case 0x51...0x60:
            return Push(op: op, data: [op - 0x50], next: at)
        default:
            return nil
        }
        guard length <= s.count - at else { return nil }
        return Push(op: op, data: Array(s[at..<(at + length)]), next: at + length)
    }

    private static func amountOf(_ push: Push) -> UInt64? {
        switch push.op {
        case 0x00:
            return 0
        case 0x51...0x60:
            return UInt64(push.op - 0x50)
        case 0x01...0x09:
            // MINIMALDATA: 0 and 1...16 have shorter opcode forms.
            guard let value = scriptNumberUInt64(push.data), value > 16 else { return nil }
            return value
        default:
            return nil
        }
    }

    /// A minimal, non-negative script number of at most 9 bytes up to 2^64-1, else nil.
    private static func scriptNumberUInt64(_ b: [UInt8]) -> UInt64? {
        guard let last = b.last else { return 0 }
        guard b.count <= 9, last & 0x80 == 0 else { return nil }
        if last == 0 && (b.count == 1 || b[b.count - 2] & 0x80 == 0) { return nil }
        if b.count == 9 && last != 0 { return nil }
        var value: UInt64 = 0
        for byte in b.prefix(8).reversed() {
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    /// Whether a script begins with a push operation followed by `OP_DROP`.
    private static func startsWithPushDrop(_ s: [UInt8]) -> Bool {
        guard let push = readPush(s, at: 0) else { return false }
        return push.next < s.count && s[push.next] == opDrop
    }

    private static func readUInt32LE(_ b: [UInt8], at index: Int) -> UInt32 {
        UInt32(b[index]) | UInt32(b[index + 1]) << 8 | UInt32(b[index + 2]) << 16 | UInt32(b[index + 3]) << 24
    }

    private static func outpointString(_ bytes: [UInt8]) -> String {
        let txid = Hex.encode(Array(bytes[0..<32].reversed()))
        let vout = bytes.count == 36 ? readUInt32LE(bytes, at: 32) : 0
        return "\(txid)_\(vout)"
    }

    private static func resolve(_ lock: OneColorLock) throws -> Script {
        switch lock {
        case .script(let script):
            return script
        case .address(let text):
            return try Script.payToPublicKeyHash(
                try Address(text),
                maximumByteCount: TemplateScript.maximumByteCount
            )
        case .publicKeyHash(let bytes):
            guard bytes.count == 20 else {
                throw OneColorError.invalidPublicKeyHash(byteCount: bytes.count)
            }
            return try Script.payToPublicKeyHash(
                try Hash160(bytes),
                maximumByteCount: TemplateScript.maximumByteCount
            )
        }
    }

    private static func payloadBytes(_ payload: OneColorPayload?) throws -> [UInt8]? {
        switch payload {
        case nil:
            return nil
        case .bytes(let bytes)?:
            return bytes
        case .metadata(let metadata)?:
            return try encodeMetadata(metadata)
        }
    }

    /// BRC-162 display fields: `sym` text, `dec` unsigned integer 0-18, `icon` exactly
    /// `[text, bytes]`. A malformed attribute is absent; the others are unaffected.
    private static func metadataOf(_ map: DagCborMap) -> OneColorMetadata {
        var metadata = OneColorMetadata()
        if case .text(let symbol)? = map["sym"] {
            metadata.symbol = symbol
        }
        if case .unsigned(let decimals)? = map["dec"], decimals <= 18 {
            metadata.decimals = Int(decimals)
        }
        if case .array(let items)? = map["icon"], items.count == 2,
           case .text(let mediaType) = items[0],
           case .bytes(let bytes) = items[1] {
            metadata.icon = OneColorIcon(mediaType: mediaType, bytes: bytes)
        }
        return metadata
    }
}
