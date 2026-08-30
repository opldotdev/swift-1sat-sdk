import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// Ordinals transfer, list, cancel, purchase, and wallet listing.
///
/// Semantics from `packages/actions/src/ordinals/index.ts`.
public enum Ordinals {
    public struct TransferItem: Sendable {
        public let ordinal: WalletOutput
        public let counterparty: PublicKey?
        public let address: String?
        /// TS `counterparty: 'self'` with `forSelf: true`, keyID = source outpoint.
        public let toSelf: Bool
        public let map: [(String, String)]
        public let extraTags: [String]
        /// Optional new inscription payload. Same coin, same origin, new content.
        public let inscription: InscriptionPayload?
        /// Sign a new inscription envelope with the current BAP identity.
        public let signWithBAP: Bool
        /// Internal family override used by OpNS; normal ordinals always use `1sat`.
        public let basket: String?

        public init(
            ordinal: WalletOutput,
            counterparty: PublicKey? = nil,
            address: String? = nil,
            toSelf: Bool = false,
            map: [(String, String)] = [],
            extraTags: [String] = [],
            inscription: InscriptionPayload? = nil,
            signWithBAP: Bool = false,
            basket: String? = nil
        ) {
            self.ordinal = ordinal
            self.counterparty = counterparty
            self.address = address
            self.toSelf = toSelf
            self.map = map
            self.extraTags = extraTags
            self.inscription = inscription
            self.signWithBAP = signWithBAP
            self.basket = basket
        }
    }

    public struct InscriptionPayload: Sendable {
        public let content: [UInt8]
        public let contentType: String

        public init(content: [UInt8], contentType: String) {
            self.content = content
            self.contentType = contentType
        }
    }

    public struct TransferRequest: Sendable {
        public let transfers: [TransferItem]
        public let inputBEEF: [UInt8]?

        public init(transfers: [TransferItem], inputBEEF: [UInt8]? = nil) {
            self.transfers = transfers
            self.inputBEEF = inputBEEF
        }
    }

    public struct ListRequest: Sendable {
        public let ordinal: WalletOutput
        public let inputBEEF: [UInt8]?
        public let price: UInt64
        public let payAddress: String

        public init(
            ordinal: WalletOutput,
            price: UInt64,
            payAddress: String,
            inputBEEF: [UInt8]? = nil
        ) {
            self.ordinal = ordinal
            self.price = price
            self.payAddress = payAddress
            self.inputBEEF = inputBEEF
        }
    }

    public struct CancelRequest: Sendable {
        public let listing: WalletOutput
        public let inputBEEF: [UInt8]?

        public init(listing: WalletOutput, inputBEEF: [UInt8]? = nil) {
            self.listing = listing
            self.inputBEEF = inputBEEF
        }
    }

    public struct PurchaseRequest: Sendable {
        public let outpoint: Outpoint
        public let marketplaceAddress: String?
        public let marketplaceRate: Double?
        public let contentType: String?
        public let origin: String?
        public let name: String?

        public init(
            outpoint: Outpoint,
            marketplaceAddress: String? = nil,
            marketplaceRate: Double? = nil,
            contentType: String? = nil,
            origin: String? = nil,
            name: String? = nil
        ) {
            self.outpoint = outpoint
            self.marketplaceAddress = marketplaceAddress
            self.marketplaceRate = marketplaceRate
            self.contentType = contentType
            self.origin = origin
            self.name = name
        }
    }

    public struct PreparedAction: Sendable {
        public let description: String
        public let inputs: [WalletCreateActionInput]
        public let outputs: [WalletCreateActionOutput]
        public let labels: [String]
        public let signers: [P2PKHSigner]
    }

    public struct P2PKHSigner: Sendable {
        public let outpoint: Outpoint
        public let protocolID: WalletProtocolID
        public let keyID: String
        public let counterparty: WalletCounterparty
    }

