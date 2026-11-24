import Foundation
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxBRC29
import ToolboxCore
import ToolboxStorage
import OneSatActions
import OneSatMetanet
import OneSatSweep

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

/// The order the module selects token inputs in.
package enum ColorInputOrder: Equatable, Sendable {
    /// TS `selectInputs`: the largest amount first.
    case largestFirst
    /// Not in the TS: proven source transactions first, then the least unproven ancestry, then
    /// the largest amount (`ColorModule.confirmedFirst`).
    case confirmedFirst
}

/// One output of the wallet's change basket.
public struct ColorFundingCoin: Equatable, Sendable {
    public let outpoint: Outpoint
    public let satoshis: UInt64

    public init(outpoint: Outpoint, satoshis: UInt64) {
        self.outpoint = outpoint
        self.satoshis = satoshis
    }
}

/// Wallet change in the change basket that the caller chose for an action to spend before any
/// other (not in the TS; `ColorExecutor.executeFunded`).
package struct ColorFunding: Sendable {
    package typealias Coin = ColorFundingCoin

    /// The coins, best first.
    package let coins: [Coin]
    /// Told what storage did with the coins, for the caller's log and tests.
    package let observe: (@Sendable (ColorFundingReport) -> Void)?

    package init(coins: [Coin], observe: (@Sendable (ColorFundingReport) -> Void)? = nil) {
        self.coins = coins
        self.observe = observe
    }

    /// createAction's `noSendChange`: the best coin last, as storage takes the last one first
    /// (wallet-toolbox `fundNewTransactionSdk`, `noSendChange.pop()`).
    package var noSendChange: [Outpoint] { coins.reversed().map(\.outpoint) }
}

/// What storage funded an action with, against the wallet change chosen for it (not in the TS).
public struct ColorFundingReport: Equatable, Sendable {
    /// `noSendChange` as sent, the best coin last.
    public let sent: [String]
    /// The chosen coins storage spent.
    public let used: [String]
    /// The chosen coins storage left unspent.
    public let unused: [String]
    /// Other wallet inputs storage added (neither chosen nor the caller's).
    public let topUps: [ColorFundingCoin]
    /// Storage refused the chosen coins and the plain request went instead: why.
    public let fellBack: String?

    public init(sent: [String], used: [String], unused: [String], topUps: [ColorFundingCoin], fellBack: String?) {
        self.sent = sent
        self.used = used
        self.unused = unused
        self.topUps = topUps
        self.fellBack = fellBack
    }

    init(_ funded: StorageCreateActionResult, funding: ColorFunding, callerInputs: [WalletCreateActionInput]) {
        let chosen = funding.coins.map(\.outpoint.description)
        let callers = Set(callerInputs.map(\.outpoint.description))
        var used: [String] = []
        var topUps: [ColorFundingCoin] = []
        for input in funded.inputs {
            let outpoint = "\(input.sourceTXID).\(input.sourceVout)"
            if chosen.contains(outpoint) {
                used.append(outpoint)
            } else if !callers.contains(outpoint), let parsed = try? Outpoint(outpoint) {
                topUps.append(ColorFundingCoin(outpoint: parsed, satoshis: UInt64(clamping: input.sourceSatoshis)))
            }
        }
        self.init(
            sent: funding.noSendChange.map(\.description), used: used, unused: chosen.filter { !used.contains($0) },
            topUps: topUps, fellBack: nil
        )
    }

