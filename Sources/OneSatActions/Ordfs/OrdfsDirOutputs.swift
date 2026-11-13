import BSVScript
import OneSatTemplates

/// How an `ord-fs/json` directory publish is written on-chain.
public enum OrdfsDirWriteMode: String, Equatable, Sendable, CaseIterable {
    /// Zero-satoshi B leaves and one 1-sat ordinal root: one ownable directory asset.
    case mixed
    /// A 1-sat ord envelope per output: ownable, transferable, updatable.
    case inscription
    /// A zero-satoshi B output per output: plain data, nothing owned.
    case b
}

/// Locking for ordinal outputs: one address for every output, or a per-vout resolver.
public enum OrdfsLocking: Sendable {
    case address(String)
    case resolve(@Sendable (Int) throws -> Script)

    func script(vout: Int) throws -> Script {
        switch self {
        case .address(let address):
            return try ActionScript.payToPublicKeyHash(address)
        case .resolve(let resolve):
            return try resolve(vout)
        }
    }
}

/// A file to include in an `ord-fs/json` directory.
public struct OrdfsDirFile: Equatable, Sendable {
    /// Relative path; `/` separates subdirectories (for example `refs/api.md`).
    public let path: String
    public let content: [UInt8]
    public let contentType: String

    public init(path: String, content: [UInt8], contentType: String) {
        self.path = path
        self.content = content
        self.contentType = contentType
    }
}

/// One output of a directory publish transaction.
public struct OrdfsDirOutput: Equatable, Sendable {
    public let lockingScript: Script
    /// 1 for ordinal outputs, 0 for B outputs.
    public let satoshis: UInt64
    public let description: String
    /// Whether this is the root manifest (the directory's identity).
    public let isManifest: Bool
}

/// Output builder from `packages/actions/src/ordfs/outputs.ts`.
///
/// Writes file outputs, then subdirectory manifests, then the root manifest last. Locking
/// applies to ordinal outputs only; B outputs are `OP_FALSE OP_RETURN` and provably
/// unspendable. MAP goes on the root manifest only, as given. Signing policy is not enforced
/// here: `deployOrdfsDir` picks SIGMA or AIP.
public enum OrdfsDirOutputs {
    public struct Result: Equatable, Sendable {
        /// Files, subdirectory manifests, then the root manifest.
        public let outputs: [OrdfsDirOutput]
        /// Output index of the root manifest: `outputs.count - 1`.
        public let manifestVout: Int
        /// The root manifest's locking script, with any MAP and AIP suffix.
        public let manifestScript: Script
        public let tree: OrdfsDirTree
    }

    /// A standalone zero-satoshi B data output: `OP_FALSE OP_RETURN <B prefix> <data>
    /// <mediaType> "binary"`. Only `OP_FALSE OP_RETURN` is provably unspendable after Genesis.
    public static func dataScript(_ content: [UInt8], contentType: String) throws -> Script {
        let section = try BTemplate.lock(content, mediaType: contentType, encoding: .binary)
        return try ActionScript.appending(section, to: opFalse())
    }

    /// Builds every output of a directory publish.
    ///
    /// - Parameters:
    ///   - files: Files in output order.
    ///   - writeMode: Output layout; `.mixed` by default.
    ///   - locking: Required unless `writeMode` is `.b`.
    ///   - map: MAP `SET` fields for the root manifest only, written as given.
    ///   - aip: Signs the root manifest script (after MAP) and returns it with an AIP suffix.
    public static func build(
        _ files: [OrdfsDirFile],
        writeMode: OrdfsDirWriteMode = .mixed,
        locking: OrdfsLocking? = nil,
        map: [(String, String)] = [],
        aip: ((Script) throws -> Script)? = nil
    ) throws -> Result {
        let leafMode: OrdfsDirWriteMode = writeMode == .mixed ? .b : writeMode
        let manifestMode: OrdfsDirWriteMode = writeMode == .mixed ? .inscription : writeMode
        let leafSatoshis: UInt64 = leafMode == .b ? 0 : 1
        let manifestSatoshis: UInt64 = manifestMode == .b ? 0 : 1

        let tree = try OrdfsDirTree.build(paths: files.map(\.path))
        var outputs: [OrdfsDirOutput] = []

        for (vout, file) in files.enumerated() {
            outputs.append(OrdfsDirOutput(
                lockingScript: try leafScript(leafMode, file.content, file.contentType, locking, vout),
                satoshis: leafSatoshis,
                description: "file: \(file.path)",
                isManifest: false
            ))
        }

        for subdir in tree.subdirs {
            outputs.append(OrdfsDirOutput(
                lockingScript: try leafScript(
                    leafMode,
                    subdir.manifest.jsonBytes,
                    tree.manifestContentType,
                    locking,
                    subdir.vout
                ),
                satoshis: leafSatoshis,
                description: "dir: \(subdir.path)/",
                isManifest: false
            ))
        }

        var manifestScript = try manifestScript(
            manifestMode,
            tree.root.jsonBytes,
            tree.manifestContentType,
            locking,
            tree.manifestVout,
            map
        )
        if let aip {
            manifestScript = try aip(manifestScript)
        }
        outputs.append(OrdfsDirOutput(
            lockingScript: manifestScript,
            satoshis: manifestSatoshis,
            description: "manifest (ord-fs/json)",
            isManifest: true
        ))

        return Result(
            outputs: outputs,
            manifestVout: tree.manifestVout,
            manifestScript: manifestScript,
            tree: tree
        )
    }

    private static func opFalse() throws -> Script {
        try Script(bytes: [Opcode.zero.rawValue], maximumByteCount: ActionScript.maximumByteCount)
    }

    private static func leafScript(
        _ mode: OrdfsDirWriteMode,
        _ content: [UInt8],
        _ contentType: String,
        _ locking: OrdfsLocking?,
        _ vout: Int
    ) throws -> Script {
        if mode == .b {
            return try dataScript(content, contentType: contentType)
        }
        guard let locking else {
            throw OrdfsDirTreeError(
                "buildOrdFsDirOutputs: 'locking' is required for ordinal outputs — it controls who can spend the UTXO"
            )
        }
        return try Inscription.create(
            content: content,
            contentType: contentType,
            scriptPrefix: locking.script(vout: vout)
        ).lock()
    }

    /// `'b'`: B and MAP share one `OP_RETURN` through BitCom. Ordinal: MAP is the envelope's
    /// `scriptSuffix`, after the P2PKH prefix and the envelope.
    private static func manifestScript(
        _ mode: OrdfsDirWriteMode,
        _ manifest: [UInt8],
        _ contentType: String,
        _ locking: OrdfsLocking?,
        _ vout: Int,
        _ map: [(String, String)]
    ) throws -> Script {
        if mode == .b {
            var protocols = [BitComProtocolEntry(
                protocol: BTemplate.prefix,
                script: try BTemplate.body(manifest, mediaType: contentType, encoding: BTemplate.Encoding.binary.rawValue)
            )]
            if !map.isEmpty, let section = BitCom.decode(try MAPTemplate.set(map))?.protocols.first {
                protocols.append(section)
            }
            return try ActionScript.appending(BitCom.lock(protocols: protocols), to: opFalse())
        }
        guard let locking else {
            throw OrdfsDirTreeError(
                "buildOrdFsDirOutputs: 'locking' is required for the ordinal root — it controls who can spend the UTXO"
            )
        }
        return try Inscription.create(
            content: manifest,
            contentType: contentType,
            scriptPrefix: locking.script(vout: vout),
            scriptSuffix: map.isEmpty ? nil : MAPTemplate.set(map)
        ).lock()
    }
}
