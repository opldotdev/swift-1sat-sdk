import BSVKeys
import BSVWallet
import ToolboxServices
import ToolboxStorage
import ToolboxStorageClient

/// Network selected for address encoding. Matches `@1sat/actions` `OneSatContext.chain`.
public enum OneSatChain: String, Equatable, Sendable {
    case main
    case test

    public var network: BitcoinNetwork {
        switch self {
        case .main: .mainnet
        case .test: .testnet
        }
    }
}

/// Overlay and token-status reads used by `sendBsv21`.
///
/// Field names match `@1sat/actions` `tokens/index.ts` `ctx.services.bsv21`.
public protocol Bsv21ActionServices: Sendable {
    func tokenDetails(tokenId: String) async throws -> Bsv21TokenDetails
    func validateUnspentOutputs(tokenId: String, outpoints: [String]) async throws -> Set<String>
    /// GET /{tokenId}/outputs/{outpoint}. Throws when the overlay does not know the outpoint (404).
    func validateOutput(tokenId: String, outpoint: String) async throws
    func submitTransfer(tx: [UInt8], tokenId: String) async throws
}

public struct Bsv21TokenDetails: Equatable, Sendable {
    public let isActive: Bool
    public let feeAddress: String
    public let feePerOutput: UInt64
    public let decimals: Int
    public let symbol: String?
    public let icon: String?

    public init(
        isActive: Bool,
        feeAddress: String,
        feePerOutput: UInt64,
        decimals: Int,
        symbol: String? = nil,
        icon: String? = nil
    ) {
        self.isActive = isActive
        self.feeAddress = feeAddress
        self.feePerOutput = feePerOutput
        self.decimals = decimals
        self.symbol = symbol
        self.icon = icon
    }
}

/// Listing-transaction BEEF for `purchaseOrdinal`.
///
/// Matches `ctx.services.getBeefForTxid` in `ordinals/index.ts`.
public protocol ListingBeefSource: Sendable {
    func beef(forTxid txid: String) async throws -> [UInt8]
}

/// Wallet handle for 1Sat actions.
///
/// The identity key is the BRC-42 root. Storage is the frozen Swift toolbox client.
/// `ActionSigner.sign` cannot sign mixed P1SAT + BRC-29 funding inputs; execute signs
/// those groups separately after `ActionAssembler` runs.
public struct OneSatContext: Sendable {
    public let identity: PrivateKey
    public let storage: StorageClient
    public let auth: AuthID
    public let maximumFee: Int64
    public let chain: OneSatChain
    public let services: (any WalletServices)?
    public let bsv21: (any Bsv21ActionServices)?
    public let mnee: (any MneeActionServices)?
    public let listings: (any ListingBeefSource)?

    public init(
        identity: PrivateKey,
        storage: StorageClient,
        auth: AuthID,
        maximumFee: Int64 = 100_000,
        chain: OneSatChain = .main,
        services: (any WalletServices)? = nil,
        bsv21: (any Bsv21ActionServices)? = nil,
        mnee: (any MneeActionServices)? = nil,
        listings: (any ListingBeefSource)? = nil
    ) {
        self.identity = identity
        self.storage = storage
        self.auth = auth
        self.maximumFee = maximumFee
        self.chain = chain
        self.services = services
        self.bsv21 = bsv21
        self.mnee = mnee
        self.listings = listings
    }

    public var deriver: WalletKeyDeriver { WalletKeyDeriver(rootKey: identity) }
}
