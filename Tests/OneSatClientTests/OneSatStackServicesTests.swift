import Foundation
import ToolboxServices
import XCTest
@testable import OneSatClient

/// Offline coverage of the 1sat-stack `WalletServices` pin. The fixture is the
/// live `GET https://api.1sat.app/1sat/chaintracks/tip` body recorded 2026-08-13.
final class OneSatStackServicesTests: XCTestCase {
    private actor URLRecorder {
        private var url: URL?
        func record(_ url: URL) { self.url = url }
        func value() -> URL? { url }
    }

    private struct StubHTTP: HTTPGet {
        let status: Int
        let body: [UInt8]
        let recorder: URLRecorder?

        init(status: Int, body: [UInt8], recorder: URLRecorder? = nil) {
            self.status = status
            self.body = body
            self.recorder = recorder
        }

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            await recorder?.record(url)
            return (status, body)
        }
    }

    /// Recorded 2026-08-13 from `GET https://api.1sat.app/1sat/chaintracks/tip`.
    private let recordedTip = """
        {"version":652509184,"previousHash":"00000000000000000f1a8cba66ea79405d5d72f9ac65c87d54c570977c684ac4","merkleRoot":"a0c504beaa04ec5f667aacb98e6b472afa54a05e24a51221f7a6901af58405e8","time":1786646786,"bits":404963795,"nonce":3558270570,"height":962178,"hash":"00000000000000000653476394492dd41f3c7e1c0e22e5f20b1bb05de4882b60"}
        """

    func test_currentHeightEqualsTheRecordedTipHeight() async throws {
        let services = OneSatStackServices(
            http: StubHTTP(status: 200, body: Array(recordedTip.utf8))
        )

        let height = try await services.currentHeight()

        XCTAssertEqual(height, 962_178)
    }

    func test_chainTipHeaderMapsHeightHashAndMerkleRoot() async throws {
        let recorder = URLRecorder()
        let services = OneSatStackServices(
            http: StubHTTP(status: 200, body: Array(recordedTip.utf8), recorder: recorder)
        )

        let header = try await services.chainTipHeader()
        let requested = await recorder.value()

        XCTAssertEqual(requested?.path, "/1sat/chaintracks/tip")
        XCTAssertEqual(header.height, 962_178)
        XCTAssertEqual(
            header.hash,
            "00000000000000000653476394492dd41f3c7e1c0e22e5f20b1bb05de4882b60"
        )
        XCTAssertEqual(header.merkleRoot.count, 32)
        XCTAssertEqual(header.merkleRoot.first, 0xa0)
        XCTAssertEqual(header.merkleRoot.last, 0xe8)
    }

    func test_nonSuccessStatusThrowsWithTheStatusCode() async {
        let services = OneSatStackServices(http: StubHTTP(status: 503, body: []))

        do {
            _ = try await services.currentHeight()
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 503))
        } catch {
            XCTFail("expected OneSatClientError.httpFailure, got \(error)")
        }
    }

    func test_missingHeightThrows() async {
        let body = #"{"hash":"00","merkleRoot":"\#(String(repeating: "aa", count: 32))"}"#
        let services = OneSatStackServices(http: StubHTTP(status: 200, body: Array(body.utf8)))

        do {
            _ = try await services.currentHeight()
            XCTFail("a tip without height must be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    func test_unimplementedUsdPerBSVNamesTheMethod() async {
        let services = OneSatStackServices(http: StubHTTP(status: 200, body: []))

        do {
            _ = try await services.usdPerBSV()
            XCTFail("expected notImplemented")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .notImplemented("usdPerBSV"))
        } catch {
            XCTFail("expected ServiceError.notImplemented, got \(error)")
        }
    }

    func test_unimplementedRawTXNamesTheMethod() async {
        let services = OneSatStackServices(http: StubHTTP(status: 200, body: []))

        do {
            _ = try await services.rawTX(txid: String(repeating: "ab", count: 32))
            XCTFail("expected notImplemented")
        } catch let error as ServiceError {
            XCTAssertEqual(error, .notImplemented("rawTX"))
        } catch {
            XCTFail("expected ServiceError.notImplemented, got \(error)")
        }
    }
}
