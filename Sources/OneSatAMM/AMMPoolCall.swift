import BigInt
import BSVCore
import BSVCrypto
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatTemplates
import ToolboxActions

/// `PoolBuildError` (pool/template.ts): a refusal by the builder's own checks; nothing was signed.
public struct AMMPoolBuildError: Error, Equatable, Sendable, CustomStringConvertible {
    /// not_a_pool, stale_pool, fee_mismatch, quote_mismatch, slippage, token_mismatch,
    /// insufficient_funds or invalid.
    public let code: String
    public let message: String
    public var description: String { "\(code): \(message)" }
}

/// A pool output being spent (`PoolUtxo`).
public struct AMMPoolUtxo: Equatable, Sendable {
    public let txid: String
    public let vout: Int
    public let satoshis: UInt64
    public let script: [UInt8]

    public init(txid: String, vout: Int, satoshis: UInt64, script: [UInt8]) {
        self.txid = txid
        self.vout = vout
        self.satoshis = satoshis
        self.script = script
    }
}

/// `SwapExpectation`: what the caller priced the leg against; any mismatch is refused.
public struct AMMSwapExpectation: Equatable, Sendable {
    public var bsvReserve: BigInt?
    public var tokenReserve: BigInt?
    public var lpFeeBps: BigInt?
    public var validatorFeeBps: BigInt?
    public var commissionBps: BigInt?
    public var lpFee: BigInt?
    public var validatorFee: BigInt?
    public var commission: BigInt?
    public var amountOut: BigInt?
    public var minAmountOut: BigInt?

    public init(
        bsvReserve: BigInt? = nil, tokenReserve: BigInt? = nil, lpFeeBps: BigInt? = nil, validatorFeeBps: BigInt? = nil,
        commissionBps: BigInt? = nil, lpFee: BigInt? = nil, validatorFee: BigInt? = nil, commission: BigInt? = nil,
        amountOut: BigInt? = nil, minAmountOut: BigInt? = nil
    ) {
        self.bsvReserve = bsvReserve
        self.tokenReserve = tokenReserve
        self.lpFeeBps = lpFeeBps
        self.validatorFeeBps = validatorFeeBps
        self.commissionBps = commissionBps
        self.lpFee = lpFee
        self.validatorFee = validatorFee
        self.commission = commission
        self.amountOut = amountOut
        self.minAmountOut = minAmountOut
    }
}

/// A Swap call's required outputs and arguments before any funding (`CallPlan & {swap}`).
public struct AMMSwapPlan: Equatable, Sendable {
    public struct Output: Equatable, Sendable {
        public let satoshis: UInt64
        public let script: [UInt8]
    }

    /// A method argument (`encodeArg`'s cases): `EMPTY_SIG`, a number, a boolean, bytes.
    public enum Arg: Equatable, Sendable {
        case emptySig
        case number(BigInt)
        case bool(Bool)
        case data([UInt8])
    }

    public let pool: AMMPool
    public let poolUtxo: AMMPoolUtxo
    /// The outputs the contract requires, in order; sats change (if any) follows them.
    public let outputs: [Output]
    public let args: [Arg]
    /// The continuation's state and sats.
    public let next: AMMPool
    public let nextSatoshis: UInt64
    public let amountOut: BigInt
    public let lpFee: BigInt
    public let validatorFee: BigInt
    public let commission: BigInt
}

/// The Swap call (pool/template.ts `PoolTemplate.planSwap`, `callUnlock`, `maxCallUnlockLength`)
/// and the Rúnar encodings it pushes (vendor/runar runar-sdk contract.ts, state.ts).
public enum AMMPoolCall {
    static let limits = WalletTransactionLimits.standard
    /// `METHOD_INDEX.swap`.
    static let swapMethodIndex = 0
    /// `SIG_PUSH_LEN`: a length byte, a DER signature (≤ 72), the sighash byte.
    static let sigPushLength = 74
    static let zeroPkh = [UInt8](repeating: 0, count: 20)
    /// `Number.MAX_SAFE_INTEGER`.
    static let maxSafeInteger: UInt64 = (1 << 53) - 1

    static func fail(_ code: String, _ message: String) -> AMMPoolBuildError {
        AMMPoolBuildError(code: code, message: message)
    }

    // MARK: - planSwap