    /// One line for the log.
    public var text: String {
        if let fellBack { return "storage refused the chosen change [\(sent.joined(separator: ", "))]: \(fellBack)" }
        let added = topUps.map { "\($0.outpoint) (\($0.satoshis) sats)" }
        return "spent [\(used.joined(separator: ", "))], unused [\(unused.joined(separator: ", "))], storage added [\(added.joined(separator: ", "))]"
    }
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
        _ ctx: OneColorContext, request: WalletCreateActionRequest, tokenInputs: [ColorManagedInput],
        funding: ColorFunding? = nil
    ) async throws -> SignedAction {
        try await execute(ctx, request: request, funding: funding) { transaction in
            try unlocks(transaction, inputs: tokenInputs, identity: ctx.identity)
        }
    }

    /// `execute` with the caller's own inputs signed by `signCallerInputs` (input index → unlock).
    /// With `funding` (not in the TS; nil for every caller but an Open Exchange swap's staging):
    /// see `executeFunded`.
    static func execute(
        _ ctx: OneColorContext, request: WalletCreateActionRequest, funding: ColorFunding? = nil,
        signCallerInputs: (Transaction) throws -> [Int: Script]
    ) async throws -> SignedAction {
        if let funding, !funding.coins.isEmpty {
            return try await executeFunded(ctx, request: request, funding: funding, signCallerInputs: signCallerInputs)
        }
        let funded = try await ctx.storage.colorCreateAction(ctx.auth, request)
        do {
            let signed = try sign(ctx, funded: funded, request: request, signCallerInputs: signCallerInputs)
            let processed = try await ctx.storage.processAction(ctx.auth, try signed.processRequest())
            try requireSent(processed)
            return signed
        } catch {
            await abort(ctx, reference: funded.reference)
            throw error
        }
    }

    /// The action funded first from the wallet change the caller chose: createAction with
    /// `noSend` and `noSendChange` (storage spends those outputs before any other change, the
    /// last listed first), the signed transaction processed as a noSend, then a second,
    /// send-only processAction (`sendWith` its txid) broadcasts it. The outputs, their order and
    /// every other option are the caller's. Storage that refuses a `noSendChange` outpoint gets
    /// the plain request once instead. A failure before the send, or a send storage reports
    /// `failed`, aborts the action, which releases its inputs; a send that throws or reports
    /// `sending` is never aborted (its transaction may be out): it stays for recovery or storage's
    /// monitor.
    static func executeFunded(
        _ ctx: OneColorContext, request: WalletCreateActionRequest, funding: ColorFunding,
        signCallerInputs: (Transaction) throws -> [Int: Script]
    ) async throws -> SignedAction {
        let noSendChange = funding.noSendChange
        let options = request.options
        let fundedRequest = try WalletCreateActionRequest(
            description: request.description, inputBEEF: request.inputBEEF, inputs: request.inputs, outputs: request.outputs,
            lockTime: request.lockTime, version: request.version, labels: request.labels,
            options: try WalletCreateActionOptions(
                signAndProcess: options?.signAndProcess, acceptDelayedBroadcast: options?.acceptDelayedBroadcast,
                trustSelf: options?.trustSelf, knownTransactionIDs: options?.knownTransactionIDs,
                returnTransactionIDOnly: options?.returnTransactionIDOnly, noSend: true, noSendChange: noSendChange,
                sendWith: options?.sendWith, randomizeOutputs: options?.randomizeOutputs
            )
        )
        let funded: StorageCreateActionResult
        do {
            funded = try await ctx.storage.colorCreateAction(ctx.auth, fundedRequest)
        } catch let error where refusesNoSendChange(error) {
            OneSatLog.error(error, "1Color: storage refused the chosen change \(noSendChange.map(\.description)); the action goes as a plain one", category: "OneSatColor")
            funding.observe?(ColorFundingReport(
                sent: noSendChange.map(\.description), used: [], unused: noSendChange.map(\.description), topUps: [],
                fellBack: OneSatLog.message(error)
            ))
            return try await execute(ctx, request: request, signCallerInputs: signCallerInputs)
        }
        let report = ColorFundingReport(funded, funding: funding, callerInputs: request.inputs ?? [])
        OneSatLog.notice("1Color: \(fundedRequest.description) funded from the chosen change: \(report.text)", category: "OneSatColor")
        funding.observe?(report)
        // Before the send: a failure aborts the action, which releases its inputs.
        let signed: SignedAction
        do {
            signed = try sign(ctx, funded: funded, request: fundedRequest, signCallerInputs: signCallerInputs)
            let held = try await ctx.storage.processAction(ctx.auth, try signed.processRequest(isNoSend: true))
            try requireSent(held)
        } catch {
            OneSatLog.error(error, "1Color: the funded action \(funded.reference) failed before its send; aborting it", category: "OneSatColor")
            await abort(ctx, reference: funded.reference)
            throw error
        }
        let txid = signed.transactionID.displayHex
        let sent: StorageProcessActionResult
        do {
            sent = try await ctx.storage.processAction(ctx.auth, StorageProcessActionRequest(
                reference: funded.reference, isNewTx: false, isSendWith: true, rawTX: nil,
                sendWith: [txid], isNoSend: false, isDelayed: false
            ))
        } catch {
            // The transaction may be out: never aborted. It stays held, and recovery sends it
            // again (a resend of a sent transaction is harmless).
            OneSatLog.error(error, "1Color: the send of the funded action \(txid) threw; it stays held, not aborted, for recovery to send", category: "OneSatColor")
            throw error
        }
        if sent.sendWithResults.contains(where: { $0.status == .failed }) {
            OneSatLog.error("1Color: storage failed the send of the funded action \(txid); aborting it", category: "OneSatColor")
            await abort(ctx, reference: funded.reference)
            throw ColorError.custody("broadcast failed")
        }
        if let other = sent.sendWithResults.first(where: { $0.status != .unproven }) {
            // `sending`: storage's monitor broadcasts it, so it is not aborted.
            OneSatLog.error("1Color: the funded action \(txid) is \(other.status.rawValue), not sent yet; left to storage, not aborted", category: "OneSatColor")
            throw ColorError.custody("broadcast \(other.status.rawValue)")
        }
        return signed
    }

    /// The funded action assembled and signed: the caller's inputs by `signCallerInputs`, the
    /// wallet's by their BRC-29 derivation. Every caller hands the result on as Atomic BEEF
    /// (overlay submission, delivery), so a funded graph that cannot prove it stops here, before
    /// it is processed, and the caller aborts the action.
    static func sign(
        _ ctx: OneColorContext, funded: StorageCreateActionResult, request: WalletCreateActionRequest,
        signCallerInputs: (Transaction) throws -> [Int: Script]
    ) throws -> SignedAction {
        try ActionAssembler.requireFeeWithin(ctx.maximumFee, for: funded)
        var transaction = try ActionAssembler.assemble(
            funded, requested: request.outputs ?? [], changeKey: ctx.identity
        )
        let spends = try signCallerInputs(transaction)
        for (index, script) in spends { transaction.inputs[index].unlockingScript = script }
        try signFundingInputs(&transaction, funded: funded, identity: ctx.identity, alreadySigned: Set(spends.keys))
        let signed = try SignedAction(funded: funded, transaction: transaction)
        _ = try signed.atomicBEEF()
        return signed
    }

    /// Every broadcast storage reports went out (`unproven`).
    static func requireSent(_ processed: StorageProcessActionResult) throws {
        if let failed = processed.sendWithResults.first(where: { $0.status != .unproven }) {
            throw ColorError.custody("broadcast \(failed.status.rawValue)")
        }
    }

    /// Storage's `WERR_INVALID_PARAMETER` for a `noSendChange` outpoint (wallet-toolbox
    /// `validateNoSendChange`: not its change, not spendable, spent, or repeated).
    static func refusesNoSendChange(_ error: any Error) -> Bool {
        if case .invalidParameter(let name, let message)? = error as? WireError {
            return "\(name) \(message)".contains("noSendChange")
        }
        let text = "\(error) \(OneSatLog.localizedMessage(error))"
        return text.contains("WERR_INVALID_PARAMETER") && text.contains("noSendChange")
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
        do {
            _ = try await ctx.storage.abortAction(ctx.auth, WalletAbortActionRequest(reference: data))
        } catch {
            // The action's own failure is what the caller sees; this only leaves inputs reserved.
            OneSatLog.error(error, "1Color: releasing the inputs of a failed action", category: "OneSatColor")
        }
    }

    static func randomBase64() -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    }
}
