import Foundation
import BSVKeys
import BSVScript
import BSVWallet
import OneSatTemplates

/// `packages/actions/src/inscriptions/index.ts` `inscribe` without Sigma.
public enum Inscriptions {
    public struct Request: Sendable {
        public let content: [UInt8]
        public let contentType: String
        public let map: [(String, String)]
        public let destination: Destination?

        public init(
            content: [UInt8],
            contentType: String,
            map: [(String, String)] = [],
            destination: Destination? = nil
        ) {
            self.content = content
            self.contentType = contentType
            self.map = map
            self.destination = destination
        }

        public init(
            base64Content: String,
            contentType: String,
            map: [(String, String)] = [],
            destination: Destination? = nil
        ) throws {
            self.content = try ActionBase64.decode(base64Content)
            self.contentType = contentType
            self.map = map
            self.destination = destination
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
        return try Inscription.create(
            content: content,
            contentType: contentType,
            scriptSuffix: suffix
        ).lock()
    }

    public static func prepare(
        identity: PrivateKey,
        _ request: Request,
        network: BitcoinNetwork = .mainnet,
        keyID: String? = nil
    ) throws -> PreparedInscription {
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
        var tags = ["type:\(request.contentType)", "origin"]
        if let name = request.map.first(where: { $0.0 == "name" })?.1 {
            tags.append("name:\(name)")
        }
        let instructions: CustomInstructions?
        if let resolvedInstructions = resolved.customInstructions {
            let name = request.map.first(where: { $0.0 == "name" })?.1
            instructions = try CustomInstructions(
                protocolID: resolvedInstructions.protocolID,
                keyID: resolvedInstructions.keyID,
                counterparty: resolvedInstructions.counterparty,
                name: name.map { String($0.prefix(64)) }
            )
        } else {
            instructions = nil
        }
        return PreparedInscription(
            lockingScript: lockingScript,
            tags: tags,
            customInstructions: instructions?.encoded(),
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
}

enum ActionBase64 {
    static func decode(_ text: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: text) else {
            throw OneSatActionError.inscriptionTooLarge(bytes: 0)
        }
        return Array(data)
    }
}
