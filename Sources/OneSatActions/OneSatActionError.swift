public enum OneSatActionError: Error, Equatable, Sendable {
    case noTransfers
    case mustProvideCounterpartyOrAddress
    case cannotTransferBsv20(outpoint: String)
    case missingPayAddress
    case invalidPrice
    case inscriptionTooLarge(bytes: Int)
    case noRecipients
    case amountMustBePositive
    case recipientMissingDestination
    case servicesRequired
    case tokenNotActive
    case overlayValidationFailed
    case insufficientTokens
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
    case listingTransactionNotFound
    case listingOutputNotFound
    case notAnOrdLockListing
    case listingNotFoundInOverlay
    case malformedPurchaseTransaction
    case missingSourceTxid
    case inputNotInTransaction(outpoint: String)

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
        case .malformedPurchaseTransaction:
            return "Malformed transaction: requires at least 2 outputs"
        case .missingSourceTxid:
            return "sourceTXID is required"
        case .inputNotInTransaction(let outpoint):
            return "input-not-in-transaction-\(outpoint)"
        }
    }
}

public struct ActionResult: Equatable, Sendable {
    public let txid: String?
    public let tx: [UInt8]?
    public let actionId: String?
    public let error: String?

    public init(txid: String? = nil, tx: [UInt8]? = nil, actionId: String? = nil, error: String? = nil) {
        self.txid = txid
        self.tx = tx
        self.actionId = actionId
        self.error = error
    }

    public static func failure(_ error: OneSatActionError, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: error.wireMessage)
    }

    public static func failure(_ message: String, actionId: String? = nil) -> ActionResult {
        ActionResult(actionId: actionId, error: message)
    }
}
