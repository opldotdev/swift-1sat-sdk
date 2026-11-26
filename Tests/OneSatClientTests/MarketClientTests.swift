import Foundation
import XCTest
import OneSatSweep
@testable import OneSatClient

/// `MarketClient` (`@1sat/client` `MarketClient`) offline: URLs, decoding of rows captured from
/// mainnet (`Fixtures/market-listings.json`), 404 as no listing, failures, and paging.
final class MarketClientTests: XCTestCase {
    private actor ScriptedHTTP: OneSatHTTPTransport {
        struct Call: Sendable {
            let method: String
            let url: URL
            let headers: [String: String]
            let body: [UInt8]?
        }

        private var calls: [Call] = []
        private var responses: [(status: Int, body: [UInt8])]

        init(_ responses: [(status: Int, body: [UInt8])]) {
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

    private let base = URL(string: "https://api.example")!

    /// The `active`, `sale` and `cancel` arrays of the fixture, as served.
    private func fixture(_ key: String) throws -> [UInt8] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/market-listings", withExtension: "json")
                ?? Bundle.module.url(forResource: "market-listings", withExtension: "json", subdirectory: "Fixtures")
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return Array(try JSONSerialization.data(withJSONObject: try XCTUnwrap(root[key])))
    }

    func test_searchURLCarriesOnlyWhatIsSet() {
        XCTAssertEqual(
            MarketClient.searchURL(baseURL: base).absoluteString,
            "https://api.example/1sat/market/listings?status=active&limit=20&rev=true"
        )
        XCTAssertEqual(
            MarketClient.searchURL(
                baseURL: URL(string: "https://api.example/")!,
                status: .sale, type: "image/svg+xml", query: "pixel fox", limit: 5,
                from: 1795372297.2825608, reverse: false
            ).absoluteString,
            "https://api.example/1sat/market/listings?status=sale&type=image%2Fsvg%2Bxml&q=pixel%20fox&limit=5&from=1795372297.2825608&rev=false"
        )
        let outpoint = String(repeating: "a", count: 64) + ".0"
        XCTAssertEqual(
            MarketClient.listingURL(outpoint: outpoint, baseURL: base).absoluteString,
            "https://api.example/1sat/market/listing/\(outpoint)"
        )
        XCTAssertEqual(
            MarketClient.originURL(origin: outpoint, baseURL: base).absoluteString,
            "https://api.example/1sat/market/origin/\(outpoint)"
        )
        XCTAssertEqual(MarketClient.originsURL(baseURL: base).absoluteString, "https://api.example/1sat/market/origins")
    }

    func test_marketRunsOnMainnetOnly() {
        XCTAssertEqual(OneSatAPI.marketURL(for: .mainnet), OneSatAPI.mainnetURL)
        XCTAssertNil(OneSatAPI.marketURL(for: .testnet))
    }

    func test_activeListingsDecodeAndPageByScore() async throws {
        let http = ScriptedHTTP([(200, try fixture("active"))])
        let page = try await MarketClient(baseURL: base, transport: http).searchListings(limit: 5)
        XCTAssertEqual(page.rows.count, 5)
        let first = page.rows[0]
        XCTAssertEqual(first.outpoint, "dedfffa9755928b5bd0d6cc97ded152be937f26c538322334dfc9d4438b1a377.0")
        XCTAssertEqual(first.score, 1795372297.2825608)
        XCTAssertEqual(first.origin, "25da0379e13867d253537b5a1044ff25c34833f3d34b936cb048a4a7e190efc5.0")
        XCTAssertEqual(first.name, "BOE DHA SOY")
        XCTAssertEqual(first.contentType, "text/html")
        XCTAssertEqual(first.price, 100_000_000)
        XCTAssertEqual(first.seller, "19XfhUxng8NRbX3km5HmuqGARiy9SY79eC")
        XCTAssertNil(first.spend)
        XCTAssertNil(first.spendType)
        XCTAssertNil(first.spendScore)
        XCTAssertEqual(first.status, .active)
        XCTAssertTrue(page.rows.allSatisfy { $0.status == .active })
        // A full page: the next starts after the last row's score.
        XCTAssertEqual(page.nextFrom, page.rows.last?.score)

        let calls = await http.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].method, "GET")
        XCTAssertEqual(calls[0].url, MarketClient.searchURL(baseURL: base, limit: 5))
    }

    func test_soldAndCancelledListingsPageBySpendScore() async throws {
        let http = ScriptedHTTP([(200, try fixture("sale")), (200, try fixture("cancel"))])
        let client = MarketClient(baseURL: base, transport: http)
        let sold = try await client.searchListings(status: .sale, limit: 3)
        XCTAssertEqual(sold.rows.count, 3)
        XCTAssertTrue(sold.rows.allSatisfy { $0.status == .sold && $0.spendType == .sale && $0.spend != nil })
        XCTAssertEqual(sold.rows[0].spend, "044bc29afc5fdbade741398accb9fac8bb2b40df7e525687bdfa989249534d51")
        XCTAssertEqual(sold.rows[0].spendScore, 1791841063.7086637)
        XCTAssertEqual(sold.nextFrom, sold.rows.last?.spendScore)
        XCTAssertNotEqual(sold.nextFrom, sold.rows.last?.score)

        // A short page has no next page.
        let cancelled = try await client.searchListings(status: .cancel, limit: 3)
        XCTAssertEqual(cancelled.rows.count, 2)
        XCTAssertTrue(cancelled.rows.allSatisfy { $0.status == .cancelled })
        XCTAssertNil(cancelled.nextFrom)
    }

    func test_anUnknownSpendIsSpent() throws {
        let row = #"{"outpoint":"a.0","score":1,"spend":"bb","data":{"ordlock":{"price":5,"seller":"1x","spend_type":"unknown"}}}"#
        let listing = try JSONDecoder().decode(MarketListing.self, from: Data(row.utf8))
        XCTAssertEqual(listing.spendType, .unknown("unknown"))
        XCTAssertEqual(listing.status, .spent)
        XCTAssertNil(listing.origin)
    }

    func test_aRowWithoutAnOrdlockIsUnreadable() async {
        let http = ScriptedHTTP([(200, Array(#"[{"outpoint":"a.0","score":1,"data":{}}]"#.utf8))])
        do {
            _ = try await MarketClient(baseURL: base, transport: http).searchListings()
            XCTFail("expected unreadableResponse")
        } catch {
            XCTAssertEqual(error as? OneSatClientError, .unreadableResponse)
        }
    }

    func test_singleLookupsAnswerNilFor404() async throws {
        let one = try JSONSerialization.jsonObject(with: Data(try fixture("active"))) as? [Any]
        let body = Array(try JSONSerialization.data(withJSONObject: try XCTUnwrap(one?.first)))
        let http = ScriptedHTTP([
            (200, body),
            (404, Array(#"{"message":"Listing not found"}"#.utf8)),
            (200, body),
            (404, Array(#"{"message":"No active listing for origin"}"#.utf8)),
        ])
        let client = MarketClient(baseURL: base, transport: http)
        let outpoint = "dedfffa9755928b5bd0d6cc97ded152be937f26c538322334dfc9d4438b1a377.0"
        let found = try await client.listing(outpoint: outpoint)
        XCTAssertEqual(found?.outpoint, outpoint)
        let missing = try await client.listing(outpoint: String(repeating: "0", count: 64) + ".0")
        XCTAssertNil(missing)
        let byOrigin = try await client.listing(origin: "25da0379e13867d253537b5a1044ff25c34833f3d34b936cb048a4a7e190efc5.0")
        XCTAssertEqual(byOrigin?.name, "BOE DHA SOY")
        let unlisted = try await client.listing(origin: String(repeating: "1", count: 64) + "_0")
        XCTAssertNil(unlisted)

        let calls = await http.recorded()
        XCTAssertEqual(calls.map(\.url), [
            MarketClient.listingURL(outpoint: outpoint, baseURL: base),
            MarketClient.listingURL(outpoint: String(repeating: "0", count: 64) + ".0", baseURL: base),
            MarketClient.originURL(origin: "25da0379e13867d253537b5a1044ff25c34833f3d34b936cb048a4a7e190efc5.0", baseURL: base),
            MarketClient.originURL(origin: String(repeating: "1", count: 64) + "_0", baseURL: base),
        ])
    }

    func test_aServerFailureThrowsItsStatus() async {
        let http = ScriptedHTTP([(500, Array(#"{"message":"Failed to get listing: db down"}"#.utf8))])
        do {
            _ = try await MarketClient(baseURL: base, transport: http).listing(outpoint: "a.0")
            XCTFail("expected the HTTP failure")
        } catch let OneSatClientError.httpFailure(status, detail) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(detail?.service, "the market")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func test_originsGoInChunksOfAHundredAndMerge() async throws {
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try fixture("active"))) as? [[String: Any]])
        func answer(_ row: [String: Any]) throws -> [UInt8] {
            let origin = try XCTUnwrap((row["data"] as? [String: Any])?["ordlock"] as? [String: Any])["origin"]
            return Array(try JSONSerialization.data(withJSONObject: [try XCTUnwrap(origin as? String): row]))
        }
        let http = ScriptedHTTP([
            (200, try answer(rows[0])),
            (200, try answer(rows[1])),
            (200, Array("null".utf8)),
        ])
        let origins = (0..<250).map { String(format: "%064x.0", $0) }
        let found = try await MarketClient(baseURL: base, transport: http).listings(origins: origins)
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found["25da0379e13867d253537b5a1044ff25c34833f3d34b936cb048a4a7e190efc5.0"]?.name, "BOE DHA SOY")

        let calls = await http.recorded()
        XCTAssertEqual(calls.count, 3)
        let sent = try calls.map { try JSONDecoder().decode([String].self, from: Data(XCTUnwrap($0.body))) }
        XCTAssertEqual(sent.map(\.count), [100, 100, 50])
        XCTAssertEqual(sent.flatMap { $0 }, origins)
        XCTAssertTrue(calls.allSatisfy {
            $0.method == "POST" && $0.url == MarketClient.originsURL(baseURL: base)
                && $0.headers["Content-Type"] == "application/json"
        })

        let none = try await MarketClient(baseURL: base, transport: ScriptedHTTP([])).listings(origins: [])
        XCTAssertTrue(none.isEmpty)
    }
}
