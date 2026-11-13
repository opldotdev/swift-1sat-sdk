import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// `packages/actions/src/inscriptions/index.ts` `inscribe`.
public enum Inscriptions {
    public struct Request: Sendable {
        public let content: [UInt8]
        public let contentType: String
        public let map: [(String, String)]
        public let destination: Destination?
        /// When true, the inscription is signed with the current BAP identity (SIGMA).
        public let signWithBAP: Bool

        public init(
            content: [UInt8],
            contentType: String,
            map: [(String, String)] = [],
            destination: Destination? = nil,
            signWithBAP: Bool = true
        ) {
            self.content = content
            self.contentType = contentType
            self.map = map
            self.destination = destination
            self.signWithBAP = signWithBAP
        }

        public init(
            base64Content: String,
            contentType: String,
            map: [(String, String)] = [],
            destination: Destination? = nil,
            signWithBAP: Bool = true
        ) throws {
            self.content = try ActionBase64.decode(base64Content)
            self.contentType = contentType
            self.map = map
            self.destination = destination
            self.signWithBAP = signWithBAP
        }
    }

    public struct PreparedInscription: Sendable {
        public let lockingScript: Script
        public let tags: [String]
        public let customInstructions: String?
        public let keyID: String?
    }

    /// Inscription envelope with P2PKH (and optional MAP) as `scriptSuffix`.
    public static func lockingScript(
        content: [UInt8],
        contentType: String,
        recipient: Script,
        map: [(String, String)] = []
    ) throws -> Script {
        let suffix = try MapSuffix.appending(map, to: recipient)
        return try Inscription.compose(
            content: content,
            contentType: contentType,
            scriptSuffix: suffix
        )
    }

    public static func prepare(
        identity: PrivateKey,
        _ request: Request,
        network: BitcoinNetwork = .mainnet,
        keyID: String? = nil
    ) throws -> PreparedInscription {
        if request.contentType.isEmpty || request.contentType.utf8.count > 255 {
            throw OneSatActionError.inscriptionContentTypeInvalid
        }
        if request.content.isEmpty {
            throw OneSatActionError.inscriptionContentEmpty
        }
        if request.content.count > OneSatConstants.maxInscriptionBytes {
            throw OneSatActionError.inscriptionTooLarge(bytes: request.content.count)
        }
        let resolved = try ResolveDestination.resolve(
            identity: identity,
            destination: request.destination,
            protocolID: try OneSatConstants.p1satProtocolID,
            keyIDPrefix: "inscribe",
            keyID: keyID,
            network: network
        )
        let lockingScript = try Self.lockingScript(
            content: request.content,
            contentType: request.contentType,
            recipient: resolved.lockingScript,
            map: request.map
        )
        let typeBase = request.contentType.split(separator: ";", maxSplits: 1)
            .first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? request.contentType
        let hash = try Inscription.create(
            content: request.content,
            contentType: request.contentType
        ).contentHash
        var tags = ["type:\(typeBase)", "origin", "sha256:\(Hex.encode(hash.bytes))"]
        if let app = request.map.first(where: { $0.0 == "app" })?.1, !app.isEmpty {
            tags.append("app:\(app)")
        }
        let instructions: String?
        if let resolvedInstructions = resolved.customInstructions {
            let name = request.map.first(where: { $0.0 == "name" })?.1
            let counterparty: String?
            switch resolvedInstructions.counterparty {
            case .self: counterparty = nil
            case .anyone: counterparty = "anyone"
            case .publicKey(let key): counterparty = Hex.encode(key.compressedBytes)
            }
            instructions = OrdinalRemittance.buildCustomInstructions(
                protocolID: resolvedInstructions.protocolID,
                keyID: resolvedInstructions.keyID,
                counterparty: counterparty,
                tags: tags,
                name: name.map { String($0.prefix(64)) }
            )
        } else {
            instructions = nil
        }
        return PreparedInscription(
            lockingScript: lockingScript,
            tags: tags,
            customInstructions: instructions,
            keyID: resolved.customInstructions?.keyID
        )
    }

    public static func inscribe(
        _ ctx: OneSatContext,
        _ request: Request,
        keyID: String? = nil
    ) async -> ActionResult {
        do {
            let prepared = try prepare(
                identity: ctx.identity,
                request,
                network: ctx.chain.network,
                keyID: keyID
            )
            if request.signWithBAP {
                return try await inscribeWithSigma(ctx, prepared)
            }
            return try await TrackedAction.execute(
                ctx,
                description: "Create inscription",
                outputs: [
                    try WalletCreateActionOutput(
                        lockingScript: prepared.lockingScript.bytes,
                        satoshis: 1,
                        outputDescription: "Inscription",
                        basket: OneSatConstants.ordinalsBasket,
                        customInstructions: prepared.customInstructions,
                        tags: prepared.tags
                    ),
                ],
                options: TrackedAction.Options(
                    randomizeOutputs: false,
                    acceptDelayedBroadcast: false
                )
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `inscribeWithSigma` (`inscriptions/index.ts`) through the SIGMA apply step
    /// (`apply/inscribeSigma.ts`): a 2-sat noSend anchor keyed `anchor-<actionId>`, the
    /// inscription sealed against anchor input 0, then the publish spending the anchor and
    /// sending it along.
    ///
    /// The output keeps the custom instructions built for it, as TS does: `creator:` carries no
    /// remittance field, so the apply step's ordinal CI stamp leaves them as they are. Its tags
    /// come out as the apply step writes them: the inscription tags, `id:`, then `creator:`.
    private static func inscribeWithSigma(
        _ ctx: OneSatContext,
        _ prepared: PreparedInscription
    ) async throws -> ActionResult {
        try await SigmaPublish.publish(
            ctx,
            description: "Create inscription",
            sealing: prepared.lockingScript
        ) { sealed in
            [
                try WalletCreateActionOutput(
                    lockingScript: sealed.script.bytes,
                    satoshis: 1,
                    outputDescription: "Inscription",
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: prepared.customInstructions,
                    tags: sealed.tags(prepared.tags, index: 0)
                ),
            ]
        }
    }
}

enum ActionBase64 {
    static func decode(_ text: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: text) else {
            throw OneSatActionError.inscriptionTooLarge(bytes: 0)
        }
        return Array(data)
    }
}
