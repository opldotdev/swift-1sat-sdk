import BigInt
import Foundation
import BSVCore
import BSVCrypto
import BSVInterpreter
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatColor
import OneSatTemplates
import ToolboxActions

/// The swap basket's names, as the TypeScript wallet writes them (wallet/color.ts,
/// market/activeSwap.ts, market/swapAction.ts): a TS wallet and this one share storage for the
/// same seed, so each is byte for byte.
public enum OpenExchangeSwapNames {
    /// `SWAP_BASKET`.
    public static let basket = "amm-swap"
    /// The label every swap action carries.
    public static let label = "amm-swap"
    /// `SWAP_PROTOCOL`: `[2, "amm swap"]`.
    public static let protocolName = "amm swap"
    /// `SWAP_KEY_PREFIX`.
    public static let keyPrefix = "amm-swap-"
    /// `SWAP_STAGE_LABEL`: a staging action that carries tokens.
    public static let stageLabel = "amm-swap-stage"
    /// `SWAP_KEY_MARK`.
    public static let keyMark = " · amm-swap "
    /// `P2PKH_UNLOCK_LENGTH`.
    public static let p2pkhUnlockLength = 108
    /// `LIST_LIMIT`.
    public static let listLimit: UInt32 = 10000
    /// `LEG_PAYOUT_PREFIX`, `LEG_COMMISSION_PREFIX`, `LEG_CHANGE_PREFIX`: base64 of "amm swap",
    /// "amm swap commission", "amm swap change".
    public static let payoutPrefix = Data("amm swap".utf8).base64EncodedString()
    public static let commissionPrefix = Data("amm swap commission".utf8).base64EncodedString()
    public static let changePrefix = Data("amm swap change".utf8).base64EncodedString()

    public enum Derivation: String, Sendable { case payout, commission, change }

    static func swapProtocol() throws -> WalletProtocolID {
        try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: protocolName)
    }

    /// `swapInstructions`: `{protocolID, keyID, counterparty, order?}`, that order.
    public static func swapInstructions(keyID: String, order: String? = nil) -> String {
        "{\"protocolID\":[2,\"amm swap\"],\"keyID\":\(JSONText.quote(keyID)),\"counterparty\":\"self\"\(order.map { ",\"order\":\(JSONText.quote($0))" } ?? "")}"
    }

    /// `swapSatsInstructions`: `{sats: true, protocolID, keyID, counterparty, order?}`, that order.
    public static func swapSatsInstructions(keyID: String, order: String? = nil) -> String {
        "{\"sats\":true,\"protocolID\":[2,\"amm swap\"],\"keyID\":\(JSONText.quote(keyID)),\"counterparty\":\"self\"\(order.map { ",\"order\":\(JSONText.quote($0))" } ?? "")}"
    }

    /// `legDerivation`: the prefix of `which`, the suffix base64(sha256(utf8 `keyInput`)).
    public static func legDerivation(_ keyInput: String, _ which: Derivation) -> (derivationPrefix: String, derivationSuffix: String) {
        let prefix = switch which {
        case .payout: payoutPrefix
        case .commission: commissionPrefix
        case .change: changePrefix
        }
        return (prefix, Data(BSVHashing.sha256(Array(keyInput.utf8)).bytes).base64EncodedString())
    }

    /// `changeKeyID`: `amm-swap-<txid>.<vout>:change` of the leg's first input.
    public static func changeKeyID(_ firstInput: String) throws -> String {
        guard let op = AMMTokenID.parseOutpoint(firstInput) else { throw OpenExchangeError.failed("not an outpoint: \(firstInput)") }
        return "amm-swap-\(op.txid).\(op.vout):change"
    }

    /// `describe`: at most 50 characters, else 49 and "…".
    static func describe(_ text: String) -> String {
        text.count <= 50 ? text : String(text.prefix(49)) + "…"
    }

    /// `newSwapKeyID`: `amm-swap-` and 16 random bytes as hex.
    static func newSwapKeyID(random: [UInt8]? = nil) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = random ?? (0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return keyPrefix + AMMPool.hex(bytes)
    }
}

/// `SatsInput`: a staged sats row of the swap basket, a P2PKH output to a `[2, "amm swap"]` key.
public struct OpenExchangeSatsRow: Equatable, Sendable {
    /// `<txid>.<vout>`.
    public let outpoint: String
    public let txid: String
    public let vout: Int
    public let satoshis: UInt64
    public let lockingScript: [UInt8]
    public let protocolID: WalletProtocolID
    public let keyID: String
    public let counterparty: String
    /// The order key of a later leg's change.
    public let order: String?
}

