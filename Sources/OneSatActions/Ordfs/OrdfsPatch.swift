import BSVTransaction

/// `ordfs/patch`: a VCDIFF delta against an earlier inscription, from
/// `packages/actions/src/ordfs/patch.ts`.
///
/// Envelope (version 0): `[1B version][36B base outpoint][VCDIFF delta]`, where the outpoint is
/// the transaction-wire form (internal-order txid, little-endian vout) and the delta carries the
/// plain RFC 3284 header `D6 C3 C4 00 00`.
public enum OrdfsPatch {
    /// Content type written on `ordfs/patch` inscription outputs.
    public static let contentType = "ordfs/patch"

    /// Current patch envelope version.
    public static let version = 0

    /// Version byte, outpoint, and the five-byte VCDIFF header.
    public static let minimumByteCount = 1 + 36 + 5

    /// Encodes a patch envelope; the delta must start with the plain RFC header.
    public static func encode(_ record: OrdfsPatchRecord) throws -> [UInt8] {
        guard record.version == version else {
            throw OrdfsPatchFormatError("unsupported patch version \(record.version)")
        }
        do {
            try Vcdiff.assertPlainRFC(record.delta)
        } catch let error as VcdiffError {
            throw OrdfsPatchFormatError(error.message)
        }
        return [UInt8(version)] + record.base.wireBytes + record.delta
    }

    /// Decodes a patch envelope. The delta itself is checked only when applied.
    public static func decode(_ bytes: [UInt8]) throws -> OrdfsPatchRecord {
        guard bytes.count >= minimumByteCount else {
            throw OrdfsPatchFormatError("patch too short")
        }
        guard Int(bytes[0]) == version else {
            throw OrdfsPatchFormatError("unsupported patch version \(bytes[0])")
        }
        let base: Outpoint
        do {
            base = try Outpoint(wireBytes: Array(bytes[1..<37]))
        } catch {
            throw OrdfsPatchFormatError("outpoint wire length must be 36")
        }
        return OrdfsPatchRecord(version: version, base: base, delta: Array(bytes[37...]))
    }

    /// Builds a patch turning `source` into `target`. Identical content must be cited directly
    /// from a manifest entry, never written as an empty patch.
    public static func fromContent(base: Outpoint, source: [UInt8], target: [UInt8]) throws -> [UInt8] {
        guard source != target else {
            throw OrdfsPatchFormatError("identical content must be a direct citation, never a patch")
        }
        return try encode(OrdfsPatchRecord(
            version: version,
            base: base,
            delta: Vcdiff.encode(target, source: source)
        ))
    }

    /// Applies `record` to the base content, mapping VCDIFF failures to ``OrdfsPatchFormatError``.
    public static func apply(_ record: OrdfsPatchRecord, source: [UInt8]) throws -> [UInt8] {
        do {
            return try Vcdiff.decode(record.delta, source: source)
        } catch let error as VcdiffError {
            throw OrdfsPatchFormatError(error.message)
        }
    }
}

/// A decoded `ordfs/patch` envelope.
public struct OrdfsPatchRecord: Hashable, Sendable {
    public var version: Int
    /// The inscription whose content is the delta's source.
    public var base: Outpoint
    public var delta: [UInt8]

    public init(version: Int = OrdfsPatch.version, base: Outpoint, delta: [UInt8]) {
        self.version = version
        self.base = base
        self.delta = delta
    }
}

/// A malformed `ordfs/patch` envelope or a delta that does not apply.
public struct OrdfsPatchFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
