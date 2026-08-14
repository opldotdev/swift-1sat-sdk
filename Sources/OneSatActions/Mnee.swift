import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import OneSatAddresses
import OneSatTemplates
import ToolboxActions

public enum Mnee {
    public struct Config: Equatable, Sendable {
        public let approver: String
        public let feeAddress: String
        public let burnAddress: String
        public let fees: [FeeTier]
        public let tokenId: String

        public init(
            approver: String,
            feeAddress: String,
            burnAddress: String,
            fees: [FeeTier],
            tokenId: String
        ) {
            self.approver = approver
            self.feeAddress = feeAddress
            self.burnAddress = burnAddress
            self.fees = fees
            self.tokenId = tokenId
        }
    }

    public struct FeeTier: Equatable, Sendable {
        public let min: Int
        public let max: Int
        public let fee: Int

        public init(min: Int, max: Int, fee: Int) {
            self.min = min
            self.max = max
            self.fee = fee
        }
    }

    public struct Utxo: Equatable, Sendable {
        public let txid: String
        public let vout: UInt32
        public let amount: Int
        public let owners: [String]

        public init(txid: String, vout: UInt32, amount: Int, owners: [String]) {
            self.txid = txid
            self.vout = vout
            self.amount = amount
            self.owners = owners
        }
    }

    public struct TicketStatus: Equatable, Sendable {
        public let status: String
        public let txid: String
        public let errors: String?

        public init(status: String, txid: String, errors: String? = nil) {
            self.status = status
            self.txid = txid
            self.errors = errors
        }
    }

    public struct Derivation: Equatable, Sendable {
        public let address: String
        public let derivationPrefix: String
        public let derivationSuffix: String

        public init(address: String, derivationPrefix: String, derivationSuffix: String) {
            self.address = address
            self.derivationPrefix = derivationPrefix
            self.derivationSuffix = derivationSuffix
        }
    }

    public struct Recipient: Equatable, Sendable {
        public let address: String
        public let amount: Double

        public init(address: String, amount: Double) {
            self.address = address
            self.amount = amount
        }
    }

    public struct SendRequest: Equatable, Sendable {
        public let recipients: [Recipient]
        public let derivations: [Derivation]
        public let changeAddress: String?

        public init(
            recipients: [Recipient],
            derivations: [Derivation],
            changeAddress: String? = nil
        ) {
            self.recipients = recipients
            self.derivations = derivations
            self.changeAddress = changeAddress
        }
    }

    public struct SendResult: Equatable, Sendable {
        public let txid: String?
        public let ticketId: String?
        public let error: String?

        public init(txid: String? = nil, ticketId: String? = nil, error: String? = nil) {
            self.txid = txid
            self.ticketId = ticketId
            self.error = error
        }
    }

    public static let statusBroadcasting = "BROADCASTING"
    public static let statusSuccess = "SUCCESS"
    public static let statusMined = "MINED"
    public static let statusFailed = "FAILED"

    /// Math.round parity: Int((mneeAmount * 100_000).rounded())
    public static func toAtomicAmount(_ mneeAmount: Double) -> Int {
        Int((mneeAmount * 100_000).rounded())
    }

    /// JS shortest-number parity for error strings and displays, computed from the
    /// atomic integer: 150000 → "1.5", 100000 → "1", 12 → "0.00012".
    public static func decimalString(atomic: Int) -> String {
        if atomic == 0 { return "0" }
        let sign = atomic < 0 ? "-" : ""
        let value = abs(atomic)
        let whole = value / 100_000
        let remainder = value % 100_000
        if remainder == 0 {
            return sign + String(whole)
        }
        var fraction = String(remainder)
        fraction = String(repeating: "0", count: 5 - fraction.count) + fraction
        while fraction.last == "0" {
            fraction.removeLast()
        }
        return sign + "\(whole).\(fraction)"
    }

    /// The MNEE default address set: DepositAddresses prefix "1sat", indices 0-4.
    public static func depositDerivations(
        identity: PrivateKey,
        network: BitcoinNetwork = .mainnet,
        startIndex: Int = 0,
        count: Int = 5
    ) throws -> [Derivation] {
        try (startIndex..<(startIndex + count)).map { index in
            let address = try DepositAddresses.address(
                identity: identity,
                index: index,
                prefix: DepositAddresses.defaultPrefix,
                network: network
            )
            return Derivation(
                address: address.description,
                derivationPrefix: DepositAddresses.defaultPrefix,
                derivationSuffix: String(index)
            )
        }
    }

