import Foundation
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxAuth
import ToolboxBRC29
import ToolboxStorage
import OneSatColor

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let txLimits = WalletTransactionLimits.standard
let beefLimits = WalletBEEFLimits.standard

func graph(_ transactions: [Transaction]) throws -> BEEF {
    try BEEF(version: .v2, merklePaths: [], transactions: transactions.map { .raw($0) }, limits: beefLimits)
}

/// The transactions behind `roots`, parents first, from `pool`.
func ancestry(_ roots: [TransactionID], pool: [TransactionID: Transaction]) -> [Transaction] {
    var order: [Transaction] = []
    var seen: Set<TransactionID> = []
    func visit(_ id: TransactionID) {
        guard !seen.contains(id), let transaction = pool[id] else { return }
        seen.insert(id)
        for input in transaction.inputs { visit(input.previousOutput.transactionID) }
        order.append(transaction)
    }
    for root in roots { visit(root) }
    return order
}

/// A transaction with no inputs standing in for a token deploy: the client never reads it.
func deployTransaction(_ marker: UInt8 = 1) throws -> Transaction {
    Transaction(
        version: 1, inputs: [],
        outputs: [TransactionOutput(satoshis: 1, lockingScript: try Script(bytes: [0x6a, 0x01, marker], maximumByteCount: 100))],
        lockTime: 0
    )
}

func atomicBytes(_ transaction: Transaction) throws -> [UInt8] {
    let id = try transaction.transactionID(limits: txLimits)
    return try AtomicBEEF(subjectTransactionID: id, beef: try graph([transaction]), limits: beefLimits).serialized(limits: beefLimits)
}

