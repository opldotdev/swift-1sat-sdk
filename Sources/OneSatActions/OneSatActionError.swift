import Foundation
import OneSatSweep

public enum OneSatActionError: Error, Equatable, Sendable {
    case noTransfers
    case mustProvideCounterpartyOrAddress
    case cannotTransferBsv20(outpoint: String)
    case missingPayAddress
    case invalidPrice
    case inscriptionTooLarge(bytes: Int)
    case inscriptionContentTypeInvalid
    case inscriptionContentEmpty
    case noRecipients
    case amountMustBePositive
    case recipientMissingDestination
    case servicesRequired
    case tokenNotActive
    case overlayValidationFailed
    case insufficientTokens
    case insufficientValidTokens
    /// Queued overlay outputs would cover the amount once indexed.
    case tokensQueued
    case tokenNotFound
    case unvalidatedInputs
    case fundingNotNeeded
    case fundingSubmitFailed
    case noBeefAvailable
    case noLockRequests
    case invalidSatoshis
    case invalidBlockHeight
    case noMaturedLocks
    case noTxidReturned
    case missingCustomInstructions
    case invalidCustomInstructions
    case missingSourceLockingScript(inputIndex: Int)
    case missingSourceTransaction(inputIndex: Int)
    case noSignableTransaction
    case servicesRequiredForPurchase
    case listingCreateDisabled
    case listingTransactionNotFound
    case listingOutputNotFound
    case notAnOrdLockListing
    case listingNotFoundInOverlay
    /// An OrdLock v2 purchase or cancel guard refused to sign; the message says why.
    case ordLockV2Refused(String)
    /// Front-funding preparation failed; carries the wallet error when there is one.
    case ordLockV2FrontFundingFailed(String?)
    case missingSourceTxid
    case inputNotInTransaction(outpoint: String)
    case quantityMustBePositive
    case anchorNoTxid
    /// The SIGMA anchor came back without a txid or transaction (`applyInscribeSigma`).
    case sigmaAnchorFailed
    case exactlyOneOfContentOrRef
    case contentTypeRequiredWithContent
    case invalidRef(ref: String)
    case invalidCollectionIdFormat(id: String)
    case noBapIdentity
    case signWithBapRequiresInscription
    case sigmaPlaceholderMissing
    case deployNoTxid
    case authAndEndMintingMutuallyExclusive
    case mustProvideMintOrAuth
    case mintAmountMustBePositive
    case noAuthUtxoForToken
    case authUtxoMissingCustomInstructions
    /// The authority output is a P2MS (multisig) authority, which this port does not sign.
    case multiSigAuthNotSupported
    /// A deploy whose transaction carries no BSV-21 deploy at output 0.
    case notABsv21Deploy
    /// `internalizeOpns`: the transaction holds no two adjacent OpNS nodes followed by a third
    /// output (the name).
    case notAnOpnsMint
    /// The overlay fee the indexer asks for (`fee_per_output` times the token outputs) is above
    /// the caller's `maxFee`. Swift only: `@1sat/actions` pays whatever the indexer returns.
    case overlayFeeExceedsMaxFee(fee: UInt64, maxFee: UInt64)
    /// `fee_per_output` times the token output count does not fit in a `UInt64`.
    case overlayFeeOverflow

