import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// `deployOrdfsDir` from `packages/actions/src/ordfs/index.ts`: publish a directory of files as
/// one on-chain `ord-fs/json` tree.
///
/// Output layout: files, then subdirectory manifests, then the root manifest (the directory's
/// identity). `.mixed` (default) writes zero-satoshi B leaves and one wallet-locked ordinal root;
/// `.inscription` locks every output; `.b` writes every output as plain data. When `sign` is
/// set, the signing protocol follows the layout: SIGMA, bound to a spent anchor input, for an
/// ordinal root; AIP over the manifest's `OP_RETURN` data for an all-B tree.
public enum DeployOrdfsDir {
    public struct Request: Sendable {
        /// Files in output order; paths use `/` for subdirectories.
        public let files: [OrdfsDirFile]
        /// MAP `SET` fields for the root manifest only, attached verbatim.
        public let map: [(String, String)]
        public let writeMode: OrdfsDirWriteMode
        /// Sign the root manifest's authorship (SIGMA or AIP, by `writeMode`).
        public let sign: Bool

        public init(
            files: [OrdfsDirFile],
            map: [(String, String)] = [],
            writeMode: OrdfsDirWriteMode = .mixed,
            sign: Bool = true
        ) {
            self.files = files
            self.map = map
            self.writeMode = writeMode
            self.sign = sign
        }

        /// The TypeScript action's JSON input shape: base64 file content and an optional
        /// write-mode name (`mixed`, `inscription`, or `b`).
        public init(
            base64Files: [(path: String, base64Content: String, contentType: String)],
            map: [(String, String)] = [],
            writeMode: String? = nil,
            sign: Bool = true
        ) throws {
            guard let mode = OrdfsDirWriteMode(rawValue: writeMode ?? OrdfsDirWriteMode.mixed.rawValue) else {
                throw DeployOrdfsDirError("invalid-write-mode: \(writeMode ?? "")")
            }
            self.files = try base64Files.map { file in
                guard let data = Data(base64Encoded: file.base64Content) else {
                    throw DeployOrdfsDirError("invalid-base64: \(file.path)")
                }
                return OrdfsDirFile(path: file.path, content: Array(data), contentType: file.contentType)
            }
            self.map = map
            self.writeMode = mode
            self.sign = sign
        }
    }

    public struct Response: Equatable, Sendable {
        public let txid: String?
        /// Output index of the root manifest.
        public let manifestVout: Int?
        /// `"{txid}_{vout}"` for every output; the root is `origins[manifestVout]`. For `.b`
        /// these are locations only: nothing there is a spendable ordinal.
        public let origins: [String]?
        public let error: String?

        public init(txid: String? = nil, manifestVout: Int? = nil, origins: [String]? = nil, error: String? = nil) {
            self.txid = txid
            self.manifestVout = manifestVout
            self.origins = origins
            self.error = error
        }
    }

    public static let description = "Publish ord-fs directory"
    static let manifestTags = ["type:ord-fs/json", "origin"]

    public static func execute(_ ctx: OneSatContext, _ request: Request) async -> Response {
        do {
            guard !request.files.isEmpty else {
                return Response(error: "no-files")
            }
            let writeMode = request.writeMode

            // Mixed and inscription layouts hold at least one ordinal; an all-B tree holds none.
            let resolved = writeMode == .b ? nil : try ResolveDestination.resolve(
                identity: ctx.identity,
                destination: nil,
                protocolID: try OneSatConstants.p1satProtocolID,
                keyIDPrefix: "ordfs-dir",
                network: ctx.chain.network
            )
            let locking = resolved.map { resolved in
                OrdfsLocking.resolve { _ in resolved.lockingScript }
            }

            // AIP is transaction-independent, so a signed all-B tree is signed at build time.
            var aip: ((Script) throws -> Script)?
            if writeMode == .b, request.sign {
                let keyID = try await Sigma.resolveCurrentKeyId(ctx)
                let key = try WalletKeyDeriver(rootKey: ctx.identity).derivePrivateKey(
                    protocolID: try OneSatConstants.bapProtocolID,
                    keyID: try WalletKeyID(keyID),
                    counterparty: .self
                )
                aip = { try AIPSign.apply(to: $0, signingKey: key) }
            }

            let built = try OrdfsDirOutputs.build(
                request.files,
                writeMode: writeMode,
                locking: locking,
                map: request.map,
                aip: aip
            )
            let customInstructions = try resolved?.customInstructions.map {
                try CustomInstructions(protocolID: $0.protocolID, keyID: $0.keyID).encoded()
            }
            return try await publish(
                ctx,
                built,
                writeMode: writeMode,
                sigma: writeMode != .b && request.sign,
                manifestCustomInstructions: customInstructions
            )
        } catch let error as OneSatActionError {
            return Response(error: error.wireMessage)
        } catch let error as OrdfsDirTreeError {
            return Response(error: error.message)
        } catch {
            return Response(error: String(describing: error))
        }
    }