    /// 1-sat P2PKH, optional MAP suffix. `ordinals/index.ts` `buildTransferOrdinals`.
    public static func transferLockingScript(
        address: String,
        map: [(String, String)] = []
    ) throws -> Script {
        try MapSuffix.appending(map, to: ActionScript.payToPublicKeyHash(address))
    }

    public static func recipientAddress(
        identity: PrivateKey,
        outpoint: String,
        counterparty: PublicKey,
        network: BitcoinNetwork = .mainnet
    ) throws -> Address {
        try P1SATKey.address(
            identity: identity,
            keyID: outpoint,
            counterparty: .publicKey(counterparty),
            forSelf: false,
            network: network
        )
    }

    public static func cancelAddress(
        identity: PrivateKey,
        outpoint: String,
        network: BitcoinNetwork = .mainnet
    ) throws -> Address {
        try P1SATKey.address(
            identity: identity,
            keyID: outpoint,
            counterparty: .self,
            forSelf: true,
            network: network
        )
    }

    public static func resolveOrdinalTags(
        outpoint: String,
        tags: [String]?,
        contentType: String? = nil,
        origin: String? = nil,
        name: String? = nil
    ) -> (tags: [String], basket: String) {
        var contentTypes: [String] = contentType.map { [$0] } ?? []
        var resolvedOrigin = origin
        var resolvedName = name
        if let tags {
            for tag in tags {
                if tag.hasPrefix("type:") {
                    let value = String(tag.dropFirst(5))
                    if !contentTypes.contains(value) { contentTypes.append(value) }
                }
                if resolvedOrigin == nil, tag == "origin" {
                    resolvedOrigin = outpoint
                } else if resolvedOrigin == nil, tag.hasPrefix("origin:") {
                    resolvedOrigin = String(tag.dropFirst(7))
                }
                if resolvedName == nil, tag.hasPrefix("name:") {
                    resolvedName = String(tag.dropFirst(5))
                }
            }
        }
        let resolvedContentType = contentTypes.last
        resolvedOrigin = resolvedOrigin ?? outpoint
        var next: [String] = contentTypes.map { "type:\($0)" }
        if let resolvedOrigin { next.append("origin:\(resolvedOrigin)") }
        if let resolvedName { next.append("name:\(String(resolvedName.prefix(64)))") }
        let basket = resolvedContentType == "application/op-ns"
            ? OneSatConstants.opnsBasket
            : OneSatConstants.ordinalsBasket
        return (next, basket)
    }

    /// `ordinalSeedTags` from `packages/actions/src/utils/ordinalSeedTags.ts`.
    public static func seedTags(source: WalletOutput) -> [String] {
        var out: [String] = []
        for tag in source.tags ?? [] {
            if tag == "origin" {
                let promoted = "origin:\(Bsv21Remittance.formatOrdinalOutpoint(source.outpoint.description))"
                if !out.contains(promoted) { out.append(promoted) }
                continue
            }
            if tag.hasPrefix("origin:") {
                let normalized = "origin:\(Bsv21Remittance.formatOrdinalOutpoint(String(tag.dropFirst(7))))"
                if !out.contains(normalized) { out.append(normalized) }
                continue
            }
            if tag.hasPrefix("content:") {
                let normalized = "content:\(Bsv21Remittance.formatOrdinalOutpoint(String(tag.dropFirst(8))))"
                if !out.contains(normalized) { out.append(normalized) }
                continue
            }
            if tag.hasPrefix("collection:") {
                let normalized = "collection:\(Bsv21Remittance.formatOrdinalOutpoint(String(tag.dropFirst(11))))"
                if !out.contains(normalized) { out.append(normalized) }
                continue
            }
            if tag.hasPrefix("type:") || tag.hasPrefix("app:") || tag.hasPrefix("creator:") {
                if !out.contains(tag) { out.append(tag) }
            }
        }
        let types = out.filter { $0.hasPrefix("type:") }
        if types.count > 1 {
            let full = types.filter { $0.contains("/") }
            if !full.isEmpty {
                return out.filter { !$0.hasPrefix("type:") || full.contains($0) }
            }
        }
        return out
    }

