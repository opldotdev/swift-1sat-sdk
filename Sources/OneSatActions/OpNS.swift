import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// OpNS `listOpns` / `registerOpns` / `deregisterOpns` / `cancelOpnsListing` from
/// `packages/actions/src/opns/index.ts`.
///
/// A published name is locked in a signed PushDrop (`opns:published`): its `identity` field is
/// the wallet's BRC-100 identity key, its `profile` field a DAG-CBOR map. Spending one unlocks
/// with a single signature push (``SignOrdinalInput``).
public enum OpNS {
    public struct NamesResult: Sendable {
        public let outputs: [WalletOutput]
        public let beef: [UInt8]?

        public init(outputs: [WalletOutput], beef: [UInt8]?) {
            self.outputs = outputs
            self.beef = beef
        }
    }

    /// `getOpnsNames`: lists OneSatConstants.opnsBasket with tags, customInstructions,
    /// and entire transactions.
    public static func getNames(
        _ ctx: OneSatContext,
        limit: UInt32 = 100,
        offset: UInt32 = 0
    ) async throws -> NamesResult {
        let result = try await ctx.storage.listOutputs(
            ctx.auth,
            try WalletListOutputsRequest(
                basket: OneSatConstants.opnsBasket,
                include: .entireTransactions,
                includeCustomInstructions: true,
                includeTags: true,
                pagination: WalletPagination(limit: limit, offset: offset)
            )
        )
        return NamesResult(
            outputs: result.outputs,
            beef: try result.beef?.serialized(limits: WalletBEEFLimits.standard)
        )
    }

    public struct Request: Sendable {
        public let ordinal: WalletOutput
        public let inputBEEF: [UInt8]?

        public init(ordinal: WalletOutput, inputBEEF: [UInt8]? = nil) {
            self.ordinal = ordinal
            self.inputBEEF = inputBEEF
        }
    }

