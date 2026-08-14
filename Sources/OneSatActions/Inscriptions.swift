import Foundation
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

    /// Two-transaction SIGMA flow from `inscribeWithSigma` in the TypeScript actions.
    private static func inscribeWithSigma(
        _ ctx: OneSatContext,
        _ prepared: PreparedInscription
    ) async throws -> ActionResult {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let anchorKeyID = "anchor-\(millis)"
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
        guard let anchorTxid = anchor.txid else { throw OneSatActionError.anchorNoTxid }

        let sigmaScript = try await Sigma.apply(
            ctx,
            to: prepared.lockingScript,
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
            description: "Create inscription",
            inputBEEF: inputBEEF,
            inputs: [
                try WalletCreateActionInput(
                    outpoint: try Outpoint("\(anchorTxid).0"),
                    inputDescription: "Sigma anchor",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: sigmaScript.bytes,
                    satoshis: 1,
                    outputDescription: "Inscription",
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: prepared.customInstructions,
                    tags: prepared.tags
                ),
            ],
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

enum ActionBase64 {
    static func decode(_ text: String) throws -> [UInt8] {
        guard let data = Data(base64Encoded: text) else {
            throw OneSatActionError.inscriptionTooLarge(bytes: 0)
        }
        return Array(data)
    }
}
