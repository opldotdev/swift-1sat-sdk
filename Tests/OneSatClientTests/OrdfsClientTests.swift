import Foundation
import ToolboxCore
import XCTest
@testable import OneSatClient

/// `OrdfsClient` and `OrdinalTags` against vectors taken from the TypeScript SDK.
final class OrdfsClientTests: XCTestCase {
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

    private let baseURL = URL(string: "https://api.1sat.app/")!

    private func fixtures() throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(OrdfsFixtures.json.utf8))
    }

    private func cases(_ key: String) throws -> [JSONValue] {
        try XCTUnwrap(try fixtures()[key]?.arrayValue, key)
    }

    private func optionalString(_ value: JSONValue?) -> String? {
        value?.stringValue
    }

    func test_ordinalTagsMatchTypeScript() throws {
        let all = try cases("tagCases")
        XCTAssertEqual(all.count, 13)
        for (index, vector) in all.enumerated() {
            let metadata = vector["metadata"]?.objectValue
            let tags = OrdinalTags.fromMetadata(
                origin: metadata?["origin"]?.stringValue,
                contentType: metadata?["contentType"]?.stringValue,
                map: metadata?["map"]?.objectValue,
                parent: metadata?["parent"]?.stringValue,
                fallbackOrigin: vector["fallbackOrigin"]?.stringValue
            )
            let expected = try XCTUnwrap(vector["tags"]?.arrayValue).compactMap(\.stringValue)
            XCTAssertEqual(tags, expected, "tag case \(index)")
        }
    }

    func test_tagsFromDecodedMetadataMatchTheFieldForm() throws {
        let metadata = OrdfsMetadata(
            outpoint: String(repeating: "a", count: 64) + "_0",
            origin: String(repeating: "a", count: 64) + ".0",
            sequence: 0,
            contentType: "image/png",
            contentLength: 1,
            map: ["app": "1sat.market"]
        )
        XCTAssertEqual(
            OrdinalTags.fromMetadata(metadata),
            ["origin:" + String(repeating: "a", count: 64) + "_0", "app:1sat.market", "type:image/png"]
        )
    }

    func test_nameFromMapMatchesTypeScript() throws {
        for (index, vector) in try cases("nameCases").enumerated() {
            XCTAssertEqual(
                OrdinalTags.nameFromMap(vector["map"]?.objectValue),
                optionalString(vector["name"]),
                "name case \(index)"
            )
        }
    }

    func test_displayNameForCiMatchesTypeScript() throws {
        for (index, vector) in try cases("display").enumerated() {
            XCTAssertEqual(
                OrdinalTags.displayNameForCi(vector["input"]?.stringValue),
                optionalString(vector["output"]),
                "display case \(index)"
            )
        }
    }

    func test_contentTypeTagMatchesTypeScript() throws {
        for (index, vector) in try cases("types").enumerated() {
            XCTAssertEqual(
                OrdinalTags.contentTypeTag(vector["input"]?.stringValue),
                optionalString(vector["output"]),
                "type case \(index)"
            )
        }
    }

    func test_parseMapSubTypeDataMatchesTypeScript() throws {
        for (index, vector) in try cases("std").enumerated() {
            XCTAssertEqual(
                OrdinalTags.parseMapSubTypeData(vector["map"]?.objectValue),
                vector["output"]?.objectValue,
                "subTypeData case \(index)"
            )
        }
    }

    func test_formatOrdinalOutpointMatchesTypeScript() throws {
        for (index, vector) in try cases("outpoints").enumerated() {
            XCTAssertEqual(
                OrdinalOutpoint.format(try XCTUnwrap(vector["input"]?.stringValue)),
                vector["output"]?.stringValue,
                "outpoint case \(index)"
            )
        }
    }

    func test_contentURLMatchesTypeScript() throws {
        for (index, vector) in try cases("urlCases").enumerated() {
            let options = vector["options"]?.objectValue ?? [:]
            let url = OrdfsClient(baseURL: baseURL).contentURL(
                outpoint: try XCTUnwrap(vector["outpoint"]?.stringValue),
                options: OrdfsContentOptions(
                    seq: options["seq"]?.intValue,
                    map: options["map"]?.boolValue ?? false,
                    parent: options["parent"]?.boolValue ?? false,
                    raw: options["raw"]?.boolValue ?? false
                )
            )
            XCTAssertEqual(url.absoluteString, vector["url"]?.stringValue, "url case \(index)")
        }
    }

    func test_bulkMetadataSendsOnePostAndKeysResultsAsProvided() async throws {
        let fixtures = try fixtures()
        let expectedCalls = try XCTUnwrap(fixtures["calls"]?.arrayValue)
        let responseBody = Array(try JSONEncoder().encode(try XCTUnwrap(fixtures["bulk"])))
        let http = ScriptedHTTP(responses: [(200, responseBody)])
        let client = OrdfsClient(baseURL: baseURL, transport: http)

        let a = String(repeating: "a", count: 64)
        let c = String(repeating: "c", count: 64)
        let result = try await client.bulkMetadata(["\(a)_0:-2", "\(c)_1:-2"])

        let recorded = await http.recorded()
        let call = try XCTUnwrap(recorded.first)
        let expected = expectedCalls[0]
        XCTAssertEqual(call.method, expected["method"]?.stringValue)
        XCTAssertEqual(call.url.absoluteString, expected["url"]?.stringValue)
        XCTAssertEqual(call.headers["Content-Type"], expected["contentType"]?.stringValue)
        XCTAssertEqual(call.body.map { String(decoding: $0, as: UTF8.self) }, expected["body"]?.stringValue)

        XCTAssertEqual(result.count, 2)
        let found = try XCTUnwrap(result["\(a)_0:-2"] ?? nil)
        XCTAssertEqual(found.origin, String(repeating: "b", count: 64) + "_0")
        XCTAssertEqual(found.sequence, 2)
        XCTAssertEqual(found.contentLength, 10)
        XCTAssertEqual(OrdinalTags.nameFromMap(found.map), "N")
        XCTAssertEqual(result.keys.contains("\(c)_1:-2"), true)
        XCTAssertNil(result["\(c)_1:-2"] ?? nil)
    }

    func test_metadataURLsMatchTypeScript() async throws {
        let calls = try XCTUnwrap(try fixtures()["calls"]?.arrayValue)
        let body = Array(#"{"outpoint":"x_0","sequence":0,"contentType":"text/plain","contentLength":3}"#.utf8)
        let http = ScriptedHTTP(responses: [(200, body), (200, body)])
        let client = OrdfsClient(baseURL: baseURL, transport: http)
        let outpoint = String(repeating: "a", count: 64) + "_0"

        _ = try await client.metadata(outpoint: outpoint, seq: -1)
        let latest = try await client.metadata(outpoint: outpoint)

        let recorded = await http.recorded()
        XCTAssertEqual(recorded.map(\.method), ["GET", "GET"])
        XCTAssertEqual(recorded[0].url.absoluteString, calls[1]["url"]?.stringValue)
        XCTAssertEqual(recorded[1].url.absoluteString, calls[2]["url"]?.stringValue)
        XCTAssertEqual(latest.contentType, "text/plain")
        XCTAssertNil(latest.origin)
    }

    func test_bulkEntryMissingOptionalMembersStillDecodes() async throws {
        let body = Array(#"{"x_0":{"outpoint":"x_0"},"y_1":null}"#.utf8)
        let client = OrdfsClient(baseURL: baseURL, transport: ScriptedHTTP(responses: [(200, body)]))

        let result = try await client.bulkMetadata(["x_0", "y_1"])

        XCTAssertEqual(result["x_0"] ?? nil, OrdfsMetadata(outpoint: "x_0"))
        XCTAssertNil(result["y_1"] ?? nil)
        XCTAssertEqual(OrdinalTags.fromMetadata(result["x_0"] ?? nil, fallbackOrigin: "x.0"), ["origin:x_0"])
    }

    func test_unparseableBodyIsUnreadable() async throws {
        let client = OrdfsClient(
            baseURL: baseURL,
            transport: ScriptedHTTP(responses: [(200, Array("not json".utf8))])
        )
        do {
            _ = try await client.bulkMetadata(["x_0"])
            XCTFail("expected an error")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        }
    }

    func test_httpFailureSurfacesTheStatus() async throws {
        let http = ScriptedHTTP(responses: [(404, Array("{}".utf8))])
        do {
            _ = try await OrdfsClient(baseURL: baseURL, transport: http).metadata(outpoint: "x_0")
            XCTFail("expected an error")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 404))
        }
    }
}
