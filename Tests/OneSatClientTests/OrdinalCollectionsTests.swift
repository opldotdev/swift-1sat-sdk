import Foundation
import ToolboxServices
import XCTest
@testable import OneSatClient

/// Proves the collections read path: origin/name events survive into `OrdinalOutput`, ORDFS
/// metadata decodes through its double-encoded layer, and grouping shapes what a wallet stacks.
final class OrdinalCollectionsTests: XCTestCase {
    private let address = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2"

    private let itemTxidA = String(repeating: "a", count: 64)
    private let itemTxidB = String(repeating: "b", count: 64)
    private let singleTxid = String(repeating: "c", count: 64)
    private let collectionTxid = String(repeating: "d", count: 64)

    private struct StubHTTP: HTTPGet {
        let status: Int
        let body: [UInt8]

        func get(_ url: URL) async throws -> (status: Int, body: [UInt8]) {
            (status, body)
        }
    }

    /// Records every POST and answers each URL-body pair from a canned table keyed by the
    /// outpoints requested, so one stub serves both metadata rounds of `holdings`.
    private actor PostRecorder {
        private(set) var requests: [(url: URL, body: String)] = []

        func record(url: URL, body: String) {
            requests.append((url, body))
        }
    }

    private struct StubHTTPPost: HTTPPost {
        let recorder: PostRecorder
        /// Maps an outpoint to the JSON value returned for it; unknown outpoints answer null.
        let records: [String: String]

        func post(_ url: URL, body: [UInt8], contentType: String) async throws
            -> (status: Int, body: [UInt8]) {
            let bodyText = String(decoding: body, as: UTF8.self)
            await recorder.record(url: url, body: bodyText)

            guard let request = try? JSONDecoder().decode(
                [String: [String]].self, from: Data(body)
            ), let outpoints = request["outpoints"] else {
                return (400, [])
            }
            let entries = outpoints.map { outpoint in
                "\"\(outpoint)\": \(records[outpoint] ?? "null")"
            }
            return (200, Array("{\(entries.joined(separator: ","))}".utf8))
        }
    }

    // MARK: - Events into OrdinalOutput

    func testOrdinalsCarryOriginAndNameEvents() async throws {
        let sse = """
        event: txo
        data: {"outpoint":"\(itemTxidA).1","score":1,"satoshis":1,"events":["insc","type:image","type:image/png","origin:\(collectionTxid).9","name:Bored Crocs"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"image/png"}}}}

        event: txo
        data: {"outpoint":"\(itemTxidB).0","score":2,"satoshis":1,"events":["insc","type:image/jpeg"],"data":{"insc":{"file":{"hash":"AA==","size":1,"type":"image/jpeg"}}}}

        event: done
        data: {}

        """
        let client = OneSatClient(http: StubHTTP(status: 200, body: Array(sse.utf8)))
        let ordinals = try await client.ordinals(forAddress: address)

        XCTAssertEqual(ordinals.count, 2)
        XCTAssertEqual(ordinals[0].origin, "\(collectionTxid).9")
        XCTAssertEqual(ordinals[0].name, "Bored Crocs")
        // No origin event means the output is its own origin, never a nil identity.
        XCTAssertEqual(ordinals[1].origin, "\(itemTxidB).0")
        XCTAssertNil(ordinals[1].name)
    }

    // MARK: - Metadata decoding

    func testMetadataDecodesDoubleEncodedSubTypeData() async throws {
        let recorder = PostRecorder()
        let post = StubHTTPPost(recorder: recorder, records: [
            "\(itemTxidA).0": """
            {"contentType":"image/jpeg","contentLength":100,
             "map":{"name":"Bored Croc #1","subType":"collectionItem",
                    "subTypeData":"{\\"collectionId\\":\\"\(collectionTxid)_0\\",\\"mintNumber\\":\\"7\\",\\"rarityLabel\\":\\"Rare\\"}",
                    "type":"ord"},
             "origin":"\(itemTxidA).0","outpoint":"\(itemTxidA).0","sequence":0}
            """,
        ])
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        // The underscore form must canonicalise on the way in and match on the way out.
        let records = try await client.metadata(
            forOutpoints: ["\(itemTxidA)_0"], http: post
        )

        let record = try XCTUnwrap(records["\(itemTxidA).0"])
        XCTAssertEqual(record.contentType, "image/jpeg")
        XCTAssertEqual(record.name, "Bored Croc #1")
        XCTAssertEqual(record.subType, "collectionItem")
        XCTAssertEqual(record.collectionID, "\(collectionTxid).0")
        XCTAssertEqual(record.mintNumber, 7)
        XCTAssertEqual(record.rarityLabel, "Rare")
    }