    /// The error whose `wireMessage` is `message`, so a caller can switch on the case behind an
    /// `ActionResult.error` (or a deploy or mint result's `error`) instead of comparing text. Nil
    /// for any other text, and for the two cases whose message is free text
    /// (`ordLockV2Refused`, `ordLockV2FrontFundingFailed` with a reason).
    ///
    /// `@1sat/actions` returns these as plain `error` strings and has no typed form; the results
    /// here keep the strings, and this reads them back.
    public init?(wireMessage message: String) {
        if let fixed = Self.fixedCases.first(where: { $0.wireMessage == message }) {
            self = fixed
            return
        }
        if let rest = Self.suffix(of: message, after: "overlay-fee-exceeds-max-fee: "),
           let parts = Self.split(rest, " sats > maxFee ", end: " sats"),
           let fee = UInt64(parts.0), let maxFee = UInt64(parts.1) {
            self = .overlayFeeExceedsMaxFee(fee: fee, maxFee: maxFee)
        } else if let text = Self.suffix(of: message, after: "missing-source-locking-script-for-input-"),
                  let index = Int(text) {
            self = .missingSourceLockingScript(inputIndex: index)
        } else if let text = Self.suffix(of: message, after: "missing-source-transaction-for-input-"),
                  let index = Int(text) {
            self = .missingSourceTransaction(inputIndex: index)
        } else if let outpoint = Self.suffix(of: message, after: "input-not-in-transaction-") {
            self = .inputNotInTransaction(outpoint: outpoint)
        } else if let ref = Self.suffix(of: message, after: "invalid-ref: ") {
            self = .invalidRef(ref: ref)
        } else if let id = Self.suffix(of: message, after: "Invalid collectionId format: ") {
            self = .invalidCollectionIdFormat(id: id)
        } else if let rest = Self.suffix(of: message, after: "Inscription data too large: "),
                  let parts = Self.split(rest, " bytes (max ", end: ")"),
                  parts.1 == String(OneSatConstants.maxInscriptionBytes), let bytes = Int(parts.0) {
            self = .inscriptionTooLarge(bytes: bytes)
        } else if let rest = Self.suffix(of: message, after: "Cannot transfer BSV-20 token "),
                  rest.hasSuffix(Self.bsv20TransferTail), rest.count > Self.bsv20TransferTail.count {
            self = .cannotTransferBsv20(outpoint: String(rest.dropLast(Self.bsv20TransferTail.count)))
        } else {
            return nil
        }
    }

    private static let bsv20TransferTail = " through ordinal transfer — use BSV-21 transfer instead"

    /// Every case without a payload, plus front funding with no reason.
    private static let fixedCases: [OneSatActionError] = [
        .noTransfers, .mustProvideCounterpartyOrAddress, .missingPayAddress, .invalidPrice,
        .inscriptionContentTypeInvalid, .inscriptionContentEmpty, .noRecipients, .amountMustBePositive,
        .recipientMissingDestination, .servicesRequired, .tokenNotActive, .overlayValidationFailed,
        .insufficientTokens, .insufficientValidTokens, .tokensQueued, .tokenNotFound, .unvalidatedInputs,
        .fundingNotNeeded, .fundingSubmitFailed, .noBeefAvailable, .noLockRequests, .invalidSatoshis,
        .invalidBlockHeight, .noMaturedLocks, .noTxidReturned, .missingCustomInstructions,
        .invalidCustomInstructions, .noSignableTransaction, .servicesRequiredForPurchase,
        .listingCreateDisabled, .listingTransactionNotFound, .listingOutputNotFound, .notAnOrdLockListing,
        .listingNotFoundInOverlay, .ordLockV2FrontFundingFailed(nil), .missingSourceTxid,
.quantityMustBePositive, .anchorNoTxid, .sigmaAnchorFailed,
        .exactlyOneOfContentOrRef, .contentTypeRequiredWithContent, .noBapIdentity,
        .signWithBapRequiresInscription, .sigmaPlaceholderMissing, .deployNoTxid,
        .authAndEndMintingMutuallyExclusive, .mustProvideMintOrAuth, .mintAmountMustBePositive,
        .noAuthUtxoForToken, .authUtxoMissingCustomInstructions, .multiSigAuthNotSupported,
        .notABsv21Deploy, .notAnOpnsMint, .overlayFeeOverflow,
    ]

    /// The non-empty text after `prefix`, or nil when `message` does not start with it.
    private static func suffix(of message: String, after prefix: String) -> String? {
        guard message.hasPrefix(prefix), message.count > prefix.count else { return nil }
        return String(message.dropFirst(prefix.count))
    }

    /// `text` as `<first><separator><second><end>`, or nil when it is not that shape.
    private static func split(_ text: String, _ separator: String, end: String) -> (String, String)? {
        guard text.hasSuffix(end), let range = text.range(of: separator) else { return nil }
        let first = String(text[..<range.lowerBound])
        let second = String(text[range.upperBound...].dropLast(end.count))
        guard !first.isEmpty else { return nil }
        return (first, second)
    }

