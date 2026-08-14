import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates

/// BAP `publishIdentity`, `updateProfile`, and `getProfile` from `@1sat/actions` `identity/index.ts`.
public enum Identity {
    public struct PublishResult: Sendable {
        public let txid: String?
        public let tx: [UInt8]?
        public let bapId: String?
        public let error: String?

        public init(
            txid: String? = nil,
            tx: [UInt8]? = nil,
            bapId: String? = nil,
            error: String? = nil
        ) {
            self.txid = txid
            self.tx = tx
            self.bapId = bapId
            self.error = error
        }
    }

    public struct ProfileResult: Sendable {
        public let bapId: String?
        public let profileJSON: String?
        public let error: String?

        public init(bapId: String? = nil, profileJSON: String? = nil, error: String? = nil) {
            self.bapId = bapId
            self.profileJSON = profileJSON
            self.error = error
        }
    }

    public struct AliasCandidate: Equatable, Sendable {
        public let outpoint: String
        public let id: String?
        public let publishedAt: Int64?

        public init(outpoint: String, id: String?, publishedAt: Int64?) {
            self.outpoint = outpoint
            self.id = id
            self.publishedAt = publishedAt
        }
    }

    public static func signingKeyID(_ index: Int) -> String {
        "\(OneSatConstants.bapKeyID)-\(index)"
    }

    /// `base58(ripemd160(sha256(identity-0.address)))`. Address is mainnet.
    public static func computeBapId(identity: PrivateKey) throws -> String {
        let address = try derivedAddress(identity, index: 0).description
        return Base58.encode(BSVHashing.hash160(Array(address.utf8)).bytes)
    }

