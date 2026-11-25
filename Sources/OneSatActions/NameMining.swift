import Foundation
import BSVCore
import BSVKeys
import BSVTransaction
import BSVWallet
import OneSatAddresses
import OneSatClient
import OneSatSweep
import ToolboxActions
import ToolboxAuth
import ToolboxCore
import ToolboxStorage

/// Paid OpNS mining against the 1sat.name orchestrator, as the 1sat-name app's
/// `frontend/src/mine.ts` does it (`mineName`, `mineStatus`, `mineRefund`, `atomicBeefFromJob`,
/// `internalizeMint`, `internalizeRefund`).
///
/// The service runs on the site's own origin: `GET /price` is open, every `/jobs` route is
/// BRC-103 authenticated, and `POST /jobs` is paid with BRC-105. A job's id is its payment's txid.
public struct NameMiningJob: Equatable, Sendable, Decodable {
    public enum State: String, Equatable, Sendable, Decodable {
        case mining, failed, complete, refunded
    }

    /// What the buyer needs to file a refund: the BRC-29 remittance of output 0 of `beef`.
    public struct Refund: Equatable, Sendable, Decodable {
        public let txid: String?
        public let satoshis: UInt64
        public let derivationPrefix: String
        public let derivationSuffix: String
        public let senderIdentityKey: String
        /// Atomic BEEF (or plain BEEF) of the refund, base64.
        public let beef: String?

        public init(
            txid: String?, satoshis: UInt64, derivationPrefix: String, derivationSuffix: String,
            senderIdentityKey: String, beef: String?
        ) {
            self.txid = txid
            self.satoshis = satoshis
            self.derivationPrefix = derivationPrefix
            self.derivationSuffix = derivationSuffix
            self.senderIdentityKey = senderIdentityKey
            self.beef = beef
        }
    }

    /// The payment's txid.
    public let jobId: String
    public let name: String?
    public let state: State
    public let charsRemaining: Int?
    public let satoshisRemaining: UInt64?
    /// The price charged; only `POST /jobs` answers with it.
    public let priceSats: UInt64?
    public let mintTxid: String?
    /// Atomic BEEF (or plain BEEF) of the mint, base64. Only a single job's status carries it.
    public let mintBeef: String?
    public let refund: Refund?
    public let error: String?

    public init(
        jobId: String, name: String? = nil, state: State, charsRemaining: Int? = nil,
        satoshisRemaining: UInt64? = nil, priceSats: UInt64? = nil, mintTxid: String? = nil,
        mintBeef: String? = nil, refund: Refund? = nil, error: String? = nil
    ) {
        self.jobId = jobId
        self.name = name
        self.state = state
        self.charsRemaining = charsRemaining
        self.satoshisRemaining = satoshisRemaining
        self.priceSats = priceSats
        self.mintTxid = mintTxid
        self.mintBeef = mintBeef
        self.refund = refund
        self.error = error
    }
}

/// `GET /price`: the flat price of one name and the longest name the service mines.
public struct NameMiningPrice: Equatable, Sendable, Decodable {
    public let priceSats: UInt64
    public let maxNameLength: Int

    public init(priceSats: UInt64, maxNameLength: Int) {
        self.priceSats = priceSats
        self.maxNameLength = maxNameLength
    }
}

