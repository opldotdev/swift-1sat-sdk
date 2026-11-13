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

    /// `mintCollection` (`collections/index.ts:265-422`).
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
            let displayName = String(request.name.prefix(64))
            let tags = [
                typeTag(request.contentType),
                "origin",
                "subType:collection",
            ]
            let result = try await publishWithSigma(
                ctx,
                description: "Create collection: \(request.name)",
                outputDescription: "Collection inscription",
                lockingScript: lockingScript,
                tags: tags,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: keyID,
                    counterparty: "self",
                    tags: tags,
                    name: displayName
                )
            )
            guard let txid = result.txid else {
                return MintResult(error: SigmaPublish.publishError(result.error))
            }
            return MintResult(txid: txid, collectionId: "\(txid)_0", tx: result.tx)
        } catch let error as OneSatActionError {
            return MintResult(error: error.wireMessage)
        } catch {
            return MintResult(error: error.localizedDescription)
        }
    }

    /// `mintCollectionItem` (`collections/index.ts:427-586`).
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
            let displayName = String(request.name.prefix(64))
            let tags = [
                typeTag(contentType),
                "origin",
                "subType:collectionItem",
                "collection:\(request.collectionId)",
            ]
            let result = try await publishWithSigma(
                ctx,
                description: "Create collection item: \(request.name)",
                outputDescription: "Collection item inscription",
                lockingScript: lockingScript,
                tags: tags,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: keyID,
                    counterparty: "self",
                    tags: tags,
                    name: displayName
                )
            )
            guard result.txid != nil else {
                return ActionResult.failure(SigmaPublish.publishError(result.error))
            }
            return result
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `mintWithSigma` (`collections/index.ts:199-256`) through the SIGMA apply step
    /// (`apply/inscribeSigma.ts`): a 2-sat noSend anchor keyed `anchor-<actionId>`, the
    /// inscription sealed against anchor input 0, then the publish spending the anchor and
    /// sending it along. Its tags come out as the apply step writes them: the collection tags,
    /// `id:`, then `creator:`.
    private static func publishWithSigma(
        _ ctx: OneSatContext,
        description: String,
        outputDescription: String,
        lockingScript: Script,
        tags: [String],
        customInstructions: String
    ) async throws -> ActionResult {
        try await SigmaPublish.publish(
            ctx,
            description: description,
            sealing: lockingScript
        ) { sealed in
            [
                try WalletCreateActionOutput(
                    lockingScript: sealed.script.bytes,
                    satoshis: 1,
                    outputDescription: outputDescription,
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: customInstructions,
                    tags: sealed.tags(tags, index: 0)
                ),
            ]
        }
    }

    private static func isValidRef(_ ref: String) -> Bool {
        ref.range(
            of: #"^(_\d+|[0-9a-fA-F]{64}_\d+(:-?\d+)?)$"#,
            options: .regularExpression
        ) != nil
    }

    private static func typeTag(_ contentType: String) -> String {
        let base = contentType.split(
            separator: ";",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return "type:\(base.isEmpty ? contentType : base)"
    }
}
