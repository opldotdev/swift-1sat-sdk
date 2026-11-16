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
import OneSatSweep
import OneSatTemplates
import ToolboxAuth

// A sell's side of the swap basket (skein-amm 0.55.1 market/activeSwap.ts `stage` with tokens,
// `moveBack`, `unfiledStagedTokens`, `fileStagedToken`; lp/close.ts `submitToOverlay`,
// `steakText`; market/swapAction.ts `submissionBeef`): tokens go into `amm-swap` by a module
// transfer to a swap key, are filed there, and come back by a module plan whose one output the
// wallet keeps; the page submits each to the token's topic at the host root itself.

/// BRC-22's STEAK: per topic, in the answer's order, the outputs admitted.
public struct OpenExchangeSteak: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let topic: String
        public let outputsToAdmit: [Int]
    }

    public let entries: [Entry]
}

/// `UnfiledStaged`: a staged token output the swap basket lacks.
public struct OpenExchangeUnfiledStaged: Equatable, Sendable {
    public let txid: String
    public let vout: Int
    /// `<txid>_<vout>`.
    public let tokenId: String
    public let amount: BigInt
    public let keyID: String
}

extension OpenExchange {
    /// The page's submit: the topic and an Atomic BEEF in; the host's STEAK, or nil when the host
    /// has not decided yet (503).
    public typealias Submit = @Sendable (_ topic: String, _ beef: [UInt8]) async throws -> OpenExchangeSteak?

    /// `xTopics`: the BRC-22 JSON array.
    static func xTopics(_ topics: [String]) -> String {
        StrictJSON.array(topics.map { .string($0) }).serialized
    }

    /// `submissionBeef`: an Atomic BEEF submitted to `tm_color_<tokenId>` as `topicBeef` of its
    /// subject, admitted by `topicAdmitted` of the token's pool asset id (the pool's transaction
    /// not known here; a token with a 36-byte id admits nothing), in the Atomic envelope. Any other
    /// topic, or a BEEF that is not Atomic, is sent as given.
    public static func submissionBEEF(topic: String, _ bytes: [UInt8]) throws -> [UInt8] {
        let prefix = "tm_color_"
        guard topic.hasPrefix(prefix), let ref = AMMTokenID.parse(String(topic.dropFirst(prefix.count))) else { return bytes }
        guard bytes.starts(with: [0x01, 0x01, 0x01, 0x01]) else {
            // `Beef.fromBinary` reads it (and throws on bytes that are no BEEF); not Atomic: as given.
            _ = try BEEF(bytes: bytes, limits: beefLimits, transactionOrder: .any)
            return bytes
        }
        // `Beef.fromBinary`: the envelope read as given, its ancestry not required complete (an
        // ancestor it lacks becomes txid-only in `topicBeef`).
        guard bytes.count >= 36 else { throw OpenExchangeSwapLeg.fail("the Atomic BEEF is \(bytes.count) bytes: too short") }
        let id = try TransactionID(wireBytes: Array(bytes[4..<36]))
        let beef = try BEEF(bytes: Array(bytes[36...]), limits: beefLimits, transactionOrder: .any)
        let admitted: (String, Transaction?) -> Bool = ref.vout == 0
            ? OpenExchangeSwapLeg.topicAdmitted(assetId: try OpenExchangeSwapLeg.assetIdOf(ref.txid), poolTxid: "")
            : { _, _ in false }
        return try OpenExchangeSwapLeg.topicBEEF(beef, subjects: [id.displayHex], admitted: admitted, atomic: id.displayHex)
    }

    /// `submitToOverlay`: `POST <origin>/submit`, `x-topics` the topic, the body
    /// `submissionBeef`. 503: no STEAK yet (nil); any other refusal throws with the host's answer
    /// in full; a 2xx that is not a JSON object throws.
    public func submitToOverlay(topic: String, beef: [UInt8]) async throws -> OpenExchangeSteak? {
        let url = "\(try WebURL(base).origin)/submit"
        guard let target = URL(string: url) else { throw OpenExchangeError.failed("Invalid URL: \(url)") }
        let body = try Self.submissionBEEF(topic: topic, beef)
        let response = try await http.send(HTTPRequest(
            method: "POST", url: target,
            headers: ["content-type": "application/octet-stream", "x-topics": Self.xTopics([topic])], body: body
        ))
        let text = String(decoding: response.body, as: UTF8.self)
        if response.statusCode == 503 { return nil }
        guard (200..<300).contains(response.statusCode) else {
            Self.logHTTP("submitToOverlay", method: "POST", url: url, status: response.statusCode, body: response.body)
            throw OpenExchangeError.failed("POST \(url): \(response.statusCode) \(text)")
        }
        guard let steak = Self.steak(text) else {
            Self.logHTTP("submitToOverlay: the answer is not a STEAK", method: "POST", url: url, status: response.statusCode, body: response.body)
            throw OpenExchangeError.failed("POST \(url): want the STEAK, got \(String(text.prefix(300)))")
        }
        return steak
    }