/// One leg's payout or change, as the wallet takes it in (`SwapPayout`).
public enum OpenExchangeLegOutput: Equatable, Sendable {
    /// Tokens into the module's per-asset basket, under a receipt for self.
    case color(outputIndex: Int, satoshis: UInt64, lockingScript: [UInt8], receipt: ColorReceipt)
    /// Sats as a BRC-29 payment to self.
    case brc29(outputIndex: Int, satoshis: UInt64, lockingScript: [UInt8], derivationPrefix: String, derivationSuffix: String, senderIdentityKey: String)
    /// Kept in the swap basket for a later leg.
    case basket(outputIndex: Int, satoshis: UInt64, lockingScript: [UInt8], customInstructions: String)

    var internalize: ColorInternalize.Output {
        switch self {
        case let .color(index, _, _, receipt):
            .basketInsertion(outputIndex: UInt32(index), basket: ColorIdentifiers.basket(receipt.assetID, role: .value), customInstructions: receipt.customInstructions)
        case let .brc29(index, _, _, prefix, suffix, sender):
            .walletPayment(outputIndex: UInt32(index), derivationPrefix: prefix, derivationSuffix: suffix, senderIdentityKey: sender)
        case let .basket(index, _, _, instructions):
            .basketInsertion(outputIndex: UInt32(index), basket: OpenExchangeSwapNames.basket, customInstructions: instructions)
        }
    }
}

/// `LegNeed`: what a leg's sats rows must hold.
public struct OpenExchangeLegNeed: Equatable, Sendable {
    /// The outputs' sats less the pool's (and the token inputs').
    public let outputs: Int64
    public let fee: Int64
    public let need: Int64
    public let feeWithChange: Int64
    public let needWithChange: Int64
    public let satsPerKb: Double
}

/// `PreparedSwap`: one buy leg built and signed, the validator's slot empty.
public struct OpenExchangePreparedLeg: Sendable {
    /// The pool's outpoint, `<txid>_<vout>`.
    public let pool: String
    /// The pool's validator identity key.
    public let validator: String
    public let plan: AMMSwapPlan
    /// The order key every payout of the order derives from.
    public let order: String
    public let last: Bool
    /// The funding sent beside the swap: an Atomic BEEF of the first sats row's transaction.
    public let fundingAtomicBEEF: [UInt8]
    public let fundingTxid: String
    public let fee: Int64
    public let need: Int64
    public let swap: Transaction
    public let satsInputs: [OpenExchangeSatsRow]
    public let payout: OpenExchangeLegOutput
    public let commissionAmount: BigInt
    /// Hash160 hex the commission goes to.
    public let commissionPkh: String
    /// "relay", "own" or "none".
    public let commissionTo: String
    public let commissionPayout: OpenExchangeLegOutput?
    public let satsChange: OpenExchangeLegOutput?
    /// The pool's source transaction (input 0's) and the swap basket's BEEF the leg was built from.
    let sources: BEEF

    /// `takeInOutputs`: the payout, the own commission, the sats change.
    public var takeIn: [OpenExchangeLegOutput] {
        [payout] + [commissionPayout, satsChange].compactMap { $0 }
    }

    /// `swapIdOf`: sha256 of the swap's bytes, hex.
    public var id: String {
        AMMPool.hex(BSVHashing.sha256((try? swap.serialized(limits: OpenExchangeSwapLeg.txLimits)) ?? []).bytes)
    }
}

/// `CompletedSwap`.
public struct OpenExchangeCompletedLeg: Equatable, Sendable {
    public let txid: String
    public let internalized: Bool
    public let errors: [String]
}

/// One buy leg (market/swapAction.ts): its inputs, its transaction and its take-in.
public enum OpenExchangeSwapLeg {
    static let txLimits = WalletTransactionLimits.standard
    static let beefLimits = WalletBEEFLimits.standard
    static let zeroPkh = [UInt8](repeating: 0, count: 20)
    static let brc29Protocol = "3241645161d8"

    static func fail(_ message: String) -> OpenExchangeError { .failed(message) }

    // MARK: - The basket's rows

