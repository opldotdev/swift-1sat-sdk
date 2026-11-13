import BSVCore
import BSVKeys
import BSVScript
import BSVTransaction
import BSVWallet
import OneSatClient
import ToolboxActions

/// OpNS name to identity, read from the signed PushDrop bind on the name's current coin.
///
/// Port of `packages/wallet-server/src/paymail/resolve.ts` (`resolvePaymailBind`,
/// `verifyPushDropBind`) and `ResolvedBind` from `paymail/types.ts`.
extension OpNS {
    /// `Omit<ResolvedBind, 'outpoint'>`: what a verified bind names.
    public struct Bind: Equatable, Sendable {
        /// Hex of the 33-byte compressed identity key.
        public let identityKey: String
        /// `profile.domain`: the BRC-169 domain the identity is reached at.
        public let domain: String?
        /// `profile.name`: presentation-only display name.
        public let profileName: String?
        /// `profile.avatar` as an origin outpoint, `txid.vout`.
        public let avatarOrigin: String?

        public init(
            identityKey: String,
            domain: String? = nil,
            profileName: String? = nil,
            avatarOrigin: String? = nil
        ) {
            self.identityKey = identityKey
            self.domain = domain
            self.profileName = profileName
            self.avatarOrigin = avatarOrigin
        }
    }

    /// `ResolvedBind`: the verified bind plus the outpoint (`txid.vout`) it was read from.
    public struct ResolvedBind: Equatable, Sendable {
        public let identityKey: String
        public let outpoint: String
        public let domain: String?
        public let profileName: String?
        public let avatarOrigin: String?

        public init(
            identityKey: String,
            outpoint: String,
            domain: String? = nil,
            profileName: String? = nil,
            avatarOrigin: String? = nil
        ) {
            self.identityKey = identityKey
            self.outpoint = outpoint
            self.domain = domain
            self.profileName = profileName
            self.avatarOrigin = avatarOrigin
        }

        public init(_ bind: Bind, outpoint: String) {
            self.init(
                identityKey: bind.identityKey,
                outpoint: outpoint,
                domain: bind.domain,
                profileName: bind.profileName,
                avatarOrigin: bind.avatarOrigin
            )
        }

        public var bind: Bind {
            Bind(
                identityKey: identityKey,
                domain: domain,
                profileName: profileName,
                avatarOrigin: avatarOrigin
            )
        }
    }

    /// `resolvePaymailBind`: OpNS origin of `name`, ORDFS latest revision (`seq` -1) of that
    /// origin, BEEF of the latest transaction, then ``verifyPushDropBind(transaction:vout:lockingScript:)``
    /// on the latest output.
    public static func resolveBind(
        name: String,
        opns: OpnsClient,
        beef: any ListingBeefSource
    ) async throws -> ResolvedBind {
        let origin = try await opns.origin(forName: name)
        let latest = try await opns.metadata(outpoint: origin.outpoint, seq: -1)
        let outpoint = try Outpoint(wireBytes: OpnsFields.outpointWire(latest.outpoint))
        let txid = outpoint.transactionID.displayHex
        let vout = outpoint.outputIndex

        let parsed = try BEEF(
            bytes: try await beef.beef(forTxid: txid),
            limits: WalletBEEFLimits.standard
        )
        guard let transaction = try parsed.transaction(
                  for: outpoint.transactionID,
                  limits: WalletBEEFLimits.standard.transactionLimits
              ),
              transaction.outputs.indices.contains(Int(vout))
        else {
            throw OpnsBindError.noOutput(txid: txid, vout: vout)
        }

        let bind = try await verifyPushDropBind(
            transaction: transaction,
            vout: Int(vout),
            lockingScript: transaction.outputs[Int(vout)].lockingScript
        )
        return ResolvedBind(bind, outpoint: "\(txid).\(vout)")
    }