    /// Builds, owner-signs, submits, then polls (30 × 2000 ms via `sleep`).
    /// Never throws: every failure is SendResult(error:).
    public static func send(
        _ ctx: OneSatContext,
        _ request: SendRequest,
        sleep: @escaping @Sendable (_ milliseconds: UInt64) async throws -> Void
            = { try await Task.sleep(nanoseconds: $0 * 1_000_000) }
    ) async -> SendResult {
        guard let client = ctx.mnee else {
            return SendResult(error: OneSatActionError.mneeClientRequired.wireMessage)
        }
        do {
            if request.recipients.isEmpty {
                return SendResult(error: "no-recipients")
            }
            if request.derivations.isEmpty {
                return SendResult(error: "no-derivations")
            }

            var addressKeyMap: [String: String] = [:]
            for derivation in request.derivations {
                addressKeyMap[derivation.address] =
                    "\(derivation.derivationPrefix) \(derivation.derivationSuffix)"
            }

            let config = try await client.config()
            if config.approver.isEmpty {
                return SendResult(error: "failed-to-get-mnee-config")
            }

            let totalAmount = request.recipients.reduce(0.0) { $0 + $1.amount }
            if totalAmount <= 0 {
                return SendResult(error: "invalid-amount")
            }
            let totalAtomic = toAtomicAmount(totalAmount)

            let fee: Int
            if request.recipients.contains(where: { $0.address == config.burnAddress }) {
                fee = 0
            } else if let tier = config.fees.first(where: {
                totalAtomic >= $0.min && totalAtomic <= $0.max
            }) {
                fee = tier.fee
            } else {
                return SendResult(error: "fee-ranges-inadequate")
            }

            let allUtxos = try await client.utxos(
                addresses: request.derivations.map(\.address)
            )
            let tokensNeeded = totalAtomic + fee
            var selectedUtxos: [Utxo] = []
            var tokensIn = 0
            for utxo in allUtxos {
                if tokensIn >= tokensNeeded { break }
                if utxo.amount <= 0 { continue }
                selectedUtxos.append(utxo)
                tokensIn += utxo.amount
            }
            if tokensIn < tokensNeeded {
                return SendResult(
                    error: "Insufficient MNEE. Have: \(decimalString(atomic: tokensIn)), Need: \(decimalString(atomic: tokensNeeded))"
                )
            }

            let limits = WalletTransactionLimits.standard
            let emptyUnlock = try Script(
                bytes: [],
                maximumByteCount: Int(limits.maximumScriptByteCount)
            )
            var inputs: [TransactionInput] = []
            for utxo in selectedUtxos {
                let raw: [UInt8]
                do {
                    raw = try await client.rawTransaction(txid: utxo.txid)
                } catch {
                    return SendResult(error: "failed-to-fetch-source-tx: \(utxo.txid)")
                }
                let sourceTx: Transaction
                do {
                    sourceTx = try Transaction(bytes: raw, limits: limits)
                } catch {
                    return SendResult(error: "failed-to-fetch-source-tx: \(utxo.txid)")
                }
                guard sourceTx.outputs.indices.contains(Int(utxo.vout)) else {
                    return SendResult(error: "failed-to-fetch-source-tx: \(utxo.txid)")
                }
                inputs.append(
                    TransactionInput(
                        previousOutput: Outpoint(
                            transactionID: try TransactionID(displayHex: utxo.txid),
                            outputIndex: utxo.vout
                        ),
                        unlockingScript: emptyUnlock,
                        sequence: 0xffff_ffff,
                        sourceOutput: sourceTx.outputs[Int(utxo.vout)]
                    )
                )
            }

            let approver = try Hex.decode(config.approver, maximumDecodedByteCount: 33)
            var outputs: [TransactionOutput] = []
            for recipient in request.recipients {
                outputs.append(
                    try inscriptionOutput(
                        address: recipient.address,
                        atomic: toAtomicAmount(recipient.amount),
                        tokenId: config.tokenId,
                        approver: approver
                    )
                )
            }
            if fee > 0 {
                outputs.append(
                    try inscriptionOutput(
                        address: config.feeAddress,
                        atomic: fee,
                        tokenId: config.tokenId,
                        approver: approver
                    )
                )
            }
            let change = tokensIn - totalAtomic - fee
            if change > 0 {
                let decodedChange = inputs[0].sourceOutput.flatMap {
                    Cosign.decode($0.lockingScript, network: ctx.chain.network)?.address.description
                }
                let changeAddress =
                    request.changeAddress
                    ?? decodedChange
                    ?? request.derivations[0].address
                outputs.append(
                    try inscriptionOutput(
                        address: changeAddress,
                        atomic: change,
                        tokenId: config.tokenId,
                        approver: approver
                    )
                )
            }

            var tx = Transaction(version: 1, inputs: inputs, outputs: outputs, lockTime: 0)
            for index in tx.inputs.indices {
                let owner = selectedUtxos[index].owners.first
                guard let owner, let keyID = addressKeyMap[owner] else {
                    return SendResult(
                        error: "No key found for address \(owner ?? "") — not a yours wallet address"
                    )
                }
                tx.inputs[index].unlockingScript = try ownerUnlockingScript(
                    transaction: tx,
                    inputIndex: index,
                    identity: ctx.identity,
                    keyID: keyID
                )
            }

            let ticketId = try await client.submitTransfer(
                tx: try tx.serialized(format: .raw, limits: limits)
            )
            if ticketId.isEmpty {
                return SendResult(error: "no-ticket-id-returned")
            }

            for _ in 0..<30 {
                do {
                    try await sleep(2000)
                    let status = try await client.transferStatus(ticketId: ticketId)
                    if status.status == statusFailed {
                        return SendResult(
                            ticketId: ticketId,
                            error: status.errors ?? "transaction-failed"
                        )
                    }
                    if status.status == statusSuccess || status.status == statusMined {
                        return SendResult(txid: status.txid, ticketId: ticketId)
                    }
                } catch {
                    continue
                }
            }
            return SendResult(ticketId: ticketId, error: "timeout-waiting-for-txid")
        } catch let error as OneSatActionError {
            return SendResult(error: error.wireMessage)
        } catch {
            return SendResult(error: error.localizedDescription)
        }
    }

