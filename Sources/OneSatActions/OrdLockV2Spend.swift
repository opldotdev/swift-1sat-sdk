import BSVScript
import BSVTransaction
import OneSatTemplates

/// Purchase-side layout and guards of `@1sat/templates` `ordlock/ordlockV2.ts`
/// (`planPurchase`, `ordinalOutput`, `assertDelivery`).
///
/// The covenant binds the seller's payment, not the buyer's delivery. The
/// listed satoshi follows first-sat ordering, so a purchase is laid out as:
///
/// ```text
/// inputs:  0…m-1 front funding · m…m+n-1 listings · trailing fee funding
/// outputs: 0…m-1 cushion + 0-sat fillers · m…m+n-1 seller payouts · buyer receives · change
/// ```
public enum OrdLockV2Spend {
    /// A receive output the buyer approved: the exact index and script the listed satoshi must reach.
    public struct DeliveryTarget: Equatable, Sendable {
        public let vout: Int
        public let lockingScript: Script

        public init(vout: Int, lockingScript: Script) {
            self.vout = vout
            self.lockingScript = lockingScript
        }
    }

    /// Output layout produced by ``planPurchase(frontSatoshis:listings:receives:cushionScript:)``.
    public struct Plan: Equatable, Sendable {
        /// Outputs in transaction order: leading slots, payouts, receives.
        public let outputs: [TransactionOutput]
        /// Index of the cushion output, or nil when the cushion is zero.
        public let cushionVout: Int?
        /// Indices of the zero-satoshi `OP_FALSE OP_RETURN` fillers.
        public let fillerVouts: [Int]
        /// Index of each seller payout (equals its listing's input index).
        public let payoutVouts: [Int]
        /// Index of each buyer receive output, in listing order.
        public let receiveVouts: [Int]
        /// Total front funding minus total payouts.
        public let cushion: UInt64
    }

    /// `OP_FALSE OP_RETURN`, the 0-sat filler that holds a leading slot.
    public static let fillerScriptBytes: [UInt8] = [0x00, 0x6a]

    /// `OrdLockV2.planPurchase`: every listing's payout at its own input index and
    /// every listed satoshi flowing into its receive output. Front funding inputs
    /// `0…m-1` must cover the payouts; fee funding goes after the listings and
    /// change after these outputs, or the sat map shifts.
    public static func planPurchase(
        frontSatoshis: [UInt64],
        listings: [Script],
        receives: [TransactionOutput],
        cushionScript: Script
    ) throws -> Plan {
        let frontCount = frontSatoshis.count
        guard frontCount >= 1 else {
            throw refused("OrdLockV2.planPurchase: at least one front funding input")
        }
        guard !listings.isEmpty else {
            throw refused("OrdLockV2.planPurchase: at least one listing")
        }
        guard receives.count == listings.count else {
            throw refused("OrdLockV2.planPurchase: one receive output per listing")
        }
        let payouts = try listings.map { listing -> TransactionOutput in
            let payout = try OrdLockV2.payoutOutput(listing)
            return TransactionOutput(satoshis: payout.satoshis, lockingScript: payout.script)
        }
        let totalPayout = payouts.reduce(UInt64(0)) { $0 + $1.satoshis }
        let front = frontSatoshis.reduce(UInt64(0), +)
        guard front >= totalPayout else {
            throw refused(
                "OrdLockV2.planPurchase: front funding \(front) does not cover payouts \(totalPayout)"
            )
        }
        let cushion = front - totalPayout
        let filler = try Script(bytes: fillerScriptBytes, maximumByteCount: 2)

        var outputs: [TransactionOutput] = []
        var fillerVouts: [Int] = []
        var cushionVout: Int?
        for index in 0..<frontCount {
            if index == 0, cushion > 0 {
                cushionVout = outputs.count
                outputs.append(TransactionOutput(satoshis: cushion, lockingScript: cushionScript))
            } else {
                fillerVouts.append(outputs.count)
                outputs.append(TransactionOutput(satoshis: 0, lockingScript: filler))
            }
        }
        var payoutVouts: [Int] = []
        for payout in payouts {
            payoutVouts.append(outputs.count)
            outputs.append(payout)
        }
        var receiveVouts: [Int] = []
        for receive in receives {
            guard receive.satoshis == 1 else {
                throw refused("OrdLockV2.planPurchase: receive outputs must carry exactly 1 satoshi")
            }
            receiveVouts.append(outputs.count)
            outputs.append(receive)
        }
        return Plan(
            outputs: outputs,
            cushionVout: cushionVout,
            fillerVouts: fillerVouts,
            payoutVouts: payoutVouts,
            receiveVouts: receiveVouts,
            cushion: cushion
        )
    }

    /// `OrdLockV2.ordinalOutput`: the output that receives the first satoshi of
    /// `inputIndex` under first-sat ordering. Every earlier input must carry its source output.
    public static func ordinalOutput(transaction: Transaction, inputIndex: Int) throws -> Int {
        var offset: UInt64 = 0
        for index in 0..<inputIndex {
            guard transaction.inputs.indices.contains(index),
                  let source = transaction.inputs[index].sourceOutput else {
                throw refused(
                    "OrdLockV2: input \(index) has no source satoshis; cannot map the ordinal from input \(inputIndex)"
                )
            }
            offset += source.satoshis
        }
        var accumulated: UInt64 = 0
        for (vout, output) in transaction.outputs.enumerated() {
            let next = accumulated + output.satoshis
            if offset < next { return vout }
            accumulated = next
        }
        throw refused(
            "OrdLockV2: the ordinal from input \(inputIndex) is not mapped to any output (it would be burned as fee)"
        )
    }

    /// `OrdLockV2.assertDelivery`: the listed satoshi spent by `inputIndex` must
    /// land on a 1-sat output and, when `deliveries` is given, match one of them
    /// by index and script. Without `deliveries` the destination must at least not
    /// be a data output or the payout slot of a v2 listing in the transaction.
    @discardableResult
    public static func assertDelivery(
        transaction: Transaction,
        inputIndex: Int,
        deliveries: [DeliveryTarget]?
    ) throws -> Int {
        let vout = try ordinalOutput(transaction: transaction, inputIndex: inputIndex)
        let output = transaction.outputs[vout]
        guard output.satoshis == 1 else {
            throw refused(
                "OrdLockV2: listing input \(inputIndex) delivers its ordinal to output \(vout) carrying \(output.satoshis) sats, not a 1-sat receive output"
            )
        }
        let script = output.lockingScript.bytes
        if let deliveries {
            guard deliveries.contains(where: { $0.vout == vout && $0.lockingScript.bytes == script }) else {
                throw refused(
                    "OrdLockV2: listing input \(inputIndex) delivers its ordinal to output \(vout), which is not an approved receive output"
                )
            }
            return vout
        }
        if script.first == 0x6a || (script.count >= 2 && script[0] == 0x00 && script[1] == 0x6a) {
            throw refused(
                "OrdLockV2: listing input \(inputIndex) delivers its ordinal to data output \(vout)"
            )
        }
        if transaction.inputs.indices.contains(vout),
           let source = transaction.inputs[vout].sourceOutput,
           OrdLockV2.isOrdLockV2(source.lockingScript) {
            throw refused(
                "OrdLockV2: listing input \(inputIndex) delivers its ordinal to output \(vout), the payout slot of listing input \(vout)"
            )
        }
        return vout
    }

    private static func refused(_ message: String) -> OneSatActionError {
        .ordLockV2Refused(message)
    }
}
