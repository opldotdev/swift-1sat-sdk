import Foundation
import XCTest
@testable import OneSatClient

/// Offline URL, auth, and decode coverage for `MneeClient`. No live HTTP.
final class MneeClientTests: XCTestCase {
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

    private let baseURL = URL(string: "https://proxy-api.mnee.net")!
    private let apiKey = "92982ec1c0975f31979da515d46bae9f"

    func test_configURLPinsTheProductionRouteAndToken() {
        XCTAssertEqual(
            MneeClient.configURL(baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/config?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_balanceURLPinsTheProductionRouteAndToken() {
        XCTAssertEqual(
            MneeClient.balanceURL(baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/balance?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_utxosURLJoinsAuthWithAmpersandWhenQueryParamsExist() {
        XCTAssertEqual(
            MneeClient.utxosURL(page: 1, size: 1000, order: nil, baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/utxos?page=1&size=1000&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_utxosURLJoinsAuthWithQuestionMarkWhenNoQueryParams() {
        XCTAssertEqual(
            MneeClient.utxosURL(page: nil, size: nil, order: nil, baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/utxos?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_utxosURLIncludesOrderAfterPageAndSize() {
        XCTAssertEqual(
            MneeClient.utxosURL(page: 1, size: 10, order: "desc", baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/utxos?page=1&size=10&order=desc&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_ticketURLPinsTicketIDThenAuth() {
        XCTAssertEqual(
            MneeClient.ticketURL(ticketId: "abc", baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/ticket?ticketID=abc&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_syncURLPrintsAWholeFromScoreWithoutAFraction() {
        XCTAssertEqual(
            MneeClient.syncURL(fromScore: 840000, limit: 50, baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/sync?from=840000&limit=50&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_syncURLPrintsAFractionalFromScoreInShortestForm() {
        XCTAssertEqual(
            MneeClient.syncURL(fromScore: 840000.5, limit: 50, baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/sync?from=840000.5&limit=50&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_syncURLOmitsLimitWhenZero() {
        XCTAssertEqual(
            MneeClient.syncURL(fromScore: 840000, limit: 0, baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/sync?from=840000&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_rawTxURLPinsTheTxidPath() {
        XCTAssertEqual(
            MneeClient.rawTxURL(txid: "deadbeef", baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/tx/deadbeef?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_transferURLPinsTheProductionRouteAndToken() {
        XCTAssertEqual(
            MneeClient.transferURL(baseURL: baseURL, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v2/transfer?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_configURLTrimsOneTrailingSlashFromTheBase() {
        let slashed = URL(string: "https://proxy-api.mnee.net/")!
        XCTAssertEqual(
            MneeClient.configURL(baseURL: slashed, apiKey: apiKey).absoluteString,
            "https://proxy-api.mnee.net/v1/config?auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_configURLUsesTheProvidedApiKey() {
        XCTAssertEqual(
            MneeClient.configURL(baseURL: baseURL, apiKey: "custom-key").absoluteString,
            "https://proxy-api.mnee.net/v1/config?auth_token=custom-key"
        )
    }

    func test_queryNumberRendersWholeAndFractionalValues() {
        XCTAssertEqual(MneeClient.queryNumber(840000), "840000")
        XCTAssertEqual(MneeClient.queryNumber(840000.5), "840000.5")
    }

    func test_getConfigDecodesAFullFixture() async throws {
        let body = #"{"approver":"1Approver","feeAddress":"1Fee","burnAddress":"1Burn","mintAddress":"1Mint","fees":[{"min":0,"max":100000,"fee":100}],"decimals":5,"tokenId":"token-origin"}"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let config = try await client.getConfig()
        let recorded = await transport.recorded()

        XCTAssertEqual(
            config,
            MneeConfig(
                approver: "1Approver",
                feeAddress: "1Fee",
                burnAddress: "1Burn",
                mintAddress: "1Mint",
                fees: [MneeFeeTier(min: 0, max: 100000, fee: 100)],
                decimals: 5,
                tokenId: "token-origin"
            )
        )
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].method, "GET")
        XCTAssertEqual(recorded[0].url, MneeClient.configURL(baseURL: baseURL, apiKey: apiKey))
    }

    func test_getBalancesPostsAddressesInCallerOrder() async throws {
        let body = #"[{"address":"a","amt":100,"precised":0.001},{"address":"b","amt":200,"precised":0.002}]"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let balances = try await client.getBalances(["a", "b"])
        let recorded = await transport.recorded()

        XCTAssertEqual(
            balances,
            [
                MneeBalance(address: "a", amt: 100, precised: 0.001),
                MneeBalance(address: "b", amt: 200, precised: 0.002),
            ]
        )
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].url, MneeClient.balanceURL(baseURL: baseURL, apiKey: apiKey))
        XCTAssertEqual(recorded[0].headers["Content-Type"], "application/json")
        let posted = try JSONDecoder().decode([String].self, from: Data(XCTUnwrap(recorded[0].body)))
        XCTAssertEqual(posted, ["a", "b"])
    }

    func test_getUtxosKeepsTransferAndDeployMintAndDropsTheRest() async throws {
        let transfer = utxoJSON(txid: "aa", op: "transfer", includeTokenOptionals: false, includeCosign: true)
        let mint = utxoJSON(txid: "bb", op: "deploy+mint", includeTokenOptionals: true)
        let burn = utxoJSON(txid: "cc", op: "burn")
        let missing = utxoJSON(txid: "dd", op: nil)
        let body = "[\(transfer),\(mint),\(burn),\(missing)]"
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let utxos = try await client.getUtxos(addresses: ["owner"])

        XCTAssertEqual(utxos.map(\.txid), ["aa", "bb"])
        XCTAssertEqual(utxos[0].data.bsv21?.op, "transfer")
        XCTAssertNil(utxos[0].data.bsv21?.sym)
        XCTAssertNil(utxos[0].data.bsv21?.icon)
        XCTAssertNil(utxos[0].data.bsv21?.dec)
        XCTAssertEqual(utxos[0].data.cosign?.address, "1Cosign")
        XCTAssertEqual(utxos[1].data.bsv21?.op, "deploy+mint")
        XCTAssertEqual(utxos[1].data.bsv21?.sym, "MNEE")
        XCTAssertEqual(utxos[1].data.bsv21?.icon, "icon")
        XCTAssertEqual(utxos[1].data.bsv21?.dec, 5)
    }

    func test_getAllUtxosPagesUntilAShortBatch() async throws {
        let page1 = "[" + (0..<1000).map { utxoJSON(txid: String(format: "%064x", $0), op: "transfer") }.joined(separator: ",") + "]"
        let page2 = "["
            + utxoJSON(txid: String(format: "%064x", 1000), op: "transfer")
            + ","
            + utxoJSON(txid: String(format: "%064x", 1001), op: "transfer")
            + "]"
        let transport = ScriptedHTTP(responses: [
            (200, Array(page1.utf8)),
            (200, Array(page2.utf8)),
        ])
        let client = MneeClient(transport: transport)

        let utxos = try await client.getAllUtxos(addresses: ["owner"])
        let recorded = await transport.recorded()

        XCTAssertEqual(utxos.count, 1002)
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(
            recorded[0].url,
            MneeClient.utxosURL(page: 1, size: 1000, order: nil, baseURL: baseURL, apiKey: apiKey)
        )
        XCTAssertEqual(
            recorded[1].url,
            MneeClient.utxosURL(page: 2, size: 1000, order: nil, baseURL: baseURL, apiKey: apiKey)
        )
    }

    func test_submitRawTxBroadcastFalseDoesNotCallTransport() async throws {
        let transport = ScriptedHTTP(responses: [])
        let client = MneeClient(transport: transport)
        let tx: [UInt8] = [0x01, 0x02, 0x03]

        let result = try await client.submitRawTx(tx: tx, broadcast: false)
        let recorded = await transport.recorded()

        XCTAssertNil(result.ticketId)
        XCTAssertEqual(result.rawtx, tx)
        XCTAssertEqual(recorded.count, 0)
    }

    func test_submitRawTxPostsBase64AndReadsPlainTextTicketId() async throws {
        let tx: [UInt8] = [0x01, 0x02, 0x03]
        let base64 = Data(tx).base64EncodedString()
        let transport = ScriptedHTTP(responses: [(200, Array("ticket-123".utf8))])
        let client = MneeClient(transport: transport)

        let result = try await client.submitRawTx(tx: tx)
        let recorded = await transport.recorded()

        XCTAssertEqual(result.ticketId, "ticket-123")
        XCTAssertNil(result.rawtx)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(recorded[0].url, MneeClient.transferURL(baseURL: baseURL, apiKey: apiKey))
        XCTAssertEqual(recorded[0].headers["Content-Type"], "application/json")
        XCTAssertEqual(
            String(bytes: try XCTUnwrap(recorded[0].body), encoding: .utf8),
            #"{"rawtx":"\#(base64)"}"#
        )
    }

    func test_submitRawTxIncludesCallbackUrlWhenProvided() async throws {
        let tx: [UInt8] = [0x01]
        let transport = ScriptedHTTP(responses: [(200, Array("ticket-1".utf8))])
        let client = MneeClient(transport: transport)

        _ = try await client.submitRawTx(tx: tx, callbackUrl: "https://example.com/cb")
        let recorded = await transport.recorded()
        let posted = try JSONDecoder().decode(
            [String: String].self,
            from: Data(XCTUnwrap(recorded[0].body))
        )

        XCTAssertEqual(posted["rawtx"], Data(tx).base64EncodedString())
        XCTAssertEqual(posted["callback_url"], "https://example.com/cb")
    }

    func test_submitRawTxThrowsHttpFailureOn500() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [(500, [])]))

        do {
            _ = try await client.submitRawTx(tx: [0x00])
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 500))
        } catch {
            XCTFail("expected OneSatClientError.httpFailure, got \(error)")
        }
    }

    func test_submitRawTxThrowsUnreadableResponseOnNonUTF8Body() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [(200, [0xFF])]))

        do {
            _ = try await client.submitRawTx(tx: [0x00])
            XCTFail("expected the unreadable body to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    func test_getTxStatusDecodesSnakeCaseAndNullErrors() async throws {
        let body = #"{"id":"t1","tx_id":"abc","tx_hex":"00","action_requested":"transfer","status":"SUCCESS","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:01Z","errors":null}"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let status = try await client.getTxStatus(ticketId: "t1")
        let recorded = await transport.recorded()

        XCTAssertEqual(
            status,
            MneeTransferStatus(
                id: "t1",
                txid: "abc",
                txHex: "00",
                actionRequested: "transfer",
                status: "SUCCESS",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:01Z",
                errors: nil
            )
        )
        XCTAssertEqual(
            recorded[0].url,
            MneeClient.ticketURL(ticketId: "t1", baseURL: baseURL, apiKey: apiKey)
        )
    }

    func test_fetchRawTxDecodesBase64ToBytes() async throws {
        let tx: [UInt8] = [0x01, 0x02, 0x03]
        let body = #"{"rawtx":"\#(Data(tx).base64EncodedString())"}"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let decoded = try await client.fetchRawTx(txid: "deadbeef")
        let recorded = await transport.recorded()

        XCTAssertEqual(decoded, tx)
        XCTAssertEqual(recorded[0].method, "GET")
        XCTAssertEqual(
            recorded[0].url,
            MneeClient.rawTxURL(txid: "deadbeef", baseURL: baseURL, apiKey: apiKey)
        )
    }

    func test_fetchRawTxThrowsUnreadableResponseWhenRawtxIsMissing() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [(200, Array("{}".utf8))]))

        do {
            _ = try await client.fetchRawTx(txid: "deadbeef")
            XCTFail("expected the missing rawtx field to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    func test_fetchRawTxThrowsUnreadableResponseOnInvalidBase64() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [
            (200, Array(#"{"rawtx":"!!!"}"#.utf8)),
        ]))

        do {
            _ = try await client.fetchRawTx(txid: "deadbeef")
            XCTFail("expected invalid base64 to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    func test_fetchRawTxThrowsHttpFailureOn404() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [(404, [])]))

        do {
            _ = try await client.fetchRawTx(txid: "deadbeef")
            XCTFail("expected the HTTP failure")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .httpFailure(statusCode: 404))
        } catch {
            XCTFail("expected OneSatClientError.httpFailure, got \(error)")
        }
    }

    func test_getTxHistoryDecodesASyncEntry() async throws {
        let body = #"[{"txid":"aa","height":100,"idx":1,"score":840000,"blocktime":1700000000,"rawtx":"AQID","outs":[0,1],"senders":["s"],"receivers":["r"]}]"#
        let transport = ScriptedHTTP(responses: [(200, Array(body.utf8))])
        let client = MneeClient(transport: transport)

        let entries = try await client.getTxHistory(addresses: ["owner"], fromScore: 840000, limit: 50)
        let recorded = await transport.recorded()

        XCTAssertEqual(
            entries,
            [
                MneeSyncEntry(
                    txid: "aa",
                    height: 100,
                    idx: 1,
                    score: 840000,
                    blocktime: 1_700_000_000,
                    rawtx: "AQID",
                    outs: [0, 1],
                    senders: ["s"],
                    receivers: ["r"]
                ),
            ]
        )
        XCTAssertEqual(recorded[0].method, "POST")
        XCTAssertEqual(
            recorded[0].url,
            MneeClient.syncURL(fromScore: 840000, limit: 50, baseURL: baseURL, apiKey: apiKey)
        )
        XCTAssertEqual(recorded[0].headers["Content-Type"], "application/json")
        let posted = try JSONDecoder().decode([String].self, from: Data(XCTUnwrap(recorded[0].body)))
        XCTAssertEqual(posted, ["owner"])
    }

    func test_getTxHistoryLimitZeroOmitsTheLimitParam() async throws {
        let transport = ScriptedHTTP(responses: [(200, Array("[]".utf8))])
        let client = MneeClient(transport: transport)

        _ = try await client.getTxHistory(addresses: ["a"], fromScore: 840000, limit: 0)
        let recorded = await transport.recorded()

        XCTAssertEqual(
            recorded[0].url.absoluteString,
            "https://proxy-api.mnee.net/v1/sync?from=840000&auth_token=92982ec1c0975f31979da515d46bae9f"
        )
    }

    func test_getConfigThrowsUnreadableResponseOnGarbageBody() async {
        let client = MneeClient(transport: ScriptedHTTP(responses: [(200, Array("not-json".utf8))]))

        do {
            _ = try await client.getConfig()
            XCTFail("expected the garbage body to be refused")
        } catch let error as OneSatClientError {
            XCTAssertEqual(error, .unreadableResponse)
        } catch {
            XCTFail("expected OneSatClientError.unreadableResponse, got \(error)")
        }
    }

    private func utxoJSON(
        txid: String,
        op: String?,
        includeTokenOptionals: Bool = false,
        includeCosign: Bool = false
    ) -> String {
        var fields: [String] = []
        if let op {
            var token = #""id":"tok","op":"\#(op)","amt":1"#
            if includeTokenOptionals {
                token += #","sym":"MNEE","icon":"icon","dec":5"#
            }
            fields.append(#""bsv21":{\#(token)}"#)
        }
        if includeCosign {
            fields.append(#""cosign":{"address":"1Cosign","cosigner":"02ab"}"#)
        }
        return #"{"txid":"\#(txid)","vout":0,"outpoint":"\#(txid)_0","satoshis":1,"script":"00","owners":["a"],"senders":["b"],"height":100,"idx":1,"score":840000,"data":{\#(fields.joined(separator: ","))}}"#
    }
}
