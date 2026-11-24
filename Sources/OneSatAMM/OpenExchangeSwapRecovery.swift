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
import OneSatSweep

// The overlay pass and the move back of the swap basket (skein-amm 0.55.1 wallet/swapPayouts.ts,
// market/activeSwap.ts `moveBackSats`, lib/overlay.ts `readSpendsAll` / `readTx`): the overlay is
// the truth about an `amm-swap` row, not the wallet's own flag. Every row is asked in one
// `/spends` read; a spender's transaction is read from its token's `/tx`; a spender that pays
// this wallet's keys for one of its orders is taken in with ONE internalizeAction; again, until
// no row has a spender the wallet lacks.

/// `SpendAll` (lib/overlay.ts): one outpoint's spender as the host's H9 answers it.
public struct OpenExchangeSpend: Equatable, Sendable {
    /// `<txid>.<vout>`.
    public let outpoint: String
    public let tokenId: String?
    /// Lowercase.
    public let spentBy: String?

    public init(outpoint: String, tokenId: String?, spentBy: String?) {
        self.outpoint = outpoint
        self.tokenId = tokenId
        self.spentBy = spentBy
    }
}

/// `ResolvedLeg`: a leg the pass took in.
public struct OpenExchangeResolvedLeg: Equatable, Sendable {
    public let txid: String
    public let tokenId: String
    /// The outpoints it spends, `<txid>.<vout>`, the pool's first.
    public let inputs: [String]
    /// Output 1's satoshis, and its tokens when it is a token output.
    public let payoutSatoshis: UInt64
    public let payoutTokens: BigInt?
}

/// `StuckRow`: a row whose spender the pass could not take in, the spender and why.
public struct OpenExchangeStuckRow: Equatable, Sendable {
    public let outpoint: String
    public let spentBy: String
    public let error: String
}

/// `Resolved`: the legs taken in, and the rows left stuck.
public struct OpenExchangeResolved: Equatable, Sendable {
    public let taken: [OpenExchangeResolvedLeg]
    public let stuck: [OpenExchangeStuckRow]
}

/// What `settleSwaps` did on one load.
public struct OpenExchangeSettled: Equatable, Sendable {
    /// The staged token outputs filed in the swap basket on this load: each one's outpoint, token
    /// id and amount.
    public let filed: [OpenExchangeUnfiledStaged]
    /// The overlay pass that followed (`resolveSwaps`).
    public let resolved: OpenExchangeResolved
    /// The txids taken in: the TS's return value.
    public var taken: [String] { resolved.taken.map(\.txid) }

    public init(filed: [OpenExchangeUnfiledStaged], resolved: OpenExchangeResolved) {
        self.filed = filed
        self.resolved = resolved
    }
}

/// The pass's two reads: H9 `/spends` over outpoints, P9 `/tx` of a spender (nil: not held).
public struct OpenExchangeSwapReads: Sendable {
    public let spendsAll: @Sendable ([String]) async throws -> [OpenExchangeSpend]
    public let tx: @Sendable (_ tokenId: String, _ txid: String) async throws -> [UInt8]?

    public init(
        spendsAll: @escaping @Sendable ([String]) async throws -> [OpenExchangeSpend],
        tx: @escaping @Sendable (_ tokenId: String, _ txid: String) async throws -> [UInt8]?
    ) {
        self.spendsAll = spendsAll
        self.tx = tx
    }
}

/// `MovedBack`: the action that took the swap basket's rows back to the wallet.
public struct OpenExchangeMovedBack: Equatable, Sendable {
    public let txid: String
    /// The transaction, Atomic BEEF.
    public let atomicBEEF: [UInt8]
    /// The tokens moved back (0: the sats alone).
    public let amount: BigInt
    /// The page's submit to the token's topic, in words (`steakText`).
    public let submitted: String
    /// The submit's failure.
    public let errors: [String]
}

extension OpenExchangeSwapLeg {
    // MARK: - A spender's take-in

