/// `ord-fs/json` directory tree layout, from `packages/actions/src/ordfs/manifest.ts`.
///
/// Lays out relative file paths as ORDFS manifests: a root manifest, one manifest per
/// subdirectory, and the output index that carries each file. Manifest values are `_N`
/// same-transaction references. Output layout:
///
///     [0 ..< F]      one output per file, in caller order
///     [F ..< F + D]  one output per subdirectory manifest, depth-first in first-seen order
///     [F + D]        the root manifest (always last)
///
/// Pure layout only: no keys, scripts, or inscriptions.
public struct OrdfsDirTree: Equatable, Sendable {
    /// Maximum directory levels above a file, mirroring 1sat-stack's `maxDirectoryDepth`
    /// (`pkg/ordfs/routes.go`), so a tree the ordfs server would refuse fails at build time.
    public static let maximumDirectoryDepth = 8

    /// Content type of every manifest output, root and subdirectories.
    public static let manifestContentType = OrdfsDir.legacyJSONContentType

    /// One subdirectory manifest at any depth.
    public struct Subdir: Equatable, Sendable {
        /// Full path from the root, such as `refs` or `refs/v1`.
        public let path: String
        /// Single-segment child names mapped to `_N` references.
        public let manifest: OrdfsJSONManifest
        /// The output that carries this manifest.
        public let vout: Int
    }

    /// One file's output assignment, parallel to the input paths.
    public struct File: Equatable, Sendable {
        public let path: String
        public let vout: Int
    }

    /// The root manifest: the directory's identity.
    public let root: OrdfsJSONManifest
    public let subdirs: [Subdir]
    public let files: [File]
    /// Output index of the root manifest: `files.count + subdirs.count`.
    public let manifestVout: Int
    public var manifestContentType: String { Self.manifestContentType }

    /// Builds the layout for `paths` (separator `/`), assigning file `i` to output `i`.
    ///
    /// Throws ``OrdfsDirTreeError`` on a path collision (a duplicate path, or a file and a
    /// directory with the same name) or a path nested deeper than ``maximumDirectoryDepth``.
    public static func build(paths: [String]) throws -> OrdfsDirTree {
        final class Node {
            // Keyed by UTF-8 bytes: JavaScript compares names by code units, not by Swift's
            // canonical equivalence.
            var names: [String] = []
            var children: [[UInt8]: Child] = [:]

            enum Child {
                case file(Int)
                case directory(Node)
            }

            func child(_ name: String) -> Child? {
                children[Array(name.utf8)]
            }

            func insert(_ name: String, _ child: Child) {
                if children[Array(name.utf8)] == nil { names.append(name) }
                children[Array(name.utf8)] = child
            }
        }

        func collision(_ key: String, _ walked: String) -> OrdfsDirTreeError {
            let scope = walked.isEmpty ? "the root directory" : "directory \"\(walked)/\""
            return OrdfsDirTreeError(
                "ord-fs directory path collision: \"\(key)\" conflicts with an existing entry in \(scope)"
            )
        }

        let root = Node()
        for (vout, path) in paths.enumerated() {
            // Split on the byte, as `String.prototype.split('/')` does, keeping empty segments.
            let parts = Array(path.utf8).split(separator: 0x2f, omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            let depth = parts.count - 1
            if depth >= maximumDirectoryDepth {
                throw OrdfsDirTreeError(
                    "ord-fs directory path too deep: \"\(path)\" nests \(depth) directory levels; the ordfs server resolves at most \(maximumDirectoryDepth) (see 1sat-stack pkg/ordfs/routes.go maxDirectoryDepth)"
                )
            }
            var node = root
            var walked = ""
            for segment in parts.dropLast() {
                switch node.child(segment) {
                case nil:
                    let child = Node()
                    node.insert(segment, .directory(child))
                    node = child
                case .directory(let child):
                    node = child
                case .file:
                    throw collision(segment, walked)
                }
                walked = walked.isEmpty ? segment : "\(walked)/\(segment)"
            }
            let name = parts[parts.count - 1]
            if node.child(name) != nil {
                throw collision(name, walked)
            }
            node.insert(name, .file(vout))
        }

        var directories: [(path: String, node: Node)] = []
        func collect(_ node: Node, _ path: String) {
            for name in node.names {
                if case .directory(let child)? = node.child(name) {
                    let childPath = path.isEmpty ? name : "\(path)/\(name)"
                    directories.append((childPath, child))
                    collect(child, childPath)
                }
            }
        }
        collect(root, "")

        var voutByPath: [[UInt8]: Int] = [:]
        for (offset, directory) in directories.enumerated() {
            voutByPath[Array(directory.path.utf8)] = paths.count + offset
        }

        func manifest(_ node: Node, _ path: String) -> OrdfsJSONManifest {
            OrdfsJSONManifest(entries: node.names.map { name in
                let vout: Int
                switch node.child(name) {
                case .file(let index)?:
                    vout = index
                case .directory?:
                    vout = voutByPath[Array((path.isEmpty ? name : "\(path)/\(name)").utf8)] ?? -1
                case nil:
                    vout = -1
                }
                return OrdfsJSONManifest.Entry(name: name, ref: "_\(vout)")
            })
        }

        return OrdfsDirTree(
            root: manifest(root, ""),
            subdirs: directories.map {
                Subdir(path: $0.path, manifest: manifest($0.node, $0.path), vout: voutByPath[Array($0.path.utf8)] ?? -1)
            },
            files: paths.enumerated().map { File(path: $0.element, vout: $0.offset) },
            manifestVout: paths.count + directories.count
        )
    }
}

/// An `ord-fs/json` manifest object: child names mapped to `_N` references, in insertion order.
public struct OrdfsJSONManifest: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let name: String
        public let ref: String