    /// A STEAK: a JSON object of topics, each with its `outputsToAdmit`; nil for anything else.
    static func steak(_ text: String) -> OpenExchangeSteak? {
        guard let value = try? StrictJSON.parse(text, label: "STEAK"), case .object(let members) = value else { return nil }
        var entries: [OpenExchangeSteak.Entry] = []
        for (topic, entry) in members {
            guard case .array(let admitted)? = entry["outputsToAdmit"] else { return nil }
            var outputs: [Int] = []
            for item in admitted {
                guard case .number(let n) = item, let index = Int(exactly: n) else { return nil }
                outputs.append(index)
            }
            entries.append(OpenExchangeSteak.Entry(topic: topic, outputsToAdmit: outputs))
        }
        return OpenExchangeSteak(entries: entries)
    }

    /// `steakText`: the topics that admitted outputs, else "taken by no topic"; no STEAK, "not
    /// decided yet".
    public static func steakText(_ steak: OpenExchangeSteak?) -> String {
        guard let steak else { return "not decided yet" }
        let took = steak.entries.filter { !$0.outputsToAdmit.isEmpty }
            .map { "\($0.topic) (outputs \($0.outputsToAdmit.map(String.init).joined(separator: ", ")))" }
        return took.isEmpty ? "taken by no topic" : "admitted under \(took.joined(separator: "; "))"
    }

    /// `submitAt(swapBase)`: the page's submit at this host's root.
    public var submitter: Submit {
        { [self] topic, beef in try await self.submitToOverlay(topic: topic, beef: beef) }
    }

    /// `moveBackTokens` (client.ts): the swap basket's rows of `tokenId` and every sats row back
    /// to the wallet in one module plan, submitted at this host's root; with sats rows alone, the
    /// plain move back of the sats.
    public func moveBackTokens(_ ctx: OneColorContext, tokenId: String, sym: String = "token") async throws -> OpenExchangeMovedBack {
        do {
            return try await OpenExchangeSwapLeg.moveBack(ctx, tokenId: tokenId, sym: sym, submit: submitter)
        } catch {
            throw OpenExchangeError.of(error)
        }
    }
}

extension OpenExchangeSwapLeg {
    // MARK: - The staged token's key, in its output's description

    /// `swapKeyDescription`: the readable text (at most 50 characters), then `SWAP_KEY_MARK` and
    /// the key ID's hex.
    public static func swapKeyDescription(_ readable: String, keyID: String) throws -> String {
        let hex = keyID.hasPrefix(OpenExchangeSwapNames.keyPrefix) ? String(keyID.dropFirst(OpenExchangeSwapNames.keyPrefix.count)) : ""
        guard isKeyHex(hex) else { throw fail("not a staged key id: \(keyID)") }
        return OpenExchangeSwapNames.describe(readable) + OpenExchangeSwapNames.keyMark + hex
    }

    /// `swapKeyIdOfDescription`: the key ID a staged token output's description names
    /// (`/ · amm-swap ([0-9a-f]{2,128})$/`, an even count of digits), or nil.
    public static func swapKeyIdOfDescription(_ description: String?) -> String? {
        guard let description, let mark = description.range(of: OpenExchangeSwapNames.keyMark, options: .backwards) else { return nil }
        let hex = String(description[mark.upperBound...])
        guard isKeyHex(hex), hex.utf8.count % 2 == 0 else { return nil }
        return OpenExchangeSwapNames.keyPrefix + hex
    }

