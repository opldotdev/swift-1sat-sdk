import Foundation
import XCTest
@testable import OneSatSweep

/// A URL loading error never puts a URL's query string (MNEE's `auth_token`) in the log.
final class OneSatLogRedactionTests: XCTestCase {
    private let url = URL(string: "https://proxy-api.mnee.net/v1/tx/abc?auth_token=SECRET")!

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
        XCTAssertTrue(text.contains("proxy-api.mnee.net/v1/tx/abc"), text)
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
        XCTAssertEqual(OneSatLog.redactingQueries("mnee_token=SECRET"), "mnee_token=<redacted>")
        XCTAssertEqual(OneSatLog.redactingQueries("x token=SEC,RET;MORE)tail"), "x token=<redacted>")
    }

    func test_redactingQueriesLeavesOtherNamesAlone() {
        XCTAssertEqual(OneSatLog.redactingQueries("monkey=banana xkey=v"), "monkey=banana xkey=v")
        XCTAssertEqual(
            OneSatLog.redactingQueries(#"identityKey: "02ab" publicKey=03cd"#),
            #"identityKey: "02ab" publicKey=03cd"#
        )
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
        XCTAssertTrue(text.contains("proxy-api.mnee.net/v1/tx/abc"), text)
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
        XCTAssertEqual(OneSatLog.withoutQuery(url)?.absoluteString, "https://proxy-api.mnee.net/v1/tx/abc")
    }
}