    public static func buildTransfer(
        _ ctx: OneSatContext,
        _ request: TransferRequest
    ) throws -> PreparedAction {
        guard !request.transfers.isEmpty else { throw OneSatActionError.noTransfers }

        var inputs: [WalletCreateActionInput] = []
        var outputs: [WalletCreateActionOutput] = []
        var labels: [String] = []
        var signers: [P2PKHSigner] = []

        for item in request.transfers {
            if !item.toSelf, item.counterparty == nil, item.address == nil {
                throw OneSatActionError.mustProvideCounterpartyOrAddress
            }
            if item.signWithBAP, item.inscription == nil {
                throw OneSatActionError.signWithBapRequiresInscription
            }
            let outpoint = item.ordinal.outpoint.description
            if let sourceType = item.ordinal.tags?.first(where: { $0.hasPrefix("type:") })?
                .dropFirst(5),
                sourceType == "application/bsv-20"
            {
                throw OneSatActionError.cannotTransferBsv20(outpoint: outpoint)
            }

            let recipient: String
            if item.toSelf {
                recipient = try P1SATKey.address(
                    identity: ctx.identity,
                    keyID: outpoint,
                    counterparty: .self,
                    forSelf: true,
                    network: ctx.chain.network
                ).description
            } else if let counterparty = item.counterparty {
                recipient = try Self.recipientAddress(
                    identity: ctx.identity,
                    outpoint: outpoint,
                    counterparty: counterparty,
                    network: ctx.chain.network
                ).description
            } else if let address = item.address {
                recipient = address
            } else {
                throw OneSatActionError.mustProvideCounterpartyOrAddress
            }

            var inscriptionContent: [UInt8]?
            var inscriptionType: String?
            if let payload = item.inscription {
                if payload.contentType.isEmpty || payload.contentType.utf8.count > 255 {
                    throw OneSatActionError.inscriptionContentTypeInvalid
                }
                if payload.content.isEmpty {
                    throw OneSatActionError.inscriptionContentEmpty
                }
                if payload.content.count > OneSatConstants.maxInscriptionBytes {
                    throw OneSatActionError.inscriptionTooLarge(bytes: payload.content.count)
                }
                inscriptionContent = payload.content
                inscriptionType = payload.contentType
            }

            // BRC-147 identity is the first envelope. Reinscription changes the
            // current bytes but preserves the source origin and type tags.
            var tags = seedTags(source: item.ordinal)
            tags.append(contentsOf: item.extraTags)
            let basket = item.basket ?? OneSatConstants.ordinalsBasket

            try inputs.append(
                WalletCreateActionInput(
                    outpoint: item.ordinal.outpoint,
                    inputDescription: "Ordinal to transfer",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                )
            )
            if let inputID = OneSatConstants.assetID(in: item.ordinal.tags) {
                labels.append(
                    OneSatConstants.inputAssetLabel(
                        basket: OneSatConstants.ordinalsBasket,
                        id: inputID
                    )
                )
            }

            let recipientScript = try ActionScript.payToPublicKeyHash(recipient)
            var lockingScript: Script
            if let inscriptionContent, let inscriptionType {
                lockingScript = try Inscriptions.lockingScript(
                    content: inscriptionContent,
                    contentType: inscriptionType,
                    recipient: recipientScript,
                    map: item.map
                )
            } else {
                lockingScript = try transferLockingScript(address: recipient, map: item.map)
            }
            if item.signWithBAP {
                lockingScript = try Sigma.appendPlaceholder(to: lockingScript, vin: inputs.count - 1)
            }
            if item.toSelf {
                var sourceName: String?
                if let instructions = item.ordinal.customInstructions,
                   let parsed = try? CustomInstructions.parse(instructions)
                {
                    sourceName = parsed.name
                }
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: lockingScript.bytes,
                        satoshis: 1,
                        outputDescription: "Ordinal self-transfer",
                        basket: basket,
                        customInstructions: OrdinalRemittance.buildCustomInstructions(
                            protocolID: try OneSatConstants.p1satProtocolID,
                            keyID: outpoint,
                            tags: tags,
                            name: sourceName
                        ),
                        tags: tags
                    )
                )
            } else {
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: lockingScript.bytes,
                        satoshis: 1,
                        outputDescription: item.counterparty == nil
                            ? "Ordinal transfer to external address"
                            : "Ordinal transfer",
                        tags: []
                    )
                )
            }

            guard let instructions = item.ordinal.customInstructions else {
                throw OneSatActionError.missingCustomInstructions
            }
            let parsed = try CustomInstructions.parse(instructions)
            signers.append(
                P2PKHSigner(
                    outpoint: item.ordinal.outpoint,
                    protocolID: parsed.protocolID,
                    keyID: parsed.keyID,
                    counterparty: parsed.counterparty
                )
            )
        }

        let description = request.transfers.count == 1
            ? "Transfer ordinal"
            : "Transfer \(request.transfers.count) ordinals"
        return PreparedAction(
            description: description,
            inputs: inputs,
            outputs: outputs,
            labels: labels,
            signers: signers
        )
    }

    public static func transfer(
        _ ctx: OneSatContext,
        _ request: TransferRequest
    ) async -> ActionResult {
        do {
            let prepared = try buildTransfer(ctx, request)
            var outputs = prepared.outputs
            for (index, item) in request.transfers.enumerated() where item.signWithBAP {
                let placeholder = try Script(
                    bytes: outputs[index].lockingScript,
                    maximumByteCount: ActionScript.maximumByteCount
                )
                let sealed = try await Sigma.sealPlaceholder(
                    ctx,
                    in: placeholder,
                    inputTxid: item.ordinal.outpoint.transactionID.displayHex,
                    inputVout: item.ordinal.outpoint.outputIndex,
                    refVin: index
                )
                let tags = outputs[index].tags.filter { !$0.hasPrefix("creator:") }
                    + ["creator:\(sealed.creator)"]
                var sourceName: String?
                if let instructions = outputs[index].customInstructions {
                    sourceName = (try? CustomInstructions.parse(instructions))?.name
                }
                let customInstructions = item.toSelf
                    ? OrdinalRemittance.buildCustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: item.ordinal.outpoint.description,
                        tags: tags,
                        name: sourceName
                    )
                    : outputs[index].customInstructions
                outputs[index] = try WalletCreateActionOutput(
                    lockingScript: sealed.script.bytes,
                    satoshis: outputs[index].satoshis,
                    outputDescription: outputs[index].outputDescription,
                    basket: outputs[index].basket,
                    customInstructions: customInstructions,
                    tags: tags
                )
            }
            return try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                inputBEEF: try TrackedAction.parseInputBEEF(request.inputBEEF),
                inputs: prepared.inputs,
                outputs: outputs,
                labels: prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                try signP2PKHInputs(ctx.identity, transaction, prepared.signers)
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func buildList(
        _ ctx: OneSatContext,
        _ request: ListRequest
    ) throws -> PreparedAction {
        guard !request.payAddress.isEmpty else { throw OneSatActionError.missingPayAddress }
        guard request.price > 0 else { throw OneSatActionError.invalidPrice }

        let outpoint = request.ordinal.outpoint.description
        let cancel = try cancelAddress(
            identity: ctx.identity,
            outpoint: outpoint,
            network: ctx.chain.network
        )
        let lockingScript = try OrdLock.lock(
            cancelAddress: cancel.description,
            payAddress: request.payAddress,
            price: request.price
        )
        var tags = seedTags(source: request.ordinal)
        tags.append("ordlock")
        tags.append("price:\(request.price)")

        var sourceName: String?
        if let instructions = request.ordinal.customInstructions,
           let parsed = try? CustomInstructions.parse(instructions)
        {
            sourceName = parsed.name
        }

        let inputID = OneSatConstants.assetID(in: request.ordinal.tags)
        let labels = inputID.map {
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.ordinalsBasket, id: $0)]
        } ?? []

        guard let instructions = request.ordinal.customInstructions else {
            throw OneSatActionError.missingCustomInstructions
        }
        let parsed = try CustomInstructions.parse(instructions)

        return PreparedAction(
            description: "List ordinal for \(request.price) sats",
            inputs: [
                try WalletCreateActionInput(
                    outpoint: request.ordinal.outpoint,
                    inputDescription: "Ordinal to list",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: lockingScript.bytes,
                    satoshis: 1,
                    outputDescription: "List ordinal for \(request.price) sats",
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: OrdinalRemittance.buildCustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: outpoint,
                        tags: tags,
                        name: sourceName
                    ),
                    tags: tags
                ),
            ],
            labels: labels,
            signers: [
                P2PKHSigner(
                    outpoint: request.ordinal.outpoint,
                    protocolID: parsed.protocolID,
                    keyID: parsed.keyID,
                    counterparty: parsed.counterparty
                ),
            ]
        )
    }

    public static func list(
        _ ctx: OneSatContext,
        _ request: ListRequest
    ) async -> ActionResult {
        do {
            let prepared = try buildList(ctx, request)
            return try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                inputBEEF: try TrackedAction.parseInputBEEF(request.inputBEEF),
                inputs: prepared.inputs,
                outputs: prepared.outputs,
                labels: prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                try signP2PKHInputs(ctx.identity, transaction, prepared.signers)
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func buildCancel(
        _ ctx: OneSatContext,
        _ request: CancelRequest
    ) throws -> (prepared: PreparedAction, signProtocolID: WalletProtocolID, signKeyID: String, signCounterparty: WalletCounterparty) {
        guard let instructions = request.listing.customInstructions else {
            throw OneSatActionError.missingCustomInstructions
        }
        let parsed = try CustomInstructions.parse(instructions)
        let outpoint = request.listing.outpoint.description
        let newKeyID = outpoint
        let cancel = try cancelAddress(
            identity: ctx.identity,
            outpoint: newKeyID,
            network: ctx.chain.network
        )
        let tags = seedTags(source: request.listing)
        var sourceName: String?
        if let instructions = request.listing.customInstructions,
           let source = try? CustomInstructions.parse(instructions)
        {
            sourceName = source.name
        }
        let inputID = OneSatConstants.assetID(in: request.listing.tags)
        let labels = inputID.map {
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.ordinalsBasket, id: $0)]
        } ?? []

        let prepared = PreparedAction(
            description: "Cancel ordinal listing",
            inputs: [
                try WalletCreateActionInput(
                    outpoint: request.listing.outpoint,
                    inputDescription: "Listed ordinal",
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: [
                try WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(cancel).bytes,
                    satoshis: 1,
                    outputDescription: "Cancelled listing",
                    basket: OneSatConstants.ordinalsBasket,
                    customInstructions: OrdinalRemittance.buildCustomInstructions(
                        protocolID: try OneSatConstants.p1satProtocolID,
                        keyID: newKeyID,
                        tags: tags,
                        name: sourceName
                    ),
                    tags: tags
                ),
            ],
            labels: labels,
            signers: []
        )
        return (prepared, parsed.protocolID, parsed.keyID, parsed.counterparty)
    }

    public static func cancelListing(
        _ ctx: OneSatContext,
        _ request: CancelRequest
    ) async -> ActionResult {
        do {
            let built = try buildCancel(ctx, request)
            return try await TrackedAction.execute(
                ctx,
                description: built.prepared.description,
                inputBEEF: try TrackedAction.parseInputBEEF(request.inputBEEF),
                inputs: built.prepared.inputs,
                outputs: built.prepared.outputs,
                labels: built.prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                let index = try inputIndex(request.listing.outpoint, in: transaction)
                return [
                    UInt32(index): try UnlockScripts.ordLockCancel(
                        identity: ctx.identity,
                        transaction: transaction,
                        inputIndex: index,
                        protocolID: built.signProtocolID,
                        keyID: built.signKeyID,
                        counterparty: built.signCounterparty
                    ),
                ]
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func buildPurchase(
        _ ctx: OneSatContext,
        outpoint: Outpoint,
        listingScript: Script,
        listingSatoshis: UInt64,
        marketplaceAddress: String? = nil,
        marketplaceRate: Double? = nil,
        contentType: String? = nil,
        origin: String? = nil,
        name: String? = nil
    ) throws -> PreparedAction {
        guard let decoded = OrdLock.decode(listingScript, network: ctx.chain.network) else {
            throw OneSatActionError.notAnOrdLockListing
        }
        let outpointText = outpoint.description
        let ourAddress = try cancelAddress(
            identity: ctx.identity,
            outpoint: outpointText,
            network: ctx.chain.network
        )
        let resolved = resolveOrdinalTags(
            outpoint: outpointText,
            tags: nil,
            contentType: contentType,
            origin: origin,
            name: name
        )

        var outputs: [WalletCreateActionOutput] = [
            try WalletCreateActionOutput(
                lockingScript: try ActionScript.payToPublicKeyHash(ourAddress).bytes,
                satoshis: 1,
                outputDescription: "Purchased ordinal",
                basket: resolved.basket,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: outpointText,
                    tags: resolved.tags,
                    name: name
                ),
                tags: resolved.tags
            ),
        ]

        let payout = try payoutOutput(decoded.payout)
        try outputs.append(
            WalletCreateActionOutput(
                lockingScript: payout.script.bytes,
                satoshis: payout.satoshis,
                outputDescription: "Payment to seller",
                tags: []
            )
        )

        if let marketplaceAddress, let marketplaceRate, marketplaceRate > 0 {
            let marketFee = UInt64((Double(payout.satoshis) * marketplaceRate).rounded(.up))
            if marketFee > 0 {
                try outputs.append(
                    WalletCreateActionOutput(
                        lockingScript: try ActionScript.payToPublicKeyHash(marketplaceAddress).bytes,
                        satoshis: marketFee,
                        outputDescription: "Marketplace fee",
                        tags: []
                    )
                )
            }
        }

        _ = listingSatoshis
        return PreparedAction(
            description: "Purchase ordinal for \(payout.satoshis) sats",
            inputs: [
                try WalletCreateActionInput(
                    outpoint: outpoint,
                    inputDescription: "Listed ordinal",
                    unlockingScriptLength: OneSatConstants.purchaseUnlockingScriptLength
                ),
            ],
            outputs: outputs,
            labels: [],
            signers: []
        )
    }

    public static func purchase(
        _ ctx: OneSatContext,
        _ request: PurchaseRequest
    ) async -> ActionResult {
        do {
            guard let listings = ctx.listings else {
                return ActionResult.failure(.servicesRequiredForPurchase)
            }
            let beef = try await listings.beef(forTxid: request.outpoint.transactionID.displayHex)
            let parsed = try BEEF(bytes: beef, limits: WalletBEEFLimits.standard)
            let limits = WalletBEEFLimits.standard.transactionLimits
            guard let listingTx = parsed.transactions.compactMap(\.transaction).first(where: {
                (try? $0.transactionID(limits: limits).displayHex)
                    == request.outpoint.transactionID.displayHex
            }) else {
                return ActionResult.failure(.listingTransactionNotFound)
            }
            let vout = Int(request.outpoint.outputIndex)
            guard listingTx.outputs.indices.contains(vout) else {
                return ActionResult.failure(.listingOutputNotFound)
            }
            let listingOutput = listingTx.outputs[vout]
            let prepared = try buildPurchase(
                ctx,
                outpoint: request.outpoint,
                listingScript: listingOutput.lockingScript,
                listingSatoshis: listingOutput.satoshis,
                marketplaceAddress: request.marketplaceAddress,
                marketplaceRate: request.marketplaceRate,
                contentType: request.contentType,
                origin: request.origin,
                name: request.name
            )
            return try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                inputBEEF: parsed,
                inputs: prepared.inputs,
                outputs: prepared.outputs,
                labels: prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                let index = try inputIndex(request.outpoint, in: transaction)
                return [
                    UInt32(index): try UnlockScripts.ordLockPurchase(
                        transaction: transaction, inputIndex: index
                    ),
                ]
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    public static func getOrdinals(
        _ ctx: OneSatContext,
        limit: UInt32 = 100,
        offset: UInt32 = 0
    ) async throws -> [WalletOutput] {
        let result = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.ordinalsBasket,
                include: .entireTransactions,
                includeCustomInstructions: true,
                includeTags: true,
                pagination: WalletPagination(limit: limit, offset: offset)
            )
        )
        return result.outputs
    }

    public static func payoutOutput(_ payout: [UInt8]) throws -> (satoshis: UInt64, script: Script) {
        guard payout.count >= 9 else { throw OneSatActionError.notAnOrdLockListing }
        var satoshis: UInt64 = 0
        for index in 0..<8 {
            satoshis |= UInt64(payout[index]) << (index * 8)
        }
        let rest = Array(payout[8...])
        let prefix = try readCompactSize(rest)
        let scriptStart = prefix.consumed
        let scriptEnd = scriptStart + Int(prefix.value)
        guard rest.count >= scriptEnd else { throw OneSatActionError.notAnOrdLockListing }
        let script = try Script(
            bytes: Array(rest[scriptStart..<scriptEnd]),
            maximumByteCount: ActionScript.maximumByteCount
        )
        return (satoshis, script)
    }

    private static func readCompactSize(_ bytes: [UInt8]) throws -> (value: UInt64, consumed: Int) {
        guard let first = bytes.first else { throw OneSatActionError.notAnOrdLockListing }
        switch first {
        case 0x00...0xfc:
            return (UInt64(first), 1)
        case 0xfd:
            guard bytes.count >= 3 else { throw OneSatActionError.notAnOrdLockListing }
            return (UInt64(bytes[1]) | UInt64(bytes[2]) << 8, 3)
        case 0xfe:
            guard bytes.count >= 5 else { throw OneSatActionError.notAnOrdLockListing }
            var value: UInt64 = 0
            for index in 0..<4 { value |= UInt64(bytes[1 + index]) << (index * 8) }
            return (value, 5)
        default:
            guard bytes.count >= 9 else { throw OneSatActionError.notAnOrdLockListing }
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(bytes[1 + index]) << (index * 8) }
            return (value, 9)
        }
    }

    static func signP2PKHInputs(
        _ identity: PrivateKey,
        _ transaction: Transaction,
        _ signers: [P2PKHSigner]
    ) throws -> [UInt32: Script] {
        var spends: [UInt32: Script] = [:]
        for signer in signers {
            let index = try inputIndex(signer.outpoint, in: transaction)
            spends[UInt32(index)] = try SignP2PKH.unlockingScript(
                identity: identity,
                transaction: transaction,
                inputIndex: index,
                protocolID: signer.protocolID,
                keyID: signer.keyID,
                counterparty: signer.counterparty
            )
        }
        return spends
    }

    static func inputIndex(_ outpoint: Outpoint, in transaction: Transaction) throws -> Int {
        guard let index = transaction.inputs.firstIndex(where: {
            $0.previousOutput == outpoint
        }) else {
            throw OneSatActionError.inputNotInTransaction(outpoint: outpoint.description)
        }
        return index
    }
}