    /// `PoolTemplate.planSwap`: Pool.runar.go Swap, line for line. Outputs: the continuation, the
    /// taker's payout, then the LP fee, the validator fee and the commission (each when nonzero, in
    /// the input asset), then the token change when nonzero. Token outputs are 1-sat 1Color
    /// outputs; BSV ones P2PKH.
    public static func planSwap(
        pool utxo: AMMPoolUtxo, amountIn: BigInt, bsvIn: Bool, userPkh: [UInt8], commissionPkh: [UInt8],
        tokenChange: BigInt = 0, tokenChangePkh: [UInt8] = [UInt8](repeating: 0, count: 20), nextValidatorPubKey: String? = nil,
        expect e: AMMSwapExpectation = AMMSwapExpectation()
    ) throws -> AMMSwapPlan {
        guard let pool = AMMPool.decode(utxo.script) else {
            throw fail("not_a_pool", "\(utxo.txid):\(utxo.vout) is not a pool output")
        }
        guard utxo.satoshis > 0, utxo.satoshis <= maxSafeInteger else { throw fail("invalid", "pool satoshis") }
        let args = pool.args
        let state = pool.state
        let bsvReserve = BigInt(utxo.satoshis)
        if let x = e.bsvReserve, x != bsvReserve { throw fail("stale_pool", "BSV reserve is \(bsvReserve), priced against \(x)") }
        if let x = e.tokenReserve, x != state.tokenReserve {
            throw fail("stale_pool", "token reserve is \(state.tokenReserve), priced against \(x)")
        }
        if let x = e.lpFeeBps, x != args.lpFeeBps { throw fail("fee_mismatch", "pool LP fee is \(args.lpFeeBps) bps, priced at \(x)") }
        if let x = e.validatorFeeBps, x != args.validatorFeeBps {
            throw fail("fee_mismatch", "pool validator fee is \(args.validatorFeeBps) bps, priced at \(x)")
        }
        if let x = e.commissionBps, x != args.commissionBps {
            throw fail("fee_mismatch", "pool commission is \(args.commissionBps) bps, priced at \(x)")
        }
        guard commissionPkh.count == 20 else { throw fail("invalid", "commissionPkh must be 20 bytes of hex") }
        guard userPkh.count == 20 else { throw fail("invalid", "userPkh must be 20 bytes of hex") }
        guard tokenChange >= 0 else { throw fail("invalid", "tokenChange must be ≥ 0") }
        guard tokenChangePkh.count == 20 else { throw fail("invalid", "tokenChangePkh must be 20 bytes of hex") }

        guard amountIn > 0 else { throw fail("invalid", "amountIn must be > 0") }
        let lpFee = (amountIn * args.lpFeeBps + 9999) / 10000
        let validatorFee = (amountIn * args.validatorFeeBps + 9999) / 10000
        let commission = (amountIn * args.commissionBps + 9999) / 10000
        let net = amountIn - lpFee - validatorFee - commission
        guard net > 0 else { throw fail("invalid", "amountIn does not cover the fees") }
        var out = (net * bsvReserve) / (state.tokenReserve + net)
        var newBsv = bsvReserve - out
        var newTokens = state.tokenReserve + net
        if bsvIn {
            out = (net * state.tokenReserve) / (bsvReserve + net)
            newBsv = bsvReserve + net
            newTokens = state.tokenReserve - out
        }
        guard out > 0 else { throw fail("invalid", "amountIn too small: nothing out") }
        guard newBsv > 0, newTokens > 0 else { throw fail("invalid", "the swap would empty the pool") }
        if let x = e.lpFee, x != lpFee { throw fail("fee_mismatch", "LP fee is \(lpFee), priced at \(x)") }
        if let x = e.validatorFee, x != validatorFee { throw fail("fee_mismatch", "validator fee is \(validatorFee), priced at \(x)") }
        if let x = e.commission, x != commission { throw fail("fee_mismatch", "commission is \(commission), priced at \(x)") }
        if let x = e.amountOut, x != out { throw fail("quote_mismatch", "amount out is \(out), quoted \(x)") }
        if let x = e.minAmountOut, out < x { throw fail("slippage", "amount out \(out) is below the minimum \(x)") }

        let nextKey = try nextValidatorPubKey
            ?? OpenExchangeKeys.validatorPubKey(validatorIdentity: state.validatorIdentity, txid: utxo.txid, vout: utxo.vout)
        let nextKeyBytes = Runar.hexBytesChecked(nextKey)
        guard let nextKeyBytes, (try? PublicKey(nextKeyBytes)) != nil else { throw fail("invalid", "nextValidatorPubKey is not a public key") }
        let nextState = AMMPoolFields(
            tokenReserve: newTokens, lpPubKey: state.lpPubKey, validatorPubKey: nextKey, validatorIdentity: state.validatorIdentity,
            nonce: state.nonce, lpSatsPkh: state.lpSatsPkh, lpTokenPkh: state.lpTokenPkh, affirmation: state.affirmation
        )
        let lpPkh = Runar.hexBytes(bsvIn ? state.lpSatsPkh : state.lpTokenPkh)
        let validatorPkh = BSVHashing.hash160(Runar.hexBytes(state.validatorPubKey)).bytes
        func payout(_ amount: BigInt, _ pkh: [UInt8], _ isBsv: Bool) throws -> AMMSwapPlan.Output {
            isBsv
                ? AMMSwapPlan.Output(satoshis: try sats(amount), script: p2pkh(pkh))
                : AMMSwapPlan.Output(satoshis: 1, script: try tokenP2pkh(args.assetId, amount, pkh))
        }
        let stateBytes = try serializeState(nextState)
        let continuation = try tokenPrefix(args.assetId, newTokens) + Runar.hexBytes(pool.code) + [0x6a] + stateBytes
        var outputs = [
            AMMSwapPlan.Output(satoshis: try sats(newBsv), script: continuation),
            try payout(out, userPkh, !bsvIn),
        ]
        if lpFee > 0 { outputs.append(try payout(lpFee, lpPkh, bsvIn)) }
        if validatorFee > 0 { outputs.append(try payout(validatorFee, validatorPkh, bsvIn)) }
        if commission > 0 { outputs.append(try payout(commission, commissionPkh, bsvIn)) }
        if tokenChange > 0 { outputs.append(AMMSwapPlan.Output(satoshis: 1, script: try tokenP2pkh(args.assetId, tokenChange, tokenChangePkh))) }

        let next = AMMPool(
            version: pool.version, args: args, state: nextState, code: pool.code,
            contractScript: pool.code + "6a" + AMMPool.hex(stateBytes)
        )
        return AMMSwapPlan(
            pool: pool, poolUtxo: utxo, outputs: outputs,
            args: [.emptySig, .data(nextKeyBytes), .number(amountIn), .bool(bsvIn), .data(userPkh), .data(commissionPkh), .data(tokenChangePkh), .number(tokenChange)],
            next: next, nextSatoshis: try sats(newBsv), amountOut: out, lpFee: lpFee, validatorFee: validatorFee, commission: commission
        )
    }

