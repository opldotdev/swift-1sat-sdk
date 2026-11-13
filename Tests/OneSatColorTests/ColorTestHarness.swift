import Foundation
import XCTest
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions
import ToolboxBRC29
import ToolboxStorage
import OneSatCBOR
import OneSatMetanet
@testable import OneSatColor

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let harnessTxLimits = WalletTransactionLimits.standard
let harnessBEEFLimits = WalletBEEFLimits.standard

/// The transactions behind `roots`, parents first, from `pool`.
func ancestry(_ roots: [TransactionID], pool: [TransactionID: Transaction]) throws -> [Transaction] {
    var order: [Transaction] = []
    var seen: Set<TransactionID> = []
    func visit(_ id: TransactionID) throws {
        guard !seen.contains(id), let transaction = pool[id] else { return }
        seen.insert(id)
        for input in transaction.inputs { try visit(input.previousOutput.transactionID) }
        order.append(transaction)
    }
    for root in roots { try visit(root) }
    return order
}

func graph(_ transactions: [Transaction]) throws -> BEEF {
    try BEEF(version: .v2, merklePaths: [], transactions: transactions.map { .raw($0) }, limits: harnessBEEFLimits)
}

func transactions(in beef: BEEF?) throws -> [TransactionID: Transaction] {
    var pool: [TransactionID: Transaction] = [:]
    for entry in beef?.transactions ?? [] {
        if let transaction = entry.transaction {
            pool[try transaction.transactionID(limits: harnessTxLimits)] = transaction
        }
    }
    return pool
}