/// Why a mining call failed. `errorDescription` is a short line for the person; the full detail
/// (status, path, body, underlying error) is logged under `dev.opl.1sat-sdk` / `OneSatActions`
/// where the error is thrown.
public enum NameMiningError: Error, Equatable, Sendable, LocalizedError {
    /// 400 `invalid name`.
    case invalidName
    /// 400 `invalid receiveAddress`.
    case invalidReceiveAddress
    /// 409 `name already claimed`.
    case nameClaimed
    /// 503: the service has no mine tip for the name.
    case mineTipUnavailable
    /// 502: the service took the payment but could not broadcast it.
    case paymentBroadcastFailed
    /// 400 from the payment check (`ERR_PAYMENT_INVALID`, `ERR_PAYMENT_FAILED`,
    /// `ERR_INVALID_DERIVATION_PREFIX`, or a malformed payment header).
    case paymentRefused(code: String?)
    /// The 402 asked for a different amount than the person confirmed; nothing was paid.
    case priceChanged(confirmed: UInt64, asked: UInt64)
    /// Resuming with a saved payment, the service asked for a new one; nothing more was paid.
    case resumeWouldPayAgain
    /// 404 `job not found`.
    case jobNotFound
    /// 409 on a refund of a job still being mined.
    case jobInProgress
    /// 409 on a refund of a job that already finished.
    case jobAlreadyResolved
    /// A job id that is not a transaction id; nothing was sent.
    case invalidJobID
    /// Any other refusal, with the service's own reason when it gave one.
    case refused(status: Int, message: String?)
    case unreadableResponse
    /// Filing asked of a job not in the state it needs.
    case wrongState(NameMiningJob.State)
    /// A complete job without its mint's BEEF.
    case missingMintBEEF
    /// A refunded job without the refund's remittance or BEEF.
    case missingRefund
    /// The job's BEEF is not base64 or not a BEEF.
    case unreadableBEEF
    /// The wallet did not file the mint; carries its message.
    case mintNotFiled(String)
    /// The refund's remittance has a derivation value that is not canonical base64, which the
    /// wallet refuses (1sat.name sends the suffix as the literal `refund`).
    case refundNotFilable

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "That name can't be mined. Use only letters, digits and hyphens."
        case .invalidReceiveAddress:
            "1sat.name refused the address to deliver the name to."
        case .nameClaimed:
            "That name is already claimed."
        case .mineTipUnavailable:
            "1sat.name can't mine this name right now. Try again later."
        case .paymentBroadcastFailed:
            "1sat.name couldn't send your payment to the network. Try again to resend the same payment."
        case .paymentRefused:
            "1sat.name didn't accept the payment."
        case .priceChanged(let confirmed, let asked):
            "The price changed from \(confirmed) to \(asked) sats. Review it before paying."
        case .resumeWouldPayAgain:
            "1sat.name asked for a new payment instead of the saved one. Nothing more was paid."
        case .jobNotFound:
            "1sat.name has no such mining job."
        case .jobInProgress:
            "The name is still being mined, so it can't be refunded yet."
        case .jobAlreadyResolved:
            "This job is already finished; there is nothing to refund."
        case .invalidJobID:
            "That is not a mining job."
        case .refused(let status, let message?):
            "1sat.name refused the request (HTTP \(status)): \(message)"
        case .refused(let status, nil):
            "1sat.name refused the request (HTTP \(status))."
        case .unreadableResponse:
            "1sat.name sent an answer this wallet could not read."
        case .wrongState(let state):
            "This job is \(state.rawValue), so there is nothing to add to the wallet for it."
        case .missingMintBEEF:
            "1sat.name hasn't sent the mined name yet. Try again shortly."
        case .missingRefund:
            "1sat.name hasn't sent the refund yet. Try again shortly."
        case .unreadableBEEF:
            "1sat.name sent a transaction this wallet could not read."
        case .mintNotFiled(let message):
            "The name couldn't be added to the wallet: \(message)"
        case .refundNotFilable:
            "1sat.name sent this refund in a form the wallet can't accept yet. The refund is safe "
                + "on chain; try again after 1sat.name is updated."
        }
    }
}

