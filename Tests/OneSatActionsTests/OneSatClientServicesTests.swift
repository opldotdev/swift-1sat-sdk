import Foundation
import OneSatActions
import OneSatClient
import XCTest

/// `Bsv21Client.actionTokenDetails` and `BeefClient` as a `ListingBeefSource`, offline.
final class OneSatClientServicesTests: XCTestCase {
    private actor Scripted: OneSatHTTPTransport {
        private var responses: [(status: Int, body: [UInt8])]
        private(set) var urls: [URL] = []

        init(_ responses: [(status: Int, body: [UInt8])]) {
            self.responses = responses
        }

        func send(
            method _: String,
            url: URL,
            headers _: [String: String],
            body _: [UInt8]?
        ) async throws -> (status: Int, body: [UInt8]) {
            urls.append(url)
            return responses.removeFirst()
        }
    }

    private let base = URL(string: "https://api.example")!
    private let tokenID = String(repeating: "a", count: 64) + "_0"

    private func details(_ json: String) async throws -> OneSatActions.Bsv21TokenDetails {
        let http = Scripted([(200, Array(json.utf8))])
        return try await Bsv21Client(baseURL: base, transport: http).actionTokenDetails(tokenID: tokenID)
    }

    /// The fields a live `GET /1sat/bsv21/<tokenId>` carries, mapped to what the actions read.
    func test_actionTokenDetailsMapsTheOverlayAnswer() async throws {
        let read = try await details(
            #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)","sym":"GOLD","dec":"2","icon":"icon_0"},"status":{"is_active":true,"fee_address":"1Fee","fee_per_output":1000}}"#
        )
        XCTAssertEqual(
            read,
            OneSatActions.Bsv21TokenDetails(
                isActive: true, feeAddress: "1Fee", feePerOutput: 1_000, decimals: 2, symbol: "GOLD", icon: "icon_0"
            )
        )
    }

    func test_noDecimalsReadAsZero() async throws {
        let read = try await details(
            #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)"},"status":{"is_active":false,"fee_address":"1Fee","fee_per_output":0}}"#
        )
        XCTAssertEqual(read.decimals, 0)
        XCTAssertFalse(read.isActive)
        XCTAssertNil(read.symbol)
    }

    func test_aStatusWithoutItsFeeOrDecimalsThatAreNotANumberAreUnreadable() async {
        let answers = [
            #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)"},"status":{"is_active":true,"fee_per_output":1}}"#,
            #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)"},"status":{"fee_address":"1Fee","fee_per_output":1}}"#,
            #"{"tokenId":"\#(tokenID)","token":{"id":"\#(tokenID)","dec":"two"},"status":{"is_active":true,"fee_address":"1Fee","fee_per_output":1}}"#,
        ]
        for answer in answers {
            do {
                _ = try await details(answer)
                XCTFail("expected unreadableResponse for \(answer)")
            } catch {
                XCTAssertEqual(error as? OneSatClientError, .unreadableResponse, answer)
            }
        }
    }

    func test_beefClientIsAListingBeefSource() async throws {
        let txid = String(repeating: "ab", count: 32)
        let http = Scripted([(200, [1, 2, 3])])
        let source: any ListingBeefSource = BeefClient(baseURL: base, transport: http)
        let beef = try await source.beef(forTxid: txid)
        XCTAssertEqual(beef, [1, 2, 3])
        let urls = await http.urls
        XCTAssertEqual(urls.map(\.absoluteString), ["https://api.example/1sat/beef/\(txid)"])
    }
}
