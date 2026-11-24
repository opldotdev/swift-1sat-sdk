import BigInt
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatColor
import OneSatTemplates
import ToolboxAuth

/// `SwapOutcome` (market/swapFlow.ts): what one leg's relay came to.
public enum OpenExchangeLegOutcome: Equatable, Sendable {
    /// The validator signed and the pool spent; the leg's take-in is `completed`.
    case accepted(id: String, txid: String, completed: OpenExchangeCompletedLeg)
    /// The validator refused; nothing was sent. `pool` is the pool as the refusal reports it.
    case refused(id: String, reason: String, pool: AMMPoolState?)
    /// The host answered with an error (not 200): it relayed nothing.
    case failed(reason: String)
    /// No answer: the leg may or may not have landed (`resolve` finds out).
    case unknown(id: String, reason: String)
}

extension OpenExchange {
    /// `LEG_PATIENCE_MS`: how long one leg's POST is waited for.
    public static let legPatienceMs = 15_000
    /// `NO_ANSWER_YET`.
    static let noAnswerYet = "no answer yet"

    /// `relaySwap`: ONE plain POST of the leg to `<origin>/@<tokenId>/amm/swap` (`swapBody`, DAG-JSON
    /// bytes), waited on for `patienceMs`; accepted → `completeSwap`. A thrown error or no answer is
    /// `unknown`; a non-200 answer is `failed`. Throws, as `completeSwap` does, when the relay's
    /// transaction is not the swap built.
    public func relayLeg(
        _ ctx: OneColorContext, _ p: OpenExchangePreparedLeg, tokenId: String, peerId: String,
        patienceMs: Int = OpenExchange.legPatienceMs
    ) async throws -> OpenExchangeLegOutcome {
        let id = p.id
        let reply: SwapReply
        do {
            let base = try tokenBase(tokenId)
            let body = try Self.swapBody(p, peerId: peerId)
            reply = try await Self.withPatience(patienceMs) { [http] in
                try await Self.postSwap(http, base: base, body: body)
            }
        } catch let error as RelayError {
            return .failed(reason: "swap: \(error.code): \(error.message)")
        } catch {
            return .unknown(id: id, reason: "\(Self.noAnswerYet): \(OpenExchangeError.errorText(error))")
        }
        switch reply {
        case let .accepted(tx, txid):
            return .accepted(id: id, txid: txid, completed: try await OpenExchangeSwapLeg.complete(ctx, p, raw: tx, txid: txid))
        case let .unreachable(reason):
            return .unknown(id: id, reason: "\(Self.noAnswerYet): the host could not reach the validator (\(reason))")
        case let .refused(reason, pool):
            return .refused(id: id, reason: reason, pool: pool)
        }
    }

    // MARK: - The wire (market/relay.ts)

    enum SwapReply: Equatable {
        case accepted(tx: [UInt8], txid: String)
        case refused(reason: String, pool: AMMPoolState?)
        case unreachable(reason: String)
    }

    struct RelayError: Error {
        let code: String
        let message: String
    }

    struct PatienceError: Error, LocalizedError {
        let ms: Int
        var errorDescription: String? { "no answer within \(ms) ms" }
    }

    /// `swapBody` as `JSON.stringify` writes it: `{funding, swap, pool, validator, peerId}`, the
    /// bytes as DAG-JSON `{"/": {"bytes": <unpadded base64>}}`.
    static func swapBody(_ p: OpenExchangePreparedLeg, peerId: String) throws -> [UInt8] {
        let swap = try p.swap.serialized(limits: OpenExchangeSwapLeg.txLimits)
        guard let validator = Runar.hexBytesChecked(p.validator.lowercased()) else { throw OpenExchangeError.failed("the validator key is not hex") }
        let text = "{\"funding\":\(dagBytes(p.fundingAtomicBEEF)),\"swap\":\(dagBytes(swap)),\"pool\":\(JSONText.quote(p.pool)),\"validator\":\(dagBytes(validator)),\"peerId\":\(JSONText.quote(peerId))}"
        return Array(text.utf8)
    }

    /// `dagBytes`.
    static func dagBytes(_ bytes: [UInt8]) -> String {
        var b64 = Data(bytes).base64EncodedString()
        while b64.hasSuffix("=") { b64.removeLast() }
        return "{\"/\":{\"bytes\":\"\(b64)\"}}"
    }

