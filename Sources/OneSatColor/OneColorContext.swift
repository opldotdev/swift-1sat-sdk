import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxBRC29
import ToolboxStorage
import OneSatActions
import OneSatMetanet

/// Fixed values of the 1Color actions, as `@1sat/types` and the color permission module define them.
public enum OneColorConstants {
    /// Satoshis of every token output.
    public static let carrierSatoshis: UInt64 = 1
    /// The unlocking script length a token input declares: `<sig+hashtype> <pubkey>`.
    public static let unlockingScriptLength: UInt32 = 108
    public static let tokenInputDescription = "BRC-207 token input"
    public static let listPageLimit: UInt32 = 10_000
    public static let submitAttempts = 3
    /// The messagebox box BRC-232 deliveries go to.
    public static let transactionDeliveryBox = "transaction-delivery"
    /// Default BRC-177 expiry of a send handoff: one year.
    public static let sendExpirySeconds = 31_536_000
    /// Label carrying a send's key derivation: `1color send <prefix hex> <suffix hex>`.
    public static let sendLabelPrefix = "1color send "
}

/// What the 1Color actions run against: the wallet's identity and storage, the BRC-207 overlay,
/// handle resolution and the messagebox relay.
public struct OneColorContext: Sendable {
    public let identity: PrivateKey
    public let storage: any ColorWalletStorage
    public let auth: AuthID
    public let maximumFee: Int64
    /// The overlay the module checks spendability and admission with, and submits to. No default:
    /// actions that need it fail with `overlay-required`.
    public let overlay: (any ColorOverlayProvider)?
    public let handles: HandleResolver
    public let relay: CborRelay

    public init(
        identity: PrivateKey,
        storage: any ColorWalletStorage,
        auth: AuthID,
        maximumFee: Int64,
        overlay: (any ColorOverlayProvider)? = nil,
        handles: HandleResolver = HandleResolver(),
        relay: CborRelay? = nil
    ) {
        self.identity = identity
        self.storage = storage
        self.auth = auth
        self.maximumFee = maximumFee
        self.overlay = overlay
        self.handles = handles
        self.relay = relay ?? CborRelay(transport: MessageBoxHTTPRelay(wallet: ProtoWallet(rootKey: identity)))
    }

    public init(
        _ ctx: OneSatContext,
        overlay: (any ColorOverlayProvider)? = nil,
        handles: HandleResolver = HandleResolver(),
        relay: CborRelay? = nil
    ) {
        self.init(
            identity: ctx.identity, storage: ctx.storage, auth: ctx.auth, maximumFee: ctx.maximumFee,
            overlay: overlay, handles: handles, relay: relay
        )
    }

    /// The identity key, 66 lowercase hex.
    public var identityKey: String { Hex.encode(identity.publicKey.compressedBytes) }

    func requireOverlay() throws -> any ColorOverlayProvider {
        guard let overlay else { throw ColorError.overlay("overlay-required") }
        return overlay
    }
}

/// A `p color` output this wallet spends: its source, token and custody.
struct ColorManagedInput: Sendable {
    let outpoint: String
    let lockingScript: Script
    let satoshis: UInt64
    let assetID: ColorAssetID
    let role: ColorTokenRole
    let amount: UInt64
    let custody: ColorCustody
    let suffixTag: String
    /// Set for an output this action just created (a split), whose source is not in storage yet.
    var sourceBEEF: BEEF?
}

/// Creates, signs and processes an action whose token inputs this module signs. Storage-chosen
/// BRC-29 funding inputs are signed as `TrackedAction` signs them.
enum ColorExecutor {
    static let beefLimits = WalletBEEFLimits.standard

    static func options(noSend: Bool = false) throws -> WalletCreateActionOptions {
        try WalletCreateActionOptions(signAndProcess: false, noSend: noSend ? true : nil, randomizeOutputs: false)
    }

    static func tokenInputs(_ inputs: [ColorManagedInput]) throws -> [WalletCreateActionInput] {
        try inputs.map {
            try WalletCreateActionInput(
                outpoint: try Outpoint($0.outpoint),
                inputDescription: OneColorConstants.tokenInputDescription,
                unlockingScriptLength: OneColorConstants.unlockingScriptLength
            )
        }
    }

    static func execute(
        _ ctx: OneColorContext, request: WalletCreateActionRequest, tokenInputs: [ColorManagedInput]
    ) async throws -> SignedAction {
        let funded = try await ctx.storage.colorCreateAction(ctx.auth, request)
        do {
            try ActionAssembler.requireFeeWithin(ctx.maximumFee, for: funded)
            var transaction = try ActionAssembler.assemble(
                funded, requested: request.outputs ?? [], changeKey: ctx.identity
            )
            let spends = try unlocks(transaction, inputs: tokenInputs, identity: ctx.identity)
            for (index, script) in spends { transaction.inputs[index].unlockingScript = script }
            try signFundingInputs(&transaction, funded: funded, identity: ctx.identity, alreadySigned: Set(spends.keys))
            let signed = try SignedAction(funded: funded, transaction: transaction)
            let processed = try await ctx.storage.processAction(ctx.auth, try signed.processRequest())
            if let failed = processed.sendWithResults.first(where: { $0.status != .unproven }) {
                throw ColorError.custody("broadcast \(failed.status.rawValue)")
            }
            return signed
        } catch {
            await abort(ctx, reference: funded.reference)
            throw error
        }
    }

    /// P2PKH unlocks of the token inputs, `SIGHASH_ALL|FORKID`, with their `p color` keys.
    static func unlocks(
        _ transaction: Transaction, inputs: [ColorManagedInput], identity: PrivateKey
    ) throws -> [Int: Script] {
        var spends: [Int: Script] = [:]
        for input in inputs {
            guard let index = transaction.inputs.firstIndex(where: { $0.previousOutput.description == input.outpoint }) else {
                throw ColorError.custody("the signable transaction omits a token input")
            }
            spends[index] = try SignP2PKH.unlockingScript(
                privateKey: try ColorKeys.privateKey(identity: identity, custody: input.custody),
                transaction: transaction, inputIndex: index
            )
        }
        return spends
    }

    static func signFundingInputs(
        _ transaction: inout Transaction, funded: StorageCreateActionResult, identity: PrivateKey,
        alreadySigned: Set<Int>
    ) throws {
        for (index, input) in funded.inputs.enumerated() where !alreadySigned.contains(index) {
            guard let prefix = input.derivationPrefix, let suffix = input.derivationSuffix else { continue }
            let sender = try input.senderIdentityKey.map {
                try PublicKey(try Hex.decode($0, maximumDecodedByteCount: 33))
            } ?? identity.publicKey
            let key = try BRC29.receivingPrivateKey(recipient: identity, sender: sender, prefix: prefix, suffix: suffix)
            try transaction.signPayToPublicKeyHashInput(at: index, with: key, limits: WalletTransactionLimits.standard)
        }
    }

    static func abort(_ ctx: OneColorContext, reference: String) async {
        guard let bytes = Data(base64Encoded: reference),
              let data = try? WalletBase64Data(Array(bytes)) else { return }
        _ = try? await ctx.storage.abortAction(ctx.auth, WalletAbortActionRequest(reference: data))
    }

    static func randomBase64() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    }
}