/// An in-memory wallet storage: BRC-29 funding, baskets with custom instructions and tags,
/// `entire transactions` listing, internalize, and the BRC-177 calls. Every transaction it knows
/// is unproven, so a BEEF it returns carries the full ancestry down to its funding root.
actor MockWallet: ColorWalletStorage {
    struct Funding { let suffix: String }

    struct Record {
        let outpoint: Outpoint
        let satoshis: UInt64
        let script: [UInt8]
        var basket: String?
        var customInstructions: String?
        var tags: [String]
        var funding: Funding?
        var reserved = false
    }

    struct Pending {
        let requested: [WalletCreateActionOutput]
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

    private(set) var createRequests: [WalletCreateActionRequest] = []
    private(set) var processed: [StorageProcessActionRequest] = []
    private(set) var internalized: [WalletInternalizeActionRequest] = []
    private(set) var armed: [NoSendExpiryArm] = []
    private(set) var aborted: [String] = []

    init(identity: PrivateKey, fundingOutputs: Int = 6, satoshis: UInt64 = 100_000) throws {
        self.identity = identity
        var outputs: [TransactionOutput] = []
        var suffixes: [String] = []
        for index in 0..<fundingOutputs {
            let suffix = Data("root-\(index)".utf8).base64EncodedString()
            let key = try BRC29.receivingPrivateKey(
                recipient: identity, sender: identity.publicKey, prefix: Self.fundingPrefix, suffix: suffix
            )
            outputs.append(TransactionOutput(satoshis: satoshis, lockingScript: try BRC29.lockingScript(for: key.publicKey)))
            suffixes.append(suffix)
        }
        let root = Transaction(version: 1, inputs: [], outputs: outputs, lockTime: 0)
        let id = try root.transactionID(limits: harnessTxLimits)
        transactions[id] = root
        records = outputs.enumerated().map { index, output in
            Record(
                outpoint: Outpoint(transactionID: id, outputIndex: UInt32(index)), satoshis: output.satoshis,
                script: output.lockingScript.bytes, basket: "default", customInstructions: nil, tags: [],
                funding: Funding(suffix: suffixes[index])
            )
        }
    }

    // MARK: - Helpers

    private func next(_ kind: String) -> String {
        counter += 1
        return Data("\(kind)-\(counter)".utf8).base64EncodedString()
    }

    private func takeFunding() throws -> Record {
        guard let index = records.firstIndex(where: { $0.funding != nil && !$0.reserved && $0.basket == "default" }) else {
            throw HarnessError("no funding left")
        }
        records[index].reserved = true
        return records[index]
    }

    private func fundingInput(_ record: Record) -> StorageActionInput {
        StorageActionInput(
            sourceTXID: record.outpoint.transactionID.displayHex, sourceVout: record.outpoint.outputIndex,
            sourceSatoshis: Int64(record.satoshis), sourceLockingScript: record.script, unlockingScriptLength: 107,
            derivationPrefix: Self.fundingPrefix, derivationSuffix: record.funding?.suffix
        )
    }

    private func callerInputs(
        _ request: WalletCreateActionRequest, pool: [TransactionID: Transaction]
    ) throws -> (inputs: [StorageActionInput], satoshis: UInt64, reserved: [String]) {
        var inputs: [StorageActionInput] = []
        var total: UInt64 = 0
        var reserved: [String] = []
        for input in request.inputs ?? [] {
            let outpoint = input.outpoint
            guard let source = pool[outpoint.transactionID], source.outputs.indices.contains(Int(outpoint.outputIndex)) else {
                throw HarnessError("unknown input \(outpoint)")
            }
            let output = source.outputs[Int(outpoint.outputIndex)]
            let length: UInt32
            switch input.unlocking {
            case .script(let bytes): length = UInt32(bytes.count)
            case .scriptLength(let value): length = value
            }
            inputs.append(StorageActionInput(
                sourceTXID: outpoint.transactionID.displayHex, sourceVout: outpoint.outputIndex,
                sourceSatoshis: Int64(output.satoshis), sourceLockingScript: output.lockingScript.bytes,
                unlockingScriptLength: length, derivationPrefix: nil, derivationSuffix: nil
            ))
            total += output.satoshis
            if let index = records.firstIndex(where: { $0.outpoint.description == outpoint.description }) {
                guard !records[index].reserved else { throw HarnessError("input \(outpoint) is reserved") }
                records[index].reserved = true
                reserved.append(outpoint.description)
            }
        }
        return (inputs, total, reserved)
    }

    private func requestedOutputs(_ request: WalletCreateActionRequest) -> [StorageActionOutput] {
        (request.outputs ?? []).enumerated().map { index, output in
            StorageActionOutput(
                vout: UInt32(index), satoshis: output.satoshis, lockingScript: output.lockingScript,
                providedBy: .you, purpose: nil, derivationSuffix: nil
            )
        }
    }

    private func inputBEEF(_ inputs: [StorageActionInput], pool: [TransactionID: Transaction]) throws -> [UInt8] {
        let roots = try inputs.map { try TransactionID(displayHex: $0.sourceTXID) }
        return try graph(try ancestry(roots, pool: pool)).serialized(limits: harnessBEEFLimits)
    }

    private func release(_ outpoints: [String]) {
        for index in records.indices where outpoints.contains(records[index].outpoint.description) {
            records[index].reserved = false
        }
    }

    // MARK: - ColorWalletStorage

    func colorCreateAction(_ auth: AuthID, _ request: WalletCreateActionRequest) async throws -> StorageCreateActionResult {
        createRequests.append(request)
        let pool = transactions.merging(try OneSatColorTests.transactions(in: request.inputBEEF)) { mine, _ in mine }
        let caller = try callerInputs(request, pool: pool)
        let funding = try takeFunding()
        let inputs = caller.inputs + [fundingInput(funding)]
        var outputs = requestedOutputs(request)
        let paid = outputs.reduce(0) { $0 + $1.satoshis }
        let change = caller.satoshis + funding.satoshis - paid - Self.fee
        outputs.append(StorageActionOutput(
            vout: UInt32(outputs.count), satoshis: change, lockingScript: [0x00], providedBy: .storage,
            purpose: .change, derivationSuffix: next("change")
        ))
        let reference = next("action")
        let funded = StorageCreateActionResult(
            reference: reference, version: 1, lockTime: 0, outputs: outputs, inputs: inputs,
            inputBEEF: try inputBEEF(inputs, pool: pool), derivationPrefix: Self.fundingPrefix
        )
        pending[reference] = Pending(
            requested: request.outputs ?? [], funded: funded,
            reserved: caller.reserved + [funding.outpoint.description], anchorVout: nil
        )
        return funded
    }

    func colorListOutputs(_ auth: AuthID, _ request: WalletListOutputsRequest) async throws -> WalletListOutputsResult {
        var matching = records.filter { $0.basket == request.basket && !$0.reserved }
        if !request.tags.isEmpty {
            matching = matching.filter { record in
                request.tagQueryMode == .all
                    ? request.tags.allSatisfy(record.tags.contains)
                    : request.tags.contains(where: record.tags.contains)
            }
        }
        let offset = Int(request.pagination.effectiveOffset)
        let page = Array(matching.dropFirst(offset).prefix(Int(request.pagination.effectiveLimit)))
        let entire = request.include == .entireTransactions
        let outputs = try page.map { record in
            try WalletOutput(
                satoshis: record.satoshis,
                lockingScript: request.include == .lockingScripts ? record.script : nil,
                spendable: true,
                customInstructions: request.includeCustomInstructions == true ? record.customInstructions : nil,
                tags: request.includeTags == true ? record.tags : nil,
                outpoint: record.outpoint
            )
        }
        var beef: BEEF?
        if entire {
            var roots: [TransactionID] = []
            for record in page where !roots.contains(record.outpoint.transactionID) { roots.append(record.outpoint.transactionID) }
            beef = try graph(try ancestry(roots, pool: transactions))
        }
        return try WalletListOutputsResult(totalOutputs: UInt32(matching.count), beef: beef, outputs: outputs)
    }

    func colorInternalizeAction(_ auth: AuthID, _ request: WalletInternalizeActionRequest) async throws -> WalletInternalizeActionResult {
        internalized.append(request)
        let atomic = request.transaction
        for (id, transaction) in try OneSatColorTests.transactions(in: atomic.beef) where transactions[id] == nil {
            transactions[id] = transaction
        }
        let subjectID = atomic.subjectTransactionID
        guard let subject = transactions[subjectID] else { throw HarnessError("internalize without its subject") }
        for output in request.outputs {
            let outpoint = Outpoint(transactionID: subjectID, outputIndex: output.outputIndex)
            guard case .basketInsertion(let insertion) = output.remittance else { continue }
            if let index = records.firstIndex(where: { $0.outpoint.description == outpoint.description }) {
                records[index].basket = insertion.basket
                records[index].customInstructions = insertion.customInstructions ?? records[index].customInstructions
                for tag in insertion.tags where !records[index].tags.contains(tag) { records[index].tags.append(tag) }
            } else {
                let source = subject.outputs[Int(output.outputIndex)]
                records.append(Record(
                    outpoint: outpoint, satoshis: source.satoshis, script: source.lockingScript.bytes,
                    basket: insertion.basket, customInstructions: insertion.customInstructions, tags: insertion.tags
                ))
            }
        }
        return WalletInternalizeActionResult(accepted: true)
    }

    // MARK: - NoSendExpiryStorage

    private(set) var capabilityChecks = 0
    var noSendSupported = true
    func setNoSendSupported(_ value: Bool) { noSendSupported = value }

    func supportsNoSendExpiry() async throws -> Bool {
        capabilityChecks += 1
        return noSendSupported
    }

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
            inputs: [fundingInput(funding)],
            inputBEEF: try graph(try ancestry([funding.outpoint.transactionID], pool: transactions)).serialized(limits: harnessBEEFLimits),
            derivationPrefix: Self.fundingPrefix
        )
        pending[reference] = Pending(requested: [], funded: funded, reserved: [funding.outpoint.description], anchorVout: 0)
        anchorSuffixes[reference] = anchorSuffix
        return NoSendExpiryPrepared(funding: funded, anchorSatoshis: 1_000, anchorVout: 0, reclaimFee: 100, reclaimSatoshis: 900)
    }

    func activateNoSendExpiry(
        _ auth: AuthID, target: WalletCreateActionRequest, fundingReference: String, fundingTxid: String, anchorVout: UInt32
    ) async throws -> NoSendExpiryActivated {
        createRequests.append(target)
        guard let anchorSuffix = anchorSuffixes[fundingReference] else { throw HarnessError("unknown funding") }
        let pool = transactions.merging(try OneSatColorTests.transactions(in: target.inputBEEF)) { mine, _ in mine }
        let caller = try callerInputs(target, pool: pool)
        let anchorKey = try BRC29.receivingPrivateKey(
            recipient: identity, sender: identity.publicKey, prefix: Self.fundingPrefix, suffix: anchorSuffix
        )
        let anchor = StorageActionInput(
            sourceTXID: fundingTxid, sourceVout: anchorVout, sourceSatoshis: 1_000,
            sourceLockingScript: try BRC29.lockingScript(for: anchorKey.publicKey).bytes, unlockingScriptLength: 107,
            derivationPrefix: Self.fundingPrefix, derivationSuffix: anchorSuffix
        )
        let inputs = caller.inputs + [anchor]
        let reference = next("target")
        let action = StorageCreateActionResult(
            reference: reference, version: 1, lockTime: 0, outputs: requestedOutputs(target), inputs: inputs,
            inputBEEF: try inputBEEF(inputs, pool: pool), derivationPrefix: Self.fundingPrefix
        )
        pending[reference] = Pending(requested: target.outputs ?? [], funded: action, reserved: caller.reserved, anchorVout: nil)
        return NoSendExpiryActivated(action: action, mode: "seconds", deadline: 1_900_000_000, anchorTxid: fundingTxid, anchorVout: anchorVout)
    }

    func armNoSendExpiry(_ auth: AuthID, _ arm: NoSendExpiryArm) async throws {
        armed.append(arm)
    }

    func processAction(_ auth: AuthID, _ request: StorageProcessActionRequest) async throws -> StorageProcessActionResult {
        processed.append(request)
        guard let action = pending.removeValue(forKey: request.reference), let raw = request.rawTX else {
            throw HarnessError("unknown reference")
        }
        let transaction = try Transaction(bytes: raw, limits: harnessTxLimits)
        let id = try transaction.transactionID(limits: harnessTxLimits)
        transactions[id] = transaction
        let spent = Set(transaction.inputs.map(\.previousOutput.description))
        records.removeAll { spent.contains($0.outpoint.description) }
        for output in action.funded.outputs {
            let outpoint = Outpoint(transactionID: id, outputIndex: output.vout)
            let actual = transaction.outputs[Int(output.vout)]
            if output.isChange {
                guard output.vout != action.anchorVout else { continue }
                records.append(Record(
                    outpoint: outpoint, satoshis: actual.satoshis, script: actual.lockingScript.bytes,
                    basket: "default", customInstructions: nil, tags: [],
                    funding: Funding(suffix: output.derivationSuffix ?? "")
                ))
                continue
            }
            let requested = action.requested[Int(output.vout)]
            guard requested.basket != nil || !requested.tags.isEmpty else { continue }
            records.append(Record(
                outpoint: outpoint, satoshis: actual.satoshis, script: actual.lockingScript.bytes,
                basket: requested.basket, customInstructions: requested.customInstructions, tags: requested.tags
            ))
        }
        if request.isNoSend { return StorageProcessActionResult(sendWithResults: []) }
        return StorageProcessActionResult(sendWithResults: [SendWithResult(txid: id.displayHex, status: .unproven)])
    }

    func abortAction(_ auth: AuthID, _ request: WalletAbortActionRequest) async throws -> WalletAbortActionResult {
        aborted.append(request.reference.base64)
        if let action = pending.removeValue(forKey: request.reference.base64) { release(action.reserved) }
        return WalletAbortActionResult(aborted: true)
    }

    func record(_ outpoint: String) -> Record? {
        records.first { $0.outpoint.description == outpoint }
    }
}

