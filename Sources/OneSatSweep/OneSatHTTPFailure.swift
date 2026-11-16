import Foundation
#if canImport(os)
import os
#endif

/// What a 1Sat service answered when a request failed: enough for a short message to the user
/// and a full line in the log.
///
/// The query string is never kept: some services take an API key there (MNEE's `auth_token`).
public struct OneSatHTTPFailure: Error, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// The service in plain words, as a user would name it ("the 1Sat indexer").
    public let service: String
    /// The call that failed (`OneSatClient.ordinals`), for the log.
    public let operation: String
    public let method: String
    public let host: String
    /// The path alone, without the query string.
    public let path: String
    public let statusCode: Int
    /// The server's own reason when it gave a short readable one: one line, at most 120 characters.
    public let serverMessage: String?
    /// The response body as text, at most 2,000 characters. For the log only.
    public let body: String

    public init(service: String, operation: String, method: String, url: URL, statusCode: Int, body: [UInt8]) {
        self.service = service
        self.operation = operation
        self.method = method
        self.host = url.host ?? ""
        self.path = url.path
        self.statusCode = statusCode
        self.serverMessage = Self.serverReason(from: body)
        self.body = Self.logText(body)
    }

    /// One or two sentences for the user: the service, the status, the server's reason, and a
    /// hint when trying again may help.
    public var userMessage: String {
        let lead = Self.capitalizedFirst(service)
        let retry = statusCode == 429 || statusCode >= 500 || statusCode == 0
        let verb = retry ? "could not answer" : "refused the request"
        var text = "\(lead) \(verb) (HTTP \(statusCode))"
        if let serverMessage {
            text += ": \(serverMessage)"
        }
        if !text.hasSuffix(".") { text += "." }
        if retry { text += " Try again in a minute." }
        return text
    }

    public var description: String { userMessage }

    /// Everything known about the failure, for the log.
    public var debugDescription: String {
        "\(operation): \(method) \(host)\(path) -> HTTP \(statusCode) from \(service); body: \(body.isEmpty ? "(empty)" : body)"
    }

    /// The server's own short reason: a JSON `message`, `error`, `description`, `detail` or
    /// `reason` (or `error.message`), else a short plain-text body. HTML and long text give nil.
    public static func serverReason(from body: [UInt8]) -> String? {
        guard !body.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] {
            for key in ["message", "error", "description", "detail", "reason"] {
                if let text = object[key] as? String, let reason = oneLine(text) { return reason }
                if let nested = object[key] as? [String: Any] {
                    for inner in ["message", "description", "code"] {
                        if let text = nested[inner] as? String, let reason = oneLine(text) { return reason }
                    }
                }
            }
            return nil
        }
        let text = String(decoding: body, as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A page of markup or a long dump is not a reason a person can read.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("{"), !trimmed.hasPrefix("["),
              trimmed.count <= 300 else { return nil }
        return oneLine(trimmed)
    }

    /// The first line of `text`, trimmed to 120 characters; nil when empty.
    public static func oneLine(_ text: String) -> String? {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }

    /// A body as text for the log: at most 2,000 characters.
    public static func logText(_ body: [UInt8]) -> String {
        let text = String(decoding: body.prefix(8_000), as: UTF8.self)
        return text.count > 2_000 ? String(text.prefix(2_000)) + "… (\(body.count) bytes)" : text
    }

    /// Writes the failure to the log under `dev.opl.1sat-sdk`.
    public func log(category: String) {
        OneSatLog.error(debugDescription, category: category)
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

/// The 1Sat SDK's log: subsystem `dev.opl.1sat-sdk`, one category per module. Never pass a key,
/// a recovery phrase, a token or an auth header.
public enum OneSatLog {
    public static let subsystem = "dev.opl.1sat-sdk"

    public static func error(_ message: String, category: String) {
        #if canImport(os)
        Logger(subsystem: subsystem, category: category).error("\(message, privacy: .public)")
        #endif
    }

    /// Logs `error` in full (its type and reflection) with what the SDK was doing.
    public static func error(_ error: any Error, _ context: String, category: String) {
        Self.error("\(context): \(type(of: error)): \(String(reflecting: error))", category: category)
    }

    /// A body that could not be read: the call, where it went, the decoding error and the body.
    public static func unreadable(
        _ operation: String, method: String, url: URL, body: [UInt8], error: (any Error)?, category: String
    ) {
        let reason = error.map { "\(type(of: $0)): \(String(reflecting: $0))" } ?? "unexpected shape"
        Self.error(
            "\(operation): \(method) \(url.host ?? "")\(url.path) answered an unreadable body (\(reason)); body: \(OneSatHTTPFailure.logText(body))",
            category: category
        )
    }
}