    /// `postSwap`: the reply of a 200 answer that is one; otherwise a `RelayError`.
    static func postSwap(_ http: any HTTPTransport, base: String, body: [UInt8]) async throws -> SwapReply {
        let url = "\(OpenExchangeURLs.trimTrailingSlashes(base))/swap"
        guard let target = URL(string: url) else { throw OpenExchangeError.failed("Invalid URL: \(url)") }
        let response = try await http.send(HTTPRequest(
            method: "POST", url: target, headers: ["content-type": "application/json", "accept": "application/json"], body: body
        ))
        let answer = JSONValue.parse(response.body)
        if response.statusCode == 200, let answer, case .object = answer, answer["ok"] != nil {
            return try parseSwapReply(answer)
        }
        throw RelayError(
            code: answer?["code"]?.string ?? "HTTP \(response.statusCode)",
            message: answer?["description"]?.string ?? String(String(decoding: response.body, as: UTF8.self).prefix(200)),
        )
    }

    /// `parseSwapReply`.
    static func parseSwapReply(_ r: JSONValue) throws -> SwapReply {
        guard case .bool(let ok)? = r["ok"] else { throw OpenExchangeError.failed("relay: not a swap reply") }
        if ok {
            guard let tx = readBytes(r["tx"]), let txid = r["txid"]?.string else {
                throw OpenExchangeError.failed("relay: accepted without tx / txid")
            }
            return .accepted(tx: tx, txid: txid)
        }
        let detail = r["detail"]?.string ?? ""
        let reason = (r["reason"]?.string ?? "refused") + (detail.isEmpty ? "" : ": \(detail)")
        if r["reason"]?.string == "unreachable" { return .unreachable(reason: reason) }
        let pool: AMMPoolState? = if case .object? = r["pool"] { toPoolState(r["pool"]!) } else { nil }
        return .refused(reason: reason, pool: pool)
    }

    /// `readBytes`: a byte array, hex, or DAG-JSON bytes.
    static func readBytes(_ x: JSONValue?) -> [UInt8]? {
        guard let x else { return nil }
        if let items = x.array {
            var out: [UInt8] = []
            for item in items {
                guard let n = item.number, n == n.rounded(), n >= 0, n < 256 else { return nil }
                out.append(UInt8(n))
            }
            return out
        }
        if let text = x.string {
            let lower = text.lowercased()
            guard !lower.isEmpty, lower.utf8.count % 2 == 0, let bytes = Runar.hexBytesChecked(lower) else { return nil }
            return bytes
        }
        guard let b = x["/"]?["bytes"]?.string else { return nil }
        let padded = b + String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: padded).map(Array.init)
    }

    /// `toPoolState`: a refusal's pool, nil for a closed one or anything else.
    static func toPoolState(_ p: JSONValue) -> AMMPoolState? {
        if let closed = p["closed"], closed != .null, closed != .bool(false), closed != .number(0), closed != .string("") { return nil }
        func num(_ keys: String...) -> JSONValue? {
            keys.lazy.compactMap { key -> JSONValue? in
                switch p[key] {
                case .number?, .string?: p[key]
                default: nil
                }
            }.first
        }
        let rawID = p["validatorIdentityKey"] ?? p["validatorIdentity"]
        let identity: String? = if let text = rawID?.string { text } else if let bytes = readBytes(rawID), bytes.count == 33 { AMMPool.hex(bytes) } else { nil }
        guard let outpoint = p["outpoint"]?.string, let bsv = num("bsvReserve"), let tokens = num("tokenReserve"),
              let lp = num("liquidityFeeBps", "lpFeeBps"), let val = num("validationFeeBps", "validatorFeeBps"), let identity,
              let bsvReserve = try? JS.bigInt(bsv), let tokenReserve = try? JS.bigInt(tokens),
              let lpBps = try? JS.bigInt(lp), let valBps = try? JS.bigInt(val),
              let commission = try? JS.bigInt(num("commissionBps") ?? .number(0)) else { return nil }
        return AMMPoolState(
            outpoint: outpoint, bsvReserve: bsvReserve, tokenReserve: tokenReserve, liquidityFeeBps: lpBps,
            validationFeeBps: valBps, commissionBps: commission, validatorIdentityKey: identity
        )
    }

    /// The page's patience: `operation`'s result, or `PatienceError` once `ms` pass (the request
    /// is then cancelled).
    static func withPatience<T: Sendable>(_ ms: Int, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                throw PatienceError(ms: ms)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PatienceError(ms: ms) }
            return first
        }
    }
}

// MARK: - Staging (market/activeSwap.ts `stage`; with tokens, OpenExchangeSwapStage.swift)

