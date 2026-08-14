import Foundation
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// `mintCollection` and `mintCollectionItem` from `packages/actions/src/collections/index.ts`.
public enum Collections {
    public struct MintRequest: Sendable {
        public let base64Content: String
        public let contentType: String
        public let name: String
        public let description: String
        public let quantity: Int
        public let traits: [CollectionTraitEntry]
        public let rarityLabels: [RarityLabel]
        public let royalties: [Royalty]
        public let app: String

        public init(
            base64Content: String,
            contentType: String,
            name: String,
            description: String,
            quantity: Int,
            traits: [CollectionTraitEntry] = [],
            rarityLabels: [RarityLabel] = [],
            royalties: [Royalty] = [],
            app: String = "1sat-wallet"
        ) {
            self.base64Content = base64Content
            self.contentType = contentType
            self.name = name
            self.description = description
            self.quantity = quantity
            self.traits = traits
            self.rarityLabels = rarityLabels
            self.royalties = royalties
            self.app = app
        }
    }

    public struct MintResult: Equatable, Sendable {
        public let txid: String?
        public let collectionId: String?
        public let tx: [UInt8]?
        public let error: String?

        public init(
            txid: String? = nil,
            collectionId: String? = nil,
            tx: [UInt8]? = nil,
            error: String? = nil
        ) {
            self.txid = txid
            self.collectionId = collectionId
            self.tx = tx
            self.error = error
        }
    }

    public struct MintItemRequest: Sendable {
        public let base64Content: String?
        public let ref: String?
        public let contentType: String?
        public let name: String
        public let collectionId: String
        public let mintNumber: Int?
        public let rank: Int?
        public let rarityLabel: String?
        public let traits: [CollectionItemTrait]
        public let attachments: [CollectionItemAttachment]
        public let app: String

        public init(
            base64Content: String? = nil,
            ref: String? = nil,
            contentType: String? = nil,
            name: String,
            collectionId: String,
            mintNumber: Int? = nil,
            rank: Int? = nil,
            rarityLabel: String? = nil,
            traits: [CollectionItemTrait] = [],
            attachments: [CollectionItemAttachment] = [],
            app: String = "1sat-wallet"
        ) {
            self.base64Content = base64Content
            self.ref = ref
            self.contentType = contentType
            self.name = name
            self.collectionId = collectionId
            self.mintNumber = mintNumber
            self.rank = rank
            self.rarityLabel = rarityLabel
            self.traits = traits
            self.attachments = attachments
            self.app = app
        }
    }

    /// `mintCollection` (`collections/index.ts:417-517`).
    public static func mint(_ ctx: OneSatContext, _ request: MintRequest) async -> MintResult {
        do {
            let decoded = try ActionBase64.decode(request.base64Content)
            if decoded.count > OneSatConstants.maxInscriptionBytes {
                return MintResult(
                    error: OneSatActionError.inscriptionTooLarge(bytes: decoded.count).wireMessage
                )
            }
            if request.quantity < 1 {
                return MintResult(error: OneSatActionError.quantityMustBePositive.wireMessage)
            }

            let millis = Int64(Date().timeIntervalSince1970 * 1000)
            let keyID = "\(millis)"
            let address = try P1SATKey.address(
                identity: ctx.identity,
                keyID: keyID,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let lockingScript = try Inscription.create(
                content: decoded,
                contentType: request.contentType,
                scriptSuffix: try MapSuffix.appending(
                    CollectionMap.collection(
                        app: request.app,
                        name: request.name,
                        data: CollectionSubTypeData(
                            description: request.description,
                            quantity: request.quantity,
                            rarityLabels: request.rarityLabels,
                            traits: request.traits
                        ),
                        royalties: request.royalties
                    ),
                    to: try ActionScript.payToPublicKeyHash(address)
                )
            ).lock()
            let nameTag = String(request.name.prefix(64))
            let result = try await publishWithSigma(
                ctx,
                description: "Create collection: \(request.name)",
                outputDescription: "Collection inscription",
                lockingScript: lockingScript,
                tags: [
                    "type:\(request.contentType)",
                    "origin",
                    "name:\(nameTag)",
                    "subType:collection",
                ],
                customInstructions: try CustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: keyID,
                    name: nameTag
                ).encoded()
            )
            guard let txid = result.txid else {
                return MintResult(error: OneSatActionError.noTxidReturned.wireMessage)
            }
            return MintResult(txid: txid, collectionId: "\(txid)_0", tx: result.tx)
        } catch let error as OneSatActionError {
            return MintResult(error: error.wireMessage)
        } catch {
            return MintResult(error: error.localizedDescription)
        }
    }

