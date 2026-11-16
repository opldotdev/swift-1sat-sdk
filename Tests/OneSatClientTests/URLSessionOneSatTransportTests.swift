import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import OneSatClient

/// The transport hands callers a URLError without the MNEE API key in its failing URL.
final class URLSessionOneSatTransportTests: XCTestCase {
    func test_urlFreeDropsTheQueryAndKeepsCodeHostAndPath() {
        let url = MneeClient.rawTxURL(
            txid: "abc", baseURL: URL(string: "https://proxy-api.mnee.net")!, apiKey: "SECRET"
        )
        XCTAssertTrue(url.absoluteString.contains("SECRET"))
        let underlying = NSError(
            domain: "kCFErrorDomainCFNetwork", code: -1009,
            userInfo: ["NSErrorFailingURLStringKey": url.absoluteString]
        )
        let raw = URLError(
            .notConnectedToInternet,
            userInfo: [
                NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
                "NSErrorFailingURLKey": url,
                "NSErrorFailingURLStringKey": url.absoluteString,
                NSUnderlyingErrorKey: underlying,
            ]
        )
        let clean = URLSessionOneSatTransport.urlFree(raw)
        XCTAssertEqual(clean.code, .notConnectedToInternet)
        XCTAssertEqual(clean.localizedDescription, "The Internet connection appears to be offline.")
        let info = clean.errorUserInfo
        XCTAssertEqual(info["NSErrorFailingURLStringKey"] as? String, "https://proxy-api.mnee.net/v1/tx/abc")
        XCTAssertFalse(String(reflecting: clean).contains("SECRET"), String(reflecting: clean))
        XCTAssertFalse(String(describing: info).contains("SECRET"))
    }
}
