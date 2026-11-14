import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatTemplates
import ToolboxActions

/// BSV-21 token creation from `packages/actions/src/tokens/index.ts`: `deployBsv21Mint`,
/// `deployBsv21Auth` (both through `executeBsv21Deploy`) and `mintBsv21`.
///
/// Amounts are `UInt64`, the BSV-21 maximum; TS takes a bigint and the template rejects anything
/// above it the same way.
extension Tokens {
    // MARK: Requests and results

    /// `DeployBsv21MintInput`: a fixed supply, all of it minted to `destination` (default self).
    public struct DeployMintRequest: Equatable, Sendable {
        public let symbol: String
        public let amount: UInt64
        public let decimals: Int
        /// Passed through as TS does ("URL or data URI"); indexers expect an inscription outpoint.
        public let icon: String?
        public let destination: Destination?

        public init(
            symbol: String,
            amount: UInt64,
            decimals: Int = 0,
            icon: String? = nil,
            destination: Destination? = nil
        ) {
            self.symbol = symbol
            self.amount = amount
            self.decimals = decimals
            self.icon = icon
            self.destination = destination
        }
    }

    /// `DeployBsv21AuthInput`: a mintable token whose deploy output is the genesis authority.
    public struct DeployAuthRequest: Equatable, Sendable {
        public let symbol: String
        public let decimals: Int
        public let icon: String?
        public let destination: Destination?

        public init(
            symbol: String,
            decimals: Int = 0,
            icon: String? = nil,
            destination: Destination? = nil
        ) {
            self.symbol = symbol
            self.decimals = decimals
            self.icon = icon
            self.destination = destination
        }
    }

    /// `DeployBsv21Response`, plus `discoverySubmitted`.
    ///
    /// TS logs a failed discovery submit and returns success. Here the deploy still succeeds (it
    /// is on chain), `discoverySubmitted` is false and `submitError` says why, so the caller can
    /// retry with `submitDeploy` instead of the failure going unseen.
    public struct DeployResult: Equatable, Sendable {
        public let txid: String?
        /// Atomic BEEF of the deploy.
        public let tx: [UInt8]?
        /// `<txid>_0`.
        public let tokenId: String?
        /// `deployBsv21Auth` only: the genesis authority, equal to `tokenId`.
        public let authOutpoint: String?
        public let error: String?
        public let actionId: String?
        public let discoverySubmitted: Bool
        /// Why the discovery submit failed, when the deploy was broadcast but not submitted.
        public let submitError: String?

        public init(
            txid: String? = nil,
            tx: [UInt8]? = nil,
            tokenId: String? = nil,
            authOutpoint: String? = nil,
            error: String? = nil,
            actionId: String? = nil,
            discoverySubmitted: Bool = false,
            submitError: String? = nil
        ) {
            self.txid = txid
            self.tx = tx
            self.tokenId = tokenId
            self.authOutpoint = authOutpoint
            self.error = error
            self.actionId = actionId
            self.discoverySubmitted = discoverySubmitted
            self.submitError = submitError
        }

        static func failure(_ error: OneSatActionError, actionId: String? = nil) -> Self {
            Self(error: error.wireMessage, actionId: actionId)
        }
    }

    /// The deploy output, built without touching the network (`Inscriptions.prepare` pattern).
    public struct PreparedDeploy: Sendable {
        public let lockingScript: Script
        /// `bsv21:deploy`, plus `bsv21:auth` for a mintable deploy. No `bsv21:<tokenId>`: the id is
        /// this output's outpoint, unknown until the transaction exists.
        public let tags: [String]
        /// Only for a derived destination (self or a counterparty); nil for an address or script.
        public let customInstructions: String?
        public let keyID: String?
        public let description: String
        public let outputDescription: String
    }

    /// The minted output of `MintRequest`.
    public struct MintOutput: Equatable, Sendable {
        public let amount: UInt64
        public let destination: Destination?

        public init(amount: UInt64, destination: Destination? = nil) {
            self.amount = amount
            self.destination = destination
        }
    }