    /// `mintCollectionItem` (`collections/index.ts:585-711`).
    public static func mintItem(
        _ ctx: OneSatContext,
        _ request: MintItemRequest
    ) async -> ActionResult {
        do {
            let hasContent = request.base64Content != nil
            let hasRef = request.ref != nil
            if hasContent == hasRef {
                return ActionResult.failure(.exactlyOneOfContentOrRef)
            }
            if hasContent, request.contentType == nil || request.contentType?.isEmpty == true {
                return ActionResult.failure(.contentTypeRequiredWithContent)
            }
            if let ref = request.ref, !isValidRef(ref) {
                return ActionResult.failure(.invalidRef(ref: ref))
            }

            let content: [UInt8]
            let contentType: String
            if let ref = request.ref {
                content = Array(try JSONSerialization.data(withJSONObject: [".": ref]))
                contentType = "ord-fs/json"
            } else {
                content = try ActionBase64.decode(request.base64Content!)
                contentType = request.contentType!
            }
            if content.count > OneSatConstants.maxInscriptionBytes {
                return ActionResult.failure(.inscriptionTooLarge(bytes: content.count))
            }

            let parentBytes: [UInt8]
            do {
                parentBytes = try CollectionParse.parentBytes(collectionId: request.collectionId)
            } catch {
                return ActionResult.failure(.invalidCollectionIdFormat(id: request.collectionId))
            }

            let millis = Int64(Date().timeIntervalSince1970 * 1000)
            let keyID = "\(millis)"
            let address = try P1SATKey.address(
                identity: ctx.identity,
                keyID: keyID,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let lockingScript = try Inscription.create(
                content: content,
                contentType: contentType,
                parent: parentBytes,
                scriptSuffix: try MapSuffix.appending(
                    CollectionMap.collectionItem(
                        app: request.app,
                        name: request.name,
                        data: CollectionItemSubTypeData(
                            collectionId: request.collectionId,
                            mintNumber: request.mintNumber,
                            rank: request.rank,
                            rarityLabel: request.rarityLabel,
                            traits: request.traits,
                            attachments: request.attachments
                        )
                    ),
                    to: try ActionScript.payToPublicKeyHash(address)
                )
            ).lock()
            let nameTag = String(request.name.prefix(64))
            let result = try await publishWithSigma(
                ctx,
                description: "Create collection item: \(request.name)",
                outputDescription: "Collection item inscription",
                lockingScript: lockingScript,
                tags: [
                    "type:\(contentType)",
                    "origin",
                    "name:\(nameTag)",
                    "subType:collectionItem",
                    "collectionId:\(request.collectionId)",
                ],
                customInstructions: try CustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: keyID,
                    name: nameTag
                ).encoded()
            )
            guard result.txid != nil else {
                return ActionResult.failure(OneSatActionError.noTxidReturned)
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `publishCollectionWithSigma` (`collections/index.ts:254-352`).
    private static func publishWithSigma(
        _ ctx: OneSatContext,
        description: String,
        outputDescription: String,
        lockingScript: Script,
        tags: [String],
        customInstructions: String
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
            to: lockingScript,
            inputTxid: anchorTxid,
            inputVout: 0
        )

        // ActionResult.tx is Atomic BEEF. Phase 2 inputBEEF is the nested BEEF graph.
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
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: sigmaScript.bytes,
                    satoshis: 1,
                    outputDescription: outputDescription,
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: customInstructions,
                    tags: tags
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

    private static func isValidRef(_ ref: String) -> Bool {
        ref.range(
            of: #"^(_\d+|[0-9a-fA-F]{64}_\d+(:-?\d+)?)$"#,
            options: .regularExpression
        ) != nil
    }
}