    // MARK: - The pool input's unlock

    /// `PoolTemplate.callUnlock`: input 0's unlocking script for `plan` over a finished
    /// transaction whose input 0 spends the pool and whose outputs are the plan's, then (optionally)
    /// the P2PKH change `change` names. The validator's slot stays `OP_0`.
    public static func callUnlock(
        _ plan: AMMSwapPlan, transaction tx: Transaction, change: (pkh: [UInt8], satoshis: UInt64)?
    ) throws -> (unlockingScript: [UInt8], preimage: [UInt8]) {
        guard let in0 = tx.inputs.first, in0.previousOutput.transactionID.displayHex == plan.poolUtxo.txid,
              Int(in0.previousOutput.outputIndex) == plan.poolUtxo.vout else {
            throw fail("invalid", "input 0 does not spend the pool")
        }
        let want = plan.outputs.count + (change == nil ? 0 : 1)
        guard tx.outputs.count == want else { throw fail("invalid", "the transaction has \(tx.outputs.count) outputs, the call needs \(want)") }
        for (i, o) in plan.outputs.enumerated() where tx.outputs[i].satoshis != o.satoshis || tx.outputs[i].lockingScript.bytes != o.script {
            throw fail("invalid", "output \(i) is not the one the contract requires")
        }
        if let change {
            guard change.pkh.count == 20 else { throw fail("invalid", "change pkh must be 20 bytes of hex") }
            let got = tx.outputs[plan.outputs.count]
            guard got.satoshis == change.satoshis, got.lockingScript.bytes == p2pkh(change.pkh) else {
                throw fail("invalid", "the last output is not the named P2PKH change")
            }
        }
        let preimage = try contractPreimage(tx, plan)
        let unlock = callUnlockBytes(plan, changePkh: change?.pkh ?? zeroPkh, change: BigInt(change?.satoshis ?? 0), preimage: preimage)
        return (unlock, preimage)
    }