/// A BRC-207 overlay over every asset: a deploy is admitted under `tm_color`, other token outputs
/// under their asset topic, and a submission spends the admitted outputs its inputs name.
actor MockOverlay: ColorOverlayProvider {
    struct Entry { let beef: [UInt8]; let vout: UInt32 }

    private(set) var unspent: [String: Entry] = [:]
    private(set) var everAdmitted: [String: Entry] = [:]
    private(set) var submissions: [[String]] = []
    var refused: Set<String> = []
    var failures = 0

    func refuse(_ topic: String) { refused.insert(topic) }
    func forget(_ outpoint: String) { unspent.removeValue(forKey: outpoint) }
    func failNext(_ count: Int) { failures = count }

    func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        ColorOutputList(outputs: outpoints.compactMap { unspent[$0].map { ColorOutputList.Item(beef: $0.beef, outputIndex: $0.vout) } })
    }

    func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        ColorOutputList(outputs: outpoints.compactMap { everAdmitted[$0].map { ColorOutputList.Item(beef: $0.beef, outputIndex: $0.vout) } })
    }

    func submit(topics: [String], beef bytes: [UInt8]) async throws -> [String: ColorAdmittance] {
        submissions.append(topics)
        if failures > 0 {
            failures -= 1
            throw ColorError.overlay("overlay unavailable")
        }
        let beef: BEEF
        let subject: Transaction
        if let atomic = try? AtomicBEEF(bytes: bytes, limits: harnessBEEFLimits) {
            beef = atomic.beef
            subject = try XCTUnwrap(try beef.transaction(for: atomic.subjectTransactionID, limits: harnessTxLimits))
        } else {
            beef = try BEEF(bytes: bytes, limits: harnessBEEFLimits)
            subject = try XCTUnwrap(beef.transactions.last?.transaction)
        }
        let txid = try subject.transactionID(limits: harnessTxLimits).displayHex
        let answer = try beef.serialized(limits: harnessBEEFLimits)
        var steak: [String: ColorAdmittance] = [:]
        for topic in topics {
            if refused.contains(topic) {
                steak[topic] = ColorAdmittance(outputsToAdmit: [])
                continue
            }
            var admit: [UInt32] = []
            for (vout, output) in subject.outputs.enumerated() {
                guard let token = try? ColorTokenOutput.read(output.lockingScript, txid: txid, vout: UInt32(vout)) else { continue }
                let fits = topic == ColorIdentifiers.discoveryTopic
                    ? token.deploy
                    : !token.deploy && ColorIdentifiers.topic(token.assetID) == topic
                if fits { admit.append(UInt32(vout)) }
            }
            for input in subject.inputs { unspent.removeValue(forKey: input.previousOutput.description) }
            for vout in admit {
                let entry = Entry(beef: answer, vout: vout)
                unspent["\(txid).\(vout)"] = entry
                everAdmitted["\(txid).\(vout)"] = entry
            }
            steak[topic] = ColorAdmittance(outputsToAdmit: admit)
        }
        return steak
    }
}