    /// `/^[0-9a-f]{2,128}$/`.
    static func isKeyHex(_ text: String) -> Bool {
        (2...128).contains(text.utf8.count) && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    // MARK: - stage

    /// `stage`: ONE wallet action that puts what a swap lacks in the swap basket. Sats alone are a
    /// plain action (`stageSats`). With tokens it is the module's transfer of `tokens.amount` to a
    /// fresh swap key at output 0 (its description naming the key), the sats output at 1 when
    /// `sats` > 0, labelled `amm-swap` and `amm-swap-stage`; then the page's own submit to the
    /// token's topic and the filing of the token row in `amm-swap`, each failure reported in
    /// `errors`. Throws when the wallet or the module refuses or fails the action. The sats key
    /// is drawn first, then the token key (`randomKeyIDs`, tests only, in that order).
    public static func stage(
        _ ctx: OneColorContext, sats: UInt64, tokens: (tokenId: String, amount: BigInt)? = nil, sym: String? = nil,
        submit: OpenExchange.Submit? = nil, randomKeyIDs: [[UInt8]]? = nil
    ) async throws -> OpenExchangeStaged {
        guard sats <= AMMPoolCall.maxSafeInteger, sats > 0 || tokens != nil else { throw fail("nothing to stage in the swap basket") }
        let sym = sym ?? "token"
        guard let tokens else {
            return try await stageSats(ctx, sats: sats, sym: sym, randomKeyID: randomKeyIDs?.first)
        }
        let satsRequest = try stageRequest(ctx, sats: sats, sym: sym, keyID: OpenExchangeSwapNames.newSwapKeyID(random: randomKeyIDs?.first))
        let satsOutput = satsRequest.outputs![0]
        let satsKeyID = keyOf(satsOutput.customInstructions)!.keyID
        guard tokens.amount > 0 else { throw fail("nothing to stage in the swap basket") }
        let tokenId = try AMMTokenID.canonical(tokens.tokenId)
        guard let asset = AMMTokenID.parse(tokenId) else { throw fail("not a token id: \(tokens.tokenId)") }
        let keyID = OpenExchangeSwapNames.newSwapKeyID(random: randomKeyIDs.flatMap { $0.count > 1 ? $0[1] : nil })
        let tokenScript = try AMMPoolCall.tokenP2pkh(
            AMMPool.hex(try OneColor.idFromString(tokenId)), tokens.amount, pkh(try swapKey(ctx, keyID: keyID))
        )
        let description = OpenExchangeSwapNames.describe("AMM swap: \(sym) into the swap basket")
        let outputs = [try WalletCreateActionOutput(
            lockingScript: tokenScript, satoshis: 1, outputDescription: try swapKeyDescription("\(sym) for a swap", keyID: keyID)
        )] + (sats > 0 ? [satsOutput] : [])
        let done = await OneColorActions.transfer(
            ctx, assetID: asset, outputs: outputs, description: description,
            labels: [OpenExchangeSwapNames.label, OpenExchangeSwapNames.stageLabel], acceptDelayedBroadcast: false
        )
        if let error = done.error {
            if let txid = done.txid {
                OneSatLog.error("OpenExchange stage: the staging transaction \(txid) was broadcast, then: \(error)", category: OpenExchange.logCategory)
            }
            throw fail(error)
        }
        guard let txid = done.txid, let tx = done.tx else { throw fail("the wallet's action returned no transaction") }
        let final = try ColorBEEF.open(tx).transaction
        guard final.outputs.first?.lockingScript.bytes == tokenScript,
              sats == 0 || (final.outputs.count > 1 && final.outputs[1].lockingScript.bytes == satsOutput.lockingScript) else {
            throw fail("the wallet's action does not have the staged outputs at 0 and 1")
        }
        let swapProtocol = try OpenExchangeSwapNames.swapProtocol()
        let satsRow = sats > 0 ? OpenExchangeSatsRow(
            outpoint: "\(txid).1", txid: txid, vout: 1, satoshis: sats, lockingScript: satsOutput.lockingScript,
            protocolID: swapProtocol, keyID: satsKeyID, counterparty: "self", order: nil
        ) : nil
        let tokenRow = OpenExchangeTokenRow(
            outpoint: "\(txid).0", txid: txid, vout: 0, satoshis: 1, lockingScript: tokenScript, amount: tokens.amount,
            protocolID: swapProtocol, keyID: keyID, counterparty: "self", order: nil
        )
        var submitted = "not submitted"
        var filed = false
        var errors: [String] = []
        if let submit {
            do {
                submitted = OpenExchange.steakText(try await submit("tm_color_\(tokenId)", tx))
            } catch {
                submitted = "the submit failed"
                errors.append("submit: \(OpenExchangeError.errorText(error))")
            }
        }
        do {
            filed = try await ColorInternalize.run(
                ctx, atomicBEEF: tx,
                outputs: [.basketInsertion(outputIndex: 0, basket: OpenExchangeSwapNames.basket, customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: keyID))],
                description: description, labels: [OpenExchangeSwapNames.label]
            )
        } catch {
            errors.append("internalizeAction: \(OpenExchangeError.errorText(error))")
        }
        for e in errors { OneSatLog.error("OpenExchange stage \(txid): \(e)", category: OpenExchange.logCategory) }
        return OpenExchangeStaged(txid: txid, atomicBEEF: tx, sats: satsRow, tokens: tokenRow, filed: filed, submitted: submitted, errors: errors)
    }