    /// `verifyPushDropBind`: check the bind on a name coin and return the identity it names.
    ///
    /// The lock is a signed lock-before PushDrop whose fields are key/value pairs (`identity`,
    /// `profile`, …) followed by the field signature. The lock key must be the identity's P1SAT
    /// key for `opns:<txid>_<vout>` of `transaction`'s first input, counterparty `anyone`, and the
    /// signature must verify over the other fields concatenated. Anything after the drops (an
    /// inscription) is ignored.
    public static func verifyPushDropBind(
        transaction: Transaction,
        vout _: Int,
        lockingScript: Script
    ) async throws -> Bind {
        guard let decoded = SignOrdinalInput.lockBeforePushDrop(in: lockingScript),
              decoded.fields.count >= 3
        else {
            throw OpnsBindError.noBind("not a signed key/value PushDrop")
        }

        var fields = decoded.fields
        let signature = fields.removeLast()
        let read: (identity: PublicKey, profile: OpnsFields.Profile?)
        do {
            read = try readBindFields(fields)
        } catch let error as OpnsBindError {
            throw error
        } catch let error as OpnsFieldError {
            throw OpnsBindError.noBind(error.wireMessage)
        } catch {
            throw OpnsBindError.noBind(String(describing: error))
        }

        let identity = read.identity
        let profile = read.profile

        guard let input = transaction.inputs.first else {
            throw OpnsBindError.missingCreationInput
        }
        let keyID = try WalletKeyID(registerKeyID(input.previousOutput))
        let protocolID = try OneSatConstants.p1satProtocolID
        let anyone = try ProtoWallet.anyone()

        // forSelf false: the identity's derived key for counterparty `anyone`, which is the key
        // the publishing wallet locks to (`forSelf` true on its side).
        let expectedLock = try await anyone.getPublicKey(WalletGetPublicKeyRequest(
            selection: .derived(
                protocolID: protocolID,
                keyID: keyID,
                counterparty: .publicKey(identity),
                forSelf: false
            )
        )).publicKey
        guard expectedLock.compressedBytes == decoded.publicKey.compressedBytes else {
            throw OpnsBindError.lockKeyMismatch
        }

        guard let parsedSignature = try? ECDSASignature(derBytes: signature),
              try await anyone.verifySignature(WalletVerifySignatureRequest(
                  protocolID: protocolID,
                  keyID: keyID,
                  counterparty: .publicKey(identity),
                  payload: .data(fields.flatMap { $0 }),
                  signature: parsedSignature
              )).valid
        else {
            throw OpnsBindError.invalidSignature
        }

        return Bind(
            identityKey: Hex.encode(identity.compressedBytes),
            domain: profile.map(\.domain).flatMap { $0.isEmpty ? nil : $0 },
            profileName: profile?.name.flatMap { $0.isEmpty ? nil : $0 },
            avatarOrigin: try profile?.avatar.map(formatAvatarOrigin)
        )
    }

    /// `readBindFields`: exactly one `identity` (33-byte compressed key) and at most one
    /// `profile`; unknown keys are skipped. Errors become `no bind: <message>`.
    private static func readBindFields(
        _ fields: [[UInt8]]
    ) throws -> (identity: PublicKey, profile: OpnsFields.Profile?) {
        var identity: PublicKey?
        var profile: OpnsFields.Profile?
        var sawProfile = false
        for (key, value) in try OpnsFields.fieldPairs(fields) {
            if key == OpnsFields.identityField {
                guard identity == nil else { throw OpnsBindError.noBind("duplicate identity") }
                guard OpnsFields.isIdentityKey(value), let key = try? PublicKey(value) else {
                    throw OpnsBindError.noBind("identity is not a key")
                }
                identity = key
            } else if key == OpnsFields.profileField {
                guard !sawProfile else { throw OpnsBindError.noBind("duplicate profile") }
                sawProfile = true
                profile = try OpnsFields.decodeProfile(value)
            }
        }
        guard let identity else { throw OpnsBindError.noBind("missing identity") }
        return (identity, profile)
    }

    /// `outpointFromWire` + `formatOutpoint`: 36 bytes to `txid.vout`.
    private static func formatAvatarOrigin(_ wire: [UInt8]) throws -> String {
        let outpoint = try Outpoint(wireBytes: wire)
        return "\(outpoint.transactionID.displayHex).\(outpoint.outputIndex)"
    }
}

/// Bind-resolution failures. `wireMessage` is the TS `Error.message`.
public enum OpnsBindError: Error, Equatable, Sendable {
    /// The output is not a well-formed key/value bind (`no bind: <reason>`).
    case noBind(String)
    case lockKeyMismatch
    case invalidSignature
    case missingCreationInput
    case noOutput(txid: String, vout: UInt32)

    public var wireMessage: String {
        switch self {
        case .noBind(let reason):
            return "no bind: \(reason)"
        case .lockKeyMismatch:
            return "lock pubkey does not match bind derivation"
        case .invalidSignature:
            return "invalid PushDrop field signature"
        case .missingCreationInput:
            return "missing creation input outpoint"
        case .noOutput(let txid, let vout):
            return "no output at \(txid).\(vout)"
        }
    }
}