    /// `MintBsv21Input`.
    ///
    /// - `mint`: new supply, to `destination` (default self).
    /// - `auth`: where the continuing authority goes. Nil means self, unless `endMinting`.
    /// - `endMinting`: emit no authority, ending minting for good. Cannot be combined with `auth`.
    public struct MintRequest: Equatable, Sendable {
        public let tokenId: String
        public let mint: MintOutput?
        public let auth: Destination?
        public let endMinting: Bool

        public init(
            tokenId: String,
            mint: MintOutput? = nil,
            auth: Destination? = nil,
            endMinting: Bool = false
        ) {
            self.tokenId = tokenId
            self.mint = mint
            self.auth = auth
            self.endMinting = endMinting
        }
    }

    /// `mintBsv21` result, plus `overlaySubmitted` and `submitError` (TS logs a failed
    /// `tm_<tokenId>` submit).
    public struct MintResult: Equatable, Sendable {
        public let txid: String?
        public let tx: [UInt8]?
        /// `<txid>_<index>` of the continuing authority; nil when minting was ended.
        public let authOutpoint: String?
        public let error: String?
        public let actionId: String?
        public let overlaySubmitted: Bool
        /// Why the `tm_<tokenId>` submit failed, when the mint was broadcast but not submitted.
        public let submitError: String?

        public init(
            txid: String? = nil,
            tx: [UInt8]? = nil,
            authOutpoint: String? = nil,
            error: String? = nil,
            actionId: String? = nil,
            overlaySubmitted: Bool = false,
            submitError: String? = nil
        ) {
            self.txid = txid
            self.tx = tx
            self.authOutpoint = authOutpoint
            self.error = error
            self.actionId = actionId
            self.overlaySubmitted = overlaySubmitted
            self.submitError = submitError
        }

        static func failure(_ error: OneSatActionError, actionId: String? = nil) -> Self {
            Self(error: error.wireMessage, actionId: actionId)
        }
    }

    /// The mint transaction, built without touching the network.
    public struct PreparedMint: Sendable {
        public let description: String
        public let labels: [String]
        public let input: WalletCreateActionInput
        public let outputs: [WalletCreateActionOutput]
        public let signer: Ordinals.P2PKHSigner
        /// Index of the continuing authority output, when there is one.
        public let authOutputIndex: Int?
    }

    // MARK: Deploy

    /// `deployBsv21Mint` up to `createAction`: the `deploy+mint` output.
    public static func prepareDeployMint(
        identity: PrivateKey,
        _ request: DeployMintRequest,
        network: BitcoinNetwork = .mainnet,
        keyID: String? = nil
    ) throws -> PreparedDeploy {
        guard request.amount > 0 else { throw OneSatActionError.amountMustBePositive }
        let resolved = try ResolveDestination.resolve(
            identity: identity,
            destination: request.destination,
            protocolID: try OneSatConstants.p1satProtocolID,
            keyIDPrefix: "bsv21-deploy-\(request.symbol)",
            keyID: keyID,
            network: network
        )
        let script = try BSV21.deployMint(
            symbol: request.symbol,
            amount: String(request.amount),
            decimals: request.decimals,
            icon: request.icon
        ).lock(lockingScript: resolved.lockingScript)
        return PreparedDeploy(
            lockingScript: script,
            tags: Bsv21Remittance.filterTags(deploy: true),
            customInstructions: tokenInstructions(
                Bsv21Remittance.Fields(
                    amt: String(request.amount),
                    op: BSV21.Operation.deployMint.rawValue,
                    symbol: request.symbol,
                    decimals: String(request.decimals),
                    icon: request.icon
                ),
                derivation: resolved.customInstructions,
                derivedOnly: true
            ),
            keyID: resolved.customInstructions?.keyID,
            description: "Deploy \(request.symbol) (\(request.amount) fixed supply)",
            outputDescription: "Deploy \(request.symbol)"
        )
    }