/// An in-memory wallet storage with BRC-29 funding, baskets, `entire transactions` listing and
/// the BRC-177 calls (a trimmed copy of OneSatColorTests' `MockWallet`).
actor MemoryStorage: ColorWalletStorage {
    struct Record {
        let outpoint: Outpoint
        let satoshis: UInt64
        let script: [UInt8]
        var basket: String
        var fundingSuffix: String?
        var reserved = false
    }

    struct Pending {
        let funded: StorageCreateActionResult
        let reserved: [String]
        let anchorVout: UInt32?
    }

    static let fundingPrefix = Data("funding-prefix".utf8).base64EncodedString()
    static let fee: UInt64 = 200

    let identity: PrivateKey
    private(set) var transactions: [TransactionID: Transaction] = [:]
    private(set) var records: [Record] = []
    private var pending: [String: Pending] = [:]
    private var anchorSuffixes: [String: String] = [:]
    private var counter = 0

    private(set) var targets: [WalletCreateActionRequest] = []
    private(set) var processed: [StorageProcessActionRequest] = []
    private(set) var aborted: [String] = []
    private(set) var listed: [WalletListOutputsRequest] = []
    var noSendSupported = true

    init(identity: PrivateKey) throws {
        self.identity = identity
        var outputs: [TransactionOutput] = []
        var suffixes: [String] = []
        for index in 0..<4 {
            let suffix = Data("root-\(index)".utf8).base64EncodedString()
            let key = try BRC29.receivingPrivateKey(recipient: identity, sender: identity.publicKey, prefix: Self.fundingPrefix, suffix: suffix)
            outputs.append(TransactionOutput(satoshis: 100_000, lockingScript: try BRC29.lockingScript(for: key.publicKey)))
            suffixes.append(suffix)
        }
        let root = Transaction(version: 1, inputs: [], outputs: outputs, lockTime: 0)
        let id = try root.transactionID(limits: txLimits)
        transactions[id] = root
        records = outputs.enumerated().map { index, output in
            Record(outpoint: Outpoint(transactionID: id, outputIndex: UInt32(index)), satoshis: output.satoshis,
                   script: output.lockingScript.bytes, basket: "default", fundingSuffix: suffixes[index])
        }
    }

    func setNoSendSupported(_ value: Bool) { noSendSupported = value }

    /// Holds output `vout` of `transaction` in `basket`, as an earlier action would.
    func hold(_ transaction: Transaction, vout: UInt32, basket: String) throws {
        let id = try transaction.transactionID(limits: txLimits)
        transactions[id] = transaction
        let output = transaction.outputs[Int(vout)]
        records.append(Record(outpoint: Outpoint(transactionID: id, outputIndex: vout), satoshis: output.satoshis,
                              script: output.lockingScript.bytes, basket: basket))
    }

    private func next(_ kind: String) -> String {
        counter += 1
        return Data("\(kind)-\(counter)".utf8).base64EncodedString()
    }

    private func takeFunding() throws -> Record {
        guard let index = records.firstIndex(where: { $0.fundingSuffix != nil && !$0.reserved && $0.basket == "default" }) else {
            throw TestError("no funding left")
        }
        records[index].reserved = true
        return records[index]
    }

    private func inputBEEF(_ roots: [TransactionID]) throws -> [UInt8] {
        try graph(ancestry(roots, pool: transactions)).serialized(limits: beefLimits)
    }

    // MARK: - ColorWalletStorage

    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult {
        throw TestError("the paid enable makes no plain createAction")
    }

    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult {
        listed.append(request)
        let page = records.filter { $0.basket == request.basket && !$0.reserved }
        let outputs = try page.map {
            try WalletOutput(satoshis: $0.satoshis, spendable: true, outpoint: $0.outpoint)
        }
        var beef: BEEF?
        if request.include == .entireTransactions, !page.isEmpty {
            beef = try graph(ancestry(page.map(\.outpoint.transactionID), pool: transactions))
        }
        return try WalletListOutputsResult(totalOutputs: UInt32(page.count), beef: beef, outputs: outputs)
    }

    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        throw TestError("the paid enable internalizes nothing")
    }

    // MARK: - NoSendExpiryStorage

    func supportsNoSendExpiry() async throws -> Bool { noSendSupported }

    func prepareNoSendExpiry(_ auth: AuthID, _ target: WalletCreateActionRequest) async throws -> NoSendExpiryPrepared {
        let funding = try takeFunding()
        let anchorSuffix = next("anchor")
        let reference = next("funding")
        let funded = StorageCreateActionResult(
            reference: reference, version: 1, lockTime: 0,
            outputs: [
                StorageActionOutput(vout: 0, satoshis: 1_000, lockingScript: [0x00], providedBy: .storage,
                                    purpose: .change, derivationSuffix: anchorSuffix),
                StorageActionOutput(vout: 1, satoshis: funding.satoshis - 1_000 - Self.fee, lockingScript: [0x00],
                                    providedBy: .storage, purpose: .change, derivationSuffix: next("change")),
            ],
            inputs: [StorageActionInput(
                sourceTXID: funding.outpoint.transactionID.displayHex, sourceVout: funding.outpoint.outputIndex,
                sourceSatoshis: Int64(funding.satoshis), sourceLockingScript: funding.script, unlockingScriptLength: 107,
                derivationPrefix: Self.fundingPrefix, derivationSuffix: funding.fundingSuffix
            )],
            inputBEEF: try inputBEEF([funding.outpoint.transactionID]),
            derivationPrefix: Self.fundingPrefix
        )
        pending[reference] = Pending(funded: funded, reserved: [funding.outpoint.description], anchorVout: 0)
        anchorSuffixes[reference] = anchorSuffix
        return NoSendExpiryPrepared(funding: funded, anchorSatoshis: 1_000, anchorVout: 0, reclaimFee: 100, reclaimSatoshis: 900)
    }

    func activateNoSendExpiry(
        _ auth: AuthID, target: WalletCreateActionRequest, fundingReference: String, fundingTxid: String, anchorVout: UInt32
    ) async throws -> NoSendExpiryActivated {
        targets.append(target)
        guard let anchorSuffix = anchorSuffixes[fundingReference] else { throw TestError("unknown funding") }
        let anchorKey = try BRC29.receivingPrivateKey(recipient: identity, sender: identity.publicKey, prefix: Self.fundingPrefix, suffix: anchorSuffix)
        let anchor = StorageActionInput(
            sourceTXID: fundingTxid, sourceVout: anchorVout, sourceSatoshis: 1_000,
            sourceLockingScript: try BRC29.lockingScript(for: anchorKey.publicKey).bytes, unlockingScriptLength: 107,
            derivationPrefix: Self.fundingPrefix, derivationSuffix: anchorSuffix
        )
        let outputs = (target.outputs ?? []).enumerated().map { index, output in
            StorageActionOutput(vout: UInt32(index), satoshis: output.satoshis, lockingScript: output.lockingScript,
                                providedBy: .you, purpose: nil, derivationSuffix: nil)
        }
        let reference = next("target")
        let action = StorageCreateActionResult(
            reference: reference, version: 1, lockTime: 0, outputs: outputs, inputs: [anchor],
            inputBEEF: try inputBEEF([try TransactionID(displayHex: fundingTxid)]), derivationPrefix: Self.fundingPrefix
        )
        pending[reference] = Pending(funded: action, reserved: [], anchorVout: nil)
        return NoSendExpiryActivated(action: action, mode: "seconds", deadline: 1_900_000_000, anchorTxid: fundingTxid, anchorVout: anchorVout)
    }

    func armNoSendExpiry(_ auth: AuthID, _ arm: NoSendExpiryArm) async throws {}

    func processAction(_ auth: AuthID, _ request: StorageProcessActionRequest) async throws -> StorageProcessActionResult {
        processed.append(request)
        guard let action = pending.removeValue(forKey: request.reference), let raw = request.rawTX else {
            throw TestError("unknown reference")
        }
        let transaction = try Transaction(bytes: raw, limits: txLimits)
        let id = try transaction.transactionID(limits: txLimits)
        transactions[id] = transaction
        let spent = Set(transaction.inputs.map(\.previousOutput.description))
        records.removeAll { spent.contains($0.outpoint.description) }
        for output in action.funded.outputs where output.isChange && output.vout != action.anchorVout {
            let actual = transaction.outputs[Int(output.vout)]
            records.append(Record(outpoint: Outpoint(transactionID: id, outputIndex: output.vout), satoshis: actual.satoshis,
                                  script: actual.lockingScript.bytes, basket: "default", fundingSuffix: output.derivationSuffix))
        }
        if request.isNoSend { return StorageProcessActionResult(sendWithResults: []) }
        return StorageProcessActionResult(sendWithResults: [SendWithResult(txid: id.displayHex, status: .unproven)])
    }

    func abortAction(_ auth: AuthID, _ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult {
        // Like real storage, a call from a cancelled task does nothing.
        try Task.checkCancellation()
        aborted.append(request.reference.base64)
        return WalletAbortActionResult(aborted: true)
    }
}