    /// The transaction with each input's source output from `beef` (`Transaction.fromAtomicBEEF`
    /// links them); an input whose source is absent keeps none.
    static func withSources(_ tx: Transaction, from beef: BEEF) throws -> Transaction {
        var out = tx
        for n in out.inputs.indices {
            let previous = out.inputs[n].previousOutput
            if let source = try beef.transaction(for: previous.transactionID, limits: txLimits),
               source.outputs.indices.contains(Int(previous.outputIndex)) {
                out.inputs[n].sourceOutput = source.outputs[Int(previous.outputIndex)]
            }
        }
        return out
    }

    /// `legInputsOf`: the leg's inputs after the pool's, `<txid>.<vout>`, sats and tokens apart;
    /// an input without its source is in neither.
    static func legInputs(_ tx: Transaction) -> (sats: [String], tokens: [String]) {
        var sats: [String] = []
        var tokens: [String] = []
        for input in tx.inputs.dropFirst() {
            guard let source = input.sourceOutput else { continue }
            let outpoint = "\(input.previousOutput.transactionID.displayHex).\(input.previousOutput.outputIndex)"
            if AMMPool.decodeOneColor(source.lockingScript.bytes) != nil { tokens.append(outpoint) } else { sats.append(outpoint) }
        }
        return (sats, tokens)
    }

    /// `ownKeyInputOf`: the swap's own key input, its first sats input on a buy (output 1 a
    /// token), its first token input on a sell; nil without one.
    public static func ownKeyInput(_ tx: Transaction) -> String? {
        guard tx.outputs.count > 1 else { return nil }
        let bsvIn = AMMPool.decodeOneColor(tx.outputs[1].lockingScript.bytes) != nil
        let ins = legInputs(tx)
        return bsvIn ? ins.sats.first : ins.tokens.first
    }