    /// `deployBsv21Auth` up to `createAction`: the `deploy+auth` output, which is also the genesis
    /// authority.
    public static func prepareDeployAuth(
        identity: PrivateKey,
        _ request: DeployAuthRequest,
        network: BitcoinNetwork = .mainnet,
        keyID: String? = nil
    ) throws -> PreparedDeploy {
        let resolved = try ResolveDestination.resolve(
            identity: identity,
            destination: request.destination,
            protocolID: try OneSatConstants.p1satProtocolID,
            keyIDPrefix: "bsv21-auth-\(request.symbol)",
            keyID: keyID,
            network: network
        )
        let script = try BSV21.deployAuth(
            symbol: request.symbol,
            decimals: request.decimals,
            icon: request.icon
        ).lock(lockingScript: resolved.lockingScript)
        return PreparedDeploy(
            lockingScript: script,
            tags: Bsv21Remittance.filterTags(deploy: true, auth: true),
            customInstructions: tokenInstructions(
                Bsv21Remittance.Fields(
                    amt: "0",
                    op: BSV21.Operation.deployAuth.rawValue,
                    symbol: request.symbol,
                    decimals: String(request.decimals),
                    icon: request.icon
                ),
                derivation: resolved.customInstructions,
                derivedOnly: true
            ),
            keyID: resolved.customInstructions?.keyID,
            description: "Deploy \(request.symbol) (mintable)",
            outputDescription: "Deploy \(request.symbol) auth"
        )
    }

    /// `deployBsv21Mint`: deploys a fixed-supply token and submits it to `tm_bsv21`.
    ///
    /// The deploy carries no overlay fee. The token stays inactive until `fundOverlay` pays for it.
    public static func deployMint(
        _ ctx: OneSatContext,
        _ request: DeployMintRequest,
        keyID: String? = nil
    ) async -> DeployResult {
        do {
            let prepared = try prepareDeployMint(
                identity: ctx.identity,
                request,
                network: ctx.chain.network,
                keyID: keyID
            )
            return await executeDeploy(ctx, prepared, isAuth: false)
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return DeployResult(error: error.localizedDescription)
        }
    }

    /// `deployBsv21Auth`: deploys a mintable token. `authOutpoint` is the genesis authority.
    public static func deployAuth(
        _ ctx: OneSatContext,
        _ request: DeployAuthRequest,
        keyID: String? = nil
    ) async -> DeployResult {
        do {
            let prepared = try prepareDeployAuth(
                identity: ctx.identity,
                request,
                network: ctx.chain.network,
                keyID: keyID
            )
            return await executeDeploy(ctx, prepared, isAuth: true)
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return DeployResult(error: error.localizedDescription)
        }
    }

    /// Resubmits a deploy's BEEF to `tm_bsv21`, for a deploy whose `discoverySubmitted` was false.
    /// Checks that output 0 of the subject transaction is a BSV-21 deploy before sending it.
    public static func submitDeploy(_ ctx: OneSatContext, tx: [UInt8]) async throws {
        guard let bsv21 = ctx.bsv21 else { throw OneSatActionError.servicesRequired }
        let atomic = try AtomicBEEF(bytes: tx, limits: WalletBEEFLimits.standard)
        guard let subject = try atomic.beef.transaction(
            for: atomic.subjectTransactionID,
            limits: WalletBEEFLimits.standard.transactionLimits
        ),
            let first = subject.outputs.first,
            let decoded = BSV21.decode(first.lockingScript),
            decoded.tokenData.operation == .deployMint || decoded.tokenData.operation == .deployAuth
        else { throw OneSatActionError.notABsv21Deploy }
        try await bsv21.submitDiscovery(tx: tx)
    }

    /// The reason an overlay submit failed, as the result reports it.
    static func submitFailure(_ error: any Error) -> String {
        if let error = error as? OneSatActionError { return error.wireMessage }
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return String(describing: error)
    }

