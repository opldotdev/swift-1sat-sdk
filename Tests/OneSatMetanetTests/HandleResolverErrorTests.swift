import Foundation
import XCTest
@testable import OneSatMetanet

/// A failed handle lookup says which domain, the status and the server's own reason.
final class HandleResolverErrorTests: XCTestCase {
    func test_manifestFailureCarriesTheServerReason() async {
        let resolver = HandleResolver(fetch: { _ in (503, Array(#"{"message":"maintenance"}"#.utf8)) })
        do {
            _ = try await resolver.resolve("alice@example.com")
            XCTFail("expected a handle error")
        } catch let error as MetanetError {
            XCTAssertEqual(error, .handle("manifest fetch failed for example.com: 503: maintenance"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_paymailInboxErrorKeepsTheUnderlyingErrorOutOfEquality() {
        struct Cause: Error {}
        let error = PaymailInboxError("paymail beef is not hex", underlying: Cause())
        XCTAssertEqual(error, PaymailInboxError("paymail beef is not hex"))
        XCTAssertEqual(error.errorDescription, "paymail beef is not hex")
        XCTAssertTrue(String(reflecting: error).contains("Cause"))
    }
}
