/// Strict DAG-CBOR, matching `@ipld/dag-cbor` 10 (cborg 6, multiformats 14) as the 1Sat
/// TypeScript stack uses it.
///
/// The decoder accepts exactly what the JS library accepts by default, because the shipped TS
/// code is the source of truth:
/// - minimal heads everywhere (ints, lengths, tag numbers); no indefinite lengths;
/// - map keys must be text and unique, but need **not** be in canonical order;
/// - only tag 42 (a CID link, `0x00`-prefixed bytes); no simple values except false/true/null;
///   `undefined` (`f7`) decodes as null;
/// - 16-, 32- and 64-bit floats are accepted; NaN and infinities are rejected;
/// - invalid UTF-8 in text is repaired to U+FFFD, as JS `TextDecoder` does.
///
/// `DecodeOptions` offers stricter opt-ins (canonical key order, strict UTF-8) for callers that
/// want spec-strict DAG-CBOR. The encoder is always canonical: shortest heads, map keys ordered
/// by UTF-8 length then bytewise, floats as 64-bit.

/// A DAG-CBOR link (tag 42): the CID bytes, without the leading `0x00` multibase prefix.
public struct DagCborLink: Hashable, Sendable {
    public let cid: [UInt8]

    public init(cid: [UInt8]) {
        self.cid = cid
    }
}

/// A DAG-CBOR value. One case per wire type, so the CBOR major type survives decoding.
public enum DagCborValue: Hashable, Sendable {
    /// Major type 0.
    case unsigned(UInt64)
    /// Major type 1. The payload is the wire argument `n`; the value is `-1 - n`.
    case negative(UInt64)
    /// Major type 2.
    case bytes([UInt8])
    /// Major type 3.
    case text(String)
    /// Major type 4.
    case array([DagCborValue])
    /// Major type 5.
    case map(DagCborMap)
    /// Tag 42.
    case link(DagCborLink)
    /// `f4` / `f5`.
    case bool(Bool)
    /// `f6` (and `f7`, which decodes as null).
    case null
    /// `f9` / `fa` / `fb` on decode; always `fb` on encode.
    case float(Double)

    /// The CBOR major type this value is written with.
    public var majorType: UInt8 {
        switch self {
        case .unsigned: 0
        case .negative: 1
        case .bytes: 2
        case .text: 3
        case .array: 4
        case .map: 5
        case .link: 6
        case .bool, .null, .float: 7
        }
    }

    public var unsignedValue: UInt64? {
        if case .unsigned(let value) = self { return value }
        return nil
    }

    /// The integer value of an unsigned or negative integer, when it fits in `Int64`.
    public var int64Value: Int64? {
        switch self {
        case .unsigned(let value):
            return value <= UInt64(Int64.max) ? Int64(value) : nil
        case .negative(let n):
            return n <= UInt64(Int64.max) ? -1 - Int64(n) : nil
        default:
            return nil
        }
    }

    public var bytesValue: [UInt8]? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    public var textValue: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    public var arrayValue: [DagCborValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var mapValue: DagCborMap? {
        if case .map(let value) = self { return value }
        return nil
    }

    public var linkValue: DagCborLink? {
        if case .link(let value) = self { return value }
        return nil
    }
}

/// A text-keyed DAG-CBOR map.
///
/// Keys are compared by their exact UTF-8 bytes, as JavaScript compares strings, not by Swift's
/// Unicode-canonical `String` equality: NFC and NFD spellings are two different keys. Entries are
/// held in canonical order (UTF-8 length, then bytewise).
public struct DagCborMap: Hashable, Sendable, ExpressibleByDictionaryLiteral {
    private var storage: [(key: String, value: DagCborValue)]

    public init() {
        storage = []
    }

    /// Creates a map from entries in any order. Throws on a duplicate key.
    public init(_ entries: [(key: String, value: DagCborValue)]) throws {
        let sorted = entries.sorted { Self.keyPrecedes($0.key, $1.key) }
        for index in sorted.indices.dropFirst()
        where Array(sorted[index - 1].key.utf8) == Array(sorted[index].key.utf8) {
            throw DagCborError.duplicateMapKey
        }
        storage = sorted
    }

    public init(dictionaryLiteral elements: (String, DagCborValue)...) {
        do {
            try self.init(elements.map { (key: $0.0, value: $0.1) })
        } catch {
            preconditionFailure("DagCborMap literal has a duplicate key")
        }
    }

    /// Entries in canonical order.
    public var entries: [(key: String, value: DagCborValue)] { storage }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    public var keys: [String] { storage.map(\.key) }