    /// `cancelOpnsListing`: returns the name to the OpNS basket with its metadata.
    public static func cancelListing(_ ctx: OneSatContext, _ request: Request) async -> ActionResult {
        do {
            let inputBEEF: [UInt8]
            if let provided = request.inputBEEF {
                inputBEEF = provided
            } else {
                inputBEEF = try await ResolveBeef.resolve(
                    ctx, basket: OneSatConstants.opnsBasket, tags: request.ordinal.tags
                )
            }
            let built = try Ordinals.buildCancel(
                ctx, Ordinals.CancelRequest(listing: request.ordinal, inputBEEF: inputBEEF)
            )
            let output = built.prepared.outputs[0]
            var tags = output.tags
            if !tags.contains("opns") { tags.insert("opns", at: 0) }
            let legacyName = request.ordinal.tags?.first(where: { $0.hasPrefix("name:") })
                .map { String($0.dropFirst(5)) }
            let name = OrdinalRemittance.displayName(legacyName)
                ?? Ordinals.sourceName(from: request.ordinal)
            let restored = try WalletCreateActionOutput(
                lockingScript: output.lockingScript,
                satoshis: 1,
                outputDescription: "Cancelled OpNS listing",
                basket: OneSatConstants.opnsBasket,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: request.ordinal.outpoint.description,
                    tags: tags,
                    name: name
                ),
                tags: tags
            )
            let labels = OneSatConstants.assetID(in: request.ordinal.tags).map {
                [OneSatConstants.inputAssetLabel(basket: OneSatConstants.opnsBasket, id: $0)]
            } ?? []
            return try await TrackedAction.execute(
                ctx,
                description: String((name.map { "Cancel OpNS listing \($0)" }
                    ?? "Cancel OpNS listing").prefix(50)),
                inputBEEF: TrackedAction.parseInputBEEF(inputBEEF),
                inputs: built.prepared.inputs,
                outputs: [restored],
                labels: labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                let index = try Ordinals.inputIndex(request.ordinal.outpoint, in: transaction)
                return [UInt32(index): try UnlockScripts.ordLockV2Cancel(
                    identity: ctx.identity,
                    transaction: transaction,
                    inputIndex: index,
                    protocolID: built.signProtocolID,
                    keyID: built.signKeyID,
                    counterparty: built.signCounterparty
                )]
            }
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `OPNS_REGISTER_KEY_PREFIX`
    public static let registerKeyPrefix = "opns:"
    /// `OPNS_REGISTER_COUNTERPARTY`: counterparty of the bind lock key and the field signature.
    public static let registerCounterparty = "anyone"

    /// `opnsRegisterKeyId`: `txid.vout` of the spent name to `opns:<txid>_<vout>`.
    public static func registerKeyID(_ outpoint: Outpoint) -> String {
        "\(registerKeyPrefix)\(outpoint.transactionID.displayHex)_\(outpoint.outputIndex)"
    }

    /// `OpnsProfile`: the `profile` written on the name. `avatar` is the origin outpoint
    /// (`txid_vout` or `txid.vout`) of an on-chain image ordinal, stored as its 36 bytes.
    public struct Profile: Equatable, Sendable {
        /// BRC-169 ecosystem domain (e.g. `1sat.name`), written exactly as given.
        public let domain: String
        /// Presentation name (served by paymail public-profile).
        public let name: String?
        public let avatar: String?

        public init(domain: String, name: String? = nil, avatar: String? = nil) {
            self.domain = domain
            self.name = name
            self.avatar = avatar
        }
    }

    /// `RegisterOpnsRequest`. `inscription` rides after the PushDrop lock; ORDFS serves it as
    /// the name's latest rev. The action does not interpret its content type.
    public struct RegisterRequest: Sendable {
        public let ordinal: WalletOutput
        public let profile: Profile
        public let inscription: Ordinals.InscriptionPayload?
        public let inputBEEF: [UInt8]?

        public init(
            ordinal: WalletOutput,
            profile: Profile,
            inscription: Ordinals.InscriptionPayload? = nil,
            inputBEEF: [UInt8]? = nil
        ) {
            self.ordinal = ordinal
            self.profile = profile
            self.inscription = inscription
            self.inputBEEF = inputBEEF
        }
    }

    /// The signed PushDrop bind, without any inscription:
    /// `<lock key> OP_CHECKSIG "identity" <identity key> "profile" <dag-cbor> <sig>
    /// OP_2DROP OP_2DROP OP_DROP`.
    ///
    /// Lock key is P1SAT `opns:<txid>_<vout>` of the spent name, counterparty `anyone`,
    /// `forSelf`; the signature is that key's DER ECDSA over sha256 of the four fields
    /// concatenated. TS emits a zeroed 72-byte placeholder and `applyOpnsRegister` swaps the
    /// signature in; Swift signs here, so the bytes equal the TS lock after apply.
    public static func publishLock(
        identity: PrivateKey,
        nameOutpoint: Outpoint,
        profile: OpnsFields.Profile
    ) async throws -> Script {
        let fields: [[UInt8]] = [
            Array(OpnsFields.identityField.utf8),
            identity.publicKey.compressedBytes,
            Array(OpnsFields.profileField.utf8),
            try OpnsFields.encodeProfile(profile),
        ]
        try OpnsFields.assertPublishFields(fields)
        return try await PushDrop.lockingScript(
            fields: fields,
            using: ProtoWallet(rootKey: identity),
            protocolID: try OneSatConstants.p1satProtocolID,
            keyID: WalletKeyID(registerKeyID(nameOutpoint)),
            counterparty: .anyone,
            forSelf: true,
            includeSignature: true,
            lockPosition: .beforeCompatibility
        )
    }

    /// `registerOpns`: publish the name. Locks the name coin in a signed PushDrop carrying
    /// `identity` and `profile` key/value fields, optionally followed by an inscription.
    public static func register(_ ctx: OneSatContext, _ request: RegisterRequest) async -> ActionResult {
        do {
            let ordinal = request.ordinal
            let inputBEEF = try await resolveInputBEEF(ctx, ordinal, request.inputBEEF)
            guard let instructions = ordinal.customInstructions else {
                return ActionResult.failure(.missingCustomInstructions)
            }
            let keyID = registerKeyID(ordinal.outpoint)
            var avatar: [UInt8]?
            let avatarOutpoint = request.profile.avatar?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let avatarOutpoint, !avatarOutpoint.isEmpty {
                avatar = try OpnsFields.outpointWire(avatarOutpoint)
            }
            var lock = try await publishLock(
                identity: ctx.identity,
                nameOutpoint: ordinal.outpoint,
                profile: OpnsFields.Profile(
                    domain: request.profile.domain,
                    name: request.profile.name,
                    avatar: avatar
                )
            )
            if let inscription = request.inscription {
                lock = try Inscription.create(
                    content: inscription.content,
                    contentType: inscription.contentType,
                    scriptPrefix: lock
                ).lock()
            }
            let name = nameFromOutput(ordinal)
            let tags = fileTags(ordinal, extra: [OneSatConstants.opnsPublishedTag])
            let output = try WalletCreateActionOutput(
                lockingScript: lock.bytes,
                satoshis: 1,
                outputDescription: "OpNS identity bind",
                basket: OneSatConstants.opnsBasket,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: keyID,
                    counterparty: registerCounterparty,
                    tags: tags,
                    name: name
                ),
                tags: tags
            )
            return try await execute(
                ctx,
                ordinal: ordinal,
                instructions: instructions,
                inputBEEF: inputBEEF,
                description: name.map { "Publish OpNS \($0)" } ?? "Publish OpNS name",
                inputDescription: "OpNS name to register",
                output: output
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch let error as OpnsFieldError {
            return ActionResult.failure(error.wireMessage)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `deregisterOpns`: remove the bind. Self-transfer to the P1SAT P2PKH for keyID = the
    /// name's outpoint; the `opns:published` tag is dropped.
    public static func deregister(_ ctx: OneSatContext, _ request: Request) async -> ActionResult {
        do {
            let ordinal = request.ordinal
            let inputBEEF = try await resolveInputBEEF(ctx, ordinal, request.inputBEEF)
            guard let instructions = ordinal.customInstructions else {
                return ActionResult.failure(.missingCustomInstructions)
            }
            let outpoint = ordinal.outpoint.description
            let address = try P1SATKey.address(
                identity: ctx.identity,
                keyID: outpoint,
                counterparty: .self,
                forSelf: true,
                network: ctx.chain.network
            )
            let name = nameFromOutput(ordinal)
            let tags = fileTags(ordinal)
            let output = try WalletCreateActionOutput(
                lockingScript: try ActionScript.payToPublicKeyHash(address).bytes,
                satoshis: 1,
                outputDescription: "OpNS name (unbound)",
                basket: OneSatConstants.opnsBasket,
                customInstructions: OrdinalRemittance.buildCustomInstructions(
                    protocolID: try OneSatConstants.p1satProtocolID,
                    keyID: outpoint,
                    counterparty: "self",
                    tags: tags,
                    name: name
                ),
                tags: tags
            )
            return try await execute(
                ctx,
                ordinal: ordinal,
                instructions: instructions,
                inputBEEF: inputBEEF,
                description: name.map { "Unpublish OpNS \($0)" } ?? "Unpublish OpNS name",
                inputDescription: "OpNS name to deregister",
                output: output
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// The bind on a published name: identity key and profile, or nil when `lockingScript` is
    /// not a well-formed OpNS publish (exactly one `identity`, at most one `profile`).
    public struct PublishedRecord: Equatable, Sendable {
        public let lockKey: PublicKey
        public let identityKey: PublicKey
        public let profile: OpnsFields.Profile?
        /// The trailing signature field (DER, over the other fields).
        public let signature: [UInt8]
    }

    /// Reads the PushDrop fields of a published name (an envelope after the PushDrop is
    /// ignored). Does not verify the signature.
    public static func publishedRecord(from lockingScript: Script) -> PublishedRecord? {
        guard let decoded = SignOrdinalInput.pushDrop(in: lockingScript) else { return nil }
        var fields = decoded.fields
        guard let signature = fields.popLast(),
              (try? OpnsFields.assertPublishFields(fields)) != nil,
              let pairs = try? OpnsFields.fieldPairs(fields)
        else {
            return nil
        }
        var identity: PublicKey?
        var profile: OpnsFields.Profile?
        for (key, value) in pairs {
            if key == OpnsFields.identityField {
                identity = try? PublicKey(value)
            } else if key == OpnsFields.profileField {
                profile = try? OpnsFields.decodeProfile(value)
            }
        }
        guard let identity else { return nil }
        return PublishedRecord(
            lockKey: decoded.publicKey,
            identityKey: identity,
            profile: profile,
            signature: signature
        )
    }

    private static func resolveInputBEEF(
        _ ctx: OneSatContext,
        _ ordinal: WalletOutput,
        _ provided: [UInt8]?
    ) async throws -> [UInt8] {
        if let provided { return provided }
        return try await ResolveBeef.resolve(ctx, basket: OneSatConstants.opnsBasket, tags: ordinal.tags)
    }

    /// `nameFromOutput`: `name:` tag first, then customInstructions `name`.
    static func nameFromOutput(_ output: WalletOutput) -> String? {
        let tagName = output.tags?.first(where: { $0.hasPrefix("name:") }).map { String($0.dropFirst(5)) }
        return OrdinalRemittance.displayName(tagName) ?? Ordinals.sourceName(from: output)
    }

    /// `opnsFileTags`: ordinal seed tags, `opns` first, then the extras.
    static func fileTags(_ output: WalletOutput, extra: [String] = []) -> [String] {
        var tags = Ordinals.seedTags(source: output)
        if !tags.contains("opns") { tags.insert("opns", at: 0) }
        for tag in extra where !tag.isEmpty && !tags.contains(tag) {
            tags.append(tag)
        }
        return tags
    }

    /// One name in, one name out, signed by script shape (PushDrop or P2PKH).
    private static func execute(
        _ ctx: OneSatContext,
        ordinal: WalletOutput,
        instructions: String,
        inputBEEF: [UInt8],
        description: String,
        inputDescription: String,
        output: WalletCreateActionOutput
    ) async throws -> ActionResult {
        let labels = OneSatConstants.assetID(in: ordinal.tags).map {
            [OneSatConstants.inputAssetLabel(basket: OneSatConstants.opnsBasket, id: $0)]
        } ?? []
        return try await TrackedAction.execute(
            ctx,
            description: String(description.prefix(50)),
            inputBEEF: TrackedAction.parseInputBEEF(inputBEEF),
            inputs: [
                try WalletCreateActionInput(
                    outpoint: ordinal.outpoint,
                    inputDescription: inputDescription,
                    unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
                ),
            ],
            outputs: [output],
            labels: labels,
            options: TrackedAction.Options(randomizeOutputs: false)
        ) { transaction in
            let index = try Ordinals.inputIndex(ordinal.outpoint, in: transaction)
            return [UInt32(index): try SignOrdinalInput.unlockingScript(
                identity: ctx.identity,
                transaction: transaction,
                inputIndex: index,
                customInstructions: instructions
            )]
        }
    }
}
