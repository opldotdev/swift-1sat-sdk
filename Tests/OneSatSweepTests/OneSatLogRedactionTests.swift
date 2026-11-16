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

    func test_withoutQueryKeepsSchemeHostAndPath() {
        XCTAssertEqual(OneSatLog.withoutQuery(url)?.absoluteString, "https://proxy-api.mnee.net/v1/tx/abc")
    }
}