    public subscript(key: String) -> DagCborValue? {
        let target = Array(key.utf8)
        return storage.first { Array($0.key.utf8) == target }?.value
    }

    public static func == (lhs: DagCborMap, rhs: DagCborMap) -> Bool {
        guard lhs.storage.count == rhs.storage.count else { return false }
        return zip(lhs.storage, rhs.storage).allSatisfy {
            Array($0.key.utf8) == Array($1.key.utf8) && $0.value == $1.value
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage.count)
        for entry in storage {
            hasher.combine(Array(entry.key.utf8))
            hasher.combine(entry.value)
        }
    }

    /// Canonical DAG-CBOR key order: shorter UTF-8 first, then bytewise.
    static func keyPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        if a.count != b.count { return a.count < b.count }
        return a.lexicographicallyPrecedes(b)
    }
}

public enum DagCborError: Error, Equatable, Sendable {
    case empty
    case truncated
    case trailingBytes
    case invalidMinor(UInt8)
    case nonMinimalInteger
    case indefiniteLength
    case unsupportedSimpleValue(UInt8)
    case nonFiniteFloat
    case nonTextMapKey
    case duplicateMapKey
    case unorderedMapKeys
    case unsupportedTag(UInt64)
    case invalidLink
    case invalidUTF8
    case nestingTooDeep
}

public enum DagCbor {
    public struct DecodeOptions: Hashable, Sendable {
        /// Deepest array/map/tag nesting accepted. JS has no fixed limit (it fails on stack
        /// exhaustion); Swift caps it so hostile input cannot crash the process.
        public var maximumNestingDepth: Int
        /// Reject text that is not valid UTF-8 instead of repairing it (JS repairs).
        public var strictUTF8: Bool
        /// Reject maps whose keys are not in canonical order (JS does not check).
        public var requireCanonicalMapOrder: Bool

        public init(
            maximumNestingDepth: Int = 128,
            strictUTF8: Bool = false,
            requireCanonicalMapOrder: Bool = false
        ) {
            self.maximumNestingDepth = maximumNestingDepth
            self.strictUTF8 = strictUTF8
            self.requireCanonicalMapOrder = requireCanonicalMapOrder
        }
    }

    /// Decodes exactly one DAG-CBOR item; trailing bytes are an error.
    public static func decode(
        _ bytes: [UInt8],
        options: DecodeOptions = DecodeOptions()
    ) throws -> DagCborValue {
        guard !bytes.isEmpty else { throw DagCborError.empty }
        var reader = Reader(bytes: bytes, options: options)
        let value = try reader.readValue(depth: 0)
        guard reader.position == bytes.count else { throw DagCborError.trailingBytes }
        return value
    }

    /// Encodes a value canonically.
    public static func encode(_ value: DagCborValue) throws -> [UInt8] {
        var out: [UInt8] = []
        try write(value, into: &out)
        return out
    }

    /// Whether `bytes` is a binary CID that multiformats `CID.decode` accepts.
    public static func isValidCID(_ bytes: [UInt8]) -> Bool {
        canonicalCID(bytes) != nil
    }

    /// The CID bytes multiformats reports for a binary CID (`cid.bytes`), or nil when
    /// `CID.decode` rejects it. A CIDv0 is reported as its bare multihash: for the usual
    /// `0x12 ...` form that is the input itself, but an explicit version-0 prefix
    /// (`0x00 <codec>`) is accepted and dropped.
    static func canonicalCID(_ bytes: [UInt8]) -> [UInt8]? {
        var position = 0
        func next() -> UInt64? {
            guard let (value, length) = readVarint(bytes, at: position) else { return nil }
            position += length
            return value
        }
        guard let version = next() else { return nil }
        if version == 18 {
            // CIDv0: the whole thing is a multihash.
            position = 0
        } else {
            guard version == 0 || version == 1, next() != nil else { return nil }
        }
        let multihashStart = position
        guard next() != nil, let digestSize = next() else { return nil }
        guard digestSize <= UInt64(bytes.count - position),
              position + Int(digestSize) == bytes.count
        else { return nil }
        return version == 0 ? Array(bytes[multihashStart...]) : bytes
    }

    // MARK: - Encoding

    private static func writeHead(_ major: UInt8, _ argument: UInt64, into out: inout [UInt8]) {
        let base = major << 5
        switch argument {
        case 0..<24:
            out.append(base | UInt8(argument))
        case 24...0xff:
            out.append(base | 24)
            out.append(UInt8(argument))
        case 0x100...0xffff:
            out.append(base | 25)
            appendBigEndian(argument, byteCount: 2, into: &out)
        case 0x1_0000...0xffff_ffff:
            out.append(base | 26)
            appendBigEndian(argument, byteCount: 4, into: &out)
        default:
            out.append(base | 27)
            appendBigEndian(argument, byteCount: 8, into: &out)
        }
    }