    /// `PoolTemplate.maxCallUnlockLength`: the pool unlock's length once every signature slot is
    /// filled, the change amount bounded by 2^53 − 1.
    public static func maxCallUnlockLength(_ plan: AMMSwapPlan) throws -> Int {
        var tx = Transaction(version: 1, lockTime: 0)
        tx.inputs = [try poolInput(plan.poolUtxo)]
        tx.outputs = try plan.outputs.map { TransactionOutput(satoshis: $0.satoshis, lockingScript: try script($0.script)) }
        let preimage = try contractPreimage(tx, plan)
        let unlock = callUnlockBytes(plan, changePkh: zeroPkh, change: BigInt(maxSafeInteger), preimage: preimage)
        return unlock.count + 1 * (sigPushLength - 1)
    }

    /// The pool input: its outpoint, an empty unlock, its source output.
    static func poolInput(_ utxo: AMMPoolUtxo) throws -> TransactionInput {
        TransactionInput(
            previousOutput: Outpoint(transactionID: try TransactionID(displayHex: utxo.txid), outputIndex: UInt32(utxo.vout)),
            unlockingScript: try script([]),
            sourceOutput: TransactionOutput(satoshis: utxo.satoshis, lockingScript: try script(utxo.script))
        )
    }

    /// `contractPreimage`: the BIP-143 preimage (sighash 0x41) of input 0, its script code the
    /// contract script after the Swap method's OP_CODESEPARATOR in the code, its amount the pool's.
    static func contractPreimage(_ tx: Transaction, _ plan: AMMSwapPlan) throws -> [UInt8] {
        let code = Runar.hexBytes(plan.pool.code)
        let offsets = findCodesepOffsets(code)
        let contract = Runar.hexBytes(plan.pool.contractScript)
        var scriptCode = contract
        if offsets.count > swapMethodIndex {
            let trim = offsets[swapMethodIndex] + 1
            guard trim <= contract.count else { throw fail("invalid", "the code separator is past the script") }
            scriptCode = Array(contract[trim...])
        }
        var signing = tx
        signing.inputs[0].sourceOutput = TransactionOutput(satoshis: plan.poolUtxo.satoshis, lockingScript: try script(contract))
        return try signing.forkIDSignaturePreimage(inputIndex: 0, hashType: .all, scriptCode: try script(scriptCode), limits: limits)
    }

    /// `callUnlockHex`: `_codePart args… _changePKH _changeAmount txPreimage methodIndex`.
    static func callUnlockBytes(_ plan: AMMSwapPlan, changePkh: [UInt8], change: BigInt, preimage: [UInt8]) -> [UInt8] {
        var out = encodePushData(Runar.hexBytes(plan.pool.code))
        for arg in plan.args { out += encodeArg(arg) }
        out += encodePushData(changePkh) + encodeArg(.number(change))
        return out + encodePushData(preimage) + encodeScriptNumber(BigInt(swapMethodIndex))
    }

    // MARK: - Rúnar encodings

    /// `encodeArg`.
    static func encodeArg(_ arg: AMMSwapPlan.Arg) -> [UInt8] {
        switch arg {
        case .emptySig: [0x00]
        case .number(let n): encodeScriptNumber(n)
        case .bool(let b): [b ? 0x51 : 0x00]
        case .data(let bytes): encodePushData(bytes)
        }
    }

    /// `encodeScriptNumber`: OP_0 / OP_1..OP_16 / OP_1NEGATE, else a sign-magnitude LE push.
    static func encodeScriptNumber(_ n: BigInt) -> [UInt8] {
        if n == 0 { return [0x00] }
        if n >= 1, n <= 16 { return [UInt8(0x50 + Int(n))] }
        if n == -1 { return [0x4f] }
        let negative = n < 0
        var magnitude = negative ? -n : n
        var bytes: [UInt8] = []
        while magnitude > 0 {
            bytes.append(UInt8(magnitude & 0xff))
            magnitude >>= 8
        }
        if bytes[bytes.count - 1] & 0x80 != 0 {
            bytes.append(negative ? 0x80 : 0x00)
        } else if negative {
            bytes[bytes.count - 1] |= 0x80
        }
        return encodePushData(bytes)
    }

    /// `encodePushData` (MINIMALDATA: a single byte 0x01–0x10 is OP_N, 0x81 OP_1NEGATE).
    static func encodePushData(_ data: [UInt8]) -> [UInt8] {
        if data.isEmpty { return [0x00] }
        if data.count == 1 {
            if (0x01...0x10).contains(data[0]) { return [0x50 + data[0]] }
            if data[0] == 0x81 { return [0x4f] }
        }
        return pushHeader(data.count) + data
    }

