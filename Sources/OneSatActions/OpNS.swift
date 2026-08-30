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