    private static func appendBigEndian(_ value: UInt64, byteCount: Int, into out: inout [UInt8]) {
        for shift in stride(from: (byteCount - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func write(_ value: DagCborValue, into out: inout [UInt8]) throws {
        switch value {
        case .unsigned(let n):
            writeHead(0, n, into: &out)
        case .negative(let n):
            writeHead(1, n, into: &out)
        case .bytes(let bytes):
            writeHead(2, UInt64(bytes.count), into: &out)
            out.append(contentsOf: bytes)
        case .text(let text):
            let utf8 = Array(text.utf8)
            writeHead(3, UInt64(utf8.count), into: &out)
            out.append(contentsOf: utf8)
        case .array(let items):
            writeHead(4, UInt64(items.count), into: &out)
            for item in items {
                try write(item, into: &out)
            }
        case .map(let map):
            writeHead(5, UInt64(map.count), into: &out)
            for entry in map.entries {
                try write(.text(entry.key), into: &out)
                try write(entry.value, into: &out)
            }
        case .link(let link):
            // Write the CID as multiformats reports it, so an explicit CIDv0 prefix is
            // normalized and encode -> decode -> encode is stable.
            guard let cid = canonicalCID(link.cid) else { throw DagCborError.invalidLink }
            writeHead(6, 42, into: &out)
            try write(.bytes([0x00] + cid), into: &out)
        case .bool(let flag):
            out.append(flag ? 0xf5 : 0xf4)
        case .null:
            out.append(0xf6)
        case .float(let double):
            guard double.isFinite else { throw DagCborError.nonFiniteFloat }
            out.append(0xfb)
            appendBigEndian(double.bitPattern, byteCount: 8, into: &out)
        }
    }

    // MARK: - Decoding

    /// Unsigned LEB128 as multiformats reads it: at most 9 bytes, minimal.
    static func readVarint(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while true {
            guard index < bytes.count, index - start < 9 else { return nil }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7f) << shift
            shift += 7
            if byte < 0x80 { break }
        }
        let length = index - start
        if length > 1 && bytes[index - 1] == 0 { return nil }
        return (value, length)
    }

    private struct Reader {
        let bytes: [UInt8]
        let options: DecodeOptions
        var position = 0

        init(bytes: [UInt8], options: DecodeOptions) {
            self.bytes = bytes
            self.options = options
        }

        var remaining: Int { bytes.count - position }

        mutating func readByte() throws -> UInt8 {
            guard position < bytes.count else { throw DagCborError.truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func readBigEndian(_ count: Int) throws -> UInt64 {
            guard remaining >= count else { throw DagCborError.truncated }
            var value: UInt64 = 0
            for _ in 0..<count {
                value = value << 8 | UInt64(bytes[position])
                position += 1
            }
            return value
        }

        mutating func readSlice(_ length: UInt64) throws -> [UInt8] {
            guard length <= UInt64(remaining) else { throw DagCborError.truncated }
            let end = position + Int(length)
            defer { position = end }
            return Array(bytes[position..<end])
        }

        /// The argument of a head whose additional info is `minor`, minimal-checked.
        mutating func readArgument(minor: UInt8) throws -> UInt64 {
            switch minor {
            case 0..<24:
                return UInt64(minor)
            case 24:
                let value = try readBigEndian(1)
                guard value >= 24 else { throw DagCborError.nonMinimalInteger }
                return value
            case 25:
                let value = try readBigEndian(2)
                guard value > 0xff else { throw DagCborError.nonMinimalInteger }
                return value
            case 26:
                let value = try readBigEndian(4)
                guard value > 0xffff else { throw DagCborError.nonMinimalInteger }
                return value
            case 27:
                let value = try readBigEndian(8)
                guard value > 0xffff_ffff else { throw DagCborError.nonMinimalInteger }
                return value
            case 31:
                throw DagCborError.indefiniteLength
            default:
                throw DagCborError.invalidMinor(minor)
            }
        }

        mutating func readText(_ length: UInt64) throws -> String {
            let raw = try readSlice(length)
            let text = String(decoding: raw, as: UTF8.self)
            if options.strictUTF8 && Array(text.utf8) != raw {
                throw DagCborError.invalidUTF8
            }
            return text
        }

        mutating func readValue(depth: Int) throws -> DagCborValue {
            let initial = try readByte()
            let major = initial >> 5
            let minor = initial & 0x1f

            if major == 7 {
                return try readSimple(minor: minor)
            }
            let argument = try readArgument(minor: minor)

            switch major {
            case 0:
                return .unsigned(argument)
            case 1:
                return .negative(argument)
            case 2:
                return .bytes(try readSlice(argument))
            case 3:
                return .text(try readText(argument))
            case 4:
                guard depth < options.maximumNestingDepth else { throw DagCborError.nestingTooDeep }
                var items: [DagCborValue] = []
                var index: UInt64 = 0
                while index < argument {
                    guard remaining > 0 else { throw DagCborError.truncated }
                    items.append(try readValue(depth: depth + 1))
                    index += 1
                }
                return .array(items)
            case 5:
                guard depth < options.maximumNestingDepth else { throw DagCborError.nestingTooDeep }
                return .map(try readMap(count: argument, depth: depth))
            default: // 6
                guard argument == 42 else { throw DagCborError.unsupportedTag(argument) }
                guard depth < options.maximumNestingDepth else { throw DagCborError.nestingTooDeep }
                return .link(try readLink(depth: depth))
            }
        }

        mutating func readMap(count: UInt64, depth: Int) throws -> DagCborMap {
            var entries: [(key: String, value: DagCborValue)] = []
            var seen = Set<[UInt8]>()
            var previousKey: [UInt8]?
            var index: UInt64 = 0
            while index < count {
                guard remaining > 0 else { throw DagCborError.truncated }
                let keyHead = try readByte()
                guard keyHead >> 5 == 3 else { throw DagCborError.nonTextMapKey }
                let key = try readText(try readArgument(minor: keyHead & 0x1f))
                // Duplicates compare the decoded string, as JS object keys do.
                let keyBytes = Array(key.utf8)
                guard seen.insert(keyBytes).inserted else { throw DagCborError.duplicateMapKey }
                if options.requireCanonicalMapOrder, let previous = previousKey {
                    let ordered = previous.count != keyBytes.count
                        ? previous.count < keyBytes.count
                        : previous.lexicographicallyPrecedes(keyBytes)
                    guard ordered else { throw DagCborError.unorderedMapKeys }
                }
                previousKey = keyBytes
                guard remaining > 0 else { throw DagCborError.truncated }
                entries.append((key: key, value: try readValue(depth: depth + 1)))
                index += 1
            }
            return try DagCborMap(entries)
        }

        mutating func readLink(depth: Int) throws -> DagCborLink {
            guard remaining > 0 else { throw DagCborError.truncated }
            let content = try readValue(depth: depth + 1)
            guard case .bytes(let bytes) = content,
                  bytes.first == 0x00
            else { throw DagCborError.invalidLink }
            guard let cid = DagCbor.canonicalCID(Array(bytes.dropFirst())) else {
                throw DagCborError.invalidLink
            }
            return DagCborLink(cid: cid)
        }

        mutating func readSimple(minor: UInt8) throws -> DagCborValue {
            switch minor {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22, 23: return .null // undefined is coerced to null
            case 24:
                let value = try readByte()
                throw DagCborError.unsupportedSimpleValue(value)
            case 25:
                return .float(try finite(halfToDouble(UInt16(try readBigEndian(2)))))
            case 26:
                return .float(try finite(Double(Float(bitPattern: UInt32(try readBigEndian(4))))))
            case 27:
                return .float(try finite(Double(bitPattern: try readBigEndian(8))))
            case 31:
                throw DagCborError.indefiniteLength
            case 28, 29, 30:
                throw DagCborError.invalidMinor(minor)
            default:
                throw DagCborError.unsupportedSimpleValue(minor)
            }
        }

        func finite(_ value: Double) throws -> Double {
            guard value.isFinite else { throw DagCborError.nonFiniteFloat }
            return value
        }

        /// IEEE 754 binary16 → Double, by hand (`Float16` is unavailable on Intel macOS).
        func halfToDouble(_ bits: UInt16) -> Double {
            let sign: Double = bits & 0x8000 == 0 ? 1 : -1
            let exponent = Int((bits >> 10) & 0x1f)
            let fraction = Double(bits & 0x3ff)
            switch exponent {
            case 0:
                return sign * fraction * 0x1p-24
            case 0x1f:
                return fraction == 0 ? sign * .infinity : .nan
            default:
                return sign * (1 + fraction / 1024) * Double(sign: .plus, exponent: exponent - 15, significand: 1)
            }
        }
    }
}

/// `decodeDagCbor` from the TS: the decoded value, or nil where `@ipld/dag-cbor` would throw.
/// `.null` is a real value, distinct from nil.
public func decodeDagCbor(_ bytes: [UInt8]) -> DagCborValue? {
    try? DagCbor.decode(bytes)
}