/// `Staged`: what `stage` put in the swap basket.
public struct OpenExchangeStaged: Equatable, Sendable {
    public let txid: String
    /// The staging transaction, Atomic BEEF.
    public let atomicBEEF: [UInt8]
    /// The sats row; nil: tokens staged with no sats lacking.
    public let sats: OpenExchangeSatsRow?
    /// The token row (a sell's).
    public let tokens: OpenExchangeTokenRow?
    /// The token row filed in `amm-swap`.
    public let filed: Bool
    /// The page's submit to the token's topic, in words (`steakText`).
    public let submitted: String
    /// The submit's and the filing's failures.
    public let errors: [String]
    /// What the staging was funded with against the change basket's coins chosen for it; nil when
    /// storage chose them (not in the TS).
    public var funding: ColorFundingReport? = nil
}

extension OpenExchangeSwapLeg {
    /// `stage` of sats alone: ONE createAction of one P2PKH output of `sats` to a fresh
    /// `[2, "amm swap"]` key into the swap basket, its customInstructions `swapSatsInstructions`,
    /// labelled `amm-swap`. Not in the TS: it is funded with the change basket's best coins
    /// (`OpenExchangeSwapFunding`: confirmed first) as a noSend with `noSendChange`, then sent
    /// alone with `sendWith`; when the basket cannot be read or lists no coin it is the TS's plain
    /// broadcast action, storage choosing the change.
    public static func stageSats(
        _ ctx: OneColorContext, sats: UInt64, sym: String? = nil, randomKeyID: [UInt8]? = nil,
        feeRateSatsPerKb: Double = OpenExchangeQuotes.defaultFeeRateSatsPerKb
    ) async throws -> OpenExchangeStaged {
        guard sats > 0, sats <= AMMPoolCall.maxSafeInteger else { throw fail("nothing to stage in the swap basket") }
        let request = try stageRequest(ctx, sats: sats, sym: sym ?? "token", keyID: OpenExchangeSwapNames.newSwapKeyID(random: randomKeyID))
        let script = request.outputs![0].lockingScript
        let keyID = keyOf(request.outputs![0].customInstructions)!.keyID
        let box = OpenExchangeFundingReportBox()
        let funding = await OpenExchangeSwapFunding.funding(
            ctx, need: OpenExchangeSwapFunding.need(outputs: sats, callerInputs: 0, feeRateSatsPerKb: feeRateSatsPerKb),
            what: "stage of \(sats) sats", onFunding: { box.set($0) }
        )
        let done = try await ColorPlainAction.run(ctx, request: request, funding: funding) { _ in [:] }
        guard done.transaction.outputs.first?.lockingScript.bytes == script else {
            throw fail("the wallet's action has no output 0 to the swap key")
        }
        return OpenExchangeStaged(txid: done.txid, atomicBEEF: done.atomicBEEF, sats: OpenExchangeSatsRow(
            outpoint: "\(done.txid).0", txid: done.txid, vout: 0, satoshis: sats, lockingScript: script,
            protocolID: try OpenExchangeSwapNames.swapProtocol(), keyID: keyID, counterparty: "self", order: nil
        ), tokens: nil, filed: false, submitted: "not submitted (no token moved)", errors: [], funding: box.value)
    }

    /// The staging createAction, as `stage` sends it.
    static func stageRequest(_ ctx: OneColorContext, sats: UInt64, sym: String, keyID: String) throws -> WalletCreateActionRequest {
        let key = try swapKey(ctx, keyID: keyID)
        return try WalletCreateActionRequest(
            description: OpenExchangeSwapNames.describe("AMM swap: sats into the swap basket"),
            outputs: [try WalletCreateActionOutput(
                lockingScript: AMMPoolCall.p2pkh(pkh(key)), satoshis: sats,
                outputDescription: OpenExchangeSwapNames.describe("Sats for a \(sym) swap"),
                basket: OpenExchangeSwapNames.basket,
                customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: keyID)
            )],
            labels: [OpenExchangeSwapNames.label],
            options: try WalletCreateActionOptions(signAndProcess: false, acceptDelayedBroadcast: false, randomizeOutputs: false)
        )
    }

    /// `swapSatsTotal`: the sats the swap basket's sats rows hold.
    public static func swapBasketSats(_ ctx: OneColorContext) async throws -> UInt64 {
        try await satsHoldings(ctx).reduce(0) { $0 + $1.satoshis }
    }
}
