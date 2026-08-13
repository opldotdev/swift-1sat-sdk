import Foundation
import ToolboxServices
import XCTest
@testable import OneSatActions

final class OwnerSyncClientTests: XCTestCase {
    private let txid = String(repeating: "ab", count: 32)

    func test_parseDecodesDefaultFramesAndSkipsSync() throws {
        let sse = """
            event: sync
            data: {"phase":"fetch","total":2}

            data: {"outpoint":"\(txid).0","score":100.5}

            data: {"outpoint":"\(txid).1","score":101.25,"spendTxid":"ff"}

            event: done
            data: {}

            """
        let outputs = try OwnerSyncClient.parse(sse: Array(sse.utf8))
        XCTAssertEqual(
            outputs,
            [
                SyncOutput(outpoint: "\(txid).0", score: 100.5),
                SyncOutput(outpoint: "\(txid).1", score: 101.25, spendTxid: "ff"),
            ]
        )
    }

    func test_errorFrameThrowsTheDataAsTheMessage() {
        let sse = """
            event: error
            data: indexer unavailable

            """
        XCTAssertThrowsError(try OwnerSyncClient.parse(sse: Array(sse.utf8))) { error in
            XCTAssertEqual(error as? OwnerSyncError, .server("indexer unavailable"))
        }
    }

    func test_malformedDataFrameThrows() {
        let sse = """
            data: {"outpoint":"not-enough"}

            event: done
            data: {}

            """
        XCTAssertThrowsError(try OwnerSyncClient.parse(sse: Array(sse.utf8))) { error in
            XCTAssertEqual(error as? OwnerSyncError, .unreadableOutput)
        }
    }

    func test_syncOutputsBuildsOwnerSyncURL() async throws {
        let http = RecordingHTTP()
        let client = OwnerSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            http: http
        )
        _ = try? await client.syncOutputs(owners: ["1abc", "1def"], from: 12.5)
        let recorded = await http.url
        let url = try XCTUnwrap(recorded)
        XCTAssertEqual(url.host, "example.invalid")
        XCTAssertEqual(url.path, "/1sat/owner/sync")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items?.filter { $0.name == "owner" }.map(\.value), ["1abc", "1def"])
        XCTAssertEqual(items?.first(where: { $0.name == "from" })?.value, "12.5")
    }

    func test_httpFailureThrows() async {
        let client = OwnerSyncClient(
            baseURL: URL(string: "https://example.invalid")!,
            http: StubHTTP(status: 503, body: [])
        )
        do {
            _ = try await client.syncOutputs(owners: ["1abc"], from: nil)
            XCTFail("HTTP 503 must throw")
        } catch let error as OwnerSyncError {
            XCTAssertEqual(error, .httpFailure(statusCode: 503))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private struct StubHTTP: HTTPGet {
    let status: Int
    let body: [UInt8]
    func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) { (status, body) }
}

private actor RecordingHTTP: HTTPGet {
    private(set) var url: URL?
    func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
        self.url = url
        return (200, Array("event: done\ndata: {}\n\n".utf8))
    }
}