    /// `legTakeInOf`: the take-in of a swap leg (a pool at input 0 and output 0) under `order`:
    /// output 1 must pay the order's payout key (else nil: another's swap); then each other output
    /// that pays one of the order's keys — the taker's own commission, the change kept in
    /// `amm-swap`, or the last leg's change to the wallet.
    static func legTakeIn(_ ctx: OneColorContext, _ tx: Transaction, tokenId: String, order: String) throws -> [ColorInternalize.Output]? {
        guard tx.outputs.count >= 2, tx.inputs.count >= 2, AMMPool.decode(tx.outputs[0].lockingScript.bytes) != nil else { return nil }
        let identity = ctx.identityKey
        let assetHex = AMMPool.hex(try OneColor.idFromString(try AMMTokenID.canonical(tokenId)))
        let ins = legInputs(tx)
        func keyed(_ vout: Int, _ which: OpenExchangeSwapNames.Derivation) throws -> ColorInternalize.Output? {
            let out = tx.outputs[vout]
            let script = out.lockingScript.bytes
            let d = OpenExchangeSwapNames.legDerivation(order, which)
            if let token = AMMPool.decodeOneColor(script) {
                let k = try receivingKey(ctx, tokenId: tokenId, d)
                guard (try? AMMPoolCall.tokenP2pkh(assetHex, BigInt(token.amount), pkh(k.publicKey))) == script else { return nil }
                return OpenExchangeLegOutput.color(outputIndex: vout, satoshis: out.satoshis, lockingScript: script, receipt: k.receipt).internalize
            }
            guard AMMPoolCall.p2pkh(pkh(try brc29PublicKey(ctx, d))) == script else { return nil }
            return .walletPayment(outputIndex: UInt32(vout), derivationPrefix: d.derivationPrefix, derivationSuffix: d.derivationSuffix, senderIdentityKey: identity)
        }
        guard let payout = try keyed(1, .payout) else { return nil }
        var outs = [payout]
        func change(_ first: String?) throws -> (keyID: String, pkh: [UInt8])? {
            guard let first else { return nil }
            let keyID = try OpenExchangeSwapNames.changeKeyID(first)
            return (keyID, pkh(try swapKey(ctx, keyID: keyID)))
        }
        let satsChange = try change(ins.sats.first)
        let tokenChange = try change(ins.tokens.first)
        for vout in 2..<tx.outputs.count {
            let script = tx.outputs[vout].lockingScript.bytes
            let token = AMMPool.decodeOneColor(script)
            if let token, let tokenChange, (try? AMMPoolCall.tokenP2pkh(assetHex, BigInt(token.amount), tokenChange.pkh)) == script {
                outs.append(.basketInsertion(outputIndex: UInt32(vout), basket: OpenExchangeSwapNames.basket,
                                             customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: tokenChange.keyID, order: order)))
                continue
            }
            if token == nil, let satsChange, AMMPoolCall.p2pkh(satsChange.pkh) == script {
                outs.append(.basketInsertion(outputIndex: UInt32(vout), basket: OpenExchangeSwapNames.basket,
                                             customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: satsChange.keyID, order: order)))
                continue
            }
            if let mine = try keyed(vout, .commission) ?? keyed(vout, .change) { outs.append(mine) }
        }
        return outs
    }

    // MARK: - The pass

    static func outpointText(_ outpoint: Outpoint) -> String {
        "\(outpoint.transactionID.displayHex).\(outpoint.outputIndex)"
    }

    /// A row's `order` (its customInstructions'), or nil.
    static func orderOf(_ instructions: String?) -> String? {
        JSONValue.parse(Array((instructions ?? "{}").utf8))?["order"]?.string
    }

    /// `resolveFromOverlay`: the pass, at most 64 rounds. Never throws: a failed read ends it; a
    /// spender it could not take in is reported in `stuck`.
    public static func resolveFromOverlay(_ ctx: OneColorContext, reads: OpenExchangeSwapReads) async -> OpenExchangeResolved {
        var taken: [OpenExchangeResolvedLeg] = []
        var stuck: [OpenExchangeStuckRow] = []
        var tried = Set<String>()
        for _ in 0..<64 {
            let rows: [WalletOutput]
            let spends: [OpenExchangeSpend]
            do {
                rows = try await basketRows(ctx)
                if rows.isEmpty { break }
                spends = try await reads.spendsAll(rows.map { outpointText($0.outpoint) })
            } catch {
                break
            }
            let byOutpoint = Dictionary(rows.map { (outpointText($0.outpoint), $0) }, uniquingKeysWith: { a, _ in a })
            var took = false
            for s in spends {
                guard let spentBy = s.spentBy, let tokenId = s.tokenId, !tried.contains(spentBy) else { continue }
                tried.insert(spentBy)
                do {
                    guard let bytes = try await reads.tx(tokenId, spentBy) else {
                        stuck.append(OpenExchangeStuckRow(outpoint: s.outpoint, spentBy: spentBy, error: "the host served no transaction for the spender"))
                        continue
                    }
                    let (_, beef, subject) = try ColorBEEF.open(bytes)
                    let tx = try withSources(subject, from: beef)
                    let op = AMMTokenID.parseOutpoint(s.outpoint)
                    let own = op.map { "\($0.txid).\($0.vout)" }
                    let row = own.flatMap { byOutpoint[$0] }
                    var orders: [String] = []
                    for candidate in [row.flatMap { orderOf($0.customInstructions) }, own, ownKeyInput(tx)] {
                        if let candidate, !orders.contains(candidate) { orders.append(candidate) }
                    }
                    var matched = false
                    for order in orders {
                        guard let outputs = try legTakeIn(ctx, tx, tokenId: tokenId, order: order) else { continue }
                        matched = true
                        let accepted = try await ColorInternalize.run(
                            ctx, atomicBEEF: bytes, outputs: outputs, description: "AMM swap payout", labels: [OpenExchangeSwapNames.label]
                        )
                        if accepted {
                            let out1 = tx.outputs[1]
                            taken.append(OpenExchangeResolvedLeg(
                                txid: spentBy, tokenId: tokenId, inputs: tx.inputs.map { outpointText($0.previousOutput) },
                                payoutSatoshis: out1.satoshis,
                                payoutTokens: AMMPool.decodeOneColor(out1.lockingScript.bytes).map { BigInt($0.amount) }
                            ))
                            took = true
                        } else {
                            stuck.append(OpenExchangeStuckRow(outpoint: s.outpoint, spentBy: spentBy, error: "the wallet did not accept the take-in"))
                        }
                        break
                    }
                    if !matched {
                        stuck.append(OpenExchangeStuckRow(
                            outpoint: s.outpoint, spentBy: spentBy,
                            error: orders.isEmpty
                                ? "the spending transaction names no order key (its inputs' sources are missing)"
                                : "no output of the spending transaction pays this wallet's keys"
                        ))
                    }
                } catch {
                    stuck.append(OpenExchangeStuckRow(outpoint: s.outpoint, spentBy: spentBy, error: OpenExchangeError.errorText(error)))
                }
            }
            if !took { break }
        }
        return OpenExchangeResolved(taken: taken, stuck: stuck)
    }

    // MARK: - Move back (sats)

    /// `moveBackSats`: ONE plain createAction with the swap basket's sats rows as explicit inputs
    /// (their sources in `inputBEEF`) and NO outputs: the wallet keeps everything as its change and
    /// pays the fee from it. The rows are unlocked here, each checked to validate.
    public static func moveBackSats(_ ctx: OneColorContext, sym: String = "the swap", rows given: [OpenExchangeSatsRow]? = nil) async throws -> OpenExchangeMovedBack {
        let rows: [OpenExchangeSatsRow]
        if let given { rows = given } else { rows = try await satsHoldings(ctx) }
        if rows.isEmpty { throw fail("the swap basket holds no sats") }
        guard let sources = try await basketBEEF(ctx) else { throw fail("the wallet's BEEF lacks the swap basket output \(rows[0].outpoint)") }
        for row in rows where try sources.entry(for: try TransactionID(displayHex: row.txid), limits: txLimits) == nil {
            throw fail("the wallet's BEEF lacks the swap basket output \(row.outpoint)")
        }
        let request = try WalletCreateActionRequest(
            description: OpenExchangeSwapNames.describe("AMM move back: \(sym) sats"),
            inputBEEF: sources,
            inputs: try rows.map {
                try WalletCreateActionInput(
                    outpoint: try Outpoint("\($0.txid).\($0.vout)"),
                    inputDescription: OpenExchangeSwapNames.describe("Sats in the swap basket"),
                    unlockingScriptLength: UInt32(OpenExchangeSwapNames.p2pkhUnlockLength)
                )
            },
            outputs: [],
            labels: [OpenExchangeSwapNames.label],
            options: try WalletCreateActionOptions(signAndProcess: false, acceptDelayedBroadcast: false, randomizeOutputs: false)
        )
        let done = try await ColorPlainAction.run(ctx, request: request) { tx in
            var spends: [Int: Script] = [:]
            var signed = tx
            for row in rows {
                guard let n = signed.inputs.firstIndex(where: { outpointText($0.previousOutput) == row.outpoint }) else {
                    throw fail("the wallet's move back does not spend the swap basket output \(row.outpoint)")
                }
                let key = try WalletKeyDeriver(rootKey: ctx.identity).derivePrivateKey(
                    protocolID: row.protocolID, keyID: try WalletKeyID(row.keyID), counterparty: try counterparty(row.counterparty)
                )
                try signed.signPayToPublicKeyHashInput(at: n, with: key, limits: txLimits)
                if !spendValid(signed, n) { throw fail("input \(n) of the move back does not validate") }
                spends[n] = signed.inputs[n].unlockingScript
            }
            return spends
        }
        return OpenExchangeMovedBack(txid: done.txid, atomicBEEF: done.atomicBEEF, amount: 0, submitted: "not submitted (no token moved)", errors: [])
    }
}

