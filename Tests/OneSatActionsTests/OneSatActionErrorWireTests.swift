import XCTest
@testable import OneSatActions

/// `OneSatActionError(wireMessage:)` reads back every message the SDK writes into a result's
/// `error`, so callers can switch on the case.
final class OneSatActionErrorWireTests: XCTestCase {
    private let readable: [OneSatActionError] = [
        .noTransfers, .mustProvideCounterpartyOrAddress, .cannotTransferBsv20(outpoint: "ab_1"),
        .missingPayAddress, .invalidPrice, .inscriptionTooLarge(bytes: 900_001),
        .inscriptionContentTypeInvalid, .inscriptionContentEmpty, .noRecipients, .amountMustBePositive,
        .recipientMissingDestination, .servicesRequired, .tokenNotActive, .overlayValidationFailed,
        .insufficientTokens, .insufficientValidTokens, .tokensQueued, .tokenNotFound, .unvalidatedInputs,
        .fundingNotNeeded, .fundingSubmitFailed, .noBeefAvailable, .noLockRequests, .invalidSatoshis,
        .invalidBlockHeight, .noMaturedLocks, .noTxidReturned, .missingCustomInstructions,
        .invalidCustomInstructions, .missingSourceLockingScript(inputIndex: 3),
        .missingSourceTransaction(inputIndex: 0), .noSignableTransaction, .servicesRequiredForPurchase,
        .listingCreateDisabled, .listingTransactionNotFound, .listingOutputNotFound, .notAnOrdLockListing,
        .listingNotFoundInOverlay, .ordLockV2FrontFundingFailed(nil), .missingSourceTxid,
        .inputNotInTransaction(outpoint: "cd.2"), .mneeClientRequired, .quantityMustBePositive,
        .anchorNoTxid, .sigmaAnchorFailed, .exactlyOneOfContentOrRef, .contentTypeRequiredWithContent,
        .invalidRef(ref: "not-a-ref"), .invalidCollectionIdFormat(id: "xyz"), .noBapIdentity,
        .signWithBapRequiresInscription, .sigmaPlaceholderMissing, .deployNoTxid,
        .authAndEndMintingMutuallyExclusive, .mustProvideMintOrAuth, .mintAmountMustBePositive,
        .noAuthUtxoForToken, .authUtxoMissingCustomInstructions, .multiSigAuthNotSupported,
        .notABsv21Deploy, .notAnOpnsMint, .overlayFeeExceedsMaxFee(fee: 3_000, maxFee: 2_000), .overlayFeeOverflow,
    ]

    func test_everyMessageReadsBackAsItsCase() {
        for error in readable {
            XCTAssertEqual(OneSatActionError(wireMessage: error.wireMessage), error, error.wireMessage)
        }
    }

    func test_otherTextIsNotAnError() {
        XCTAssertNil(OneSatActionError(wireMessage: ""))
        XCTAssertNil(OneSatActionError(wireMessage: "storage is not active"))
        XCTAssertNil(OneSatActionError(wireMessage: "overlay-fee-exceeds-max-fee"))
        XCTAssertNil(OneSatActionError(wireMessage: "overlay-fee-exceeds-max-fee: lots"))
        XCTAssertNil(OneSatActionError(wireMessage: "amount-must-be-positive!"))
        XCTAssertNil(OneSatActionError(wireMessage: "missing-source-transaction-for-input-x"))
    }

    func test_freeTextCasesAreNotRead() {
        XCTAssertNil(OneSatActionError(wireMessage: OneSatActionError.ordLockV2Refused("seller moved the ordinal").wireMessage))
        XCTAssertNil(OneSatActionError(wireMessage: OneSatActionError.ordLockV2FrontFundingFailed("wallet busy").wireMessage))
    }
}