    // MARK: - Unfiled staged tokens

    /// `unfiledStagedTokens`: every output of an action labelled `amm-swap-stage` whose description
    /// names a staged key and whose script is a 1Color value output, its basket not `amm-swap`. A
    /// wallet that refuses the read: none (logged).
    public static func unfiledStagedTokens(_ ctx: OneColorContext) async -> [OpenExchangeUnfiledStaged] {
        var out: [OpenExchangeUnfiledStaged] = []
        do {
            let r = try await ctx.storage.colorListActions(ctx.auth, try WalletListActionsRequest(
                labels: [OpenExchangeSwapNames.stageLabel], includeOutputs: true, includeOutputLockingScripts: true,
                pagination: try WalletPagination(limit: 1000)
            ))
            for a in r.actions {
                for o in a.outputs ?? [] {
                    guard let keyID = swapKeyIdOfDescription(o.outputDescription), let script = o.lockingScript,
                          let t = AMMPool.decodeOneColor(script), t.role == .value, let id = t.idBytes,
                          o.basket != OpenExchangeSwapNames.basket else { continue }
                    out.append(OpenExchangeUnfiledStaged(
                        txid: a.transactionID.displayHex, vout: Int(o.outputIndex), tokenId: try tokenIdOfWire(id),
                        amount: BigInt(t.amount), keyID: keyID
                    ))
                }
            }
        } catch {
            OneSatLog.error(error, "OpenExchange: the staging history could not be read", category: OpenExchange.logCategory)
            return []
        }
        return out
    }

    /// `fileStagedToken`: one unfiled staged token output filed in `amm-swap` from its
    /// transaction's Atomic BEEF (a basket insertion, as `stage` files it).
    public static func fileStagedToken(_ ctx: OneColorContext, _ u: OpenExchangeUnfiledStaged, beef: [UInt8]) async throws -> Bool {
        try await ColorInternalize.run(
            ctx, atomicBEEF: beef,
            outputs: [.basketInsertion(outputIndex: UInt32(u.vout), basket: OpenExchangeSwapNames.basket, customInstructions: OpenExchangeSwapNames.swapInstructions(keyID: u.keyID))],
            description: "AMM swap: a staged token filed", labels: [OpenExchangeSwapNames.label]
        )
    }

    // MARK: - Move back (tokens)