/// Answers GETs by URL, 404 otherwise, and records each request.
actor StubHTTP: HTTPTransport {
    private var routes: [String: (Int, [UInt8])] = [:]
    private(set) var requests: [HTTPRequest] = []

    init(_ routes: [String: (Int, [UInt8])] = [:]) { self.routes = routes }

    func route(_ url: String, _ status: Int, _ body: [UInt8]) { routes[url] = (status, body) }
    func json(_ url: String, _ text: String, status: Int = 200) { routes[url] = (status, Array(text.utf8)) }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let (status, body) = routes[request.url.absoluteString] ?? (404, Array("no".utf8))
        return HTTPResponse(statusCode: status, body: body)
    }

    var urls: [String] { requests.map(\.url.absoluteString) }
}

/// The signed POST: records what was sent and answers as scripted.
actor StubSigned: AuthenticatedTransport {
    struct Sent: Sendable {
        let method: String
        let path: String
        let query: String?
        let headers: [String: String]
        let body: [UInt8]?
    }

    enum Answer: Sendable {
        case response(Int, String)
        case error(Error & Sendable)
        /// The caller's task is cancelled while the POST is in flight.
        case cancelled
    }

    private(set) var sent: [Sent] = []
    var answer: Answer

    init(_ answer: Answer) { self.answer = answer }

    func send(
        method: String, path: String, query: String?, headers: [String: String], body: [UInt8]?
    ) async throws -> AuthenticatedResponse {
        sent.append(Sent(method: method, path: path, query: query, headers: headers, body: body))
        switch answer {
        case .response(let status, let text): return AuthenticatedResponse(statusCode: status, headers: [:], body: Array(text.utf8))
        case .error(let error): throw error
        case .cancelled:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
    }
}

/// Who the client opened a signed session as, and to which instance.
final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [(identity: String, instance: String)] = []

    func record(_ identity: PrivateKey, _ instance: URL) {
        lock.lock(); defer { lock.unlock() }
        opened.append((Hex.encode(identity.publicKey.compressedBytes), instance.absoluteString))
    }

    var instances: [String] { lock.lock(); defer { lock.unlock() }; return opened.map(\.instance) }
    var identities: [String] { lock.lock(); defer { lock.unlock() }; return opened.map(\.identity) }
}
