import Foundation
#if canImport(os)
import os
#endif

/// What a 1Sat service answered when a request failed: enough for a short message to the user
/// and a full line in the log.
///
/// The query string is never kept: some services take an API key there (an `auth_token`).
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
/// a recovery phrase, a token or an auth header. Every line also goes through
/// ``redactingQueries(_:)`` before it is written, as a second guard.
public enum OneSatLog {
    public static let subsystem = "dev.opl.1sat-sdk"

    public static func error(_ message: String, category: String) {
        write(.error, redactingQueries(message), category: category)
    }

    /// A note, not a failure: something the SDK worked around.
    public static func notice(_ message: String, category: String) {
        write(.notice, redactingQueries(message), category: category)
    }

    private enum Level { case error, notice }

    /// Writes `message` as it is. Only ``error(_:category:)`` and ``notice(_:category:)`` call
    /// it, after redacting, and the redactions' own compile check, which cannot redact with
    /// patterns that are still being compiled.
    private static func write(_ level: Level, _ message: String, category: String) {
        #if canImport(os)
        let logger = Logger(subsystem: subsystem, category: category)
        switch level {
        case .error: logger.error("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        }
        #endif
    }

    /// ``notice(_:category:)`` the first time `key` is met in this process, and never again: for
    /// a condition met on every item of a listing.
    public static func noticeOnce(_ key: String, _ message: @autoclosure () -> String, category: String) {
        guard noticed.insert(key) else { return }
        notice(message(), category: category)
    }

    private static let noticed = KeySet()

    /// The keys ``noticeOnce(_:_:category:)`` has logged, behind a lock.
    final class KeySet: @unchecked Sendable {
        private let lock = NSLock()
        private var keys: Set<String> = []

        /// True the first time `key` is inserted.
        func insert(_ key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return keys.insert(key).inserted
        }
    }

    /// Logs `error` in full (its type and reflection, URL-free) with what the SDK was doing.
    public static func error(_ error: any Error, _ context: String, category: String) {
        Self.error("\(context): \(describe(error))", category: category)
    }

    /// `error`'s type and ``reflecting(_:)``, for a log line.
    public static func describe(_ error: any Error) -> String {
        "\(type(of: error)): \(reflecting(error))"
    }

    /// `String(reflecting: error)` without any URL's query string or secret value, for a log or a
    /// diagnostic.
    ///
    /// A URL loading error (in `NSURLErrorDomain`, or one that names its failing URL or the error
    /// under it) is described only by its domain, code, description and the failing host and
    /// path, and so is each error under it: its user info carries the full URL, and some services
    /// take an API key in the query (an `auth_token`). Anything else is reflected and passed
    /// through ``redactingQueries(_:)``.
    public static func reflecting(_ error: any Error) -> String {
        if let foundation = FoundationError(error), foundation.isURLLoading {
            return urlLoadingText(foundation, depth: 0)
        }
        return redactingQueries(String(reflecting: error))
    }

    /// `String(describing: error)`, cleaned the same way as ``reflecting(_:)``: for the text of a
    /// thrown error or a result, where the error's own words are kept.
    public static func message(_ error: any Error) -> String {
        if let foundation = FoundationError(error), foundation.isURLLoading {
            return urlLoadingText(foundation, depth: 0)
        }
        return redactingQueries(String(describing: error))
    }

    /// `error.localizedDescription` with every URL's query string and every secret value
    /// removed (``redactingQueries(_:)``): for a result's `error` or a thrown message, where a
    /// user reads the error's own localized words.
    public static func localizedMessage(_ error: any Error) -> String {
        redactingQueries(error.localizedDescription)
    }

    /// `text` with the query string (and fragment) of every `scheme://` URL removed, and every
    /// secret value left elsewhere replaced by `<redacted>`.
    ///
    /// A secret is the value of a parameter, JSON member, reflected property or header whose name
    /// ends in `password`, `passwd`, `secret`, `wif`, `mnemonic`, `phrase`, `seed`, `authorization`,
    /// `api_key` / `apiKey` (and `access`, `auth`, `secret`, `signing`, `priv`, `private` keys), or in
    /// `token` after a prefix (`auth_token`, `api_token`, `accessToken`); a `key` or `token` value
    /// that is quoted, a parameter, or a header's (at the start of a line or list item), unless it
    /// is a token ID (`<txid>_<vout>`) or, quoted, a plain word, since this SDK names token IDs and
    /// labels that way; an `Authorization:` header's credential (a plain word
    /// such as `denied` with no scheme is prose); a `Bearer` credential that looks like one (it
    /// holds a digit, or is 24 characters or more); a recovery phrase of twelve words or more; and a
    /// mainnet WIF private key. A value that reads as prose (`Invalid password: too short`) is kept.
    public static func redactingQueries(_ text: String) -> String {
        var result = text
        for redaction in redactions {
            result = redaction.pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: redaction.template
            )
        }
        return result
    }

    /// One compiled pattern and its replacement. `NSRegularExpression` is immutable and safe to
    /// share across threads, which the SDK does not declare on every platform.
    struct Redaction: @unchecked Sendable {
        let pattern: NSRegularExpression
        let template: String
    }

    /// A parameter or member name whose value is always a secret.
    private static let secretName =
        #"(?:[A-Za-z0-9_.-]*(?:password|passwd|secret|wif|mnemonic|phrase|seed|authorization|(?:api|access|auth|secret|signing|priv|private)[_-]?key)|[A-Za-z0-9_.-]+token)"#
    /// The same names but `authorization`, whose unquoted value has its own rule.
    private static let secretNameButAuthorization =
        #"(?:[A-Za-z0-9_.-]*(?:password|passwd|secret|wif|mnemonic|phrase|seed|(?:api|access|auth|secret|signing|priv|private)[_-]?key)|[A-Za-z0-9_.-]+token)"#
    /// A name this SDK also gives to token IDs and labels (`token: "<txid>_0"`, `key: "Legendary"`).
    private static let ambiguousName = #"(?:token|key)"#
    /// Not part of a longer name: `monkey=` and `xkey=` are not `key=`.
    private static let nameStart = #"(?<![A-Za-z0-9_.-])"#
    /// A BSV-21 token ID or an outpoint: a txid, `_` or `.`, and an output index.
    private static let tokenID = #"[0-9a-fA-F]{64}[_.][0-9]{1,10}"#
    /// One word of prose: a lowercase or capitalized word, never a mix with digits or inner
    /// capitals. Case-sensitive inside a case-insensitive pattern.
    private static let plainWord = #"(?-i:[A-Za-z][a-z]{0,31})"#
    /// The characters of an unquoted value: not a quote, escaped or not, so a quoted value
    /// already redacted is left alone, and not an opening `{` or `[`, so a JSON object or array
    /// after the name is not a value.
    private static let bareValue = #"[^\s"'\\,;)}\]<>(\{\[]"#
    /// An unquoted value that is prose, not a secret: a plain word, a space and another word
    /// (`Invalid password: too short`).
    private static let proseValue = #"\#(plainWord)[ \t]+[A-Za-z]"#
    /// The separator between a name and its quoted value: JSON, a reflected property or a
    /// quoted assignment, with an optional `Optional(`.
    private static let quotedSeparator = #"(\\?["']?\s*[:=]\s*(?:Optional\()?)(\\?["'])"#
    /// The separator between a name and an unquoted value on one line (`token: abc`,
    /// `"api_key": 12345`).
    private static let bareSeparator = #"(\\?["']?[ \t]*:[ \t]*)"#
    private static let base58 = "1-9A-HJ-NP-Za-km-z"

    /// The redactions as pattern and template, applied in order.
    private static let redactionSources: [(pattern: String, template: String)] = [
        // A URL's query and fragment, whatever its values hold (`,`, `;` and `)` included).
        (##"([A-Za-z][A-Za-z0-9+.-]*://[^\s?#"'<>]*)[?#][^\s"'<>]*"##, "$1"),
        // A mainnet WIF private key, wherever it stands: `5H…`/`5J…`/`5K…` (51 characters) or
        // `K…`/`L…` (52). Not testnet's `9…`/`c…`: those letters are hex, and a txid can hold
        // such a run.
        (#"(?<![\#(base58)])(?:5[HJK][\#(base58)]{49}|[KL][\#(base58)]{51})(?![\#(base58)])"#,
         "<redacted>"),
        // A quoted secret value: JSON (`"auth_token":"…"`, escaped or not), a reflected property
        // (`apiKey: "…"`, `authToken: Optional("…")`), or a quoted assignment (`password='…'`).
        (#"(?i)\#(nameStart)(\#(secretName))\#(quotedSeparator)(?:\\.|[^\\])*?\3"#, "$1$2$3<redacted>$3"),
        // A quoted `key` or `token` value, unless it is a token ID or a plain word.
        (#"(?i)\#(nameStart)(\#(ambiguousName))\#(quotedSeparator)(?!(?:\#(tokenID)|\#(plainWord))\3)(?:\\.|[^\\])*?\3"#,
         "$1$2$3<redacted>$3"),
        // An authorization header (`Authorization`, `Proxy-Authorization`, `X-Authorization`): a
        // credential after a known scheme; after any one-word scheme (`Apikey`, `Key`) when it
        // holds a digit or is 16 characters or more; or with no scheme unless it is one plain word
        // of prose (`authorization: denied.`).
        (#"(?i)\#(nameStart)([A-Za-z0-9_.-]*authorization\s*[:=]\s*)(?:(?:bearer|basic|token|digest|negotiate|ntlm)\s+[^\s"'<>]+|\#(plainWord)\s+(?:(?=[^\s"'<>]*[0-9])[^\s"'<>]+|[^\s"'<>]{16,})|(?!\#(plainWord)[.,;:!?]?(?:[\s"'<>)\]}]|$))[^\s"'<>]+)"#,
         "$1<redacted>"),
        // A recovery phrase, unquoted: twelve or more lowercase words (the BIP-39 minimum) after
        // the name.
        (#"(?i)\#(nameStart)([A-Za-z0-9_.-]*(?:mnemonic|phrase|seed)[ \t]*[:=][ \t]*)(?-i:[a-z]+(?:[ \t]+[a-z]+){11,})"#,
         "$1<redacted>"),
        // An unquoted value after a colon, as in a header (`X-Api-Key: abc`) or a JSON number;
        // not a reflected value such as `nil`, `Optional(…)` or `Type(…)`, and not prose
        // (`Invalid password: too short`).
        (#"(?i)\#(nameStart)(\#(secretNameButAuthorization))\#(bareSeparator)(?!nil\b|\#(proseValue))\#(bareValue)++(?!\()"#,
         "$1$2<redacted>"),
        // A bare `key` or `token` only where a header or a list item starts (`token: abc` on its
        // own line, `{token: abc`), so prose such as "this token: no pool" is left alone.
        (#"(?im)(^|[,;{(\[])([ \t]*\\?["']?)(\#(ambiguousName))\#(bareSeparator)(?!nil\b|\#(proseValue)|\#(tokenID)(?!\#(bareValue)))\#(bareValue)++(?!\()"#,
         "$1$2$3$4<redacted>"),
        // A query or form parameter (`key=`, `api_token=`), up to the next `&` or space.
        (#"(?i)\#(nameStart)(\#(secretName)|\#(ambiguousName))=[^&\s"'<>]+"#, "$1=<redacted>"),
        // A bare bearer credential: one that holds a digit, or is 24 characters or more, so the
        // word in prose ("the bearer certificate") is left alone.
        (#"(?i)\b(bearer)\s+(?:(?=[A-Za-z._~+/=-]*[0-9])[A-Za-z0-9._~+/=-]{8,}|[A-Za-z0-9._~+/=-]{24,})"#,
         "$1 <redacted>"),
    ]

    /// The redactions, compiled once. Every pattern is fixed and a test checks that all of them
    /// compile; one that does not is left out and logged, once, as unredacted.
    static let redactions: [Redaction] = {
        var compiled: [Redaction] = []
        for (index, source) in redactionSources.enumerated() {
            do {
                let pattern = try NSRegularExpression(pattern: source.pattern)
                compiled.append(Redaction(pattern: pattern, template: source.template))
            } catch {
                // Written as it is: redacting it would use these very patterns, still compiling.
                let reason = FoundationError(error).map { "\($0.domain) \($0.code)" } ?? "\(type(of: error))"
                write(
                    .error,
                    "OneSatLog: redaction \(index + 1) of \(redactionSources.count) does not compile (\(reason)) "
                        + "and is skipped, so what it would redact is logged as it is",
                    category: "OneSatLog"
                )
            }
        }
        return compiled
    }()

    /// How many redactions there are to compile.
    static var redactionCount: Int { redactionSources.count }

    /// `url` without its query string, user, password or fragment; nil when no such URL can be
    /// built, so a caller never falls back to the URL with its query.
    public static func withoutQuery(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }

    /// `error` rebuilt without the failing URL's query string: the same code and description,
    /// the failing URL as scheme, host and path, and the error under it as its domain, code and
    /// description only. Some services take an API key in the query (an `auth_token`), and
    /// URLSession's error carries the full URL to every caller and log.
    public static func urlFree(_ error: URLError) -> URLError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: redactingQueries(error.localizedDescription)]
        let original = FoundationError(error)
        if let failing = original?.failingURL, let bare = withoutQuery(failing) {
            info[failingURLKey] = bare
            info[failingURLStringKey] = bare.absoluteString
        }
        if let underlying = original?.underlying {
            let inner = FoundationError(underlying)
            info[NSUnderlyingErrorKey] = NSError(
                domain: inner?.domain ?? String(describing: type(of: underlying)), code: inner?.code ?? 0,
                userInfo: [NSLocalizedDescriptionKey: redactingQueries(underlying.localizedDescription)]
            )
        }
        return URLError(error.code, userInfo: info)
    }

    /// What a `URLSession` call threw, ready to throw on: a URL loading error rebuilt by
    /// ``urlFree(_:)``, anything else (a `CancellationError`, say) as it is. On Linux URLSession
    /// throws an `NSError` in the URL domain, which does not cast to `URLError` there; it carries
    /// the same full URL and is rebuilt the same way.
    public static func urlFree(thrown error: any Error) -> any Error {
        if let urlError = error as? URLError { return urlFree(urlError) }
        guard let foundation = FoundationError(error), foundation.domain == "NSURLErrorDomain" else { return error }
        // `URLError.Code(rawValue:)` is failable in corelibs Foundation and not on Darwin.
        let code: URLError.Code? = URLError.Code(rawValue: foundation.code)
        return urlFree(URLError(code ?? .unknown, userInfo: foundation.userInfo))
    }

    public static let failingURLKey = "NSErrorFailingURLKey"
    public static let failingURLStringKey = "NSErrorFailingURLStringKey"

    /// An `NSError` instance or a `CustomNSError` value such as `URLError`, read the same way on
    /// every platform. `error as NSError` does not compile for `any Error` on Linux
    /// (swift-corelibs-foundation), and there an `NSError` instance does not cast to `URLError`.
    /// A plain Swift error has no user info of its own and is not one.
    public struct FoundationError {
        public let domain: String
        public let code: Int
        public let localizedDescription: String
        public let userInfo: [String: Any]

        public init?(_ error: any Error) {
            if type(of: error) is NSError.Type, let nsError = (error as Any) as? NSError {
                domain = nsError.domain
                code = nsError.code
                userInfo = nsError.userInfo
            } else if let custom = error as? any CustomNSError {
                domain = type(of: custom).errorDomain
                code = custom.errorCode
                userInfo = custom.errorUserInfo
            } else {
                return nil
            }
            localizedDescription = error.localizedDescription
        }

        /// The failing URL, from either user-info key.
        public var failingURL: URL? {
            (userInfo[OneSatLog.failingURLKey] as? URL)
                ?? (userInfo[OneSatLog.failingURLStringKey] as? String).flatMap { URL(string: $0) }
        }

        /// The error under this one.
        public var underlying: (any Error)? {
            userInfo[NSUnderlyingErrorKey] as? any Error
        }

        /// In the URL domain, or carrying a failing URL or an error under it, either of which can
        /// hold a full URL.
        var isURLLoading: Bool {
            domain == "NSURLErrorDomain"
                || userInfo[OneSatLog.failingURLKey] != nil || userInfo[OneSatLog.failingURLStringKey] != nil
                || userInfo[NSUnderlyingErrorKey] != nil
        }
    }

    private static func urlLoadingText(_ error: FoundationError, depth: Int) -> String {
        var text = "\(error.domain) \(error.code): \(redactingQueries(error.localizedDescription))"
        if let failing = error.failingURL {
            text += " (\(failing.host ?? "")\(failing.path))"
        }
        // Each error under it is described the same way, never reflected: its user info may hold
        // the URL under a key not named here.
        if let underlying = error.underlying {
            let inner: String
            if let foundation = FoundationError(underlying) {
                inner = depth < 4 ? urlLoadingText(foundation, depth: depth + 1) : "\(foundation.domain) \(foundation.code)"
            } else {
                inner = redactingQueries(String(reflecting: underlying))
            }
            text += "; underlying: \(inner)"
        }
        return text
    }

    /// A body that could not be read: the call, where it went, the decoding error and the body.
    public static func unreadable(
        _ operation: String, method: String, url: URL, body: [UInt8], error: (any Error)?, category: String
    ) {
        let reason = error.map { describe($0) } ?? "unexpected shape"
        Self.error(
            "\(operation): \(method) \(url.host ?? "")\(url.path) answered an unreadable body (\(reason)); body: \(OneSatHTTPFailure.logText(body))",
            category: category
        )
    }
}