/// A BRC-231 messagebox server over DAG-CBOR; each caller is the identity its transport names.
actor MessageBoxServer {
    struct Stored { let id: String; let recipient: String; let box: String; let body: [UInt8]; let sender: [UInt8] }

    private(set) var messages: [Stored] = []
    private(set) var acknowledged: [String] = []
    private var counter = 0

    func inject(recipient: [UInt8], box: String, body: [UInt8], sender: [UInt8]) -> String {
        counter += 1
        let id = "msg-\(counter)"
        messages.append(Stored(id: id, recipient: Hex.encode(recipient), box: box, body: body, sender: sender))
        return id
    }

    func handle(caller: [UInt8], path: String, body: [UInt8]) throws -> [UInt8] {
        guard case .map(let request) = try DagCbor.decode(body) else { throw HarnessError("not a map") }
        switch path {
        case "/sendMessage":
            guard let message = request["message"]?.mapValue,
                  let recipient = message["recipient"]?.bytesValue,
                  let box = message["messageBox"]?.textValue,
                  let payload = message["body"]?.bytesValue else { throw HarnessError("bad sendMessage") }
            let id = inject(recipient: recipient, box: box, body: payload, sender: caller)
            return try DagCbor.encode(.map(try DagCborMap([("status", .text("success")), ("messageId", .text(id))])))
        case "/listMessages":
            let box = request["messageBox"]?.textValue
            let rows: [DagCborValue] = try messages.filter { $0.recipient == Hex.encode(caller) && $0.box == box }.map {
                .map(try DagCborMap([("messageId", .text($0.id)), ("body", .bytes($0.body)), ("sender", .bytes($0.sender))]))
            }
            return try DagCbor.encode(.map(try DagCborMap([("status", .text("success")), ("messages", .array(rows))])))
        case "/acknowledgeMessage":
            let ids = (request["messageIds"]?.arrayValue ?? []).compactMap(\.textValue)
            messages.removeAll { ids.contains($0.id) }
            acknowledged += ids
            return try DagCbor.encode(.map(try DagCborMap([("status", .text("success"))])))
        default:
            throw HarnessError("unknown path \(path)")
        }
    }
}

