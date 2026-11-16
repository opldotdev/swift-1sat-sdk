import Foundation
import XCTest
import BSVCore
import BSVTransaction
import BSVWallet
@testable import OneSatColor

/// Every 1Color action hands its transaction on as Atomic BEEF: to the overlay, or to the
/// recipient. When storage funds one with a graph that cannot prove it, the action is aborted
/// before it is processed, so nothing reaches the chain that the overlay or recipient could not
/// be shown.
final class OneColorIncompleteGraphTests: XCTestCase {
    private let incomplete = "The transaction data is incomplete: a transaction it depends on is missing."

    private func deploy(_ party: ColorWorld.Party) async throws -> ColorAssetID {
        let result = await OneColorActions.deploy(party.ctx, amount: 0, decimals: 2, symbol: "MNT")
        XCTAssertNil(result.error)
        return try ColorAssetID(try XCTUnwrap(result.assetID))
    }

    func test_aDeployWhoseGraphIsIncompleteIsAbortedBeforeProcessing() async throws {
        let world = try ColorWorld()
        await world.alice.wallet.setOmitsInputBEEF(true)

        let result = await OneColorActions.deploy(world.alice.ctx, amount: 0, decimals: 2, symbol: "MNT")

        XCTAssertEqual(result.error.map { $0.contains(incomplete) }, true)
        let processed = await world.alice.wallet.processed
        XCTAssertTrue(processed.isEmpty)
        let aborted = await world.alice.wallet.aborted
        XCTAssertEqual(aborted.count, 1)
    }

    func test_aMintWhoseGraphIsIncompleteIsAbortedBeforeProcessing() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let processedBefore = await world.alice.wallet.processed.count
        await world.alice.wallet.setOmitsInputBEEF(true)

        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 10)

        XCTAssertEqual(minted.error.map { $0.contains(incomplete) }, true)
        let processedAfter = await world.alice.wallet.processed.count
        XCTAssertEqual(processedAfter, processedBefore)
        let aborted = await world.alice.wallet.aborted
        XCTAssertEqual(aborted.count, 1)
    }

    func test_aSendWhoseGraphIsIncompleteIsAbortedBeforeProcessing() async throws {
        let world = try ColorWorld()
        let assetID = try await deploy(world.alice)
        let minted = await OneColorActions.mint(world.alice.ctx, assetID: assetID.description, amount: 300)
        XCTAssertNil(minted.error)
        await world.alice.wallet.setOmitsInputBEEF(true)

        let sent = await OneColorActions.send(world.alice.ctx, assetID: assetID.description, amount: 300, to: "bob@example.com")

        XCTAssertEqual(sent.error.map { $0.contains(incomplete) }, true)
        XCTAssertFalse(sent.delivered)
        // The hand-off itself (the activated target) is never processed; only its anchor
        // funding was broadcast, as before any check could run.
        let processed = await world.alice.wallet.processed
        XCTAssertFalse(processed.contains { (Data(base64Encoded: $0.reference).flatMap { String(data: $0, encoding: .utf8) } ?? "").hasPrefix("target-") })
        let aborted = await world.alice.wallet.aborted
        XCTAssertTrue(aborted.contains { (Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .utf8) } ?? "").hasPrefix("target-") })
    }
}
