import Foundation
import XCTest
import BSVAuth
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import OneSatClient
import OneSatAddresses
import ToolboxActions
import ToolboxAuth
import ToolboxStorage
import ToolboxStorageClient
@testable import OneSatActions
@testable import OneSatTemplates

/// The 1sat.name job client against the routes of 1sat-name `orchestrator/src/routes.ts` and the
/// flow of `frontend/src/mine.ts`, over a BRC-103 peer built from the SDK (no network).
final class NameMiningTests: XCTestCase {

    // MARK: - A 1sat.name peer

    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: String = "{}"
    }

    /// The orchestrator's side: the handshake, then each application request answered in turn.
    actor Peer: HTTPTransport {
        let authenticator: PeerAuthenticator
        private var replies: [Reply]
        private(set) var requests: [BRC104Request] = []

        init(key: PrivateKey, replies: [Reply]) {
            self.authenticator = PeerAuthenticator(wallet: ProtoWallet(rootKey: key))
            self.replies = replies
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            if request.url.path.hasSuffix(BRC104HTTPHeaderName.handshakePath) {
                let actions = try await authenticator.receive(try AuthMessageCodec.decode(request.body ?? []))
                guard case .send(let reply)? = actions.first else { return HTTPResponse(statusCode: 500, body: []) }
                return HTTPResponse(statusCode: 200, body: try AuthMessageCodec.encode(reply))
            }
            let frame = try BRC104HTTPRequestFrame(
                method: request.method, path: request.url.path, query: request.url.query.map { "?" + $0 },
                headers: request.headers.map { BRC104Header(name: $0.key, value: $0.value) }, body: request.body
            )
            let actions = try await authenticator.receive(try BRC104HTTPFrameCodec.decodeRequest(frame))
            guard case .deliver(let delivered)? = actions.first(where: {
                if case .deliver = $0 { return true }
                return false
            }) else { return HTTPResponse(statusCode: 500, body: []) }
            let inner = try BRC104Codec.decodeRequest(delivered.payload)
            requests.append(inner)
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            let answer = replies.removeFirst()
            let reply = try BRC104Response(
                requestID: inner.requestID, status: answer.status,
                headers: answer.headers.map { BRC104Header(name: $0.key, value: $0.value) },
                body: Array(answer.body.utf8)
            )
            guard case .send(let signed) = try await authenticator.makeGeneralMessage(
                payload: try BRC104Codec.encode(reply), using: delivered.sessionID
            ) else { return HTTPResponse(statusCode: 500, body: []) }
            let responseFrame = try BRC104HTTPFrameCodec.encodeResponse(signed)
            return HTTPResponse(
                statusCode: responseFrame.status,
                headers: Dictionary(responseFrame.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }),
                body: responseFrame.body ?? []
            )
        }

        func paymentHeaders() -> [String?] {
            requests.map { $0.headers.first { $0.name == "x-bsv-payment" }?.value }
        }
    }

    private struct NotUsed: Error {}

    /// Real keys; `createAction` is recorded and answered with a fixed Atomic BEEF.
    actor Payer: WalletPublicKeyProviding, WalletHMACOperations, WalletActionOperations {
        let keys: ProtoWallet
        private(set) var createActions: [WalletCreateActionRequest] = []

        init(key: PrivateKey) { self.keys = ProtoWallet(rootKey: key) }

        func getPublicKey(_ request: WalletGetPublicKeyRequest) async throws -> WalletGetPublicKeyResult {
            try await keys.getPublicKey(request)
        }
        func createHMAC(_ request: WalletCreateHMACRequest) async throws -> WalletCreateHMACResult {
            try await keys.createHMAC(request)
        }
        func verifyHMAC(_ request: WalletVerifyHMACRequest) async throws -> WalletVerifyHMACResult {
            try await keys.verifyHMAC(request)
        }
        func createAction(_ request: WalletCreateActionRequest) async throws -> WalletCreateActionResult {
            createActions.append(request)
            return try WalletCreateActionResult(
                transaction: try AtomicBEEF(bytes: try NameMiningTests.paymentBEEF(), limits: StorageLimits.beef)
            )
        }
        func signAction(_ request: WalletSignActionRequest) async throws -> WalletSignActionResult { throw NotUsed() }
        func abortAction(_ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult { throw NotUsed() }
        func listActions(_ request: WalletListActionsRequest) async throws -> WalletListActionsResult { throw NotUsed() }
        func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
            throw NotUsed()
        }
    }

    /// Answers `GET /price`.
    actor PriceHTTP: OneSatHTTPTransport {
        private(set) var urls: [String] = []
        let status: Int
        let body: String
        init(status: Int = 200, body: String) {
            self.status = status
            self.body = body
        }
        func send(method: String, url: URL, headers: [String: String], body: [UInt8]?) async throws -> (status: Int, body: [UInt8]) {
            urls.append("\(method) \(url.absoluteString)")
            return (status, Array(self.body.utf8))
        }
    }

    actor CapturingInternalizer: ActionInternalizer {
        private(set) var requests: [WalletInternalizeActionRequest] = []
        func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
            requests.append(request)
            return WalletInternalizeActionResult(accepted: true)
        }
    }

    actor MemoryProcessed: ProcessedTxStore {
        private(set) var txids: [String]
        init(_ txids: [String] = []) { self.txids = txids }
        func has(_ txid: String) async throws -> Bool { txids.contains(txid) }
        func add(_ txid: String) async throws { if !txids.contains(txid) { txids.append(txid) } }
        func lastScore() async throws -> Double { 0 }
        func setLastScore(_ score: Double) async throws {}
    }

    // MARK: - Fixtures

    /// The TS BRC-105 vector's Atomic BEEF (`mergeTxidOnly(txid); toBinaryAtomic(txid)`).
    static func paymentBEEF() throws -> [UInt8] {
        try Hex.decode(
            "01010101efefefefefefefefefefefefefefefeffbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfb"
                + "0200beef000102efefefefefefefefefefefefefefefeffbfbfbfbfbfbfbfbfbfbfbfbfbfbfbfb",
            maximumDecodedByteCount: 1_000
        )
    }

    private static let jobID = String(repeating: "ab", count: 32)
    private static let receive = "1BgGZ9tcN4rm9KBzDn7KprQz87SZ26SAMH"

    private func keys() throws -> (client: PrivateKey, server: PrivateKey) {
        (try PrivateKey(Array(repeating: 0x11, count: 32)), try PrivateKey(Array(repeating: 0x22, count: 32)))
    }

    private func client(_ replies: [Reply], http: any OneSatHTTPTransport = PriceHTTP(body: "{}")) throws -> (NameMiningClient, Peer, Payer) {
        let keys = try keys()
        let peer = Peer(key: keys.server, replies: replies)
        let session = AuthenticatedSession(
            baseURL: NameMiningClient.defaultBaseURL, wallet: ProtoWallet(rootKey: keys.client), transport: peer
        )
        return (NameMiningClient(session: session, http: http), peer, Payer(key: keys.client))
    }

    private static func paymentRequired(_ satoshis: String = "1000", prefix: String = "cHJlZml4") -> Reply {
        Reply(status: 402, headers: [
            "x-bsv-payment-version": "1.0",
            "x-bsv-payment-satoshis-required": satoshis,
            "x-bsv-payment-derivation-prefix": prefix,
        ], body: #"{"status":"error","code":"ERR_PAYMENT_REQUIRED"}"#)
    }

    private static let created = #"{"jobId":"\#(jobID)","name":"luke","priceSats":1000,"state":"mining"}"#

    /// The mint of `Fixtures/opns-internalize.json` (`mints.mint`): Atomic BEEF of a mint that
    /// delivers `name` at output 2.
    private func mintFixture() throws -> (atomic: [UInt8], txid: String, vout: UInt32, name: String) {
        struct Mint: Decodable { let beef: String }
        struct Fixture: Decodable { let mints: [String: Mint] }
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/opns-internalize", withExtension: "json")
                ?? Bundle.module.url(forResource: "opns-internalize", withExtension: "json", subdirectory: "Fixtures")
        )
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let hex = try XCTUnwrap(fixture.mints["mint"]).beef
            .replacingOccurrences(of: "{contract}", with: Hex.encode(OpNSTemplate.contract))
        let atomic = try Hex.decode(hex, maximumDecodedByteCount: 1_000_000)
        let parsed = try AtomicBEEF(bytes: atomic, limits: WalletBEEFLimits.standard, transactionOrder: .any)
        let subject = try XCTUnwrap(try parsed.beef.transaction(
            for: parsed.subjectTransactionID, limits: WalletBEEFLimits.standard.transactionLimits
        ))
        let delivery = try XCTUnwrap(OpNS.mintNameDelivery(in: subject))
        return (atomic, parsed.subjectTransactionID.displayHex, delivery.vout, delivery.name)
    }

    /// ``mintFixture()`` with its name output paid to the test context's deposit address 0, as
    /// plain BEEF in base64 (the subject's txid changes with it).
    private func ownedMint() throws -> (beef: String, txid: String, vout: UInt32, name: String) {
        let mint = try mintFixture()
        let ours = try DepositAddresses.address(identity: try ActionVectors.identity(), index: 0).publicKeyHash.bytes
        let theirs: [UInt8] = [0x76, 0xa9, 0x14] + (try Hex.decode("fc7250a211deddc70ee5a2738de5f07817351cef", maximumDecodedByteCount: 20))
        var plain = Array(mint.atomic[36...])
        let start = try XCTUnwrap(stride(from: plain.count - theirs.count, through: 0, by: -1).first {
            Array(plain[$0..<($0 + theirs.count)]) == theirs
        })
        plain.replaceSubrange((start + 3)..<(start + 23), with: ours)
        let beef = Data(plain).base64EncodedString()
        let parsed = try AtomicBEEF(
            bytes: try NameMining.atomicBEEF(fromJob: beef), limits: WalletBEEFLimits.standard, transactionOrder: .any
        )
        XCTAssertNotEqual(parsed.subjectTransactionID.displayHex, mint.txid)
        return (beef, parsed.subjectTransactionID.displayHex, mint.vout, mint.name)
    }

    private func context(_ storage: Bsv21CreateStorage) throws -> OneSatContext {
        try bsv21CreateContext(storage: storage, bsv21: nil)
    }

    // MARK: - Price

    func test_priceIsAnOpenGetOfThePrice() async throws {
        let http = PriceHTTP(body: #"{"priceSats":10000,"maxNameLength":64}"#)
        let (client, peer, _) = try client([], http: http)
        let price = try await client.price()
        XCTAssertEqual(price, NameMiningPrice(priceSats: 10_000, maxNameLength: 64))
        let urls = await http.urls
        XCTAssertEqual(urls, ["GET https://1sat.name/price"])
        let signed = await peer.requests
        XCTAssertTrue(signed.isEmpty)
    }

    func test_anUnreadablePriceIsUnreadable() async throws {
        let (client, _, _) = try client([], http: PriceHTTP(body: "<html>"))
        do {
            _ = try await client.price()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .unreadableResponse)
        }
    }

    // MARK: - Job decoding

    func test_aJobDecodesInEveryState() throws {
        func job(_ text: String) throws -> NameMiningJob {
            try JSONDecoder().decode(NameMiningJob.self, from: Data(text.utf8))
        }
        let mining = try job(#"{"jobId":"j","name":"luke","state":"mining","satoshisRemaining":900,"charsRemaining":3,"steps":[]}"#)
        XCTAssertEqual(mining, NameMiningJob(jobId: "j", name: "luke", state: .mining, charsRemaining: 3, satoshisRemaining: 900))

        let failed = try job(#"{"jobId":"j","name":"luke","state":"failed","satoshisRemaining":900,"error":"mining stalled; refund available","steps":[]}"#)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.error, "mining stalled; refund available")

        let complete = try job(#"{"jobId":"j","name":"luke","state":"complete","mintTxid":"t","mintBeef":"AQEBAQ==","steps":[]}"#)
        XCTAssertEqual(complete.state, .complete)
        XCTAssertEqual(complete.mintTxid, "t")
        XCTAssertEqual(complete.mintBeef, "AQEBAQ==")

        let refunded = try job(#"{"jobId":"j","name":"luke","state":"refunded","refund":{"txid":"r","satoshis":800,"derivationPrefix":"\#(Self.jobID)","derivationSuffix":"refund","senderIdentityKey":"02aa","beef":"AQ=="},"steps":[]}"#)
        XCTAssertEqual(refunded.state, .refunded)
        XCTAssertEqual(refunded.refund, .init(
            txid: "r", satoshis: 800, derivationPrefix: Self.jobID, derivationSuffix: "refund",
            senderIdentityKey: "02aa", beef: "AQ=="
        ))

        XCTAssertThrowsError(try job(#"{"jobId":"j","state":"queued"}"#))
    }

    // MARK: - Refusals

    func test_eachRefusalMapsToItsError() {
        let url = URL(string: "https://1sat.name/jobs")!
        func map(_ status: Int, _ body: String) -> NameMiningError {
            NameMiningClient.refusal(status: status, body: Array(body.utf8), operation: "test", method: "POST", url: url)
        }
        XCTAssertEqual(map(400, #"{"error":"invalid name"}"#), .invalidName)
        XCTAssertEqual(map(400, #"{"error":"invalid receiveAddress"}"#), .invalidReceiveAddress)
        XCTAssertEqual(map(400, #"{"error":"invalid request body"}"#), .refused(status: 400, message: "invalid request body"))
        XCTAssertEqual(map(400, #"{"status":"error","code":"ERR_PAYMENT_INVALID","description":"bad"}"#), .paymentRefused(code: "ERR_PAYMENT_INVALID"))
        XCTAssertEqual(map(400, #"{"status":"error","code":"ERR_PAYMENT_FAILED","description":"bad"}"#), .paymentRefused(code: "ERR_PAYMENT_FAILED"))
        XCTAssertEqual(map(400, #"{"status":"error","code":"ERR_INVALID_DERIVATION_PREFIX"}"#), .paymentRefused(code: "ERR_INVALID_DERIVATION_PREFIX"))
        XCTAssertEqual(map(400, #"{"status":"error","description":"malformed x-bsv-payment header"}"#), .paymentRefused(code: nil))
        XCTAssertEqual(map(404, #"{"error":"job not found"}"#), .jobNotFound)
        XCTAssertEqual(map(409, #"{"error":"name already claimed"}"#), .nameClaimed)
        XCTAssertEqual(map(409, #"{"error":"job is still in progress"}"#), .jobInProgress)
        XCTAssertEqual(map(409, #"{"error":"job already resolved"}"#), .jobAlreadyResolved)
        XCTAssertEqual(map(502, #"{"error":"payment broadcast failed: arc down"}"#), .paymentBroadcastFailed)
        XCTAssertEqual(map(503, #"{"error":"mine tip unavailable for this name"}"#), .mineTipUnavailable)
        XCTAssertEqual(map(500, "oops"), .refused(status: 500, message: "oops"))
        for error in [NameMiningError.invalidName, .nameClaimed, .refundNotFilable, .priceChanged(confirmed: 1, asked: 2)] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func test_aClaimedNameIsRefusedBeforeAnyPayment() async throws {
        let (client, peer, payer) = try client([Reply(status: 409, body: #"{"error":"name already claimed"}"#)])
        do {
            _ = try await client.createJob(
                name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000, onPayment: { _ in }
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .nameClaimed)
        }
        let created = await payer.createActions
        XCTAssertTrue(created.isEmpty)
        let headers = await peer.paymentHeaders()
        XCTAssertEqual(headers, [nil])
    }

    // MARK: - Create, resume

    func test_createJobPaysTheConfirmedPriceAndReadsTheJob() async throws {
        let (client, peer, payer) = try client([Self.paymentRequired(), Reply(status: 201, body: Self.created)])
        let seen = PaymentBox()
        let job = try await client.createJob(
            name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000,
            onPayment: { await seen.set($0) }
        )
        XCTAssertEqual(job, NameMiningJob(jobId: Self.jobID, name: "luke", state: .mining, priceSats: 1000))

        let created = await payer.createActions
        XCTAssertEqual(created.count, 1)
        XCTAssertEqual(created.first?.outputs?.map(\.satoshis), [1000])
        XCTAssertEqual(created.first?.description, "Payment for request to https://1sat.name")

        let payment = try await XCTUnwrapAsync(await seen.payment)
        XCTAssertEqual(payment.satoshisRequired, 1000)
        XCTAssertEqual(payment.derivationPrefix, "cHJlZml4")
        let requests = await peer.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(requests.map(\.path), ["/jobs", "/jobs"])
        XCTAssertEqual(requests.first.flatMap { $0.body.map { String(decoding: $0, as: UTF8.self) } },
                       #"{"name":"luke","receiveAddress":"\#(Self.receive)"}"#)
        let headers = await peer.paymentHeaders()
        XCTAssertEqual(headers, [nil, payment.headerValue])
    }

    func test_anExistingJobIsReturnedWithoutPaying() async throws {
        let (client, peer, payer) = try client([Reply(status: 200, body: Self.created)])
        let seen = PaymentBox()
        let job = try await client.createJob(
            name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000,
            onPayment: { await seen.set($0) }
        )
        XCTAssertEqual(job.jobId, Self.jobID)
        XCTAssertEqual(job.state, .mining)
        let created = await payer.createActions
        XCTAssertTrue(created.isEmpty)
        let payment = await seen.payment
        XCTAssertNil(payment)
        let count = await peer.requests.count
        XCTAssertEqual(count, 1)
    }

    func test_aChangedPriceIsRefusedBeforeAnyCreateAction() async throws {
        let (client, peer, payer) = try client([Self.paymentRequired("2000")])
        let seen = PaymentBox()
        do {
            _ = try await client.createJob(
                name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000,
                onPayment: { await seen.set($0) }
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .priceChanged(confirmed: 1000, asked: 2000))
        }
        let created = await payer.createActions
        XCTAssertTrue(created.isEmpty)
        let payment = await seen.payment
        XCTAssertNil(payment)
        let count = await peer.requests.count
        XCTAssertEqual(count, 1)
    }

    func test_aRefusalAfterThePaymentNamesThePayment() async throws {
        let (client, _, payer) = try client([
            Self.paymentRequired(), Reply(status: 409, body: #"{"error":"name already claimed"}"#),
        ])
        let seen = PaymentBox()
        do {
            _ = try await client.createJob(
                name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000,
                onPayment: { await seen.set($0) }
            )
            XCTFail("expected a refusal")
        } catch {
            let payment = try await XCTUnwrapAsync(await seen.payment)
            XCTAssertEqual(
                error as? NameMiningError,
                .refusedAfterPayment(transactionID: payment.transactionID, reason: .nameClaimed)
            )
            XCTAssertFalse((error as? NameMiningError)?.errorDescription?.isEmpty ?? true)
        }
        let created = await payer.createActions
        XCTAssertEqual(created.count, 1)
    }

    func test_oneClaimMakesOnePaymentAtMost() async throws {
        let (client, _, payer) = try client(
            [Self.paymentRequired()] + Array(repeating: Self.paymentRequired(prefix: "b3RoZXI="), count: 8)
        )
        let seen = PaymentBox()
        do {
            _ = try await client.createJob(
                name: "luke", receiveAddress: Self.receive, payer: payer, expectedPriceSats: 1000,
                onPayment: { await seen.set($0) }
            )
            XCTFail("expected a refusal")
        } catch {
            XCTAssertTrue(error is BRC105Error || error is NameMiningError, "\(error)")
        }
        let created = await payer.createActions
        XCTAssertEqual(created.count, 1)
    }

    func test_resumeSendsTheSavedPaymentWithoutANewOne() async throws {
        let (client, peer, payer) = try client([Reply(status: 201, body: Self.created)])
        let keys = try keys()
        let saved = try BRC105Payment(
            derivationPrefix: "cHJlZml4", derivationSuffix: "c3VmZml4",
            serverIdentityKey: Hex.encode(keys.server.publicKey.compressedBytes),
            satoshisRequired: 1000, transaction: try Self.paymentBEEF()
        )
        let job = try await client.resumeJob(name: "luke", receiveAddress: Self.receive, payment: saved)
        XCTAssertEqual(job.jobId, Self.jobID)
        let headers = await peer.paymentHeaders()
        XCTAssertEqual(headers, [saved.headerValue])
        let created = await payer.createActions
        XCTAssertTrue(created.isEmpty)
    }

    func test_resumeNeverPaysAgainWhenAskedForANewPayment() async throws {
        let (client, peer, _) = try client([
            Self.paymentRequired(prefix: "b3RoZXI="), Self.paymentRequired(prefix: "b3RoZXI="),
            Self.paymentRequired(prefix: "b3RoZXI="),
        ])
        let keys = try keys()
        let saved = try BRC105Payment(
            derivationPrefix: "cHJlZml4", derivationSuffix: "c3VmZml4",
            serverIdentityKey: Hex.encode(keys.server.publicKey.compressedBytes),
            satoshisRequired: 1000, transaction: try Self.paymentBEEF()
        )
        do {
            _ = try await client.resumeJob(name: "luke", receiveAddress: Self.receive, payment: saved)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .resumeWouldPayAgain)
        }
        let headers = await peer.paymentHeaders()
        XCTAssertEqual(headers, Array(repeating: saved.headerValue, count: 3))
    }

    func test_aResumeRefusedNamesTheSavedPayment() async throws {
        let (client, _, _) = try client([Reply(status: 409, body: #"{"error":"name already claimed"}"#)])
        let keys = try keys()
        let saved = try BRC105Payment(
            derivationPrefix: "cHJlZml4", derivationSuffix: "c3VmZml4",
            serverIdentityKey: Hex.encode(keys.server.publicKey.compressedBytes),
            satoshisRequired: 1000, transaction: try Self.paymentBEEF()
        )
        do {
            _ = try await client.resumeJob(name: "luke", receiveAddress: Self.receive, payment: saved)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(
                error as? NameMiningError,
                .refusedAfterPayment(transactionID: saved.transactionID, reason: .nameClaimed)
            )
        }
    }

    // MARK: - Status, list, refund

    func test_jobJobsAndRefundUseTheirRoutes() async throws {
        let status = #"{"jobId":"\#(Self.jobID)","name":"luke","state":"failed","error":"name claimed by another miner; refund available","steps":[]}"#
        let list = #"{"jobs":[{"jobId":"\#(Self.jobID)","name":"luke","state":"mining","charsRemaining":2}]}"#
        let refund = #"{"jobId":"\#(Self.jobID)","txid":"r","satoshis":800,"derivationPrefix":"\#(Self.jobID)","derivationSuffix":"refund","senderIdentityKey":"02aa","beef":"AQ=="}"#
        let (client, peer, _) = try client([
            Reply(status: 200, body: status), Reply(status: 200, body: list), Reply(status: 200, body: refund),
            Reply(status: 404, body: #"{"error":"job not found"}"#),
        ])
        let job = try await client.job(id: Self.jobID)
        XCTAssertEqual(job.state, .failed)
        let jobs = try await client.jobs()
        XCTAssertEqual(jobs, [NameMiningJob(jobId: Self.jobID, name: "luke", state: .mining, charsRemaining: 2)])
        let refunded = try await client.refund(id: Self.jobID)
        XCTAssertEqual(refunded, NameMiningJob(jobId: Self.jobID, state: .refunded, refund: .init(
            txid: "r", satoshis: 800, derivationPrefix: Self.jobID, derivationSuffix: "refund",
            senderIdentityKey: "02aa", beef: "AQ=="
        )))
        do {
            _ = try await client.job(id: Self.jobID)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .jobNotFound)
        }
        do {
            _ = try await client.refund(id: "../price")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .invalidJobID)
        }
        let requests = await peer.requests
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "GET /jobs/\(Self.jobID)", "GET /jobs", "POST /jobs/\(Self.jobID)/refund", "GET /jobs/\(Self.jobID)",
        ])
    }

    // MARK: - BEEF

    func test_atomicBEEFPassesThroughAndPlainBEEFBecomesAtomicOfItsLastTransaction() throws {
        let mint = try mintFixture()
        let atomicBase64 = Data(mint.atomic).base64EncodedString()
        XCTAssertEqual(try NameMining.atomicBEEF(fromJob: atomicBase64), mint.atomic)

        let plain = Array(mint.atomic[36...])
        XCTAssertFalse(OneSatBEEF.isAtomic(plain))
        let converted = try NameMining.atomicBEEF(fromJob: Data(plain).base64EncodedString())
        let parsed = try AtomicBEEF(bytes: converted, limits: WalletBEEFLimits.standard, transactionOrder: .any)
        XCTAssertEqual(parsed.subjectTransactionID.displayHex, mint.txid)
        XCTAssertEqual(converted, mint.atomic)

        XCTAssertThrowsError(try NameMining.atomicBEEF(fromJob: "not base64!")) {
            XCTAssertEqual($0 as? NameMiningError, .unreadableBEEF)
        }
        XCTAssertThrowsError(try NameMining.atomicBEEF(fromJob: "AAAA")) {
            XCTAssertEqual($0 as? NameMiningError, .unreadableBEEF)
        }
    }

    // MARK: - Filing the mint

    func test_fileMintFilesTheNameUnderDepositKeyZeroAndMarksItProcessed() async throws {
        let mint = try ownedMint()
        let storage = try Bsv21CreateStorage.make(rows: [])
        let internalizer = CapturingInternalizer()
        let processed = MemoryProcessed()
        let job = NameMiningJob(jobId: Self.jobID, name: mint.name, state: .complete, mintTxid: mint.txid,
                                mintBeef: mint.beef)

        let filed = try await NameMining.fileMint(job, ctx: try context(storage), internalizer: internalizer, processed: processed)

        XCTAssertEqual(filed.txid, mint.txid)
        XCTAssertEqual(filed.outpoint, "\(mint.txid).\(mint.vout)")
        XCTAssertEqual(filed.name, mint.name)
        XCTAssertFalse(filed.alreadyFiled)
        XCTAssertEqual(filed.outcome, .filed)
        let marked = await processed.txids
        XCTAssertEqual(marked, [mint.txid])

        let origin = "origin:\(mint.txid)_\(mint.vout)"
        let lists = await storage.listRequests
        XCTAssertEqual(lists.map(\.basket), ["opns"])
        XCTAssertEqual(lists.map(\.tags), [[origin]])
        XCTAssertEqual(lists.map(\.tagQueryMode), ["all"])

        let requests = await internalizer.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.transaction.subjectTransactionID.displayHex, mint.txid)
        XCTAssertEqual(request.outputs.map(\.outputIndex), [mint.vout])
        guard case .basketInsertion(let insertion) = request.outputs[0].remittance else {
            return XCTFail("not a basket insertion")
        }
        XCTAssertEqual(insertion.basket, "opns")
        XCTAssertTrue(insertion.tags.contains(origin))
        XCTAssertTrue(insertion.tags.contains("name:\(mint.name)"))
        let instructions = try XCTUnwrap(insertion.customInstructions)
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(instructions.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["protocolID"] as? [AnyHashable], [0, "onesat"])
        XCTAssertEqual(decoded["keyID"] as? String, "1sat 0")
        XCTAssertEqual(decoded["counterparty"] as? String, "self")
    }

    func test_fileMintDoesNotFileANameAlreadyInTheBasket() async throws {
        let mint = try ownedMint()
        let storage = try Bsv21CreateStorage.make(rows: [[
            "outpoint": "\(mint.txid).\(mint.vout)", "satoshis": 1, "spendable": true,
        ]])
        let internalizer = CapturingInternalizer()
        let processed = MemoryProcessed([mint.txid])
        let job = NameMiningJob(jobId: Self.jobID, state: .complete, mintBeef: mint.beef)

        let filed = try await NameMining.fileMint(job, ctx: try context(storage), internalizer: internalizer, processed: processed)

        XCTAssertTrue(filed.alreadyFiled)
        XCTAssertEqual(filed.outcome, .alreadyInOpns)
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
        let marked = await processed.txids
        XCTAssertEqual(marked, [mint.txid])
    }

    func test_fileMintDoesNotFileAMintDepositSyncProcessed() async throws {
        let mint = try ownedMint()
        let storage = try Bsv21CreateStorage.make(rows: [])
        let internalizer = CapturingInternalizer()
        let job = NameMiningJob(jobId: Self.jobID, state: .complete, mintBeef: mint.beef)

        let filed = try await NameMining.fileMint(
            job, ctx: try context(storage), internalizer: internalizer, processed: MemoryProcessed([mint.txid])
        )

        XCTAssertTrue(filed.alreadyFiled)
        XCTAssertEqual(filed.outcome, .processedByDepositSync)
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
        let lists = await storage.listRequests
        XCTAssertEqual(lists.map(\.basket), ["opns"])
    }

    func test_fileMintFilesNothingThatIsNotThisWalletsOrNotTheJobs() async throws {
        let foreign = try mintFixture()
        let owned = try ownedMint()
        let storage = try Bsv21CreateStorage.make(rows: [])
        let internalizer = CapturingInternalizer()
        for job in [
            NameMiningJob(jobId: Self.jobID, state: .complete, mintBeef: Data(foreign.atomic).base64EncodedString()),
            NameMiningJob(jobId: Self.jobID, state: .complete, mintTxid: foreign.txid, mintBeef: owned.beef),
            NameMiningJob(jobId: Self.jobID, name: "other", state: .complete, mintBeef: owned.beef),
        ] {
            do {
                _ = try await NameMining.fileMint(job, ctx: try context(storage), internalizer: internalizer, processed: MemoryProcessed())
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? NameMiningError, .mintNotForThisWallet)
            }
        }
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
        let methods = await storage.methods
        XCTAssertTrue(methods.isEmpty)
        // The job's name matches whatever its case.
        let filed = try await NameMining.fileMint(
            NameMiningJob(jobId: Self.jobID, name: owned.name.uppercased(), state: .complete, mintTxid: owned.txid.uppercased(), mintBeef: owned.beef),
            ctx: try context(storage), internalizer: internalizer
        )
        XCTAssertEqual(filed.outcome, .filed)
    }

    func test_fileMintNeedsACompleteJobWithItsBEEF() async throws {
        let storage = try Bsv21CreateStorage.make(rows: [])
        let internalizer = CapturingInternalizer()
        for (job, expected) in [
            (NameMiningJob(jobId: Self.jobID, state: .mining), NameMiningError.wrongState(.mining)),
            (NameMiningJob(jobId: Self.jobID, state: .complete), .missingMintBEEF),
        ] {
            do {
                _ = try await NameMining.fileMint(job, ctx: try context(storage), internalizer: internalizer)
                XCTFail("expected a refusal")
            } catch {
                XCTAssertEqual(error as? NameMiningError, expected)
            }
        }
    }

    // MARK: - Filing the refund

    private func refundedJob(name: String?, suffix: String) throws -> (NameMiningJob, PrivateKey) {
        let mint = try mintFixture()
        let sender = try PrivateKey(Array(repeating: 0x22, count: 32))
        let job = NameMiningJob(jobId: Self.jobID, name: name, state: .refunded, refund: .init(
            txid: mint.txid, satoshis: 800, derivationPrefix: Self.jobID, derivationSuffix: suffix,
            senderIdentityKey: Hex.encode(sender.publicKey.compressedBytes),
            beef: Data(mint.atomic).base64EncodedString()
        ))
        return (job, sender)
    }

    func test_fileRefundFilesOutputZeroAsAWalletPayment() async throws {
        for (name, description) in [("luke", "opns mine refund luke"), (nil, "opns mine refund \(Self.jobID)")] {
            let (job, sender) = try refundedJob(name: name, suffix: "c3VmZml4")
            let internalizer = CapturingInternalizer()
            try await NameMining.fileRefund(job, internalizer: internalizer)
            let requests = await internalizer.requests
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(request.description, description)
            XCTAssertEqual(request.outputs.map(\.outputIndex), [0])
            guard case .walletPayment(let payment) = request.outputs[0].remittance else {
                return XCTFail("not a wallet payment")
            }
            XCTAssertEqual(payment.derivationPrefix.base64, Self.jobID)
            XCTAssertEqual(payment.derivationSuffix.base64, "c3VmZml4")
            XCTAssertEqual(payment.senderIdentityKey.compressedBytes, sender.publicKey.compressedBytes)
        }
    }

    /// 1sat.name `REFUND_SUFFIX = 'refund'` is not canonical base64: the wallet is not asked.
    func test_theLiteralRefundSuffixIsNotFilable() async throws {
        let (job, _) = try refundedJob(name: "luke", suffix: "refund")
        let internalizer = CapturingInternalizer()
        do {
            try await NameMining.fileRefund(job, internalizer: internalizer)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? NameMiningError, .refundNotFilable)
        }
        let requests = await internalizer.requests
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: - Receive address

    func test_theReceiveAddressIsDepositAddressZero() throws {
        let identity = try keys().client
        XCTAssertEqual(
            try NameMining.receiveAddress(identity: identity),
            try DepositAddresses.address(identity: identity, index: 0).description
        )
        XCTAssertEqual(NameMining.depositKeyID, "1sat 0")
    }
}

private actor PaymentBox {
    private(set) var payment: BRC105Payment?
    func set(_ payment: BRC105Payment) { self.payment = payment }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