    private static func inscriptionOutput(
        address: String,
        atomic: Int,
        tokenId: String,
        approver: [UInt8]
    ) throws -> TransactionOutput {
        let script = try BSV21.transfer(tokenID: tokenId, amount: String(atomic))
            .lock(lockingScript: try Cosign.lock(address: try Address(address), cosigner: approver))
        return TransactionOutput(satoshis: 1, lockingScript: script)
    }

    private static func ownerUnlockingScript(
        transaction: Transaction,
        inputIndex: Int,
        identity: PrivateKey,
        keyID: String
    ) throws -> Script {
        let hashType = ForkIDSignatureHashType(outputs: .all, anyoneCanPay: true)
        let digest = try transaction.forkIDSignatureHash(
            inputIndex: inputIndex,
            hashType: hashType,
            limits: WalletTransactionLimits.standard
        )
        let key = try P1SATKey.privateKey(identity: identity, keyID: keyID)
        return try Cosign.ownerUnlock(
            ownerSigDER: key.sign(digest: digest).derBytes,
            sigHashFlag: hashType.rawValue,
            ownerPublicKey: key.publicKey
        )
    }
}

/// The one MNEE seam. Implemented by the app (Bsv21ActionServices precedent);
/// inside the SDK nothing conforms — OneSatActions does not import OneSatClient.
public protocol MneeActionServices: Sendable {
    func config() async throws -> Mnee.Config
    /// All pages, already filtered to transfer/deploy+mint ops (client behaviour).
    func utxos(addresses: [String]) async throws -> [Mnee.Utxo]
    func rawTransaction(txid: String) async throws -> [UInt8]
    /// Returns the plain-text ticketId (possibly empty).
    func submitTransfer(tx: [UInt8]) async throws -> String
    func transferStatus(ticketId: String) async throws -> Mnee.TicketStatus
}
