import Foundation
import XCTest
import BSVWallet
import ToolboxActions
import ToolboxStorage
@testable import OneSatColor

/// A conformer written before `colorListActions` (as the app's test stand-ins are): it still
/// compiles, and the default throws rather than answering an empty list.
private actor StorageWithoutListActions: ColorWalletStorage {
    struct Unused: Error {}

    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult { throw Unused() }
    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult { throw Unused() }
    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult { throw Unused() }
    func supportsNoSendExpiry() async throws -> Bool { false }
    func prepareNoSendExpiry(_ auth: AuthID, _ target: WalletCreateActionRequest) async throws -> NoSendExpiryPrepared { throw Unused() }
    func activateNoSendExpiry(
        _ auth: AuthID, target: WalletCreateActionRequest, fundingReference: String, fundingTxid: String, anchorVout: UInt32
    ) async throws -> NoSendExpiryActivated { throw Unused() }
    func armNoSendExpiry(_ auth: AuthID, _ arm: NoSendExpiryArm) async throws { throw Unused() }
    func processAction(_ auth: AuthID, _ request: StorageProcessActionRequest) async throws -> StorageProcessActionResult { throw Unused() }
    func abortAction(_ auth: AuthID, _ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult { throw Unused() }
}

final class ColorStorageDefaultTests: XCTestCase {
    func test_aConformerWithoutListActionsThrowsAClearError() async throws {
        let storage: any ColorWalletStorage = StorageWithoutListActions()
        let request = try WalletListActionsRequest(labels: ["amm-swap-stage"], includeOutputs: true)
        do {
            let answer = try await storage.colorListActions(AuthID(identityKey: String(repeating: "02", count: 33)), request)
            XCTFail("the default answered \(answer.actions.count) actions")
        } catch let error as ColorStorageCallUnimplemented {
            XCTAssertEqual(error, ColorStorageCallUnimplemented(storage: "StorageWithoutListActions", call: "colorListActions"))
            XCTAssertEqual(
                error.localizedDescription,
                "StorageWithoutListActions does not implement ColorWalletStorage.colorListActions: real wallet storage must implement it"
            )
        }
    }
}