    func testMetadataOmitsNullRecordsAndBatchesRequests() async throws {
        let recorder = PostRecorder()
        let post = StubHTTPPost(recorder: recorder, records: [:])
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        let outpoints = (0..<250).map { "\(String(repeating: "e", count: 64)).\($0)" }
        let records = try await client.metadata(forOutpoints: outpoints, http: post)

        XCTAssertTrue(records.isEmpty)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 3, "250 outpoints must split into 100 + 100 + 50")
        XCTAssertTrue(requests.allSatisfy { $0.url.path.hasSuffix("/1sat/ordfs/metadata") })
    }

    // MARK: - Grouping

    private func itemRecord(txid: String, name: String) -> String {
        """
        {"contentType":"image/png",
         "map":{"name":"\(name)","subType":"collectionItem",
                "subTypeData":"{\\"collectionId\\":\\"\(collectionTxid)_0\\"}","type":"ord"},
         "origin":"\(txid).0","outpoint":"\(txid).0","sequence":0}
        """
    }

    func testHoldingsGroupCollectionsAndLeaveSingles() async throws {
        let recorder = PostRecorder()
        let post = StubHTTPPost(recorder: recorder, records: [
            "\(itemTxidA).0": itemRecord(txid: itemTxidA, name: "Croc #1"),
            "\(itemTxidB).0": itemRecord(txid: itemTxidB, name: "Croc #2"),
            "\(singleTxid).0": """
            {"contentType":"image/jpeg","map":{"name":"Lone Wolf","type":"ord"},
             "origin":"\(singleTxid).0","outpoint":"\(singleTxid).0","sequence":0}
            """,
            "\(collectionTxid).0": """
            {"contentType":"image/jpeg",
             "map":{"name":"Bored Crocs","subType":"collection",
                    "subTypeData":"{\\"description\\":\\"Just crocs\\"}","type":"ord"},
             "origin":"\(collectionTxid).0","outpoint":"\(collectionTxid).0","sequence":0}
            """,
        ])
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        let outputs = [
            OrdinalOutput(txid: itemTxidA, vout: 0, satoshis: 1, contentType: "image/png"),
            OrdinalOutput(txid: itemTxidB, vout: 0, satoshis: 1, contentType: "image/png"),
            OrdinalOutput(txid: singleTxid, vout: 0, satoshis: 1, contentType: "image/jpeg"),
        ]
        let holdings = try await client.holdings(for: outputs, http: post)

        XCTAssertEqual(holdings.collections.count, 1)
        let collection = try XCTUnwrap(holdings.collections.first)
        XCTAssertEqual(collection.id, "\(collectionTxid).0")
        XCTAssertEqual(collection.name, "Bored Crocs")
        XCTAssertEqual(collection.description, "Just crocs")
        XCTAssertEqual(collection.items.count, 2)
        // The collection inscription is an image, so it is its own cover.
        XCTAssertEqual(collection.coverOutpoint, "\(collectionTxid).0")

        XCTAssertEqual(holdings.singles.count, 1)
        XCTAssertEqual(holdings.singles.first?.displayName, "Lone Wolf")
    }

    func testCollectionCoverFallsBackToFirstItemWhenNotAnImage() async throws {
        let recorder = PostRecorder()
        let post = StubHTTPPost(recorder: recorder, records: [
            "\(itemTxidA).0": itemRecord(txid: itemTxidA, name: "Croc #1"),
            "\(collectionTxid).0": """
            {"contentType":"application/json",
             "map":{"name":"Bored Crocs","subType":"collection","type":"ord"},
             "origin":"\(collectionTxid).0","outpoint":"\(collectionTxid).0","sequence":0}
            """,
        ])
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        let outputs = [
            OrdinalOutput(txid: itemTxidA, vout: 0, satoshis: 1, contentType: "image/png")
        ]
        let holdings = try await client.holdings(for: outputs, http: post)

        XCTAssertEqual(holdings.collections.first?.coverOutpoint, "\(itemTxidA).0")
    }

    func testHoldingsGroupEvenWhenCollectionRecordIsMissing() async throws {
        let recorder = PostRecorder()
        let post = StubHTTPPost(recorder: recorder, records: [
            "\(itemTxidA).0": itemRecord(txid: itemTxidA, name: "Croc #1")
        ])
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        let outputs = [
            OrdinalOutput(txid: itemTxidA, vout: 0, satoshis: 1, contentType: "image/png")
        ]
        let holdings = try await client.holdings(for: outputs, http: post)

        XCTAssertEqual(holdings.collections.count, 1)
        XCTAssertNil(holdings.collections.first?.name)
        XCTAssertEqual(holdings.collections.first?.items.count, 1)
    }

    func testLargerCollectionsSortFirst() async throws {
        let otherCollection = String(repeating: "f", count: 64)
        let recorder = PostRecorder()
        var records = [
            "\(itemTxidA).0": itemRecord(txid: itemTxidA, name: "Croc #1"),
            "\(itemTxidB).0": itemRecord(txid: itemTxidB, name: "Croc #2"),
        ]
        records["\(singleTxid).0"] = """
        {"contentType":"image/png",
         "map":{"name":"Fox #1","subType":"collectionItem",
                "subTypeData":"{\\"collectionId\\":\\"\(otherCollection)_0\\"}","type":"ord"},
         "origin":"\(singleTxid).0","outpoint":"\(singleTxid).0","sequence":0}
        """
        let post = StubHTTPPost(recorder: recorder, records: records)
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))

        let outputs = [
            OrdinalOutput(txid: singleTxid, vout: 0, satoshis: 1, contentType: "image/png"),
            OrdinalOutput(txid: itemTxidA, vout: 0, satoshis: 1, contentType: "image/png"),
            OrdinalOutput(txid: itemTxidB, vout: 0, satoshis: 1, contentType: "image/png"),
        ]
        let holdings = try await client.holdings(for: outputs, http: post)

        XCTAssertEqual(holdings.collections.map { $0.items.count }, [2, 1])
    }

    // MARK: - URLs

    func testContentAndImageURLsUseUnderscoreForm() {
        let client = OneSatClient(http: StubHTTP(status: 200, body: []))
        let outpoint = "\(itemTxidA).3"

        XCTAssertEqual(
            client.contentURL(forOutpoint: outpoint).absoluteString,
            "https://api.1sat.app/content/\(itemTxidA)_3"
        )
        let image = client.imageURL(forOutpoint: outpoint, width: 148, height: 148)
        XCTAssertEqual(image.path, "/1sat/ordfs/image/\(itemTxidA)_3")
        XCTAssertEqual(image.query, "w=148&h=148&fit=fill&f=webp")
    }
}
