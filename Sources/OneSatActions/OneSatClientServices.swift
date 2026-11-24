import OneSatClient
import OneSatSweep

/// `ctx.services.getBeefForTxid` over 1sat-stack: `BeefClient.beef(forTxid:)` is the requirement.
extension BeefClient: ListingBeefSource {}

extension Bsv21Client {
    /// `getTokenDetails(tokenId)` in the form the BSV-21 actions gate on
    /// (`Bsv21ActionServices.tokenDetails`). The status must carry `is_active`, `fee_address` and
    /// `fee_per_output`; `dec` must be a whole number, and no `dec` means 0. An answer without
    /// them is logged and thrown as `OneSatClientError.unreadableResponse`, where TS would let an
    /// action read `undefined`. This client keeps no cache, so every call reads fresh.
    public func actionTokenDetails(tokenID: String) async throws -> Bsv21TokenDetails {
        let details = try await tokenDetails(tokenID: tokenID)
        let status = details.status
        guard let isActive = status.isActive,
              let feeAddress = status.feeAddress,
              let feePerOutput = status.feePerOutput
        else {
            OneSatLog.error(
                "Bsv21Client.actionTokenDetails: the status of token \(tokenID) lacks is_active, fee_address or fee_per_output",
                category: "OneSatActions"
            )
            throw OneSatClientError.unreadableResponse
        }
        var decimals = 0
        if let dec = details.token.decimals {
            guard let parsed = Int(dec) else {
                OneSatLog.error(
                    "Bsv21Client.actionTokenDetails: token \(tokenID) has dec \(dec), not a whole number",
                    category: "OneSatActions"
                )
                throw OneSatClientError.unreadableResponse
            }
            decimals = parsed
        }
        return Bsv21TokenDetails(
            isActive: isActive,
            feeAddress: feeAddress,
            feePerOutput: feePerOutput,
            decimals: decimals,
            symbol: details.token.symbol,
            icon: details.token.icon
        )
    }
}