    /// The `createAction` outputs: only the root manifest is tagged, and only an ordinal root
    /// is basketed as the tradeable asset. File and subdirectory outputs are plumbing.
    public static func actionOutputs(
        _ built: OrdfsDirOutputs.Result,
        writeMode: OrdfsDirWriteMode,
        manifestCustomInstructions: String? = nil,
        manifestScript: Script? = nil,
        extraManifestTags: [String] = []
    ) throws -> [WalletCreateActionOutput] {
        try built.outputs.map { output in
            let isOrdinalRoot = output.isManifest && writeMode != .b
            return try WalletCreateActionOutput(
                lockingScript: (output.isManifest ? manifestScript ?? output.lockingScript : output.lockingScript).bytes,
                satoshis: output.satoshis,
                outputDescription: String(output.description.prefix(50)),
                basket: isOrdinalRoot ? OneSatConstants.ordinalsBasket : nil,
                customInstructions: isOrdinalRoot ? manifestCustomInstructions : nil,
                tags: output.isManifest ? manifestTags + extraManifestTags : []
            )
        }
    }

    private static func publish(
        _ ctx: OneSatContext,
        _ built: OrdfsDirOutputs.Result,
        writeMode: OrdfsDirWriteMode,
        sigma: Bool,
        manifestCustomInstructions: String?
    ) async throws -> Response {
        let result: ActionResult
        if sigma {
            result = try await publishWithSigma(
                ctx,
                built,
                writeMode: writeMode,
                manifestCustomInstructions: manifestCustomInstructions
            )
        } else {
            result = try await TrackedAction.execute(
                ctx,
                description: description,
                outputs: try actionOutputs(
                    built,
                    writeMode: writeMode,
                    manifestCustomInstructions: manifestCustomInstructions
                ),
                options: TrackedAction.Options(randomizeOutputs: false, acceptDelayedBroadcast: false)
            )
        }
        guard let txid = result.txid else {
            return Response(error: result.error ?? OneSatActionError.noTxidReturned.wireMessage)
        }
        return Response(
            txid: txid,
            manifestVout: built.manifestVout,
            origins: built.outputs.indices.map { "\(txid)_\($0)" }
        )
    }

    /// The inscribe SIGMA flow: a 2-sat noSend anchor keyed by the action id, the root manifest
    /// sealed against anchor input 0, then the publish spending the anchor.
    private static func publishWithSigma(
        _ ctx: OneSatContext,
        _ built: OrdfsDirOutputs.Result,
        writeMode: OrdfsDirWriteMode,
        manifestCustomInstructions: String?
    ) async throws -> ActionResult {
        let actionID = TrackedAction.randomActionID()
        let anchorKeyID = "anchor-\(actionID)"
        let anchorAddress = try P1SATKey.address(
            identity: ctx.identity,
            keyID: anchorKeyID,
            counterparty: .self,
            forSelf: true,
            network: ctx.chain.network
        )
        let anchor = try await TrackedAction.execute(
            ctx,
            description: "Sigma anchor output",
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(anchorAddress).bytes,
                    satoshis: 2,
                    outputDescription: "Sigma anchor",
                    basket: OneSatConstants.sigmaBasket,
                    customInstructions: try CustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: anchorKeyID
                    ).encoded()
                ),
            ],
            options: TrackedAction.Options(
                bypassP1Sat: true,
                randomizeOutputs: false,
                acceptDelayedBroadcast: true,
                noSend: true
            )
        )
        guard let anchorTxid = anchor.txid else {
            if let error = anchor.error { return ActionResult(error: error) }
            throw OneSatActionError.anchorNoTxid
        }

        let sealed = try await Sigma.applyWithCreator(
            ctx,
            to: built.manifestScript,
            inputTxid: anchorTxid,
            inputVout: 0
        )
        let inputBEEF: BEEF?
        if let tx = anchor.tx {
            inputBEEF = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard).beef
        } else {
            inputBEEF = nil
        }

        return try await TrackedAction.execute(
            ctx,
            description: description,
            inputBEEF: inputBEEF,
            inputs: [
                try WalletCreateActionInput(
                    outpoint: try Outpoint("\(anchorTxid).0"),
                    inputDescription: "Sigma anchor",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: try actionOutputs(
                built,
                writeMode: writeMode,
                manifestCustomInstructions: manifestCustomInstructions,
                manifestScript: sealed.script,
                extraManifestTags: ["creator:\(sealed.creator)"]
            ),
            actionID: actionID,
            options: TrackedAction.Options(
                randomizeOutputs: false,
                acceptDelayedBroadcast: true,
                noSend: true,
                noSendChange: anchor.noSendChange ?? [],
                knownTxids: [anchorTxid],
                sendWith: [anchorTxid]
            ),
            sign: { tx in
                [
                    0: try SignP2PKH.unlockingScript(
                        identity: ctx.identity,
                        transaction: tx,
                        inputIndex: 0,
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: anchorKeyID
                    ),
                ]
            }
        )
    }
}

/// A `deployOrdfsDir` request that cannot be read.
public struct DeployOrdfsDirError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