/// The 1sat.name job API. GETs of `/price` go over `http`; every `/jobs` call over `session`,
/// which must be an `AuthenticatedSession` to the same origin as `baseURL`.
public struct NameMiningClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://1sat.name")!
    static let category = "OneSatActions"
    static let service = "1sat.name"

    public let baseURL: URL
    private let session: AuthenticatedSession
    private let http: any OneSatHTTPTransport

    public init(
        baseURL: URL = NameMiningClient.defaultBaseURL,
        session: AuthenticatedSession,
        http: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.http = http
    }

    /// `GET /price`, unauthenticated: display data. The 402 of ``createJob`` is the charge.
    public func price() async throws -> NameMiningPrice {
        let url = url("/price")
        let response = try await http.send(method: "GET", url: url, headers: [:], body: nil)
        guard (200..<300).contains(response.status) else {
            throw Self.refusal(status: response.status, body: response.body, operation: "price", method: "GET", url: url)
        }
        return try Self.decode(NameMiningPrice.self, response.body, operation: "price", method: "GET", url: url)
    }

    /// `POST /jobs {name, receiveAddress}` behind BRC-105 (`mineName`'s job creation).
    ///
    /// `receiveAddress` is the wallet's deposit address 0 (``NameMining/receiveAddress(identity:network:)``),
    /// the key ``NameMining/fileMint(_:ctx:internalizer:processed:)`` files the name under.
    /// `expectedPriceSats` is the price the person confirmed: a 402 asking for any other amount is
    /// refused with ``NameMiningError/priceChanged(confirmed:asked:)`` before the wallet builds a
    /// payment. `onPayment` gets the payment once it is built and before it is sent; persist it
    /// there, and if the call fails after it, pass it to ``resumeJob(name:receiveAddress:payment:)``
    /// rather than paying again. The service answers 200 with the buyer's job for the same name
    /// without charging, so a repeat call pays nothing.
    public func createJob(
        name: String, receiveAddress: String, payer: any PayingWallet, expectedPriceSats: UInt64,
        onPayment: (@Sendable (BRC105Payment) async throws -> Void)? = nil
    ) async throws -> NameMiningJob {
        try await postJob(
            name: name, receiveAddress: receiveAddress, operation: "createJob",
            payer: ConfirmedPricePayer(payer: payer, confirmedSats: expectedPriceSats),
            payment: nil, onPayment: onPayment
        )
    }

    /// `POST /jobs` again with a payment saved from ``createJob``'s `onPayment`: the request goes
    /// straight out with it and nothing new is paid. When the service asks for a different payment
    /// instead, every paid attempt resends the saved one and the call fails with
    /// ``NameMiningError/resumeWouldPayAgain``.
    public func resumeJob(name: String, receiveAddress: String, payment: BRC105Payment) async throws -> NameMiningJob {
        let payer = NoNewPaymentPayer()
        do {
            return try await postJob(
                name: name, receiveAddress: receiveAddress, operation: "resumeJob",
                payer: payer, payment: payment, onPayment: nil
            )
        } catch let error as BRC105Error {
            guard case .paymentFailed = error, payer.refusals.count > 0 else { throw error }
            OneSatLog.error(
                "NameMiningClient.resumeJob: \(OneSatLog.describe(error)); 1sat.name wanted a new "
                    + "payment, so saved payment \(payment.transactionID) was not accepted",
                category: Self.category
            )
            throw NameMiningError.resumeWouldPayAgain
        }
    }

    /// `GET /jobs/:id`: the job's state, and the mint or refund once it has one.
    public func job(id: String) async throws -> NameMiningJob {
        let path = "/jobs/\(try Self.checkedJobID(id))"
        return try await authenticated("GET", path, operation: "job", as: NameMiningJob.self)
    }

    /// `GET /jobs`: the caller's jobs, without BEEF.
    public func jobs() async throws -> [NameMiningJob] {
        struct List: Decodable { let jobs: [NameMiningJob] }
        return try await authenticated("GET", "/jobs", operation: "jobs", as: List.self).jobs
    }

    /// `POST /jobs/:id/refund` for a failed job: the refund, as a `refunded` job to pass to
    /// ``NameMining/fileRefund(_:internalizer:)`` (`mineRefund`). Its `name` is nil: the service
    /// answers with the job id alone.
    public func refund(id: String) async throws -> NameMiningJob {
        struct Answer: Decodable {
            let jobId: String
            let txid: String?
            let satoshis: UInt64
            let derivationPrefix: String
            let derivationSuffix: String
            let senderIdentityKey: String
            let beef: String?
        }
        let path = "/jobs/\(try Self.checkedJobID(id))/refund"
        let answer = try await authenticated("POST", path, operation: "refund", as: Answer.self)
        return NameMiningJob(
            jobId: answer.jobId, state: .refunded,
            refund: .init(
                txid: answer.txid, satoshis: answer.satoshis, derivationPrefix: answer.derivationPrefix,
                derivationSuffix: answer.derivationSuffix, senderIdentityKey: answer.senderIdentityKey,
                beef: answer.beef
            )
        )
    }

    // MARK: - Requests

    private func postJob(
        name: String, receiveAddress: String, operation: String, payer: any PayingWallet,
        payment: BRC105Payment?, onPayment: (@Sendable (BRC105Payment) async throws -> Void)?
    ) async throws -> NameMiningJob {
        let body = Array(OrderedJSON.record([
            "name": .string(name), "receiveAddress": .string(receiveAddress),
        ]).serialized().utf8)
        let response = try await session.sendPaid(
            method: "POST", path: "/jobs", headers: ["Content-Type": "application/json"], body: body,
            payer: payer, payment: payment, onPayment: onPayment
        )
        let url = url("/jobs")
        guard response.statusCode == 200 || response.statusCode == 201 else {
            if let payment {
                OneSatLog.error("\(operation): POST /jobs for \(name) refused after payment \(payment.transactionID)", category: Self.category)
            }
            throw Self.refusal(status: response.statusCode, body: response.body, operation: operation, method: "POST", url: url)
        }
        return try Self.decode(NameMiningJob.self, response.body, operation: operation, method: "POST", url: url)
    }

    private func authenticated<T: Decodable>(
        _ method: String, _ path: String, operation: String, as type: T.Type
    ) async throws -> T {
        let response = try await session.send(method: method, path: path)
        let url = url(path)
        guard response.statusCode == 200 else {
            throw Self.refusal(status: response.statusCode, body: response.body, operation: operation, method: method, url: url)
        }
        return try Self.decode(type, response.body, operation: operation, method: method, url: url)
    }

    private func url(_ path: String) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? baseURL
    }

    /// A job id is the payment's txid; anything else could not name a job and is not sent.
    static func checkedJobID(_ id: String) throws -> String {
        guard id.utf8.count == 64, id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) || ($0 >= 0x41 && $0 <= 0x46) }) else {
            OneSatLog.error("NameMiningClient: refused job id \(id.debugDescription): not a txid", category: category)
            throw NameMiningError.invalidJobID
        }
        return id
    }

    static func decode<T: Decodable>(
        _ type: T.Type, _ body: [UInt8], operation: String, method: String, url: URL
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(body))
        } catch {
            OneSatLog.unreadable("NameMiningClient.\(operation)", method: method, url: url, body: body, error: error, category: category)
            throw NameMiningError.unreadableResponse
        }
    }

    /// The error for a refusal, logged in full here.
    static func refusal(status: Int, body: [UInt8], operation: String, method: String, url: URL) -> NameMiningError {
        OneSatHTTPFailure(
            service: service, operation: "NameMiningClient.\(operation)", method: method, url: url,
            statusCode: status, body: body
        ).log(category: category)
        let object = (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
        let message = (object?["error"] as? String) ?? (object?["description"] as? String)
        let code = object?["code"] as? String
        switch (status, message) {
        case (400, "invalid name"): return .invalidName
        case (400, "invalid receiveAddress"): return .invalidReceiveAddress
        case (400, "malformed x-bsv-payment header"): return .paymentRefused(code: code)
        case (400, _) where code?.hasPrefix("ERR_PAYMENT") == true || code == "ERR_INVALID_DERIVATION_PREFIX":
            return .paymentRefused(code: code)
        case (404, "job not found"): return .jobNotFound
        case (409, "name already claimed"): return .nameClaimed
        case (409, "job is still in progress"): return .jobInProgress
        case (409, "job already resolved"): return .jobAlreadyResolved
        case (502, let text?) where text.hasPrefix("payment broadcast failed"): return .paymentBroadcastFailed
        case (503, "mine tip unavailable for this name"): return .mineTipUnavailable
        default: return .refused(status: status, message: OneSatHTTPFailure.serverReason(from: body))
        }
    }
}

