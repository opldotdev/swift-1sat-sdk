import BSVCore
import BSVTransaction
import BSVWallet
import ToolboxActions

/// OpNS `getOpnsNames` / `opnsRegister` / `opnsDeregister` from `packages/actions/src/opns/index.ts`.
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
                return [UInt32(index): try UnlockScripts.ordLockCancel(
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

    /// `opnsRegister`. Returns .failure(.servicesRequired) when ctx.services is nil.
    public static func register(_ ctx: OneSatContext, _ request: Request) async -> ActionResult {
        do {
            guard ctx.services != nil else {
                return ActionResult.failure(.servicesRequired)
            }
            let identityHex = Hex.encode(ctx.identity.publicKey.compressedBytes)
            let inputBEEF: [UInt8]
            if let provided = request.inputBEEF {
                inputBEEF = provided
            } else {
                inputBEEF = try await ResolveBeef.resolve(
                    ctx,
                    basket: OneSatConstants.opnsBasket,
                    tags: request.ordinal.tags
                )
            }
            return await Ordinals.transfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [
                        Ordinals.TransferItem(
                            ordinal: request.ordinal,
                            toSelf: true,
                            map: [("opns.idKey", identityHex)],
                            extraTags: ["opns:published"],
                            basket: OneSatConstants.opnsBasket
                        ),
                    ],
                    inputBEEF: inputBEEF
                )
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }

    /// `opnsDeregister`. No services check.
    public static func deregister(_ ctx: OneSatContext, _ request: Request) async -> ActionResult {
        do {
            let inputBEEF: [UInt8]
            if let provided = request.inputBEEF {
                inputBEEF = provided
            } else {
                inputBEEF = try await ResolveBeef.resolve(
                    ctx,
                    basket: OneSatConstants.opnsBasket,
                    tags: request.ordinal.tags
                )
            }
            return await Ordinals.transfer(
                ctx,
                Ordinals.TransferRequest(
                    transfers: [
                        Ordinals.TransferItem(
                            ordinal: request.ordinal,
                            toSelf: true,
                            map: [("opns.idKey", "")],
                            extraTags: [],
                            basket: OneSatConstants.opnsBasket
                        ),
                    ],
                    inputBEEF: inputBEEF
                )
            )
        } catch let error as OneSatActionError {
            return ActionResult.failure(error)
        } catch {
            return ActionResult.failure(error.localizedDescription)
        }
    }
}
