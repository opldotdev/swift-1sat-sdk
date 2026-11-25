import Foundation
import BSVCore
import BSVTransaction
import BSVWallet
import OneSatSweep
import OneSatTemplates
import ToolboxActions

/// `internalizeOpns` from `packages/actions/src/opns/index.ts`: files a name mined elsewhere (an
/// OpNS mint delivered as Atomic BEEF) in the OpNS basket.
extension OpNS {
    /// `InternalizeOpnsInput`.
    public struct InternalizeRequest: Sendable {
        /// Atomic BEEF (BRC-95) of the mint.
        public let tx: [UInt8]
        /// Derivation of the key the name is locked to, recorded in its customInstructions.
        public let protocolID: WalletProtocolID
        public let keyID: String
        /// `counterparty`; nil records `self`, as TS does.
        public let counterparty: String?

        public init(tx: [UInt8], protocolID: WalletProtocolID, keyID: String, counterparty: String? = nil) {
            self.tx = tx
            self.protocolID = protocolID
            self.keyID = keyID
            self.counterparty = counterparty
        }
    }

    /// `InternalizeOpnsResult`.
    public struct InternalizeResult: Equatable, Sendable {
        public let txid: String?
        /// `<txid>.<vout>` of the name.
        public let outpoint: String?
        public let name: String?
        /// `<actionId>_<vout>`: the name's `id:` tag without its prefix.
        public let id: String?
        public let error: String?
        /// For a log, not for display: the reflection of the error behind `error` when it was not
        /// a `OneSatActionError`. Ignored by `==`.
        public let diagnostic: String?

        public init(
            txid: String? = nil,
            outpoint: String? = nil,
            name: String? = nil,
            id: String? = nil,
            error: String? = nil,
            diagnostic: String? = nil
        ) {
            self.txid = txid
            self.outpoint = outpoint
            self.name = name
            self.id = id
            self.error = error
            self.diagnostic = diagnostic
        }

        public static func == (lhs: InternalizeResult, rhs: InternalizeResult) -> Bool {
            lhs.txid == rhs.txid && lhs.outpoint == rhs.outpoint && lhs.name == rhs.name
                && lhs.id == rhs.id && lhs.error == rhs.error
        }
    }

    /// `internalizeOpns`: finds the name the mint delivers (``mintNameDelivery(in:)``) and
    /// internalizes that one output into `opns` with the tags and customInstructions TS stamps.
    /// A transaction that is not a mint fails with ``OneSatActionError/notAnOpnsMint``; any other
    /// failure, the wallet's included, comes back as `error`, as TS returns it.
    public static func internalize(
        _ internalizer: any ActionInternalizer,
        _ request: InternalizeRequest,
        actionID: String = TrackedAction.randomActionID()
    ) async -> InternalizeResult {
        do {
            let limits = WalletBEEFLimits.standard
            let atomic = try AtomicBEEF(bytes: request.tx, limits: limits, transactionOrder: .any)
            let subjectID = atomic.subjectTransactionID
            guard let subject = try atomic.beef.transaction(for: subjectID, limits: limits.transactionLimits)
            else { throw BEEFError.missingSubjectTransaction(subjectID) }
            let txid = subjectID.displayHex
            guard let delivery = mintNameDelivery(in: subject) else {
                return InternalizeResult(error: OneSatActionError.notAnOpnsMint.wireMessage)
            }
            let outpoint = "\(txid).\(delivery.vout)"
            let origin = "origin:\(Bsv21Remittance.formatOrdinalOutpoint(outpoint))"
            let id = "\(actionID)_\(delivery.vout)"
            _ = try await internalizer.internalizeAction(WalletInternalizeActionRequest(
                transaction: atomic,
                description: DepositIndex.utf16Prefix("opns name \(delivery.name)", 50),
                outputs: [WalletInternalizeOutput(
                    outputIndex: delivery.vout,
                    remittance: .basketInsertion(try WalletBasketInsertion(
                        basket: OneSatConstants.opnsBasket,
                        customInstructions: OrdinalRemittance.buildCustomInstructions(
                            protocolID: request.protocolID,
                            keyID: request.keyID,
                            counterparty: request.counterparty ?? "self",
                            tags: [origin],
                            name: delivery.name
                        ),
                        tags: [
                            "opns",
                            "type:\(OpNSTemplate.contentType)",
                            origin,
                            "name:\(delivery.name)",
                            "id:\(id)",
                        ]
                    ))
                )]
            ))
            return InternalizeResult(txid: txid, outpoint: outpoint, name: delivery.name, id: id)
        } catch let error as OneSatActionError {
            return InternalizeResult(error: error.wireMessage)
        } catch {
            OneSatLog.error(error, "internalize OpNS mint failed", category: "OneSatActions")
            return InternalizeResult(
                error: OneSatLog.localizedMessage(error), diagnostic: OneSatLog.reflecting(error)
            )
        }
    }

    /// `findMintNameDelivery`: the first `i` where outputs `i` and `i + 1` are OpNS nodes, a third
    /// output follows, and the child's domain is a name (trimmed, first 64 UTF-16 units, not
    /// empty). The name is output `i + 2`.
    public static func mintNameDelivery(in transaction: Transaction) -> (vout: UInt32, name: String)? {
        let outputs = transaction.outputs
        var index = 0
        while index + 2 < outputs.count {
            defer { index += 1 }
            guard OpNSTemplate.decode(outputs[index].lockingScript) != nil,
                  let child = OpNSTemplate.decode(outputs[index + 1].lockingScript),
                  let name = DepositIndex.opnsName(Array(child.domain.utf8))
            else { continue }
            return (UInt32(index + 2), name)
        }
        return nil
    }
}
