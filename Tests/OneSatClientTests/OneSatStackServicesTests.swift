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

    // MARK: - merklePath and header(atHeight:), as `OneSatServices.getMerklePath` reads them

    private struct RoutedHTTP: HTTPGet {
        let answer: @Sendable (URL) -> (status: Int, body: [UInt8])
        let recorder: URLRecorder

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            await recorder.record(url)
            return answer(url)
        }
    }

    private let base = URL(string: "https://api.example")!
    private let txid = String(repeating: "ab", count: 32)

    func test_merklePathIsTheProofAsServed() async throws {
        let recorder = URLRecorder()
        let services = OneSatStackServices(
            baseURL: base, http: RoutedHTTP(answer: { _ in (200, [9, 8, 7]) }, recorder: recorder)
        )

        let proof = try await services.merklePath(txid: txid)
        let requested = await recorder.value()

        XCTAssertEqual(proof, [9, 8, 7])
        XCTAssertEqual(requested?.absoluteString, "https://api.example/1sat/beef/\(txid)/proof")
    }

    func test_merklePathIsNilWhileTheIndexerAnswers404() async throws {
        let services = OneSatStackServices(baseURL: base, http: StubHTTP(status: 404, body: []))
        let proof = try await services.merklePath(txid: txid)
        XCTAssertNil(proof)
    }

    func test_merklePathThrowsAnyOtherFailure() async {
        let services = OneSatStackServices(baseURL: base, http: StubHTTP(status: 500, body: []))
        do {
            _ = try await services.merklePath(txid: txid)
            XCTFail("expected the HTTP failure")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .httpFailure(statusCode: 500))
        }
    }

    /// An 80-byte header with `merkleRoot` at bytes 36..<68 and `time` at 68..<72, little-endian.
    private static func header(merkleRoot: [UInt8], time: UInt32) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4) + [UInt8](repeating: 0x11, count: 32) + merkleRoot
        bytes += [UInt8(time & 0xff), UInt8((time >> 8) & 0xff), UInt8((time >> 16) & 0xff), UInt8(time >> 24)]
        bytes += [UInt8](repeating: 0, count: 8)
        return bytes
    }

    func test_headerAtHeightParsesTheEightyBytesTheChainTrackerSends() async throws {
        let root = [UInt8](repeating: 0x5a, count: 32)
        let bytes = Self.header(merkleRoot: root, time: 1_794_660_480)
        XCTAssertEqual(bytes.count, 80)
        let recorder = URLRecorder()
        let services = OneSatStackServices(
            baseURL: base, http: RoutedHTTP(answer: { _ in (200, bytes) }, recorder: recorder)
        )

        let header = try await services.header(atHeight: 900_123)
        let requested = await recorder.value()

        XCTAssertEqual(requested?.absoluteString, "https://api.example/1sat/chaintracks/headers?height=900123&count=1")
        XCTAssertEqual(header.height, 900_123)
        XCTAssertEqual(header.merkleRoot, root)
        XCTAssertEqual(header.serializedBytes, bytes)
    }

    func test_headerAtHeightRefusesABodyThatIsNotOneHeader() async {
        let services = OneSatStackServices(baseURL: base, http: StubHTTP(status: 200, body: [UInt8](repeating: 0, count: 79)))
        do {
            _ = try await services.header(atHeight: 5)
            XCTFail("expected unreadableResponse")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .unreadableResponse)
        }
    }

    func test_headerAtHeightThrowsAFailureStatus() async {
        let services = OneSatStackServices(baseURL: base, http: StubHTTP(status: 404, body: []))
        do {
            _ = try await services.header(atHeight: 5)
            XCTFail("expected the HTTP failure")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .httpFailure(statusCode: 404))
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