    /// `moveBack`: the swap basket's rows of `tokenId` and every sats row spent in ONE module plan
    /// whose one output (the whole amount, 1 sat) is locked to a new receiving key of the
    /// wallet's own, the plan's owned output 0, filed by the module with its custody; the wallet's
    /// change takes the sats. The rows are unlocked here, each checked to validate. Then the
    /// page's submit to the token's topic, a failure reported in `errors`. With no token row and
    /// sats rows, `moveBackSats`; with neither, it throws. `derivation` is for tests only.
    public static func moveBack(
        _ ctx: OneColorContext, tokenId: String, sym: String = "token", submit: OpenExchange.Submit?,
        derivation: (derivationPrefix: String, derivationSuffix: String)? = nil
    ) async throws -> OpenExchangeMovedBack {
        let canonical = try AMMTokenID.canonical(tokenId)
        guard let asset = AMMTokenID.parse(canonical) else { throw fail("not a token id: \(tokenId)") }
        let rows = try await basketRows(ctx)
        let holdings = try tokenRows(rows, tokenId: canonical)
        let sats = satsRows(rows)
        if holdings.isEmpty, !sats.isEmpty { return try await moveBackSats(ctx, sym: sym, rows: sats) }
        if holdings.isEmpty { throw fail("the swap basket holds no \(sym)") }
        let amount = holdings.reduce(BigInt(0)) { $0 + $1.amount }
        let sources = try await basketBEEF(ctx) ?? BEEF(version: .v2, merklePaths: [], transactions: [], limits: beefLimits)
        let spends = holdings.map { BasketSpend(outpoint: $0.outpoint, txid: $0.txid, vout: $0.vout, protocolID: $0.protocolID, keyID: $0.keyID, counterparty: $0.counterparty) }
            + sats.map { BasketSpend(outpoint: $0.outpoint, txid: $0.txid, vout: $0.vout, protocolID: $0.protocolID, keyID: $0.keyID, counterparty: $0.counterparty) }
        for row in spends where try sources.entry(for: try TransactionID(displayHex: row.txid), limits: txLimits) == nil {
            throw fail("the wallet's BEEF lacks the swap basket output \(row.outpoint)")
        }

        // The output: the whole amount to a module receiving key of the wallet's own.
        let d = derivation ?? (randomBase64(16), randomBase64(16))
        let key = try receivingKey(ctx, tokenId: canonical, d)
        let custody = try ColorCustody(
            asset: .asset(asset), derivationPrefix: d.derivationPrefix, derivationSuffix: d.derivationSuffix, senderIdentityKey: ctx.identityKey
        )
        let lockingScript = try AMMPoolCall.tokenP2pkh(AMMPool.hex(try OneColor.idFromString(canonical)), amount, pkh(key.publicKey))
        let inputs = try holdings.map {
            try WalletCreateActionInput(
                outpoint: try Outpoint($0.outpoint), inputDescription: OpenExchangeSwapNames.describe("\(sym) in the swap basket"),
                unlockingScriptLength: UInt32(OpenExchangeSwapNames.p2pkhUnlockLength)
            )
        } + sats.map {
            try WalletCreateActionInput(
                outpoint: try Outpoint($0.outpoint), inputDescription: OpenExchangeSwapNames.describe("Sats in the swap basket"),
                unlockingScriptLength: UInt32(OpenExchangeSwapNames.p2pkhUnlockLength)
            )
        }
        let done = try await ColorAppSignedTransfer.run(
            ctx, assetID: asset, description: OpenExchangeSwapNames.describe("AMM move back: \(sym)"), inputBEEF: sources,
            inputs: inputs,
            outputs: [try WalletCreateActionOutput(lockingScript: lockingScript, satoshis: 1, outputDescription: OpenExchangeSwapNames.describe("\(sym) back to your wallet"))],
            owned: [.init(outputIndex: 0, custody: custody)], labels: [OpenExchangeSwapNames.label]
        ) { tx in try basketSpends(ctx, tx, spends, what: "move back") }

        var submitted = "not submitted"
        var errors: [String] = []
        if let submit {
            do {
                submitted = OpenExchange.steakText(try await submit("tm_color_\(canonical)", done.atomicBEEF))
            } catch {
                submitted = "the submit failed"
                errors.append("submit: \(OpenExchangeError.errorText(error))")
                OneSatLog.error("OpenExchange move back \(done.txid): submit: \(OpenExchangeError.errorText(error))", category: OpenExchange.logCategory)
            }
        }
        return OpenExchangeMovedBack(txid: done.txid, atomicBEEF: done.atomicBEEF, amount: amount, submitted: submitted, errors: errors)
    }

    /// `swapBasketSpends`: the page's unlocking scripts for the swap basket rows in the wallet's
    /// transaction, each checked to validate.
    static func basketSpends(_ ctx: OneColorContext, _ tx: Transaction, _ rows: [BasketSpend], what: String) throws -> [Int: Script] {
        var spends: [Int: Script] = [:]
        var signed = tx
        for row in rows {
            guard let n = signed.inputs.firstIndex(where: { outpointText($0.previousOutput) == row.outpoint }) else {
                throw fail("the wallet's \(what) does not spend the swap basket output \(row.outpoint)")
            }
            signed.inputs[n].unlockingScript = try unlock(ctx, signed, n, row)
            if !spendValid(signed, n) { throw fail("input \(n) of the \(what) does not validate") }
            spends[n] = signed.inputs[n].unlockingScript
        }
        return spends
    }

    /// `randomBase64(n)`: n random bytes, base64.
    static func randomBase64(_ n: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &generator) }).base64EncodedString()
    }
}