/// The payer ``NameMiningClient/createJob(name:receiveAddress:payer:expectedPriceSats:onPayment:)``
/// hands `sendPaid`: a payment of any amount but the confirmed price is refused before the wallet
/// builds it, as `OpenExchange.enablePaid` refuses a changed fee.
struct ConfirmedPricePayer: WalletPublicKeyProviding, WalletHMACOperations, WalletActionOperations {
    let payer: any PayingWallet
    let confirmedSats: UInt64

    func createAction(_ request: WalletCreateActionRequest) async throws -> WalletCreateActionResult {
        let outputs = request.outputs ?? []
        guard outputs.count == 1, outputs[0].satoshis == confirmedSats else {
            let asked = outputs.reduce(UInt64(0)) { $0 &+ $1.satoshis }
            OneSatLog.error(
                "NameMiningClient.createJob: 1sat.name asked for \(asked) sats in \(outputs.count) output(s); "
                    + "the confirmed price is \(confirmedSats). Not paid.",
                category: NameMiningClient.category
            )
            throw NameMiningError.priceChanged(confirmed: confirmedSats, asked: asked)
        }
        return try await payer.createAction(request)
    }

    func getPublicKey(_ request: WalletGetPublicKeyRequest) async throws -> WalletGetPublicKeyResult {
        try await payer.getPublicKey(request)
    }
    func createHMAC(_ request: WalletCreateHMACRequest) async throws -> WalletCreateHMACResult {
        try await payer.createHMAC(request)
    }
    func verifyHMAC(_ request: WalletVerifyHMACRequest) async throws -> WalletVerifyHMACResult {
        try await payer.verifyHMAC(request)
    }
    func signAction(_ request: WalletSignActionRequest) async throws -> WalletSignActionResult {
        try await payer.signAction(request)
    }
    func abortAction(_ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult {
        try await payer.abortAction(request)
    }
    func listActions(_ request: WalletListActionsRequest) async throws -> WalletListActionsResult {
        try await payer.listActions(request)
    }
    func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        try await payer.internalizeAction(request)
    }
}

