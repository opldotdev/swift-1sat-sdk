import Foundation
import XCTest
@testable import OneSatSweep

/// A URL loading error never puts a URL's query string (an `auth_token`) in the log.
final class OneSatLogRedactionTests: XCTestCase {
    private let url = URL(string: "https://api.example.com/v1/tx/abc?auth_token=SECRET")!

    /// What URLSession throws offline: the full URL in its user info, and again in the error
    /// under it.
    private func offline() -> NSError {
        let underlying = NSError(
            domain: "kCFErrorDomainCFNetwork", code: -1009,
            userInfo: ["NSErrorFailingURLStringKey": url.absoluteString, "NSErrorFailingURLKey": url]
        )
        return NSError(
            domain: "NSURLErrorDomain", code: -1009,
            userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
                "NSErrorFailingURLStringKey": url.absoluteString,
                "NSErrorFailingURLKey": url,
                NSUnderlyingErrorKey: underlying,
            ]
        )
    }

    func test_urlLoadingErrorIsDescribedByDomainCodeAndHostPath() {
        let text = OneSatLog.describe(offline())
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertFalse(text.contains("auth_token"), text)
        XCTAssertTrue(text.contains("NSURLErrorDomain -1009"), text)
        XCTAssertTrue(text.contains("The Internet connection appears to be offline."), text)
        XCTAssertTrue(text.contains("api.example.com/v1/tx/abc"), text)
        XCTAssertTrue(text.contains("underlying: kCFErrorDomainCFNetwork -1009"), text)
    }

    func test_aWrappedURLErrorLosesItsQueryInTheReflection() {
        struct Wrapper: Error { let underlying: any Error }
        let text = OneSatLog.describe(Wrapper(underlying: offline()))
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertTrue(text.hasPrefix("Wrapper: "), text)
    }

    func test_redactingQueriesDropsQueriesAndTokenValues() {
        XCTAssertEqual(
            OneSatLog.redactingQueries("GET https://x.example/a/b?auth_token=SECRET&n=1 failed"),
            "GET https://x.example/a/b failed"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("sent auth_token=SECRET&n=1"), "sent auth_token=<redacted>&n=1")
        XCTAssertEqual(OneSatLog.redactingQueries("plain text"), "plain text")
    }

    func test_everyRedactionPatternCompiles() {
        XCTAssertEqual(OneSatLog.redactions.count, OneSatLog.redactionCount)
    }

    func test_redactingQueriesCutsAQueryWhateverItsValuesHold() {
        XCTAssertEqual(OneSatLog.redactingQueries("https://h.example/p?t=a,b;c)d end"), "https://h.example/p end")
    }

    func test_redactingQueriesRedactsJSONAndReflectedSecrets() {
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"body {"auth_token":"SECRET","n":1}"#),
            #"body {"auth_token":"<redacted>","n":1}"#
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"body { "apiKey" : "SECRET" }"#),
            #"body { "apiKey" : "<redacted>" }"#
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Config(apiKey: "SECRET", host: "x")"#),
            #"Config(apiKey: "<redacted>", host: "x")"#
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"escaped {\"auth_token\":\"SECRET\"}"#),
            #"escaped {\"auth_token\":\"<redacted>\"}"#
        )
        XCTAssertEqual(OneSatLog.redactingQueries("token='SECRET' ok"), "token='<redacted>' ok")
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Client(token: Optional("SECRET"))"#),
            #"Client(token: Optional("<redacted>"))"#
        )
    }

    func test_redactingQueriesRedactsAuthorization() {
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization: Bearer SECRETSECRET"), "Authorization: <redacted>")
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"headers ["Authorization": "Bearer SECRET"]"#),
            #"headers ["Authorization": "<redacted>"]"#
        )
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization=Basic SECRET"), "Authorization=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("sent Bearer abcdefgh123"), "sent Bearer <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("the bearer of bad news"), "the bearer of bad news")
    }

    func test_redactingQueriesRedactsSecretParameters() {
        XCTAssertEqual(OneSatLog.redactingQueries("key=SECRET&x=1"), "key=<redacted>&x=1")
        XCTAssertEqual(OneSatLog.redactingQueries("password=SECRET"), "password=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("secret=SECRET"), "secret=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("wif=SECRET"), "wif=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("api_token=SECRET"), "api_token=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("x token=SEC,RET;MORE)tail"), "x token=<redacted>")
    }

    func test_redactingQueriesLeavesOtherNamesAlone() {
        XCTAssertEqual(OneSatLog.redactingQueries("monkey=banana xkey=v"), "monkey=banana xkey=v")
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"identityKey: "02ab" publicKey=03cd"#),
            #"identityKey: "02ab" publicKey=03cd"#
        )
    }

    /// A token ID as this SDK writes one: a txid, `_`, an output index.
    private let tokenID = "e6d40ba206340aa94ed40fe1a8adcd722c08c9438b2c1dd16b4527d561e848a2_0"

    func test_redactingQueriesRedactsUnquotedHeaderValues() {
        XCTAssertEqual(OneSatLog.redactingQueries("token: abc"), "token: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("X-Api-Key: abc"), "X-Api-Key: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("x-api-key: abc123 sent"), "x-api-key: <redacted> sent")
        XCTAssertEqual(
            OneSatLog.redactingQueries("headers: [token: abc, accept: json]"),
            "headers: [token: <redacted>, accept: json]"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("GET /v1\ntoken: abc\nhost: x"), "GET /v1\ntoken: <redacted>\nhost: x")
        XCTAssertEqual(OneSatLog.redactingQueries(#"{"api_key": 12345}"#), #"{"api_key": <redacted>}"#)
        XCTAssertEqual(OneSatLog.redactingQueries(#"{"api_key": [1]}"#), #"{"api_key": [1]}"#)
        XCTAssertEqual(OneSatLog.redactingQueries("password: hunter2"), "password: <redacted>")
    }

    func test_redactingQueriesLeavesUnquotedTokenWordsInProseAndReflections() {
        for prose in [
            "no liveness read for this token: no pool can be planned",
            "token: no pool can be planned",
            "Invalid mnemonic: word count must be 12",
            "Invalid password: too short",
            "Invalid WIF: bad checksum",
        ] {
            XCTAssertEqual(OneSatLog.redactingQueries(prose), prose)
        }
        XCTAssertEqual(OneSatLog.redactingQueries("token: \(tokenID)"), "token: \(tokenID)")
        XCTAssertEqual(OneSatLog.redactingQueries("Session(authToken: nil)"), "Session(authToken: nil)")
        let nested = #"Holder(token: OneSatClient.Token(id: "x"))"#
        XCTAssertEqual(OneSatLog.redactingQueries(nested), nested)
        let json = #"{"token":{"id":"x"}}"#
        XCTAssertEqual(OneSatLog.redactingQueries(json), json)
    }

    func test_redactingQueriesRedactsABearerCredentialButNotTheWord() {
        XCTAssertEqual(OneSatLog.redactingQueries("sent Bearer abcdefgh123"), "sent Bearer <redacted>")
        XCTAssertEqual(
            OneSatLog.redactingQueries("sent Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig"),
            "sent Bearer <redacted>"
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries("sent bearer abcdefghijklmnopqrstuvwxyz"), "sent bearer <redacted>"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("the bearer certificate expired"), "the bearer certificate expired")
        XCTAssertEqual(OneSatLog.redactingQueries("bearer instruments are paper"), "bearer instruments are paper")
    }

    func test_redactingQueriesRedactsAnAuthorizationCredentialButNotProse() {
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization: abc123"), "Authorization: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization: SECRETSECRET"), "Authorization: <redacted>")
        XCTAssertEqual(
            OneSatLog.redactingQueries("Proxy-Authorization: Basic dXNlcjpwYXNz"), "Proxy-Authorization: <redacted>"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("authorization: denied"), "authorization: denied")
        XCTAssertEqual(
            OneSatLog.redactingQueries("Authorization: denied. Sign in again"), "Authorization: denied. Sign in again"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("authorization: denied for user"), "authorization: denied for user")
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization: Apikey abc123"), "Authorization: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("Authorization: Key abc123"), "Authorization: <redacted>")
        XCTAssertEqual(
            OneSatLog.redactingQueries("Authorization: Key abcdefghijklmnopqr"), "Authorization: <redacted>"
        )
        XCTAssertEqual(OneSatLog.redactingQueries("X-Authorization: abc123"), "X-Authorization: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("x-authorization: denied"), "x-authorization: denied")
    }

    func test_redactingQueriesKeepsTokenIDsAndLabelsButNotSecretsInKeyAndTokenFields() {
        let reflected = #"Bsv21Token(token: "\#(tokenID)", amount: 5)"#
        XCTAssertEqual(OneSatLog.redactingQueries(reflected), reflected)
        let label = #"RarityLabelEntry(key: "Legendary", value: "1")"#
        XCTAssertEqual(OneSatLog.redactingQueries(label), label)
        XCTAssertEqual(OneSatLog.redactingQueries(#"{"token":"\#(tokenID)"}"#), #"{"token":"\#(tokenID)"}"#)
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Session(token: "eyJhbGciOiJIUzI1NiJ9")"#),
            #"Session(token: "<redacted>")"#
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Config(key: "L1aXYZ9secretvalue")"#), #"Config(key: "<redacted>")"#
        )
        XCTAssertEqual(OneSatLog.redactingQueries(#"{"key":"abc_0"}"#), #"{"key":"<redacted>"}"#)
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Client(authToken: "\#(tokenID)")"#), #"Client(authToken: "<redacted>")"#
        )
    }

    func test_redactingQueriesRedactsRecoveryPhrases() {
        let phrase = "abandon ability able about above absent absorb abstract absurd abuse access accident"
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"Wallet(mnemonic: "abandon ability able about")"#),
            #"Wallet(mnemonic: "<redacted>")"#
        )
        XCTAssertEqual(OneSatLog.redactingQueries("mnemonic: \(phrase)"), "mnemonic: <redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("recovery_phrase=\(phrase)"), "recovery_phrase=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("seedPhrase: \(phrase), next"), "seedPhrase: <redacted>, next")
        XCTAssertEqual(OneSatLog.redactingQueries("a phrase of three words"), "a phrase of three words")
    }

    func test_redactingQueriesRedactsAWIFButNotAnAddressOrATxid() {
        XCTAssertEqual(
            OneSatLog.redactingQueries("imported KwdMAjGmerYanjeui5SHS7JkmpZvVipYvB2LJGU1ZxJwYvP98617 ok"),
            "imported <redacted> ok"
        )
        XCTAssertEqual(
            OneSatLog.redactingQueries("imported 5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ ok"),
            "imported <redacted> ok"
        )
        let address = "pay 1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH now"
        XCTAssertEqual(OneSatLog.redactingQueries(address), address)
        XCTAssertEqual(OneSatLog.redactingQueries("sent \(tokenID)"), "sent \(tokenID)")
    }

    func test_redactingTwiceChangesNothing() {
        let text = #"Authorization: Bearer abc123 {"auth_token":"S"} token: abc key=v https://h/p?q=1 "#
            + "KwdMAjGmerYanjeui5SHS7JkmpZvVipYvB2LJGU1ZxJwYvP98617"
        let once = OneSatLog.redactingQueries(text)
        XCTAssertEqual(OneSatLog.redactingQueries(once), once)
        XCTAssertFalse(once.contains("abc123"), once)
        XCTAssertFalse(once.contains("KwdMAj"), once)
    }

    func test_localizedMessageKeepsTheLocalizedWordsWithoutSecrets() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "The overlay at https://o.example/submit?api_key=SECRET refused it." }
        }
        XCTAssertEqual(OneSatLog.localizedMessage(Refused()), "The overlay at https://o.example/submit refused it.")
        struct Plain: LocalizedError { var errorDescription: String? { "overlay-required" } }
        XCTAssertEqual(OneSatLog.localizedMessage(Plain()), "overlay-required")
    }

    func test_urlFreeThrownRebuildsAURLErrorWithoutItsQuery() throws {
        let error = URLError(
            .timedOut,
            userInfo: [
                NSLocalizedDescriptionKey: "The request timed out.",
                "NSErrorFailingURLKey": url, "NSErrorFailingURLStringKey": url.absoluteString,
            ]
        )
        let clean = try XCTUnwrap(OneSatLog.urlFree(thrown: error) as? URLError)
        XCTAssertEqual(clean.code, .timedOut)
        XCTAssertEqual(clean.errorUserInfo["NSErrorFailingURLStringKey"] as? String, "https://api.example.com/v1/tx/abc")
        XCTAssertFalse(String(reflecting: clean).contains("SECRET"), String(reflecting: clean))
    }

    /// What URLSession throws on Linux: an `NSError` in the URL domain, not a `URLError`.
    func test_urlFreeThrownRebuildsAnNSErrorInTheURLDomain() throws {
        let clean = try XCTUnwrap(OneSatLog.urlFree(thrown: offline()) as? URLError)
        XCTAssertEqual(clean.code, .notConnectedToInternet)
        XCTAssertFalse(String(reflecting: clean).contains("SECRET"), String(reflecting: clean))
        XCTAssertFalse(String(describing: clean.errorUserInfo).contains("SECRET"))
    }

    func test_urlFreeThrownPassesOtherErrorsThrough() {
        XCTAssertTrue(OneSatLog.urlFree(thrown: CancellationError()) is CancellationError)
        let other = NSError(domain: "dev.opl.test", code: 3)
        let passed = OneSatLog.urlFree(thrown: other)
        XCTAssertEqual(OneSatLog.FoundationError(passed)?.domain, "dev.opl.test")
    }

    func test_messageKeepsAPlainErrorsOwnWords() {
        struct Plain: Error, CustomStringConvertible { var description: String { "the overlay refused it" } }
        XCTAssertEqual(OneSatLog.message(Plain()), "the overlay refused it")
    }

    func test_messageDescribesAURLErrorWithoutItsQuery() {
        let error = URLError(
            .timedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out.", "NSErrorFailingURLKey": url]
        )
        let text = OneSatLog.message(error)
        XCTAssertFalse(text.contains("SECRET"), text)
        XCTAssertTrue(text.hasPrefix("NSURLErrorDomain -1001: The request timed out."), text)
        XCTAssertTrue(text.contains("api.example.com/v1/tx/abc"), text)
    }

    func test_foundationErrorReadsAnNSErrorAndAURLError() {
        let ns = OneSatLog.FoundationError(offline())
        XCTAssertEqual(ns?.domain, "NSURLErrorDomain")
        XCTAssertEqual(ns?.code, -1009)
        XCTAssertEqual(ns?.failingURL, url)
        XCTAssertNotNil(ns?.underlying)
        let urlError = OneSatLog.FoundationError(URLError(.timedOut))
        XCTAssertEqual(urlError?.domain, "NSURLErrorDomain")
        XCTAssertEqual(urlError?.code, URLError.Code.timedOut.rawValue)
        struct Plain: Error {}
        XCTAssertNil(OneSatLog.FoundationError(Plain()))
    }

    func test_withoutQueryKeepsSchemeHostAndPath() {
        XCTAssertEqual(OneSatLog.withoutQuery(url)?.absoluteString, "https://api.example.com/v1/tx/abc")
    }
}