        public init(name: String, ref: String) {
            self.name = name
            self.ref = ref
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// The entries as a dictionary, for order-insensitive comparison.
    public var dictionary: [String: String] {
        Dictionary(entries.map { ($0.name, $0.ref) }, uniquingKeysWith: { _, last in last })
    }

    /// UTF-8 bytes exactly as `JSON.stringify` writes the TypeScript manifest object.
    ///
    /// JavaScript orders object keys that are canonical array indices (`"0"`, `"42"`, below
    /// 2^32 - 1) numerically ahead of every other key, which keep insertion order; the
    /// serializer reproduces that so manifests are byte-identical to the TypeScript writer.
    public var jsonBytes: [UInt8] {
        let indexKeys = entries.compactMap { entry in Self.arrayIndex(entry.name).map { ($0, entry) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        let otherKeys = entries.filter { Self.arrayIndex($0.name) == nil }
        var out: [UInt8] = [0x7b]
        for (offset, entry) in (indexKeys + otherKeys).enumerated() {
            if offset > 0 { out.append(0x2c) }
            Self.appendJSONString(entry.name, to: &out)
            out.append(0x3a)
            Self.appendJSONString(entry.ref, to: &out)
        }
        out.append(0x7d)
        return out
    }

    private static func arrayIndex(_ key: String) -> UInt64? {
        let utf8 = Array(key.utf8)
        guard !utf8.isEmpty, utf8.count <= 10, utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        guard utf8.count == 1 || utf8[0] != 0x30, let value = UInt64(key), value < 0xffff_ffff else {
            return nil
        }
        return value
    }

    /// `JSON.stringify` string quoting: `"` and `\` escaped, C0 controls as short escapes or
    /// lowercase `\u00xx`, everything else (non-ASCII included) written as UTF-8.
    private static func appendJSONString(_ string: String, to out: inout [UInt8]) {
        let hex = Array("0123456789abcdef".utf8)
        out.append(0x22)
        for byte in string.utf8 {
            switch byte {
            case 0x22: out += [0x5c, 0x22]
            case 0x5c: out += [0x5c, 0x5c]
            case 0x08: out += [0x5c, 0x62]
            case 0x0c: out += [0x5c, 0x66]
            case 0x0a: out += [0x5c, 0x6e]
            case 0x0d: out += [0x5c, 0x72]
            case 0x09: out += [0x5c, 0x74]
            case 0x00..<0x20:
                out += [0x5c, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0f)]]
            default:
                out.append(byte)
            }
        }
        out.append(0x22)
    }
}

/// A path collision or too-deep path in an `ord-fs/json` directory layout.
public struct OrdfsDirTreeError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