    /// `nil` when the `bap` basket has no `type:id` output.
    public static func resolveBapId(_ ctx: OneSatContext) async throws -> String? {
        let listed = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.bapBasket,
                tags: ["type:id"],
                pagination: WalletPagination(limit: 1)
            )
        )
        if listed.outputs.isEmpty { return nil }
        return try computeBapId(identity: ctx.identity)
    }

    /// Port of `updateProfile` (`identity/index.ts:450-586`). `profileJSON` must be a JSON object;
    /// its UTF-8 bytes are pushed verbatim.
    public static func updateProfile(_ ctx: OneSatContext, profileJSON: String) async -> PublishResult {
        do {
            guard isJSONObject(profileJSON) else {
                return PublishResult(error: Failure.profileNotObject.rawValue)
            }

            let publishedAtTag = "publishedAt:\(Int64(Date().timeIntervalSince1970 * 1000))"
            let existingId = try await resolveBapId(ctx)
            let bapId = try existingId ?? computeBapId(identity: ctx.identity)

            let existingAliases = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.bapBasket,
                    tags: ["type:alias"],
                    pagination: WalletPagination(limit: 100)
                )
            )

            let aliasScript = try pushReturnScript([
                Array(OneSatConstants.bapBitcomAddress.utf8),
                Array("ALIAS".utf8),
                Array(bapId.utf8),
                Array(profileJSON.utf8),
            ])

            var outputs: [WalletCreateActionOutput] = []
            if existingId == nil {
                let id = try buildIdOutput(
                    identity: ctx.identity,
                    bapId: bapId,
                    seq: 1,
                    signerKeyID: signingKeyID(0),
                    declareKeyID: signingKeyID(1)
                )
                outputs.append(
                    try WalletCreateActionOutput(
                        lockingScript: id.lockingScript,
                        satoshis: 0,
                        outputDescription: "BAP ID",
                        basket: OneSatConstants.bapBasket,
                        customInstructions: id.customInstructions,
                        tags: id.tags
                    )
                )
                let signedAlias = try AIPSign.apply(
                    to: aliasScript,
                    signingKey: try derivedKey(ctx.identity, keyID: signingKeyID(1))
                )
                outputs.append(
                    try WalletCreateActionOutput(
                        lockingScript: signedAlias.bytes,
                        satoshis: 0,
                        outputDescription: "BAP ALIAS",
                        basket: OneSatConstants.bapBasket,
                        tags: ["type:alias", "bapId:\(bapId)", publishedAtTag]
                    )
                )
            } else {
                let keyID: String
                do {
                    keyID = try await Sigma.resolveCurrentKeyId(ctx)
                } catch let error as OneSatActionError {
                    return PublishResult(error: error.wireMessage)
                }
                let signedAlias = try AIPSign.apply(
                    to: aliasScript,
                    signingKey: try derivedKey(ctx.identity, keyID: keyID)
                )
                outputs.append(
                    try WalletCreateActionOutput(
                        lockingScript: signedAlias.bytes,
                        satoshis: 0,
                        outputDescription: "BAP ALIAS",
                        basket: OneSatConstants.bapBasket,
                        tags: ["type:alias", "bapId:\(bapId)", publishedAtTag]
                    )
                )
            }

            let result = try await TrackedAction.execute(
                ctx,
                description: existingId == nil
                    ? "BAP identity creation with profile"
                    : "BAP alias update",
                outputs: outputs,
                options: TrackedAction.Options(
                    randomizeOutputs: false,
                    acceptDelayedBroadcast: false
                )
            )
            if let error = result.error {
                return PublishResult(bapId: bapId, error: error)
            }
            guard let txid = result.txid else {
                return PublishResult(bapId: bapId, error: Failure.noTxid.rawValue)
            }

            for old in existingAliases.outputs {
                do {
                    _ = try await ctx.storage.relinquishOutput(
                        ctx.auth,
                        try WalletRelinquishOutputRequest(
                            basket: OneSatConstants.bapBasket,
                            output: old.outpoint
                        )
                    )
                } catch {
                    continue
                }
            }

            return PublishResult(txid: txid, tx: result.tx, bapId: bapId)
        } catch {
            return PublishResult(error: error.localizedDescription)
        }
    }

    public static func publish(_ ctx: OneSatContext) async -> PublishResult {
        do {
            let existing = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.bapBasket,
                    tags: ["type:id"],
                    pagination: WalletPagination(limit: 1)
                )
            )
            if !existing.outputs.isEmpty {
                return PublishResult(error: Failure.identityExists.rawValue)
            }

            let bapId = try computeBapId(identity: ctx.identity)
            let id = try buildIdOutput(
                identity: ctx.identity,
                bapId: bapId,
                seq: 1,
                signerKeyID: signingKeyID(0),
                declareKeyID: signingKeyID(1)
            )
            let output = try WalletCreateActionOutput(
                lockingScript: id.lockingScript,
                satoshis: 0,
                outputDescription: "BAP ID",
                basket: OneSatConstants.bapBasket,
                customInstructions: id.customInstructions,
                tags: id.tags
            )
            let result = try await TrackedAction.execute(
                ctx,
                description: "BAP identity publication",
                outputs: [output],
                options: TrackedAction.Options(
                    randomizeOutputs: false,
                    acceptDelayedBroadcast: false
                )
            )
            if let error = result.error {
                return PublishResult(bapId: bapId, error: error)
            }
            guard let txid = result.txid else {
                return PublishResult(bapId: bapId, error: Failure.noTxid.rawValue)
            }
            return PublishResult(txid: txid, tx: result.tx, bapId: bapId)
        } catch {
            return PublishResult(error: error.localizedDescription)
        }
    }

    public static func pickNewestAlias(
        _ outputs: [WalletOutput]
    ) -> (winner: AliasCandidate, losers: [AliasCandidate])? {
        guard !outputs.isEmpty else { return nil }
        var candidates = outputs.map(parseCandidate)
        candidates.sort { left, right in
            switch (left.publishedAt, right.publishedAt) {
            case let (leftAt?, rightAt?) where leftAt != rightAt:
                return leftAt > rightAt
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if left.outpoint != right.outpoint {
                    return left.outpoint < right.outpoint
                }
                return false
            }
        }
        let winner = candidates[0]
        return (winner, Array(candidates.dropFirst()))
    }

    public static func getProfile(_ ctx: OneSatContext) async -> ProfileResult {
        do {
            let scan = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.bapBasket,
                    tags: ["type:alias"],
                    includeTags: true,
                    pagination: WalletPagination(limit: 10_000)
                )
            )
            guard let picked = pickNewestAlias(scan.outputs) else {
                return ProfileResult(error: Failure.noProfile.rawValue)
            }

            let winnerOutput: WalletOutput?
            if let id = picked.winner.id {
                let byId = try await ctx.storage.listOutputs(
                    ctx.auth,
                    try WalletListOutputsRequest(
                        basket: OneSatConstants.bapBasket,
                        tags: ["type:alias", "id:\(id)"],
                        tagQueryMode: .all,
                        include: .lockingScripts,
                        pagination: WalletPagination(limit: 1)
                    )
                )
                winnerOutput = byId.outputs.first
            } else {
                let fallback = try await ctx.storage.listOutputs(
                    ctx.auth,
                    try WalletListOutputsRequest(
                        basket: OneSatConstants.bapBasket,
                        tags: ["type:alias"],
                        include: .lockingScripts,
                        pagination: WalletPagination(limit: 10_000)
                    )
                )
                winnerOutput = fallback.outputs.first {
                    $0.outpoint.description == picked.winner.outpoint
                }
            }

            guard let lockingScript = winnerOutput?.lockingScript else {
                return ProfileResult(error: Failure.noLockingScript.rawValue)
            }
            let script = try Script(
                bytes: lockingScript,
                maximumByteCount: ActionScript.maximumByteCount
            )
            guard let bitcom = BitCom.decode(script) else {
                return ProfileResult(error: Failure.noBitcom.rawValue)
            }
            guard let bap = BAPTemplate.decode(bitcom), bap.type == .alias else {
                return ProfileResult(error: Failure.noBap.rawValue)
            }

            for loser in picked.losers {
                do {
                    let outpoint = try Outpoint(loser.outpoint)
                    _ = try await ctx.storage.relinquishOutput(
                        ctx.auth,
                        try WalletRelinquishOutputRequest(
                            basket: OneSatConstants.bapBasket,
                            output: outpoint
                        )
                    )
                } catch {
                    continue
                }
            }

            return ProfileResult(bapId: bap.idKey ?? "", profileJSON: bap.profileJSON)
        } catch {
            return ProfileResult(error: error.localizedDescription)
        }
    }

    private enum Failure: String, LocalizedError {
        case identityExists = "identity-exists: already published"
        case noTxid = "no-txid-returned"
        case noProfile = "no-profile: no alias output in wallet"
        case noLockingScript = "malformed-alias: winner has no locking script"
        case noBitcom = "malformed-alias: no bitcom structure found"
        case noBap = "malformed-alias: no BAP protocol found in bitcom"
        case profileNotObject = "profile-must-be-json-object"

        var errorDescription: String? { rawValue }
    }

    private struct IdOutput {
        let lockingScript: [UInt8]
        let tags: [String]
        let customInstructions: String
    }

    /// Same ID-output bytes `publish` used to build inline. One builder, two callers.
    private static func buildIdOutput(
        identity: PrivateKey,
        bapId: String,
        seq: Int,
        signerKeyID: String,
        declareKeyID: String
    ) throws -> IdOutput {
        let declareAddress = try derivedAddress(identity, keyID: declareKeyID).description
        let script = try pushReturnScript([
            Array(OneSatConstants.bapBitcomAddress.utf8),
            Array("ID".utf8),
            Array(bapId.utf8),
            Array(declareAddress.utf8),
        ])
        let signed = try AIPSign.apply(
            to: script,
            signingKey: try derivedKey(identity, keyID: signerKeyID)
        )
        let instructions = try CustomInstructions(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: declareKeyID
        ).encoded()
        return IdOutput(
            lockingScript: signed.bytes,
            tags: ["type:id", "bapId:\(bapId)", "seq:\(seq)"],
            customInstructions: instructions
        )
    }

    private static func pushReturnScript(_ chunks: [[UInt8]]) throws -> Script {
        var script = try Script(bytes: [], maximumByteCount: ActionScript.maximumByteCount)
        try script.append(.zero, maximumScriptByteCount: ActionScript.maximumByteCount)
        try script.append(.return, maximumScriptByteCount: ActionScript.maximumByteCount)
        for chunk in chunks {
            try script.appendPushData(chunk, maximumScriptByteCount: ActionScript.maximumByteCount)
        }
        return script
    }

    private static func isJSONObject(_ raw: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else {
            return false
        }
        return object is [String: Any]
    }

    private static func derivedKey(_ identity: PrivateKey, keyID: String) throws -> PrivateKey {
        try WalletKeyDeriver(rootKey: identity).derivePrivateKey(
            protocolID: try OneSatConstants.bapProtocolID,
            keyID: try WalletKeyID(keyID),
            counterparty: .self
        )
    }

    private static func derivedKey(_ identity: PrivateKey, index: Int) throws -> PrivateKey {
        try derivedKey(identity, keyID: signingKeyID(index))
    }

    private static func derivedAddress(_ identity: PrivateKey, keyID: String) throws -> Address {
        Address(
            publicKey: try derivedKey(identity, keyID: keyID).publicKey,
            network: .mainnet,
            compressed: true
        )
    }

    private static func derivedAddress(_ identity: PrivateKey, index: Int) throws -> Address {
        try derivedAddress(identity, keyID: signingKeyID(index))
    }

    private static func parseCandidate(_ output: WalletOutput) -> AliasCandidate {
        var id: String?
        var publishedAt: Int64?
        for tag in output.tags ?? [] {
            if tag.hasPrefix("publishedAt:") {
                let raw = String(tag.dropFirst("publishedAt:".count))
                if let value = Int64(raw) {
                    publishedAt = value
                }
            } else if tag.hasPrefix("id:") {
                id = String(tag.dropFirst("id:".count))
            }
        }
        return AliasCandidate(
            outpoint: output.outpoint.description,
            id: id,
            publishedAt: publishedAt
        )
    }
}