    /// `encodePushDataState`: a push with no OP_N shortcut.
    static func pushHeader(_ length: Int) -> [UInt8] {
        if length <= 75 { return [UInt8(length)] }
        if length <= 0xff { return [0x4c, UInt8(length)] }
        if length <= 0xffff { return [0x4d, UInt8(length & 0xff), UInt8(length >> 8)] }
        return [0x4e, UInt8(length & 0xff), UInt8((length >> 8) & 0xff), UInt8((length >> 16) & 0xff), UInt8((length >> 24) & 0xff)]
    }

    /// `stateHex` / `serializeState` over the pool's state fields: the reserve a fixed 8-byte
    /// sign-magnitude word, keys, hashes and addresses raw, the affirmation a push (OP_0 empty).
    static func serializeState(_ s: AMMPoolFields) throws -> [UInt8] {
        let limit = BigInt(1) << 63
        guard s.tokenReserve < limit, s.tokenReserve > -limit else {
            throw fail("invalid", "tokenReserve does not fit the 8-byte state word")
        }
        var word = [UInt8](repeating: 0, count: 8)
        var magnitude = s.tokenReserve < 0 ? -s.tokenReserve : s.tokenReserve
        for i in 0..<8 where magnitude > 0 {
            word[i] = UInt8(magnitude & 0xff)
            magnitude >>= 8
        }
        if s.tokenReserve < 0 { word[7] |= 0x80 }
        let affirmation = Runar.hexBytes(s.affirmation)
        var out = word
        for field in [s.lpPubKey, s.validatorPubKey, s.validatorIdentity, s.nonce, s.lpSatsPkh, s.lpTokenPkh] {
            out += Runar.hexBytes(field)
        }
        out += affirmation.isEmpty ? [0x00] : pushHeader(affirmation.count) + affirmation
        return out
    }

    /// `findCodesepOffsets`: the byte offset of every OP_CODESEPARATOR at an opcode boundary.
    static func findCodesepOffsets(_ s: [UInt8]) -> [Int] {
        var out: [Int] = []
        var off = 0
        let n = s.count
        while off < n {
            let op = Int(s[off])
            switch op {
            case 0xab:
                out.append(off)
                off += 1
            case 0x01...0x4b:
                off += 1 + op
            case 0x4c:
                guard off + 2 <= n else { return out }
                off += 2 + Int(s[off + 1])
            case 0x4d:
                guard off + 3 <= n else { return out }
                off += 3 + (Int(s[off + 1]) | Int(s[off + 2]) << 8)
            case 0x4e:
                guard off + 5 <= n else { return out }
                let length = Int(s[off + 1]) | Int(s[off + 2]) << 8 | Int(s[off + 3]) << 16 | Int(s[off + 4]) << 24
                guard length <= n - off - 5 else { return out }
                off += 5 + length
            default:
                off += 1
            }
        }
        return out
    }

    // MARK: - Scripts

    static func p2pkh(_ pkh: [UInt8]) -> [UInt8] { [0x76, 0xa9, 0x14] + pkh + [0x88, 0xac] }

    /// `oneColorValuePrefix(assetId, amount)`.
    static func tokenPrefix(_ assetId: String, _ amount: BigInt) throws -> [UInt8] {
        guard amount > 0, amount <= BigInt(UInt64.max) else { throw fail("invalid", "token amount out of range") }
        return try OneColor.value(idBytes: Runar.hexBytes(assetId), amount: UInt64(amount), lock: .publicKeyHash(zeroPkh)).prefix().bytes
    }

    /// `tokenP2pkhHex`: a 1Color value output of `amount` to `pkh`.
    static func tokenP2pkh(_ assetId: String, _ amount: BigInt, _ pkh: [UInt8]) throws -> [UInt8] {
        try tokenPrefix(assetId, amount) + p2pkh(pkh)
    }

    static func sats(_ n: BigInt) throws -> UInt64 {
        guard n >= 0, n <= BigInt(maxSafeInteger) else { throw fail("invalid", "an output's satoshis are out of range") }
        return UInt64(n)
    }

    static func script(_ bytes: [UInt8]) throws -> Script {
        try Script(bytes: bytes, maximumByteCount: Int(limits.maximumScriptByteCount))
    }
}

extension Runar {
    /// Lowercase hex to bytes; nil for anything else.
    static func hexBytesChecked(_ text: String) -> [UInt8]? {
        guard text.utf8.count % 2 == 0, AMMPool.isHex(text, text.utf8.count / 2) else { return nil }
        return hexBytes(text)
    }
}
