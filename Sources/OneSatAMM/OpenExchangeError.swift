import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolboxAuth

/// What an Open Exchange call threw: `ClientError` of `@dcasegr/amm-client` 0.55.1 (errors.ts:36)
/// for the kinds a paid enable meets, and `failed` for what TS leaves a plain `Error`. `message`
/// is the TS text.
public enum OpenExchangeError: Error, Equatable, Sendable, LocalizedError {
    /// `refused`: the exchange (or the wallet, before anything was sent) said no. `code` is the
    /// exchange's code when it gave one; `message` leads with it, as `"<code>: <description>"`.
    case refused(code: String?, message: String)
    /// `network`: the request did not get through.
    case network(String)
    /// `user_rejected`: the user declined in the wallet.
    case userRejected(String)
    /// `below_minimum`: no pool here takes a swap this small (a quote under every validator's
    /// minimum leg).
    case belowMinimum(String)
    /// A failure of no named kind (a malformed answer, a bad token id).
    case failed(String)

    public var message: String {
        switch self {
        case .refused(_, let message), .network(let message), .userRejected(let message), .belowMinimum(let message),
             .failed(let message):
            message
        }
    }

    public var errorDescription: String? { message }

    /// The exchange's refusal code, when it is one the paid enable names.
    public var refusal: OpenExchangeRefusal? {
        guard case .refused(let code?, _) = self else { return nil }
        return OpenExchangeRefusal(rawValue: code)
    }

    /// `errorKind` (errors.ts:48) for what a Swift wallet or transport throws: the user's denial
    /// and a request that did not get through; nil for anything else.
    static func kinded(_ error: Error) -> OpenExchangeError? {
        if let known = error as? OpenExchangeError {
            switch known {
            case .failed: return nil
            default: return known
            }
        }
        let text = errorText(error)
        if text.contains("ERR_PERMISSION_DENIED") || deniedPattern(text) { return .userRejected(text) }
        if error is URLError { return .network(text) }
        if case AuthTransportError.transportFailed = error { return .network(text) }
        return nil
    }

    /// `toClientError` (errors.ts:107) for a public call's error: its kind, else `failed`.
    static func of(_ error: Error) -> OpenExchangeError {
        if let known = error as? OpenExchangeError { return known }
        return kinded(error) ?? .failed(errorText(error))
    }

    /// `/user has denied|permission denied|user rejected|denied by the user/i`.
    private static func deniedPattern(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["user has denied", "permission denied", "user rejected", "denied by the user"].contains(where: lower.contains)
    }

    /// `errText` (client.ts:768): the error's own words.
    static func errorText(_ error: Error) -> String {
        if let known = error as? OpenExchangeError { return known.message }
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty { return localized }
        return String(describing: error)
    }
}

/// The paid enable's refusal codes (open-exchange apps/swap/programs/config/src/paid.zig `check`,
/// main.zig `enablePaid`; `ERR_BEEF` from the host's BEEF filter).
public enum OpenExchangeRefusal: String, Sendable, CaseIterable {
    case paidEnableOff = "ERR_PAID_ENABLE_OFF"
    case badRequest = "ERR_BAD_REQUEST"
    case badDeploy = "ERR_BAD_DEPLOY"
    case beef = "ERR_BEEF"
    case invalidPayment = "ERR_INVALID_PAYMENT"
    case tokenEnabled = "ERR_TOKEN_ENABLED"
    case tokenDisabled = "ERR_TOKEN_DISABLED"
    case paymentReplayed = "ERR_PAYMENT_REPLAYED"
    case paymentRequired = "ERR_PAYMENT_REQUIRED"
    case paymentTooSmall = "ERR_PAYMENT_TOO_SMALL"
}
