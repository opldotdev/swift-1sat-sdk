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
    case mneeClientRequired
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
    /// The overlay fee the indexer asks for (`fee_per_output` times the token outputs) is above
    /// the caller's `maxFee`. Swift only: `@1sat/actions` pays whatever the indexer returns.
    case overlayFeeExceedsMaxFee(fee: UInt64, maxFee: UInt64)
    /// `fee_per_output` times the token output count does not fit in a `UInt64`.
    case overlayFeeOverflow

    /// Exact `error` strings from `@1sat/actions`.
    public var wireMessage: String {
        switch self {
        case .noTransfers:
            return "no-transfers"
        case .mustProvideCounterpartyOrAddress:
            return "must-provide-counterparty-or-address"
        case .cannotTransferBsv20(let outpoint):
            return "Cannot transfer BSV-20 token \(outpoint) through ordinal transfer — use BSV-21 transfer instead"
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
        case .mneeClientRequired:
            return "MNEE client not available — services required"
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

    public init(
        txid: String? = nil,
        tx: [UInt8]? = nil,
        actionId: String? = nil,
        error: String? = nil,
        noSendChange: [String]? = nil
    ) {
        self.txid = txid
        self.tx = tx
        self.actionId = actionId
        self.error = error
        self.noSendChange = noSendChange
    }

    public static func failure(_ error: OneSatActionError, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: error.wireMessage)
    }

    public static func failure(_ message: String, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: message)
    }
}