    /// Exact `error` strings from `@1sat/actions`.
    public var wireMessage: String {
        switch self {
        case .noTransfers:
            return "no-transfers"
        case .mustProvideCounterpartyOrAddress:
            return "must-provide-counterparty-or-address"
        case .cannotTransferBsv20(let outpoint):
            return "Cannot transfer BSV-20 token \(outpoint)\(Self.bsv20TransferTail)"
        case .missingPayAddress:
            return "missing-pay-address"
        case .invalidPrice:
            return "invalid-price"
        case .inscriptionTooLarge(let bytes):
            return "Inscription data too large: \(bytes) bytes (max \(OneSatConstants.maxInscriptionBytes))"
        case .inscriptionContentTypeInvalid:
            return "inscription-content-type-invalid"
        case .inscriptionContentEmpty:
            return "inscription-content-empty"
        case .noRecipients:
            return "no-recipients"
        case .amountMustBePositive:
            return "amount-must-be-positive"
        case .recipientMissingDestination:
            return "recipient-missing-destination"
        case .servicesRequired:
            return "services-required"
        case .tokenNotActive:
            return "token-not-active"
        case .overlayValidationFailed:
            return "overlay-validation-failed"
        case .insufficientTokens:
            return "insufficient-tokens"
        case .insufficientValidTokens:
            return "insufficient-valid-tokens"
        case .tokensQueued:
            return "tokens-queued"
        case .tokenNotFound:
            return "token-not-found"
        case .unvalidatedInputs:
            return "unvalidated-inputs"
        case .fundingNotNeeded:
            return "funding-not-needed"
        case .fundingSubmitFailed:
            return "funding-submit-failed"
        case .noBeefAvailable:
            return "no-beef-available"
        case .noLockRequests:
            return "no-lock-requests"
        case .invalidSatoshis:
            return "invalid-satoshis"
        case .invalidBlockHeight:
            return "invalid-block-height"
        case .noMaturedLocks:
            return "no-matured-locks"
        case .noTxidReturned:
            return "no-txid-returned"
        case .missingCustomInstructions:
            return "missing-custom-instructions"
        case .invalidCustomInstructions:
            return "invalid-custom-instructions"
        case .missingSourceLockingScript(let index):
            return "missing-source-locking-script-for-input-\(index)"
        case .missingSourceTransaction(let index):
            return "missing-source-transaction-for-input-\(index)"
        case .noSignableTransaction:
            return "no-signable-transaction"
        case .listingCreateDisabled:
            return "listing-create-disabled"
        case .servicesRequiredForPurchase:
            return "services-required-for-purchase"
        case .listingTransactionNotFound:
            return "listing-transaction-not-found"
        case .listingOutputNotFound:
            return "listing-output-not-found"
        case .notAnOrdLockListing:
            return "not-an-ordlock-listing"
        case .listingNotFoundInOverlay:
            return "listing-not-found-in-overlay"
        case .ordLockV2Refused(let message):
            return message
        case .ordLockV2FrontFundingFailed(let reason):
            return reason ?? "ordlock.purchase apply: front funding preparation failed"
        case .missingSourceTxid:
            return "sourceTXID is required"
        case .inputNotInTransaction(let outpoint):
            return "input-not-in-transaction-\(outpoint)"
        case .quantityMustBePositive:
            return "quantity-must-be-positive"
        case .anchorNoTxid:
            return "anchor-no-txid"
        case .sigmaAnchorFailed:
            return "ordinal.inscribe-sigma apply: anchor failed"
        case .exactlyOneOfContentOrRef:
            return "exactly-one-of-base64Content-or-ref-required"
        case .contentTypeRequiredWithContent:
            return "contentType-required-with-base64Content"
        case .invalidRef(let ref):
            return "invalid-ref: \(ref)"
        case .invalidCollectionIdFormat(let id):
            return "Invalid collectionId format: \(id)"
        case .noBapIdentity:
            return "No BAP identity published — cannot resolve current signing key. Publish an identity before signing."
        case .signWithBapRequiresInscription:
            return "sign-with-bap-requires-inscription"
        case .sigmaPlaceholderMissing:
            return "sigma seal: no zeroed placeholder tape on the script"
        case .deployNoTxid:
            return "deploy-no-txid"
        case .authAndEndMintingMutuallyExclusive:
            return "auth-and-end-minting-are-mutually-exclusive"
        case .mustProvideMintOrAuth:
            return "must-provide-mint-or-auth"
        case .mintAmountMustBePositive:
            return "mint-amount-must-be-positive"
        case .noAuthUtxoForToken:
            return "no-auth-utxo-for-token"
        case .authUtxoMissingCustomInstructions:
            return "auth-utxo-missing-custom-instructions"
        case .multiSigAuthNotSupported:
            return "multisig-auth-not-supported"
        case .notABsv21Deploy:
            return "not-a-bsv21-deploy"
        case .notAnOpnsMint:
            return "not-an-opns-mint"
        case .overlayFeeExceedsMaxFee(let fee, let maxFee):
            return "overlay-fee-exceeds-max-fee: \(fee) sats > maxFee \(maxFee) sats"
        case .overlayFeeOverflow:
            return "overlay-fee-overflow"
        }
    }
}