/// The payer of ``NameMiningClient/resumeJob(name:receiveAddress:payment:)``: it makes no payment.
struct NoNewPaymentPayer: WalletPublicKeyProviding, WalletHMACOperations, WalletActionOperations {
    /// Counts the payments refused, so `resumeJob` can tell its caller why the send failed:
    /// `sendPaid` retries a refused new payment and reports only the attempts.
    final class Refusals: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func add() { lock.lock(); value += 1; lock.unlock() }
    }

    let refusals = Refusals()

    private func refuse() -> NameMiningError {
        refusals.add()
        OneSatLog.error(
            "NameMiningClient.resumeJob: 1sat.name asked for a new payment instead of the saved one; not paid",
            category: NameMiningClient.category
        )
        return .resumeWouldPayAgain
    }

    func getPublicKey(_ request: WalletGetPublicKeyRequest) async throws -> WalletGetPublicKeyResult { throw refuse() }
    func createHMAC(_ request: WalletCreateHMACRequest) async throws -> WalletCreateHMACResult { throw refuse() }
    func verifyHMAC(_ request: WalletVerifyHMACRequest) async throws -> WalletVerifyHMACResult { throw refuse() }
    func createAction(_ request: WalletCreateActionRequest) async throws -> WalletCreateActionResult { throw refuse() }
    func signAction(_ request: WalletSignActionRequest) async throws -> WalletSignActionResult { throw refuse() }
    func abortAction(_ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult { throw refuse() }
    func listActions(_ request: WalletListActionsRequest) async throws -> WalletListActionsResult { throw refuse() }
    func internalizeAction(_ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        throw refuse()
    }
}

/// Filing what a mining job delivers.
public enum NameMining {
    /// `DEPOSIT_KEY_ID`: the name is delivered to deposit address 0 and filed under its key.
    public static let depositKeyID = "\(DepositAddresses.defaultPrefix) 0"

    /// `defaultReceive`: the wallet's deposit address 0 (`[0, "onesat"]`, `1sat 0`, self), the
    /// address deposit sync watches and ``depositKeyID`` files under.
    public static func receiveAddress(identity: PrivateKey, network: BitcoinNetwork = .mainnet) throws -> String {
        try DepositAddresses.address(identity: identity, index: 0, network: network).description
    }

    /// `atomicBeefFromJob`: base64 BEEF from the job API as Atomic BEEF. An Atomic envelope passes
    /// through as sent; plain BEEF becomes the Atomic BEEF of its last transaction.
    public static func atomicBEEF(fromJob base64: String) throws -> [UInt8] {
        guard let decoded = Data(base64Encoded: base64) else {
            OneSatLog.error("NameMining: job BEEF is not base64 (\(base64.count) characters)", category: NameMiningClient.category)
            throw NameMiningError.unreadableBEEF
        }
        let bytes = Array(decoded)
        if OneSatBEEF.isAtomic(bytes) { return bytes }
        do {
            let limits = WalletBEEFLimits.standard
            let graph = try OneSatBEEF.graph(bytes, limits: limits)
            // Read parents-first, so `last` is spent by nothing else here (TS takes the wire's last).
            guard let last = graph.transactions.last else { throw NameMiningError.unreadableBEEF }
            let subject = try last.transactionID(limits: limits.transactionLimits)
            return try OneSatBEEF.atomic(subject, in: graph, limits: limits).serialized(limits: limits)
        } catch {
            OneSatLog.error(error, "NameMining: reading the job's plain BEEF (\(bytes.count) bytes)", category: NameMiningClient.category)
            throw NameMiningError.unreadableBEEF
        }
    }