struct MockTransport: MetanetTransport {
    let server: MessageBoxServer
    let caller: [UInt8]
    func post(host: URL, path: String, body: [UInt8]) async throws -> [UInt8] {
        try await server.handle(caller: caller, path: path, body: body)
    }
}

/// Two wallets, alice and bob, with handles at example.com, one overlay and one messagebox.
struct ColorWorld {
    struct Party {
        let identity: PrivateKey
        let wallet: MockWallet
        let ctx: OneColorContext
        var key: String { Hex.encode(identity.publicKey.compressedBytes) }
    }

    let overlay = MockOverlay()
    let server = MessageBoxServer()
    let alice: Party
    let bob: Party

    init() throws {
        let aliceKey = try PrivateKey([UInt8](repeating: 0, count: 31) + [0x0a])
        let bobKey = try PrivateKey([UInt8](repeating: 0, count: 31) + [0x0b])
        let directory = [
            "alice": Hex.encode(aliceKey.publicKey.compressedBytes),
            "bob": Hex.encode(bobKey.publicKey.compressedBytes),
        ]
        let handles = HandleResolver { url in
            if url.absoluteString == "https://example.com/manifest.json" {
                return (200, Array(#"{"metanet":{"handles":{"version":"1.0"}}}"#.utf8))
            }
            let prefix = "https://example.com/.well-known/metanet-handles/resolve?handle="
            guard url.absoluteString.hasPrefix(prefix) else { return (404, []) }
            let handle = String(url.absoluteString.dropFirst(prefix.count))
            guard let key = directory[handle] else { return (404, []) }
            return (200, Array(#"{"metanetHandles":"1.0","handle":"\#(handle)","domain":"example.com","identityKey":"\#(key)","certificate":{"subject":"\#(key)"},"messagebox":"https://mb.example.com","ttl":60,"revoked":false}"#.utf8))
        }
        alice = try Self.party(aliceKey, overlay: overlay, server: server, handles: handles)
        bob = try Self.party(bobKey, overlay: overlay, server: server, handles: handles)
    }

    static func party(
        _ identity: PrivateKey, overlay: MockOverlay?, server: MessageBoxServer, handles: HandleResolver
    ) throws -> Party {
        let wallet = try MockWallet(identity: identity)
        let ctx = OneColorContext(
            identity: identity, storage: wallet,
            auth: AuthID(identityKey: Hex.encode(identity.publicKey.compressedBytes)), maximumFee: 20_000,
            overlay: overlay, handles: handles,
            relay: CborRelay(transport: MockTransport(server: server, caller: identity.publicKey.compressedBytes))
        )
        return Party(identity: identity, wallet: wallet, ctx: ctx)
    }

    /// The same party without an overlay.
    func withoutOverlay(_ party: Party) -> OneColorContext {
        OneColorContext(
            identity: party.identity, storage: party.wallet, auth: party.ctx.auth, maximumFee: party.ctx.maximumFee,
            overlay: nil, handles: party.ctx.handles, relay: party.ctx.relay
        )
    }
}