    /// `basketRows(wallet, SWAP_BASKET)`: the rows with their scripts, tags and instructions
    /// (decrypted where the TS wallet's permissions manager stored them encrypted).
    static func basketRows(_ ctx: OneColorContext) async throws -> [WalletOutput] {
        let page = try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
            basket: OpenExchangeSwapNames.basket, include: .lockingScripts, includeCustomInstructions: true, includeTags: true,
            pagination: try WalletPagination(limit: OpenExchangeSwapNames.listLimit)
        ))
        var rows: [WalletOutput] = []
        for row in page.outputs {
            let instructions = await row.customInstructions.asyncMap { await ColorMetadata.decrypt($0, identity: ctx.identity) ?? $0 }
            rows.append(try WalletOutput(
                satoshis: row.satoshis, lockingScript: row.lockingScript, spendable: row.spendable,
                customInstructions: instructions, tags: row.tags, outpoint: row.outpoint, labels: row.labels
            ))
        }
        return rows
    }

    /// `basketBeef(wallet, SWAP_BASKET)`: the swap basket's source transactions.
    static func basketBEEF(_ ctx: OneColorContext) async throws -> BEEF? {
        try await ctx.storage.colorListOutputs(ctx.auth, try WalletListOutputsRequest(
            basket: OpenExchangeSwapNames.basket, include: .entireTransactions,
            pagination: try WalletPagination(limit: OpenExchangeSwapNames.listLimit)
        )).beef
    }

    /// `keyOf`: the row's key from its customInstructions.
    static func keyOf(_ instructions: String?) -> (protocolID: WalletProtocolID, keyID: String, counterparty: String, order: String?, sats: Bool)? {
        guard let value = JSONValue.parse(Array((instructions ?? "{}").utf8)),
              let proto = value["protocolID"]?.array, proto.count == 2,
              let level = proto[0].number, let name = proto[1].string,
              let securityLevel = WalletSecurityLevel(rawValue: UInt8(exactly: level) ?? .max),
              let protocolID = try? WalletProtocolID(securityLevel: securityLevel, name: name),
              let keyID = value["keyID"]?.string else { return nil }
        var sats = false
        if case .bool(true)? = value["sats"] { sats = true }
        return (protocolID, keyID, value["counterparty"]?.string ?? "self", value["order"]?.string, sats)
    }

    /// `satsInputsOf`: the rows that are P2PKH and marked `sats`.
    public static func satsRows(_ rows: [WalletOutput]) -> [OpenExchangeSatsRow] {
        rows.compactMap { row in
            guard let script = row.lockingScript, script.count == 25, script.starts(with: [0x76, 0xa9, 0x14]),
                  script[23] == 0x88, script[24] == 0xac,
                  let key = keyOf(row.customInstructions), key.sats else { return nil }
            let txid = row.outpoint.transactionID.displayHex
            let vout = Int(row.outpoint.outputIndex)
            return OpenExchangeSatsRow(
                outpoint: "\(txid).\(vout)", txid: txid, vout: vout, satoshis: row.satoshis, lockingScript: script,
                protocolID: key.protocolID, keyID: key.keyID, counterparty: key.counterparty, order: key.order
            )
        }
    }

    /// `swapSatsHoldings`.
    public static func satsHoldings(_ ctx: OneColorContext) async throws -> [OpenExchangeSatsRow] {
        satsRows(try await basketRows(ctx))
    }

    // MARK: - Sizing

    static func varIntSize(_ n: Int) -> Int { n < 0xfd ? 1 : n <= 0xffff ? 3 : n <= 0xffff_ffff ? 5 : 9 }

    /// `swapTxSize`: the leg's size with `takerInputs` P2PKH inputs (and the change output).
    public static func swapTxSize(_ plan: AMMSwapPlan, takerInputs: Int, withChange: Bool = false) throws -> Int {
        let poolUnlock = try AMMPoolCall.maxCallUnlockLength(plan)
        let unlock = OpenExchangeSwapNames.p2pkhUnlockLength
        var size = 4 + varIntSize(1 + takerInputs)
        size += 36 + varIntSize(poolUnlock) + poolUnlock + 4
        size += takerInputs * (36 + varIntSize(unlock) + unlock + 4)
        size += varIntSize(plan.outputs.count + (withChange ? 1 : 0))
        for o in plan.outputs { size += 8 + varIntSize(o.script.count) + o.script.count }
        if withChange { size += 34 }
        return size + 4
    }

    /// `legNeed` of a buy (no token inputs).
    public static func legNeed(_ plan: AMMSwapPlan, inputs: Int, satsPerKb: Double) throws -> OpenExchangeLegNeed {
        let outputs = Int64(plan.outputs.reduce(UInt64(0)) { $0 + $1.satoshis }) - Int64(plan.poolUtxo.satoshis)
        let fee = Int64((Double(try swapTxSize(plan, takerInputs: inputs)) * satsPerKb / 1000).rounded(.up))
        let feeWithChange = Int64((Double(try swapTxSize(plan, takerInputs: inputs, withChange: true)) * satsPerKb / 1000).rounded(.up))
        return OpenExchangeLegNeed(
            outputs: outputs, fee: fee, need: outputs + fee, feeWithChange: feeWithChange,
            needWithChange: outputs + feeWithChange, satsPerKb: satsPerKb
        )
    }

    // MARK: - The leg

    /// `PlanLegInput` of a buy: the leg, its pool (as listed and as read), the commission
    /// destination, the fee rate.
    public struct LegInput: Sendable {
        public let tokenId: String
        public let leg: AMMLeg
        public let pool: AMMPoolState
        /// The pool's transaction, Atomic BEEF (`LookupOutput.beef`), and the pool's output index.
        public let poolBEEF: [UInt8]
        public let poolOutputIndex: Int
        /// Hash160 hex of the commission destination, or nil for the taker's own key.
        public let commissionPkh: String?
        public let satsPerKb: Double

        public init(tokenId: String, leg: AMMLeg, pool: AMMPoolState, poolBEEF: [UInt8], poolOutputIndex: Int, commissionPkh: String?, satsPerKb: Double) {
            self.tokenId = tokenId
            self.leg = leg
            self.pool = pool
            self.poolBEEF = poolBEEF
            self.poolOutputIndex = poolOutputIndex
            self.commissionPkh = commissionPkh
            self.satsPerKb = satsPerKb
        }
    }

    /// `poolUtxoFrom`: the pool output of the lookup's Atomic BEEF, refused unless it is the
    /// planned leg's outpoint.
    static func poolUtxo(_ i: LegInput) throws -> (utxo: AMMPoolUtxo, beef: BEEF) {
        let (id, beef, tx) = try ColorBEEF.open(i.poolBEEF)
        guard tx.outputs.indices.contains(i.poolOutputIndex) else {
            throw fail("the lookup's BEEF has no output \(i.poolOutputIndex)")
        }
        let out = tx.outputs[i.poolOutputIndex]
        let utxo = AMMPoolUtxo(txid: id.displayHex, vout: i.poolOutputIndex, satoshis: out.satoshis, script: out.lockingScript.bytes)
        guard "\(utxo.txid)_\(utxo.vout)" == i.leg.outpoint else {
            throw fail("the pool moved: the read's tip is \(utxo.txid).\(utxo.vout), the plan priced \(OpenExchangePrices.outpointText(i.leg.outpoint))")
        }
        return (utxo, beef)
    }

    /// `legPlan`.
    static func legPlan(_ i: LegInput, _ utxo: AMMPoolUtxo, userPkh: [UInt8], commissionPkh: [UInt8]) throws -> AMMSwapPlan {
        try AMMPoolCall.planSwap(
            pool: utxo, amountIn: i.leg.amountIn, bsvIn: true, userPkh: userPkh, commissionPkh: commissionPkh,
            expect: AMMSwapExpectation(
                bsvReserve: i.pool.bsvReserve, tokenReserve: i.pool.tokenReserve, lpFeeBps: i.pool.liquidityFeeBps,
                validatorFeeBps: i.pool.validationFeeBps, commissionBps: i.pool.commissionBps, lpFee: i.leg.liquidityFee,
                validatorFee: i.leg.validationFee, commission: i.leg.commission, amountOut: i.leg.amountOut
            )
        )
    }

    static func pkhBytes(_ hex: String?) throws -> [UInt8] {
        guard let hex else { return zeroPkh }
        guard let bytes = Runar.hexBytesChecked(hex), bytes.count == 20 else { throw fail("not a 20-byte key hash: \(hex)") }
        return bytes
    }

    /// `selectLegInputs` of a buy: the sats rows largest first (ties by outpoint), as many as
    /// cover the leg's need; nil when they cannot.
    public static func selectInputs(_ i: LegInput, sats: [OpenExchangeSatsRow]) throws -> (sats: [OpenExchangeSatsRow], need: OpenExchangeLegNeed)? {
        let (utxo, _) = try poolUtxo(i)
        let plan = try legPlan(i, utxo, userPkh: zeroPkh, commissionPkh: try pkhBytes(i.commissionPkh))
        var picked: [OpenExchangeSatsRow] = []
        var held: Int64 = 0
        let ordered = sats.sorted { a, b in a.satoshis != b.satoshis ? a.satoshis > b.satoshis : a.outpoint < b.outpoint }
        for row in ordered {
            picked.append(row)
            held += Int64(row.satoshis)
            let need = try legNeed(plan, inputs: picked.count, satsPerKb: i.satsPerKb)
            if held >= need.need { return (picked, need) }
        }
        return nil
    }

    /// What `sats` lack of the leg's need with one more row (the staged shortfall), when that lack
    /// is no more than `allowance` (the quote's per-leg miner fee estimate); nil otherwise. Not in
    /// the TS. `runSwap` asks it only once `selectInputs` has found the rows short of the leg.
    static func feeShortfall(_ i: LegInput, sats: [OpenExchangeSatsRow], allowance: BigInt) throws -> UInt64? {
        let (utxo, _) = try poolUtxo(i)
        let plan = try legPlan(i, utxo, userPkh: zeroPkh, commissionPkh: try pkhBytes(i.commissionPkh))
        let held = sats.reduce(BigInt(0)) { $0 + BigInt($1.satoshis) }
        let lack = BigInt(try legNeed(plan, inputs: sats.count + 1, satsPerKb: i.satsPerKb).need) - held
        guard lack > 0, lack <= allowance else { return nil }
        return UInt64(lack)
    }

    // MARK: - Keys

    static func brc29PublicKey(_ ctx: OneColorContext, _ d: (derivationPrefix: String, derivationSuffix: String)) throws -> PublicKey {
        try WalletKeyDeriver(rootKey: ctx.identity).derivePublicKey(
            protocolID: try WalletProtocolID(securityLevel: .everyAppAndCounterparty, name: brc29Protocol),
            keyID: try WalletKeyID("\(d.derivationPrefix) \(d.derivationSuffix)"), counterparty: .self, forSelf: true
        )
    }

    /// `newReceivingKey(wallet, assetId, identity, d)`: the module's key for a receipt to self.
    static func receivingKey(_ ctx: OneColorContext, tokenId: String, _ d: (derivationPrefix: String, derivationSuffix: String)) throws -> (receipt: ColorReceipt, publicKey: PublicKey) {
        guard let asset = AMMTokenID.parse(try AMMTokenID.canonical(tokenId)) else { throw fail("not a token id: \(tokenId)") }
        let receipt = try ColorReceipt(assetID: asset, derivationPrefix: d.derivationPrefix, derivationSuffix: d.derivationSuffix, senderIdentityKey: ctx.identityKey)
        let custody = try ColorCustody(asset: .asset(asset), derivationPrefix: d.derivationPrefix, derivationSuffix: d.derivationSuffix, senderIdentityKey: ctx.identityKey)
        return (receipt, try ColorKeys.ownPublicKey(identity: ctx.identity, custody: custody))
    }

    static func swapKey(_ ctx: OneColorContext, keyID: String) throws -> PublicKey {
        try WalletKeyDeriver(rootKey: ctx.identity).derivePublicKey(
            protocolID: try OpenExchangeSwapNames.swapProtocol(), keyID: try WalletKeyID(keyID), counterparty: .self, forSelf: true
        )
    }

    static func counterparty(_ text: String) throws -> WalletCounterparty {
        switch text {
        case "self": .self
        case "anyone": .anyone
        default: .publicKey(try PublicKey(try Hex.decode(text, maximumDecodedByteCount: 33)))
        }
    }

    static func pkh(_ key: PublicKey) -> [UInt8] { BSVHashing.hash160(key.compressedBytes).bytes }

    // MARK: - prepareSwap

    /// `prepareSwap` of a buy: the payout keys of the order, the swap transaction (the pool,
    /// then the sats rows; the contract's outputs, then the sats change), input 0's call with the
    /// validator's slot empty, the rows signed, every row's spend validated, and the funding BEEF.
    public static func prepare(
        _ ctx: OneColorContext, _ i: LegInput, inputs: [OpenExchangeSatsRow], order givenOrder: String? = nil,
        last: Bool, holdingBEEF: BEEF
    ) throws -> OpenExchangePreparedLeg {
        let (utxo, poolBEEF) = try poolUtxo(i)
        guard let first = inputs.first else { throw fail("the leg has no sats row") }
        let order = givenOrder ?? first.outpoint
        guard let decoded = AMMPool.decode(utxo.script) else { throw fail("\(OpenExchangePrices.outpointText(i.leg.outpoint)) is not a pool output") }
        let commissionAmount = (i.leg.amountIn * decoded.args.commissionBps + 9999) / 10000
        let commissionTo = commissionAmount == 0 ? "none" : i.commissionPkh != nil ? "relay" : "own"

        let pay = OpenExchangeSwapNames.legDerivation(order, .payout)
        let payToken = try receivingKey(ctx, tokenId: i.tokenId, pay)
        let userPkh = pkh(payToken.publicKey)
        var own: (key: PublicKey, d: (derivationPrefix: String, derivationSuffix: String))?
        if commissionTo == "own" {
            let d = OpenExchangeSwapNames.legDerivation(order, .commission)
            own = (try brc29PublicKey(ctx, d), d)
        }
        let commissionPkh = try own.map { pkh($0.key) } ?? pkhBytes(i.commissionPkh)
        let plan = try legPlan(i, utxo, userPkh: userPkh, commissionPkh: commissionPkh)

        let held = inputs.reduce(Int64(0)) { $0 + Int64($1.satoshis) }
        let need = try legNeed(plan, inputs: inputs.count, satsPerKb: i.satsPerKb)
        guard held >= need.need else { throw fail("the swap basket's sats rows hold \(held) sats, the leg needs \(need.need)") }
        let changeSats = held - need.needWithChange
        var change: (pkh: [UInt8], satoshis: UInt64, output: OpenExchangeLegOutput)?
        if changeSats >= 1 {
            let at = plan.outputs.count
            if last {
                let d = OpenExchangeSwapNames.legDerivation(order, .change)
                let key = try brc29PublicKey(ctx, d)
                change = (pkh(key), UInt64(changeSats), .brc29(
                    outputIndex: at, satoshis: UInt64(changeSats), lockingScript: AMMPoolCall.p2pkh(pkh(key)),
                    derivationPrefix: d.derivationPrefix, derivationSuffix: d.derivationSuffix, senderIdentityKey: ctx.identityKey
                ))
            } else {
                let keyID = try OpenExchangeSwapNames.changeKeyID(first.outpoint)
                let key = try swapKey(ctx, keyID: keyID)
                change = (pkh(key), UInt64(changeSats), .basket(
                    outputIndex: at, satoshis: UInt64(changeSats), lockingScript: AMMPoolCall.p2pkh(pkh(key)),
                    customInstructions: OpenExchangeSwapNames.swapSatsInstructions(keyID: keyID, order: order)
                ))
            }
        }
        let payout = OpenExchangeLegOutput.color(
            outputIndex: 1, satoshis: plan.outputs[1].satoshis, lockingScript: plan.outputs[1].script, receipt: payToken.receipt
        )
        var commissionPayout: OpenExchangeLegOutput?
        if let own {
            let at = plan.outputs.count - 1
            commissionPayout = .brc29(
                outputIndex: at, satoshis: plan.outputs[at].satoshis, lockingScript: plan.outputs[at].script,
                derivationPrefix: own.d.derivationPrefix, derivationSuffix: own.d.derivationSuffix, senderIdentityKey: ctx.identityKey
            )
        }

        var sources = holdingBEEF
        var sourceOutputs: [TransactionOutput] = []
        for row in inputs {
            guard let tx = try holdingBEEF.transaction(for: try TransactionID(displayHex: row.txid), limits: txLimits),
                  tx.outputs.indices.contains(row.vout) else {
                throw fail("the wallet's BEEF lacks the swap basket output \(row.outpoint)")
            }
            sourceOutputs.append(tx.outputs[row.vout])
        }
        var swap = Transaction(version: 1, lockTime: 0)
        swap.inputs = [try AMMPoolCall.poolInput(utxo)]
        for (row, source) in zip(inputs, sourceOutputs) {
            swap.inputs.append(TransactionInput(
                previousOutput: Outpoint(transactionID: try TransactionID(displayHex: row.txid), outputIndex: UInt32(row.vout)),
                unlockingScript: try AMMPoolCall.script([]), sourceOutput: source
            ))
        }
        swap.outputs = try plan.outputs.map { TransactionOutput(satoshis: $0.satoshis, lockingScript: try AMMPoolCall.script($0.script)) }
        if let change {
            swap.outputs.append(TransactionOutput(satoshis: change.satoshis, lockingScript: try AMMPoolCall.script(AMMPoolCall.p2pkh(change.pkh))))
        }
        let call = try AMMPoolCall.callUnlock(plan, transaction: swap, change: change.map { ($0.pkh, $0.satoshis) })
        swap.inputs[0].unlockingScript = try AMMPoolCall.script(call.unlockingScript)
        for (n, row) in inputs.enumerated() {
            let key = try WalletKeyDeriver(rootKey: ctx.identity).derivePrivateKey(
                protocolID: row.protocolID, keyID: try WalletKeyID(row.keyID), counterparty: try counterparty(row.counterparty)
            )
            try swap.signPayToPublicKeyHashInput(at: n + 1, with: key, limits: txLimits)
        }
        for n in 1..<swap.inputs.count where !spendValid(swap, n) {
            throw fail("input \(n) of the swap does not validate")
        }

        let assetId = decoded.args.assetId
        let funding = try fundingBEEF(
            holdingBEEF, fundingTxid: first.txid, sources: inputs.map(\.txid), poolTxid: utxo.txid,
            admitted: { txid, tx in
                txid == utxo.txid || (tx?.outputs.contains { AMMPool.decode($0.lockingScript.bytes)?.args.assetId == assetId } ?? false)
            }
        )
        sources = try sources.merging(poolBEEF, limits: beefLimits)
        return OpenExchangePreparedLeg(
            pool: i.leg.outpoint, validator: i.pool.validatorIdentityKey, plan: plan, order: order, last: last,
            fundingAtomicBEEF: funding, fundingTxid: first.txid, fee: change != nil ? need.feeWithChange : need.fee, need: need.need,
            swap: swap, satsInputs: inputs, payout: payout, commissionAmount: commissionAmount,
            commissionPkh: AMMPool.hex(commissionPkh), commissionTo: commissionTo, commissionPayout: commissionPayout,
            satsChange: change?.output, sources: sources
        )
    }

    /// `spendValid`: input `n` unlocks its source.
    static func spendValid(_ tx: Transaction, _ n: Int) -> Bool {
        guard let spent = tx.inputs[n].sourceOutput,
              let configuration = try? ScriptExecutionConfiguration(era: .afterGenesis, flags: [.enableForkID], resourceLimits: .standard) else {
            return false
        }
        do {
            _ = try ScriptInterpreter.execute(
                unlockingScript: tx.inputs[n].unlockingScript, lockingScript: spent.lockingScript, configuration: configuration,
                context: ScriptExecutionContext(transaction: tx, inputIndex: n, spentOutput: spent, transactionLimits: txLimits)
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - The funding BEEF

    /// `fundingBeef` / `topicBeef`: an Atomic envelope whose subject is the first sats row's
    /// transaction, around a V2 BEEF of every row's transaction and its unproven ancestry down to
    /// a proven or topic-admitted transaction (txid-only), the pool's transaction txid-only.
    static func fundingBEEF(
        _ beef: BEEF, fundingTxid: String, sources: [String], poolTxid: String,
        admitted: (String, Transaction?) -> Bool
    ) throws -> [UInt8] {
        // `out.toBinary()` sorts as @bsv/sdk's `sortTxs` does a walk's output: the txid-only
        // entries, then the proven, then the rest, each in the order the walk merged them.
        var txidOnly: [BEEFTransaction] = []
        var proven: [BEEFTransaction] = []
        var entries: [BEEFTransaction] = []
        var paths: [MerklePath] = []
        var done = Set<String>()
        func visit(_ txid: String) throws {
            guard done.insert(txid).inserted else { return }
            let id = try TransactionID(displayHex: txid)
            let entry = try beef.entry(for: id, limits: txLimits)
            guard let tx = entry?.transaction, !admitted(txid, tx) else {
                txidOnly.append(.transactionID(id))
                return
            }
            if let index = entry?.merklePathIndex {
                let path = beef.merklePaths[index]
                let at = paths.firstIndex(of: path) ?? { paths.append(path); return paths.count - 1 }()
                proven.append(.rawWithMerklePath(transaction: tx, merklePathIndex: at))
                return
            }
            for input in tx.inputs { try visit(input.previousOutput.transactionID.displayHex) }
            entries.append(.raw(tx))
        }
        var seen = Set<String>()
        for txid in [fundingTxid] + sources where seen.insert(txid).inserted { try visit(txid) }
        if !done.contains(poolTxid) {
            txidOnly.append(.transactionID(try TransactionID(displayHex: poolTxid)))
        }
        let out = try BEEF(version: .v2, merklePaths: paths, transactions: txidOnly + parentsFirst(proven + entries), limits: beefLimits)
        return [0x01, 0x01, 0x01, 0x01] + (try TransactionID(displayHex: fundingTxid)).wireBytes + (try out.serialized(limits: beefLimits))
    }

    /// The walk's raw entries (the proven, then the rest) in that order, except that one spending
    /// another listed entry comes after it. The walk stops at a proven transaction without visiting
    /// its inputs, and the wallet's storage can hold a transaction's proof before its parent's, so
    /// a proven child can meet the walk ahead of its parent (a stage and the move back that spent
    /// it, mined together; or a proven stage whose parent storage still holds unproven). @bsv/sdk
    /// writes that order as it is; a BEEF that lists a child before its parent does not serialize
    /// here (`parentAfterChild`). Entries already parents-first keep the walk's order exactly.
    static func parentsFirst(_ entries: [BEEFTransaction]) throws -> [BEEFTransaction] {
        var pending: [(id: String, entry: BEEFTransaction, parents: Set<String>)] = []
        for entry in entries {
            guard let tx = entry.transaction else { pending.append(("", entry, [])); continue }
            pending.append((try tx.transactionID(limits: txLimits).displayHex, entry, Set(tx.inputs.map { $0.previousOutput.transactionID.displayHex })))
        }
        let ids = Set(pending.map(\.id))
        var placed = Set<String>()
        var out: [BEEFTransaction] = []
        while !pending.isEmpty {
            guard let next = pending.firstIndex(where: { $0.parents.intersection(ids).isSubset(of: placed) }) else {
                throw fail("the funding BEEF's transactions spend each other in a cycle")
            }
            let item = pending.remove(at: next)
            placed.insert(item.id)
            out.append(item.entry)
        }
        return out
    }

    // MARK: - The validator's transaction

    /// `finalSwapOf`: the relay's transaction (raw or BEEF), refused unless it is the swap built:
    /// the same inputs (every unlock but the pool's), the same outputs.
    static func finalSwap(_ p: OpenExchangePreparedLeg, raw: [UInt8], txid: String?) throws -> Transaction {
        var tx: Transaction
        if let plain = try? Transaction(bytes: raw, limits: txLimits) {
            tx = plain
        } else {
            let beef = try BEEF(bytes: raw, limits: beefLimits, transactionOrder: .any)
            guard let last = try (txid.map { try TransactionID(displayHex: $0) }).flatMap({ try beef.transaction(for: $0, limits: txLimits) })
                ?? beef.transactions.last?.transaction else { throw fail("the relay's BEEF has no transaction") }
            tx = last
        }
        let got = try tx.transactionID(limits: txLimits).displayHex
        if let txid, got != txid { throw fail("the relay's transaction is \(got), not \(txid)") }
        let ours = p.swap
        let same = tx.inputs.count == ours.inputs.count && tx.outputs.count == ours.outputs.count
            && zip(tx.inputs, ours.inputs).enumerated().allSatisfy { n, pair in
                pair.0.previousOutput == pair.1.previousOutput && (n == 0 || pair.0.unlockingScript == pair.1.unlockingScript)
            }
            && zip(tx.outputs, ours.outputs).allSatisfy { $0.satoshis == $1.satoshis && $0.lockingScript == $1.lockingScript }
        guard same else { throw fail("the relay's transaction is not the swap we built") }
        for n in tx.inputs.indices { tx.inputs[n].sourceOutput = ours.inputs[n].sourceOutput }
        return tx
    }

    /// `completeSwap`: ONE internalizeAction of the leg's take-in outputs, "AMM swap tokens"
    /// (a buy's payout is tokens), labelled `amm-swap`; a wallet error is reported, not thrown.
    public static func complete(_ ctx: OneColorContext, _ p: OpenExchangePreparedLeg, raw: [UInt8], txid: String?) async throws -> OpenExchangeCompletedLeg {
        let final = try finalSwap(p, raw: raw, txid: txid)
        let finalID = try final.transactionID(limits: txLimits)
        var errors: [String] = []
        var internalized = false
        do {
            var beef = p.sources
            beef = try beef.merging(try BEEF(version: .v2, merklePaths: [], transactions: [.raw(final)], limits: beefLimits), limits: beefLimits)
            let atomic = try ColorBEEF.atomic(finalID, in: beef).serialized(limits: beefLimits)
            internalized = try await ColorInternalize.run(
                ctx, atomicBEEF: atomic, outputs: p.takeIn.map(\.internalize),
                description: p.payout.isBRC29 ? "AMM swap payout" : "AMM swap tokens", labels: [OpenExchangeSwapNames.label]
            )
        } catch {
            errors.append("internalizeAction: \(OpenExchangeError.errorText(error))")
        }
        return OpenExchangeCompletedLeg(txid: finalID.displayHex, internalized: internalized, errors: errors)
    }
}

extension OpenExchangeLegOutput {
    var isBRC29: Bool { if case .brc29 = self { true } else { false } }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