    /// What ``fileMint(_:ctx:internalizer:processed:)`` did.
    public struct FiledMint: Equatable, Sendable {
        /// The mint's txid: mark it processed so deposit sync does not file it again.
        public let txid: String
        /// `<txid>.<vout>` of the name.
        public let outpoint: String
        public let name: String
        /// True when the name was already in the `opns` basket (or the txid already processed)
        /// and nothing was filed.
        public let alreadyFiled: Bool
    }

    /// `internalizeMint`: files a complete job's name in `opns` with `OpNS.internalize`, protocol
    /// `[0, "onesat"]`, keyID `1sat 0`, counterparty `self`.
    ///
    /// Deposit sync watches the same address and would file the mint too, under another `id:`.
    /// So the name is not filed when `processed` already holds the mint's txid or the `opns`
    /// basket already holds an output tagged with its `origin:`; and after filing, the txid is
    /// added to `processed` (deposit sync's ``ProcessedTxStore``), which sync skips. Pass the
    /// store sync uses; with nil, only the basket check guards and the caller marks
    /// ``FiledMint/txid`` itself.
    public static func fileMint(
        _ job: NameMiningJob,
        ctx: OneSatContext,
        internalizer: any ActionInternalizer,
        processed: (any ProcessedTxStore)? = nil
    ) async throws -> FiledMint {
        guard job.state == .complete else { throw NameMiningError.wrongState(job.state) }
        guard let mintBeef = job.mintBeef else {
            OneSatLog.error("NameMining.fileMint: job \(job.jobId) is complete but has no mintBeef", category: NameMiningClient.category)
            throw NameMiningError.missingMintBEEF
        }
        let tx = try atomicBEEF(fromJob: mintBeef)
        let limits = WalletBEEFLimits.standard
        let txid: String
        let delivery: (vout: UInt32, name: String)?
        do {
            let atomic = try AtomicBEEF(bytes: tx, limits: limits, transactionOrder: .any)
            let subjectID = atomic.subjectTransactionID
            guard let subject = try atomic.beef.transaction(for: subjectID, limits: limits.transactionLimits) else {
                throw BEEFError.missingSubjectTransaction(subjectID)
            }
            txid = subjectID.displayHex
            delivery = OpNS.mintNameDelivery(in: subject)
        } catch {
            OneSatLog.error(error, "NameMining.fileMint: reading job \(job.jobId)'s mint", category: NameMiningClient.category)
            throw NameMiningError.unreadableBEEF
        }
        guard let delivery else {
            OneSatLog.error("NameMining.fileMint: job \(job.jobId)'s mint \(txid) delivers no name", category: NameMiningClient.category)
            throw NameMiningError.mintNotFiled(OneSatActionError.notAnOpnsMint.wireMessage)
        }
        let outpoint = "\(txid).\(delivery.vout)"

        if try await processed?.has(txid) == true {
            OneSatLog.notice("NameMining.fileMint: mint \(txid) already processed by deposit sync; not filed again", category: NameMiningClient.category)
            return FiledMint(txid: txid, outpoint: outpoint, name: delivery.name, alreadyFiled: true)
        }
        let origin = "origin:\(Bsv21Remittance.formatOrdinalOutpoint(outpoint))"
        let held = try await ctx.storage.listOutputs(ctx.auth, try WalletListOutputsRequest(
            basket: OneSatConstants.opnsBasket, tags: [origin], tagQueryMode: .all,
            pagination: WalletPagination(limit: 1)
        ))
        if !held.outputs.isEmpty {
            OneSatLog.notice("NameMining.fileMint: \(origin) is already in opns; not filed again", category: NameMiningClient.category)
            try await processed?.add(txid)
            return FiledMint(txid: txid, outpoint: outpoint, name: delivery.name, alreadyFiled: true)
        }

        let result = await OpNS.internalize(
            internalizer,
            OpNS.InternalizeRequest(
                tx: tx, protocolID: try OneSatConstants.p1satProtocolID, keyID: depositKeyID, counterparty: "self"
            )
        )
        if let error = result.error {
            OneSatLog.error(
                "NameMining.fileMint: job \(job.jobId)'s mint \(txid) was not filed: \(error)"
                    + (result.diagnostic.map { " (\($0))" } ?? ""),
                category: NameMiningClient.category
            )
            throw NameMiningError.mintNotFiled(error)
        }
        try await processed?.add(txid)
        return FiledMint(
            txid: result.txid ?? txid, outpoint: result.outpoint ?? outpoint,
            name: result.name ?? delivery.name, alreadyFiled: false
        )
    }

