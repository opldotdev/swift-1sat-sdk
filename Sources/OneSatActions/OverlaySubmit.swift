import Foundation
import OneSatSweep

/// The overlay submits that follow a successful action, and how their failures are reported.
///
/// An action's transaction is on chain whether or not an overlay was told. A failed submit never
/// turns the action into a failure: it is logged in full and its one-line reason is set on the
/// result (`submitError`), so the caller can say so and retry.
enum OverlaySubmit {
    /// The reason an overlay submit failed, as the result reports it: the action error's wire
    /// message, or the error's description with any URL query string removed. The full error is
    /// logged here.
    static func failure(_ error: any Error) -> String {
        OneSatLog.error(error, "overlay submit failed after the action succeeded", category: "OneSatActions")
        if let error = error as? OneSatActionError { return error.wireMessage }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return OneSatLog.redactingQueries(description)
        }
        return OneSatLog.message(error)
    }

    /// Submits a successful listing, cancel or purchase to the market overlay (`tm_ordlock_v2`).
    ///
    /// A deliberate addition over TS, whose `sellOrdinal`, `sellOpns`, cancel and purchase leave
    /// the overlay to find the transaction; the same pattern as the BSV-21 deploy and mint. With
    /// no `ctx.market` nothing is submitted and `submitError` stays nil. A failed action is
    /// returned unchanged.
    static func market(_ ctx: OneSatContext, _ result: ActionResult) async -> ActionResult {
        guard let market = ctx.market else { return result }
        return await ActionResult.submitting(result) { try await market.submitListing(tx: $0) }
    }
}
