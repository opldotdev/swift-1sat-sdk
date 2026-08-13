import Foundation
import BSVKeys
import BSVScript
import BSVWallet

/// `utils/resolveDestination.ts`. First set field wins: locking script, address, then counterparty.
public struct Destination: Equatable, Sendable {
    public let lockingScript: Script?
    public let address: String?
    public let counterparty: WalletCounterparty?

    public init(
        lockingScript: Script? = nil,
        address: String? = nil,
        counterparty: WalletCounterparty? = nil
    ) {
        self.lockingScript = lockingScript
        self.address = address
        self.counterparty = counterparty
    }

    public static func lockingScript(_ script: Script) -> Destination {
        Destination(lockingScript: script)
    }

    public static func address(_ address: String) -> Destination {
        Destination(address: address)
    }

    public static func counterparty(_ counterparty: WalletCounterparty) -> Destination {
        Destination(counterparty: counterparty)
    }

    public static let `self` = Destination(counterparty: .self)
}

public struct ResolvedDestination: Sendable {
    public let lockingScript: Script
    public let customInstructions: CustomInstructions?
}

public enum ResolveDestination {
    public static func resolve(
        identity: PrivateKey,
        destination: Destination?,
        protocolID: WalletProtocolID,
        keyIDPrefix: String,
        keyID: String? = nil,
        network: BitcoinNetwork = .mainnet
    ) throws -> ResolvedDestination {
        if let script = destination?.lockingScript {
            return ResolvedDestination(lockingScript: script, customInstructions: nil)
        }
        if let address = destination?.address {
            return ResolvedDestination(
                lockingScript: try ActionScript.payToPublicKeyHash(address),
                customInstructions: nil
            )
        }

        let counterparty = destination?.counterparty ?? .self
        let resolvedKeyID = keyID ?? "\(keyIDPrefix)-\(Int(Date().timeIntervalSince1970 * 1000))"
        let isSelf = counterparty == .self
        let publicKey = try WalletKeyDeriver(rootKey: identity).derivePublicKey(
            protocolID: protocolID,
            keyID: WalletKeyID(resolvedKeyID),
            counterparty: counterparty,
            forSelf: isSelf
        )
        let address = Address(publicKey: publicKey, network: network)
        return ResolvedDestination(
            lockingScript: try ActionScript.payToPublicKeyHash(address),
            customInstructions: try CustomInstructions(
                protocolID: protocolID,
                keyID: resolvedKeyID,
                counterparty: isSelf ? .self : counterparty
            )
        )
    }
}