public struct ActionResult: Equatable, Sendable {
    public let txid: String?
    public let tx: [UInt8]?
    public let actionId: String?
    public let error: String?
    public let noSendChange: [String]?
    /// For a log, not for display: `OneSatLog.reflecting(_:)` of the error behind `error` (its
    /// reflection, with no URL query string) when that error was not a `OneSatActionError`, so a
    /// typed failure such as a `BEEFError` keeps its case and transaction IDs after `error` has
    /// become a plain sentence. It is not part of the result's value and is ignored by `==`.
    public let diagnostic: String?
    /// Set when the action succeeded but the overlay that indexes it was not told: why the submit
    /// failed, or "no transaction to submit" when the action's Atomic BEEF could not be built.
    /// The transaction is on chain either way; the overlay may still find it later.
    public let submitError: String?

    public init(
        txid: String? = nil,
        tx: [UInt8]? = nil,
        actionId: String? = nil,
        error: String? = nil,
        noSendChange: [String]? = nil,
        diagnostic: String? = nil,
        submitError: String? = nil
    ) {
        self.txid = txid
        self.tx = tx
        self.actionId = actionId
        self.error = error
        self.noSendChange = noSendChange
        self.diagnostic = diagnostic
        self.submitError = submitError
    }

    public static func == (lhs: ActionResult, rhs: ActionResult) -> Bool {
        lhs.txid == rhs.txid && lhs.tx == rhs.tx && lhs.actionId == rhs.actionId
            && lhs.error == rhs.error && lhs.noSendChange == rhs.noSendChange
            && lhs.submitError == rhs.submitError
    }

    /// Submits a successful action's transaction with `submit`, recording in `submitError` why
    /// the overlay was not told: the submit's own failure, or no Atomic BEEF to send. A failed
    /// action is returned unchanged.
    static func submitting(
        _ result: ActionResult, _ submit: ([UInt8]) async throws -> Void
    ) async -> ActionResult {
        guard result.error == nil, result.txid != nil else { return result }
        let failure: String
        if let tx = result.tx {
            do {
                try await submit(tx)
                return result
            } catch {
                failure = Tokens.submitFailure(error)
            }
        } else {
            failure = "no transaction to submit"
        }
        return ActionResult(
            txid: result.txid, tx: result.tx, actionId: result.actionId, error: result.error,
            noSendChange: result.noSendChange, diagnostic: result.diagnostic, submitError: failure
        )
    }

    public static func failure(_ error: OneSatActionError, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: error.wireMessage)
    }

    /// `error`'s wire message, as `@1sat/actions` returns it, keeping the failure behind it as
    /// the ``diagnostic`` and in the log (an overlay's HTTP 500 is not a missing token).
    public static func failure(
        _ error: OneSatActionError, underlying: any Error, actionId: String? = nil
    ) -> ActionResult {
        OneSatLog.error(underlying, "action failed as \(error.wireMessage)", category: "OneSatActions")
        return ActionResult(actionId: actionId, error: error.wireMessage, diagnostic: OneSatLog.reflecting(underlying))
    }

    public static func failure(_ message: String, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: message)
    }

    /// A failure shown as `error`'s plain description, keeping its URL-free reflection as the
    /// ``diagnostic``.
    public static func failure(describing error: any Error, actionId: String? = nil) -> ActionResult {
        OneSatLog.error(error, "action failed", category: "OneSatActions")
        return ActionResult(
            actionId: actionId, error: OneSatLog.localizedMessage(error),
            diagnostic: OneSatLog.reflecting(error)
        )
    }
}