    /// `executeBsv21Deploy` plus the caller's discovery submit.
    private static func executeDeploy(
        _ ctx: OneSatContext,
        _ prepared: PreparedDeploy,
        isAuth: Bool
    ) async -> DeployResult {
        do {
            let result = try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                outputs: [
                    try WalletCreateActionOutput(
                        lockingScript: prepared.lockingScript.bytes,
                        satoshis: 1,
                        outputDescription: prepared.outputDescription,
                        basket: OneSatConstants.bsv21Basket,
                        customInstructions: prepared.customInstructions,
                        tags: prepared.tags
                    ),
                ],
                options: TrackedAction.Options(randomizeOutputs: false)
            )
            if let error = result.error {
                return DeployResult(error: error, actionId: result.actionId)
            }
            guard let txid = result.txid else {
                return .failure(.deployNoTxid, actionId: result.actionId)
            }
            let tokenId = "\(txid)_0"
            var submitted = false
            var submitError: String?
            if let tx = result.tx {
                do {
                    try await submitDeploy(ctx, tx: tx)
                    submitted = true
                } catch {
                    submitError = submitFailure(error)
                }
            } else {
                submitError = "no transaction to submit"
            }
            return DeployResult(
                txid: txid,
                tx: result.tx,
                tokenId: tokenId,
                authOutpoint: isAuth ? tokenId : nil,
                actionId: result.actionId,
                discoverySubmitted: submitted,
                submitError: submitError
            )
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return DeployResult(error: error.localizedDescription)
        }
    }

    // MARK: Mint

    /// `mintBsv21` input validation, in TS order, before any network call.
    static func validate(_ request: MintRequest) throws {
        if request.auth != nil, request.endMinting {
            throw OneSatActionError.authAndEndMintingMutuallyExclusive
        }
        if request.mint == nil, request.auth == nil, !request.endMinting {
            throw OneSatActionError.mustProvideMintOrAuth
        }
        if let mint = request.mint, mint.amount == 0 {
            throw OneSatActionError.mintAmountMustBePositive
        }
    }

    /// The first `bsv21:auth` output whose token id (CI, tags, then deploy outpoint) is `tokenId`.
    public static func authorityOutput(_ outputs: [WalletOutput], tokenId: String) -> WalletOutput? {
        let wanted = Bsv21Remittance.normalizeTokenId(tokenId)
        return outputs.first { matchesToken($0, normalizedTokenId: wanted) }
    }

    /// `mintBsv21` up to `createAction`: spends `authority` and emits the mint, the continuing
    /// authority and the overlay fee, in that order.
    public static func prepareMint(
        identity: PrivateKey,
        _ request: MintRequest,
        details: Bsv21TokenDetails,
        authority: WalletOutput,
        network: BitcoinNetwork = .mainnet,
        mintKeyID: String? = nil,
        authKeyID: String? = nil
    ) throws -> PreparedMint {
        try validate(request)
        guard let rawInstructions = authority.customInstructions else {
            throw OneSatActionError.authUtxoMissingCustomInstructions
        }
        if let object = RemittanceJSON.dictionary(rawInstructions), object["multiSig"] as? Bool == true {
            // TS signs a 1-of-N P2MS authority with `P2MS.unlockSingleWithWallet`; not ported.
            throw OneSatActionError.multiSigAuthNotSupported
        }
        let authCI = try CustomInstructions.parse(rawInstructions)
        let tokenId = request.tokenId
        let protocolID = try OneSatConstants.p1satProtocolID

        // `applyP1SatCreateAction` carries sym/dec/icon from a tracked input (one with an `id:`
        // tag, named by its input label) over the token details.
        let assetID = OneSatConstants.assetID(in: authority.tags)
        var carry: [(String, String)] = []
        if assetID != nil {
            let fields = Bsv21Remittance.fields(from: authority)
            if let id = fields.tokenId,
               Bsv21Remittance.normalizeTokenId(id) == Bsv21Remittance.normalizeTokenId(tokenId)
            {
                if let symbol = fields.symbol, !symbol.isEmpty { carry.append(("sym", symbol)) }
                if let decimals = fields.decimals, !decimals.isEmpty { carry.append(("dec", decimals)) }
                if let icon = fields.icon, !icon.isEmpty { carry.append(("icon", icon)) }
            }
        }

        func fields(amount: String, op: String) -> Bsv21Remittance.Fields {
            Bsv21Remittance.Fields(
                id: tokenId,
                amt: amount,
                op: op,
                symbol: details.symbol,
                decimals: String(details.decimals),
                icon: details.icon
            )
        }

        var outputs: [WalletCreateActionOutput] = []
        if let mint = request.mint {
            let resolved = try ResolveDestination.resolve(
                identity: identity,
                destination: mint.destination,
                protocolID: protocolID,
                keyIDPrefix: "bsv21-mint-\(tokenId)",
                keyID: mintKeyID,
                network: network
            )
            let script = try BSV21.mint(tokenID: tokenId, amount: String(mint.amount))
                .lock(lockingScript: resolved.lockingScript)
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: script.bytes,
                    satoshis: 1,
                    outputDescription: "Mint \(mint.amount) tokens",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: tokenInstructions(
                        fields(amount: String(mint.amount), op: BSV21.Operation.mint.rawValue),
                        derivation: resolved.customInstructions,
                        derivedOnly: false,
                        carry: carry
                    ),
                    tags: Bsv21Remittance.filterTags(tokenId: tokenId)
                )
            )
        }

        var authOutputIndex: Int?
        if !request.endMinting {
            let resolved = try ResolveDestination.resolve(
                identity: identity,
                destination: request.auth,
                protocolID: protocolID,
                keyIDPrefix: "bsv21-auth-\(tokenId)",
                keyID: authKeyID,
                network: network
            )
            let script = try BSV21.auth(tokenID: tokenId).lock(lockingScript: resolved.lockingScript)
            authOutputIndex = outputs.count
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: script.bytes,
                    satoshis: 1,
                    outputDescription: "Continuing mint authority",
                    basket: OneSatConstants.bsv21Basket,
                    customInstructions: tokenInstructions(
                        fields(amount: "0", op: BSV21.Operation.auth.rawValue),
                        derivation: resolved.customInstructions,
                        derivedOnly: false,
                        carry: carry
                    ),
                    tags: Bsv21Remittance.filterTags(tokenId: tokenId, auth: true)
                )
            )
        }

        // One fee per emitted token output, counted before the fee output is added.
        let tokenOutputCount = UInt64(outputs.count)
        if tokenOutputCount > 0, details.feePerOutput > 0 {
            try outputs.append(
                WalletCreateActionOutput(
                    lockingScript: try ActionScript.payToPublicKeyHash(details.feeAddress).bytes,
                    satoshis: details.feePerOutput * tokenOutputCount,
                    outputDescription: "Overlay processing fee",
                    tags: ["fee:overlay"]
                )
            )
        }

        var labels = [OneSatConstants.tokenLabel(tokenId)]
        if let assetID {
            labels.append(OneSatConstants.inputAssetLabel(basket: OneSatConstants.bsv21Basket, id: assetID))
        }
        let symbol = details.symbol.flatMap { $0.isEmpty ? nil : $0 } ?? String(tokenId.prefix(8))
        let description: String
        if let mint = request.mint {
            description = "Mint \(mint.amount) \(symbol)"
        } else if request.endMinting {
            description = "End \(symbol) mint authority"
        } else {
            description = "Re-issue \(symbol) authority"
        }

        return PreparedMint(
            description: description,
            labels: labels,
            input: try WalletCreateActionInput(
                outpoint: authority.outpoint,
                inputDescription: "Mint authority",
                unlockingScriptLength: OneSatConstants.p2pkhUnlockingScriptLength
            ),
            outputs: outputs,
            signer: Ordinals.P2PKHSigner(
                outpoint: authority.outpoint,
                protocolID: authCI.protocolID,
                keyID: authCI.keyID,
                counterparty: authCI.counterparty
            ),
            authOutputIndex: authOutputIndex
        )
    }

    /// `mintBsv21`: spends this wallet's authority for `tokenId` to mint supply, move the
    /// authority, or end minting, then submits to `tm_<tokenId>`.
    public static func mint(
        _ ctx: OneSatContext,
        _ request: MintRequest,
        mintKeyID: String? = nil,
        authKeyID: String? = nil
    ) async -> MintResult {
        do {
            try validate(request)
            guard let bsv21 = ctx.bsv21 else { return .failure(.servicesRequired) }
            let details: Bsv21TokenDetails
            do {
                details = try await bsv21.tokenDetails(tokenId: request.tokenId, fresh: true)
            } catch {
                return .failure(.tokenNotFound)
            }
            guard details.isActive else { return .failure(.tokenNotActive) }

            // A deploy+auth output cannot carry `bsv21:<tokenId>`, so candidates are listed by the
            // auth tag and matched by CI, tags, then deploy outpoint.
            let listed = try await ctx.storage.listOutputs(
                ctx.auth,
                try WalletListOutputsRequest(
                    basket: OneSatConstants.bsv21Basket,
                    tags: [Bsv21Remittance.authTag],
                    tagQueryMode: .all,
                    include: .entireTransactions,
                    includeCustomInstructions: true,
                    includeTags: true,
                    pagination: WalletPagination(limit: 1_000)
                )
            )
            guard let authority = authorityOutput(listed.outputs, tokenId: request.tokenId) else {
                return .failure(.noAuthUtxoForToken)
            }
            let prepared = try prepareMint(
                identity: ctx.identity,
                request,
                details: details,
                authority: authority,
                network: ctx.chain.network,
                mintKeyID: mintKeyID,
                authKeyID: authKeyID
            )
            let inputBEEF = try await resolveInputBEEF(
                listed: listed,
                selected: [SelectedInput(output: authority, amount: 0)],
                listings: ctx.listings
            )
            let result = try await TrackedAction.execute(
                ctx,
                description: prepared.description,
                inputBEEF: inputBEEF,
                inputs: [prepared.input],
                outputs: prepared.outputs,
                labels: prepared.labels,
                options: TrackedAction.Options(randomizeOutputs: false)
            ) { transaction in
                try Ordinals.signP2PKHInputs(ctx.identity, transaction, [prepared.signer])
            }
            if let error = result.error {
                return MintResult(error: error, actionId: result.actionId)
            }
            guard let txid = result.txid else {
                return .failure(.noTxidReturned, actionId: result.actionId)
            }
            var submitted = false
            var submitError: String?
            if let tx = result.tx {
                do {
                    try await bsv21.submitTransfer(tx: tx, tokenId: request.tokenId)
                    submitted = true
                } catch {
                    submitError = submitFailure(error)
                }
            } else {
                submitError = "no transaction to submit"
            }
            return MintResult(
                txid: txid,
                tx: result.tx,
                authOutpoint: prepared.authOutputIndex.map { "\(txid)_\($0)" },
                actionId: result.actionId,
                overlaySubmitted: submitted,
                submitError: submitError
            )
        } catch let error as OneSatActionError {
            return .failure(error)
        } catch {
            return MintResult(error: error.localizedDescription)
        }
    }

    // MARK: Custom instructions

    /// The token CI as TS writes it after `stampBsv21OutputCustomInstructions`: token fields, then
    /// derivation (`counterparty` only when not self), then carried fields overwriting in place or
    /// appended, as `JSON.stringify` orders a key set on an existing object.
    ///
    /// `derivedOnly` (the deploy) writes no CI for an address or script destination; the mint
    /// writes the token fields alone there.
    static func tokenInstructions(
        _ token: Bsv21Remittance.Fields,
        derivation: CustomInstructions?,
        derivedOnly: Bool,
        carry: [(String, String)] = []
    ) -> String? {
        if derivedOnly, derivation == nil { return nil }
        var pairs: [(String, String)] = []
        if let id = token.id, !id.isEmpty { pairs.append(("id", RemittanceJSON.string(id))) }
        pairs.append(("amt", RemittanceJSON.string(token.amt)))
        if let op = token.op, !op.isEmpty { pairs.append(("op", RemittanceJSON.string(op))) }
        if let symbol = token.symbol, !symbol.isEmpty { pairs.append(("sym", RemittanceJSON.string(symbol))) }
        if let decimals = token.decimals { pairs.append(("dec", RemittanceJSON.string(decimals))) }
        if let icon = token.icon, !icon.isEmpty { pairs.append(("icon", RemittanceJSON.string(icon))) }
        if let derivation {
            pairs.append(("protocolID", RemittanceJSON.protocolID(derivation.protocolID)))
            pairs.append(("keyID", RemittanceJSON.string(derivation.keyID)))
            switch derivation.counterparty {
            case .self:
                break
            case .anyone:
                pairs.append(("counterparty", RemittanceJSON.string("anyone")))
            case .publicKey(let key):
                pairs.append(("counterparty", RemittanceJSON.string(Hex.encode(key.compressedBytes))))
            }
        }
        for (key, value) in carry {
            let encoded = RemittanceJSON.string(value)
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[index].1 = encoded
            } else {
                pairs.append((key, encoded))
            }
        }
        return RemittanceJSON.object(pairs)
    }
}
