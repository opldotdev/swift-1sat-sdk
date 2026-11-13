import BSVTransaction

/// `ordfs/dir`: the binary directory manifest codec from `packages/actions/src/ordfs/dir.ts`.
///
/// The binary sibling of the `ord-fs/json` manifest: a directory maps child names to outpoint
/// references in a fixed byte layout, so the same logical directory always encodes to the same
/// bytes and so to the same SHA-256.
///
/// Layout (big-endian integers, no varints, no padding):
///
///     dir   := [1B version = 0x01][2B entry count][entries, ascending by raw name bytes]
///     entry := [1B flags][1B name length 1...255][name][target]
///
/// Flags: bit 0 directory, bit 1 executable, bit 2 symlink, bit 3 reference type; bits 4-7 must
/// be zero. Reference type 0 is a same-transaction output (`[1B vout]`); type 1 is a full
/// outpoint (`[32B txid in internal order][4B vout LE]`). Writers emit canonical form only and
/// readers reject anything else.
public enum OrdfsDir {
    /// Content type written on `ordfs/dir` inscription outputs.
    public static let contentType = "ordfs/dir"

    /// Legacy JSON manifest content type (read support only going forward).
    public static let legacyJSONContentType = "ord-fs/json"

    /// Current manifest format version.
    public static let version = 1

    /// Maximum entries in one manifest (the count is a `UInt16`).
    public static let maximumEntryCount = 0xffff

    static let flagDirectory: UInt8 = 0x01
    static let flagExec: UInt8 = 0x02
    static let flagSymlink: UInt8 = 0x04
    static let flagReferenceType: UInt8 = 0x08
    static let flagsReserved: UInt8 = 0xf0