    /// `internalizeRefund`: files a refunded job's output 0 as a wallet payment under the job's
    /// remittance, described `opns mine refund <name ?? jobId>`.
    ///
    /// The wallet takes only canonical base64 derivation values; 1sat.name sends the suffix as the
    /// literal `refund`, so such a refund fails with ``NameMiningError/refundNotFilable`` and the
    /// wallet is not called.
    @discardableResult
    public static func fileRefund(
        _ job: NameMiningJob, internalizer: any ActionInternalizer
    ) async throws -> WalletInternalizeActionResult {
        guard job.state == .refunded else { throw NameMiningError.wrongState(job.state) }
        guard let refund = job.refund, let beef = refund.beef else {
            OneSatLog.error("NameMining.fileRefund: job \(job.jobId) is refunded but has no refund BEEF", category: NameMiningClient.category)
            throw NameMiningError.missingRefund
        }
        let remittance = try refundRemittance(refund, jobId: job.jobId)
        let limits = WalletBEEFLimits.standard
        let tx: AtomicBEEF
        do {
            tx = try AtomicBEEF(bytes: try atomicBEEF(fromJob: beef), limits: limits, transactionOrder: .any)
        } catch let error as NameMiningError {
            throw error
        } catch {
            OneSatLog.error(error, "NameMining.fileRefund: reading job \(job.jobId)'s refund", category: NameMiningClient.category)
            throw NameMiningError.unreadableBEEF
        }
        let description = "opns mine refund \(job.name ?? job.jobId)".trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await internalizer.internalizeAction(WalletInternalizeActionRequest(
                transaction: tx,
                description: description,
                outputs: [try WalletInternalizeOutput(
                    outputIndex: 0, protocol: .walletPayment, paymentRemittance: remittance
                )]
            ))
        } catch {
            OneSatLog.error(error, "NameMining.fileRefund: filing job \(job.jobId)'s refund \(refund.txid ?? "?")", category: NameMiningClient.category)
            throw error
        }
    }

    /// The refund's BRC-29 remittance. A derivation value that is not canonical base64 is
    /// ``NameMiningError/refundNotFilable``.
    static func refundRemittance(_ refund: NameMiningJob.Refund, jobId: String) throws -> WalletPaymentRemittance {
        func base64(_ value: String, _ field: String) throws -> WalletBase64Data {
            do {
                return try WalletBase64Data(base64: value)
            } catch {
                OneSatLog.error(
                    "NameMining.fileRefund: job \(jobId)'s refund \(refund.txid ?? "?") has \(field) "
                        + "\(value.debugDescription), not canonical base64 (\(OneSatLog.describe(error))); "
                        + "the wallet can't file it. 1sat.name must send base64 derivation values.",
                    category: NameMiningClient.category
                )
                throw NameMiningError.refundNotFilable
            }
        }
        let prefix = try base64(refund.derivationPrefix, "derivationPrefix")
        let suffix = try base64(refund.derivationSuffix, "derivationSuffix")
        let sender: PublicKey
        do {
            sender = try PublicKey(try Hex.decode(refund.senderIdentityKey, maximumDecodedByteCount: 65))
        } catch {
            OneSatLog.error(
                "NameMining.fileRefund: job \(jobId)'s refund names sender \(refund.senderIdentityKey.debugDescription), "
                    + "not a public key: \(OneSatLog.describe(error))",
                category: NameMiningClient.category
            )
            throw NameMiningError.unreadableResponse
        }
        return try WalletPaymentRemittance(derivationPrefix: prefix, derivationSuffix: suffix, senderIdentityKey: sender)
    }
}
