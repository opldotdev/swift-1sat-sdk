import Foundation
import XCTest
@testable import OneSatActions

/// An offline call never puts its API key in an action's diagnostic.
final class ActionResultRedactionTests: XCTestCase {
    private func offline() -> NSError {
        let url = URL(string: "https://api.example.com/v1/tx/abc?auth_token=SECRET")!
        return NSError(
            domain: "NSURLErrorDomain", code: -1009,
            userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
                "NSErrorFailingURLStringKey": url.absoluteString,
                "NSErrorFailingURLKey": url,
            ]
        )
    }

    func test_failureDescribingAURLErrorKeepsTheKeyOutOfTheDiagnostic() {
        let result = ActionResult.failure(describing: offline())
        let diagnostic = result.diagnostic ?? ""
        XCTAssertFalse(diagnostic.contains("SECRET"), diagnostic)
        XCTAssertTrue(diagnostic.contains("api.example.com/v1/tx/abc"), diagnostic)
        XCTAssertFalse(result.error?.contains("SECRET") ?? false)
    }

    func test_failureWithAnUnderlyingURLErrorKeepsTheKeyOutOfTheDiagnostic() {
        let result = ActionResult.failure(.tokenNotFound, underlying: offline())
        XCTAssertFalse((result.diagnostic ?? "").contains("SECRET"), result.diagnostic ?? "")
        XCTAssertEqual(result.error, OneSatActionError.tokenNotFound.wireMessage)
    }

    func test_failureDescribingKeepsTheErrorsWordsWithoutItsSecrets() {
        struct Refused: LocalizedError {
            var errorDescription: String? { "GET https://api.example.com/v1/tx/abc?auth_token=SECRET was refused" }
        }
        let result = ActionResult.failure(describing: Refused())
        XCTAssertEqual(result.error, "GET https://api.example.com/v1/tx/abc was refused")
    }
}