    /// Orders names ascending by unsigned raw bytes, shorter prefix first.
    public static func namePrecedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.lexicographicallyPrecedes(b)
    }

    /// Encodes `manifest` canonically: entries are sorted by raw name bytes, and duplicate
    /// names or any spec violation throw ``OrdfsDirFormatError``.
    public static func encode(_ manifest: OrdfsDirManifest) throws -> [UInt8] {
        guard manifest.version == version else {
            throw OrdfsDirFormatError("unsupported dir version \(manifest.version)")
        }
        guard manifest.entries.count <= maximumEntryCount else {
            throw OrdfsDirFormatError("entry count \(manifest.entries.count) exceeds uint16")
        }
        let entries = manifest.entries.sorted { namePrecedes($0.name, $1.name) }
        for (previous, entry) in zip(entries, entries.dropFirst()) where previous.name == entry.name {
            throw OrdfsDirFormatError("duplicate entry name: \(nameString(entry.name))")
        }

        var out: [UInt8] = [UInt8(version), UInt8(entries.count >> 8), UInt8(entries.count & 0xff)]
        for entry in entries {
            try validate(entry)
            var flags: UInt8 = 0
            if entry.isDirectory { flags |= flagDirectory }
            if entry.exec { flags |= flagExec }
            if entry.symlink { flags |= flagSymlink }
            if case .outpoint = entry.ref { flags |= flagReferenceType }
            out.append(flags)
            out.append(UInt8(entry.name.count))
            out += entry.name
            switch entry.ref {
            case .sameTx(let vout):
                out.append(UInt8(vout))
            case .outpoint(let outpoint):
                out += outpoint.wireBytes
            }
        }
        return out
    }

    /// Decodes `ordfs/dir` bytes strictly: known version, canonical sorted order, unique names,
    /// zero reserved bits, legal names, and no trailing bytes.
    public static func decode(_ bytes: [UInt8]) throws -> OrdfsDirManifest {
        guard bytes.count >= 3 else {
            throw OrdfsDirFormatError("dir manifest too short")
        }
        guard Int(bytes[0]) == version else {
            throw OrdfsDirFormatError("unsupported dir version \(bytes[0])")
        }
        let count = Int(bytes[1]) << 8 | Int(bytes[2])
        var entries: [OrdfsDirEntry] = []
        entries.reserveCapacity(min(count, bytes.count / 3))
        var p = 3

        for _ in 0..<count {
            guard p + 2 <= bytes.count else {
                throw OrdfsDirFormatError("truncated dir manifest")
            }
            let flags = bytes[p]
            p += 1
            guard flags & flagsReserved == 0 else {
                throw OrdfsDirFormatError("reserved flag bits must be zero")
            }
            let nameLength = Int(bytes[p])
            p += 1
            guard nameLength >= 1, p + nameLength <= bytes.count else {
                throw OrdfsDirFormatError("truncated or empty entry name")
            }
            let name = Array(bytes[p..<(p + nameLength)])
            guard !name.contains(0x00), !name.contains(0x2f) else {
                throw OrdfsDirFormatError("entry name contains NUL or \"/\"")
            }
            p += nameLength
            if let last = entries.last, !namePrecedes(last.name, name) {
                throw OrdfsDirFormatError("entries not in canonical sorted order (or duplicate name)")
            }

            let ref: OrdfsDirRef
            if flags & flagReferenceType == 0 {
                guard p + 1 <= bytes.count else {
                    throw OrdfsDirFormatError("truncated vout")
                }
                ref = .sameTx(vout: Int(bytes[p]))
                p += 1
            } else {
                guard p + 36 <= bytes.count else {
                    throw OrdfsDirFormatError("truncated outpoint")
                }
                ref = .outpoint(try outpoint(wire: Array(bytes[p..<(p + 36)])))
                p += 36
            }

            entries.append(OrdfsDirEntry(
                name: name,
                isDirectory: flags & flagDirectory != 0,
                exec: flags & flagExec != 0,
                symlink: flags & flagSymlink != 0,
                ref: ref
            ))
        }

        guard p == bytes.count else {
            throw OrdfsDirFormatError("trailing bytes after last entry (\(bytes.count - p))")
        }
        return OrdfsDirManifest(version: version, entries: entries)
    }

    /// UTF-8 encodes one path component, rejecting NUL, `/`, and lengths outside 1...255 bytes.
    public static func name(_ name: String) throws -> [UInt8] {
        let bytes = Array(name.utf8)
        guard (1...255).contains(bytes.count) else {
            throw OrdfsDirFormatError("name \"\(name)\" byte length out of range 1..255")
        }
        guard !bytes.contains(0x00), !bytes.contains(0x2f) else {
            throw OrdfsDirFormatError("name \"\(name)\" must not contain NUL or \"/\"")
        }
        return bytes
    }

    /// UTF-8 decodes an entry name, replacing invalid sequences.
    public static func nameString(_ name: [UInt8]) -> String {
        String(decoding: name, as: UTF8.self)
    }

    /// The default file for a directory with no remaining path: the entry named `.`, else
    /// `index.html` (the `ord-fs/json` convention).
    public static func defaultEntry(_ manifest: OrdfsDirManifest) -> OrdfsDirEntry? {
        let dot: [UInt8] = [0x2e]
        let indexHTML = Array("index.html".utf8)
        var index: OrdfsDirEntry?
        for entry in manifest.entries {
            if entry.name == dot { return entry }
            if index == nil, entry.name == indexHTML { index = entry }
        }
        return index
    }

    private static func validate(_ entry: OrdfsDirEntry) throws {
        guard (1...255).contains(entry.name.count) else {
            throw OrdfsDirFormatError("entry name length \(entry.name.count) out of range 1..255")
        }
        guard !entry.name.contains(0x00), !entry.name.contains(0x2f) else {
            throw OrdfsDirFormatError("entry name must not contain NUL or \"/\"")
        }
        // git has no 111xxx mode; symlink + exec is not a real git state.
        if !entry.isDirectory, entry.symlink, entry.exec {
            throw OrdfsDirFormatError("entry cannot be both symlink and exec")
        }
        if case .sameTx(let vout) = entry.ref, !(0...255).contains(vout) {
            throw OrdfsDirFormatError("same-tx vout \(vout) out of range 0..255")
        }
    }

    static func outpoint(wire: [UInt8]) throws -> Outpoint {
        do {
            return try Outpoint(wireBytes: wire)
        } catch {
            throw OrdfsDirFormatError("outpoint wire length must be 36")
        }
    }
}

/// What a directory entry points at.
public enum OrdfsDirRef: Hashable, Sendable {
    /// Another output of the same transaction (`_N` in `ord-fs/json`), 0...255.
    case sameTx(vout: Int)
    /// An exact outpoint elsewhere.
    case outpoint(Outpoint)
}

/// One child entry of a directory manifest.
public struct OrdfsDirEntry: Hashable, Sendable {
    /// Raw UTF-8 name bytes of a single path component.
    public var name: [UInt8]
    /// Directory (`true`) or file (`false`).
    public var isDirectory: Bool
    /// Executable file bit (git mode 100755). Files only.
    public var exec: Bool
    /// The leaf content is a relative target path. Files only.
    public var symlink: Bool
    public var ref: OrdfsDirRef

    public init(
        name: [UInt8],
        isDirectory: Bool,
        exec: Bool = false,
        symlink: Bool = false,
        ref: OrdfsDirRef
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.exec = exec
        self.symlink = symlink
        self.ref = ref
    }
}

/// A decoded `ordfs/dir` manifest.
public struct OrdfsDirManifest: Hashable, Sendable {
    public var version: Int
    public var entries: [OrdfsDirEntry]

    public init(version: Int = OrdfsDir.version, entries: [OrdfsDirEntry]) {
        self.version = version
        self.entries = entries
    }
}

/// A spec violation: malformed, non-canonical, or invalid `ordfs/dir` input.
public struct OrdfsDirFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