extension OpenExchange {
    /// H9 `readSpendsAll`: `GET <swap>/spends?outpoint=a,b`, one record per outpoint (one
    /// outpoint: its object); a record without an outpoint is dropped.
    public func readSpendsAll(_ outpoints: [String]) async throws -> [OpenExchangeSpend] {
        if outpoints.isEmpty { return [] }
        do {
            let url = "\(OpenExchangeURLs.trimTrailingSlashes(base))/spends?outpoint=\(outpoints.map(Self.uriComponent).joined(separator: ","))"
            let answer = try await getJSON(url)
            let records = answer?.array ?? (answer.map { [$0] } ?? [])
            return records.compactMap { r in
                guard case .object = r, let outpoint = r["outpoint"]?.string else { return nil }
                return OpenExchangeSpend(outpoint: outpoint, tokenId: r["tokenId"]?.string, spentBy: r["spentBy"]?.string?.lowercased())
            }
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// P9 `readTx`: `GET <origin>/@<tokenId>/amm/tx?id=<txid>`, the transaction's BEEF with every
    /// input's source; nil when the instance does not hold it (404).
    public func readTx(tokenId: String, txid: String) async throws -> [UInt8]? {
        do {
            let url = "\(OpenExchangeURLs.trimTrailingSlashes(try tokenBase(tokenId)))/tx?id=\(Self.uriComponent(txid))"
            let response = try await get(url, accept: "application/octet-stream")
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                throw OpenExchangeError.failed("GET \(url): \(response.statusCode) \(Self.preview(response.body))")
            }
            return response.body
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// The pass's reads at this host.
    public var swapReads: OpenExchangeSwapReads {
        OpenExchangeSwapReads(
            spendsAll: { try await self.readSpendsAll($0) },
            tx: { try await self.readTx(tokenId: $0, txid: $1) }
        )
    }

    /// `resolve` (client.ts:1094): the overlay pass over the swap basket at this host.
    public func resolveSwaps(_ ctx: OneColorContext) async -> OpenExchangeResolved {
        await OpenExchangeSwapLeg.resolveFromOverlay(ctx, reads: swapReads)
    }

    /// `settleSwaps` (client.ts:1716): on load, each labelled staged token output the swap basket
    /// lacks filed from its action's description (its BEEF `GET /@<token>/amm/tx?id=`), then the
    /// overlay pass. Never throws: a read or a filing that fails is left for the next load, as the
    /// TS leaves it, and logged and told to `onEvent` (the TS drops it). Returns the txids taken
    /// in (the TS's return), and beside them what was filed and the pass itself (the TS keeps only
    /// whether anything was filed, for its `emit`), so a caller need not file or pass again.
    public func settleSwaps(_ ctx: OneColorContext, onEvent: (@Sendable (OpenExchangeSettleEvent) -> Void)? = nil) async -> OpenExchangeSettled {
        // Not in the TS: a staging held between its noSend and its send is sent again (or left
        // held when that throws) first, so its staged token can be filed below.
        await OpenExchangeSwapLeg.recoverHeldStages(ctx, onEvent: onEvent)
        var filed: [OpenExchangeUnfiledStaged] = []
        for u in await OpenExchangeSwapLeg.unfiledStagedTokens(ctx, onEvent: onEvent) {
            let outpoint = "\(u.txid).\(u.vout)"
            let beef: [UInt8]?
            do {
                beef = try await readTx(tokenId: u.tokenId, txid: u.txid)
            } catch {
                OneSatLog.error(error, "Open Exchange: the staged token \(outpoint) could not be read to file it", category: Self.logCategory)
                onEvent?(.unread(outpoint: outpoint, error: OpenExchangeError.errorText(error)))
                continue
            }
            guard let beef else {
                OneSatLog.error("Open Exchange: the host served no transaction for the staged token \(outpoint): not filed", category: Self.logCategory)
                onEvent?(.notServed(outpoint: outpoint))
                continue
            }
            do {
                if try await OpenExchangeSwapLeg.fileStagedToken(ctx, u, beef: beef) {
                    filed.append(u)
                    onEvent?(.filed(outpoint: outpoint))
                } else {
                    OneSatLog.error("Open Exchange: the wallet did not accept the filing of the staged token \(outpoint)", category: Self.logCategory)
                    onEvent?(.notAccepted(outpoint: outpoint))
                }
            } catch {
                OneSatLog.error(error, "Open Exchange: the staged token \(outpoint) could not be filed", category: Self.logCategory)
                onEvent?(.notFiled(outpoint: outpoint, error: OpenExchangeError.errorText(error)))
            }
        }
        return OpenExchangeSettled(filed: filed, resolved: await resolveSwaps(ctx))
    }
}
