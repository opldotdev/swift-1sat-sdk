import Foundation
import XCTest
@testable import OneSatClient

/// Offline URL pins and scripted-transport decode coverage for `OpnsClient`.
final class OpnsClientTests: XCTestCase {
    private actor ScriptedHTTP: OneSatHTTPTransport {
        struct Call: Sendable {
            let method: String
            let url: URL
            let headers: [String: String]
            let body: [UInt8]?
        }

        private var calls: [Call] = []
        private var responses: [(status: Int, body: [UInt8])]

        init(responses: [(status: Int, body: [UInt8])]) {
            self.responses = responses
        }

        func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: [UInt8]?
        ) async throws -> (status: Int, body: [UInt8]) {
            calls.append(Call(method: method, url: url, headers: headers, body: body))
            return responses.removeFirst()
        }

        func recorded() -> [Call] { calls }
    }

    private let baseURL = URL(string: "https://api.1sat.app")!
    private let outpoint = String(repeating: "a", count: 64) + "_0"

    func test_originURLPinsTheUnencodedName() {
        XCTAssertEqual(
            OpnsClient.originURL(name: "alice", baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/origin/alice"
        )
    }

    func test_originURLPercentEncodesASpace() {
        XCTAssertEqual(
            OpnsClient.originURL(name: "a lice", baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/origin/a%20lice"
        )
    }

    func test_originURLPercentEncodesASlash() {
        XCTAssertEqual(
            OpnsClient.originURL(name: "a/lice", baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/origin/a%2Flice"
        )
    }

    func test_originURLPercentEncodesAPlus() {
        XCTAssertEqual(
            OpnsClient.originURL(name: "a+lice", baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/origin/a%2Blice"
        )
    }

    func test_originURLTrimsOneTrailingSlashFromTheBase() {
        let slashed = URL(string: "https://api.1sat.app/")!
        XCTAssertEqual(
            OpnsClient.originURL(name: "alice", baseURL: slashed).absoluteString,
            "https://api.1sat.app/1sat/opns/origin/alice"
        )
    }

    func test_mineURLPinsTheRoute() {
        XCTAssertEqual(
            OpnsClient.mineURL(name: "alice", baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/mine/alice"
        )
    }

    func test_originsURLPinsTheRoute() {
        XCTAssertEqual(
            OpnsClient.originsURL(baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/opns/origins"
        )
    }

    func test_metadataURLPinsLatestSequence() {
        XCTAssertEqual(
            OpnsClient.metadataURL(outpoint: outpoint, seq: -1, baseURL: baseURL).absoluteString,
            "https://api.1sat.app/1sat/ordfs/metadata/\(outpoint):-1"
        )
    }

    func test_originDecodesNameAndOutpoint() async throws {
        let body = #"{"name":"alice","outpoint":"\#(outpoint)"}"#
        let client = OpnsClient(transport: ScriptedHTTP(responses: [(200, Array(body.utf8))]))

        let origin = try await client.origin(forName: "alice")

        XCTAssertEqual(origin, OpnsOrigin(name: "alice", outpoint: outpoint))
    }

    func test_mineDecodesOutpointAndDomain() async throws {
        let body = #"{"outpoint":"\#(outpoint)","domain":"alice"}"#
        let client = OpnsClient(transport: ScriptedHTTP(responses: [(200, Array(body.utf8))]))

        let mine = try await client.mine(forName: "alice")

        XCTAssertEqual(mine, OpnsMine(outpoint: outpoint, domain: "alice"))
    }

    func test_validateOriginsPostsTheOutpointArray() async throws {
        let transport = ScriptedHTTP(responses: [
            (200, Array(#"{"a_0":true,"b_1":false}"#.utf8)),
        ])
        let client = OpnsClient(transport: transport)

        let result = try await client.validateOrigins(["a_0", "b_1"])
        let recorded = await transport.recorded()

        XCTAssertEqual(result, ["a_0": true, "b_1": false])
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].url, OpnsClient.originsURL(baseURL: baseURL))
        XCTAssertEqual(recorded[0].headers["Content-Type"], "application/json")
        let posted = try JSONDecoder().decode([String].self, from: Data(XCTUnwrap(recorded[0].body)))
        XCTAssertEqual(posted, ["a_0", "b_1"])
    }

    func test_metadataRequestsTheSequenceAndDecodesTheOutpoint() async throws {
        let latest = String(repeating: "b", count: 64) + "_1"
        let body = #"{"outpoint":"\#(latest)","origin":"\#(outpoint)","sequence":3,"contentType":"application/op-ns","contentLength":4,"map":{"name":"x"}}"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = OpnsClient(transport: transport)

        let metadata = try await client.metadata(outpoint: outpoint, seq: -1)
        let recorded = await transport.recorded()

        XCTAssertEqual(metadata, OrdfsMetadata(
            outpoint: latest,
            origin: outpoint,
            sequence: 3,
            contentType: "application/op-ns",
            contentLength: 4
        ))
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].method, "GET")
        XCTAssertEqual(
            recorded[0].url,
            OpnsClient.metadataURL(outpoint: outpoint, seq: -1, baseURL: baseURL)
        )
    }

    func test_metadataNeedsAnOutpoint() async {
        let client = OpnsClient(transport: ScriptedHTTP(responses: [
            (200, Array(#"{"sequence":3}"#.utf8)),
        ]))

        do {
            _ = try await client.metadata(outpoint: outpoint, seq: -1)
            XCTFail("expected a body without an outpoint to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    func test_originThrowsHttpFailureOn404() async {
        let client = OpnsClient(transport: ScriptedHTTP(responses: [(404, [])]))

        do {
            _ = try await client.origin(forName: "alice")
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 404))
        } catch {
            XCTFail("expected OneSatClientError.httpFailure, got \(error)")
        }
    }

    func test_originThrowsUnreadableResponseOnGarbageBody() async {
        let client = OpnsClient(transport: ScriptedHTTP(responses: [
            (200, Array("not-json".utf8)),
        ]))

        do {
            _ = try await client.origin(forName: "alice")
            XCTFail("expected the garbage body to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }
}
