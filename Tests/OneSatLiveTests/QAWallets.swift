import BSVCore
import BSVCrypto
import BSVKeys
import BSVWallet
import Foundation
import OneSatActions
import ToolboxStorage
import ToolboxStorageClient
import ToolboxWallet

/// The QA wallets: `HMAC-SHA256(key: root, message: "<set>/<role>")` for the roles A, B and T.
///
/// - A is the working wallet; flows spend from it and send B's funds back to it.
/// - B receives in two-wallet flows.
/// - T is the treasury that tops A up; it is funded from the testnet faucet.
///
/// Sets keep runners apart on storage: `ci` (the CircleCI job), `sandbox` (cloud sessions),
/// `mac` (the Mac Studio). The set is `ONESAT_QA_SET`.
///
/// The root is `ONESAT_QA_ROOT`, 32 bytes as 64 hex characters, read from the environment only. It
/// is never printed, logged or written anywhere, and neither is any key derived from it; only
/// identity keys and addresses are printed. A local run never reads it: the local stack is a
/// throwaway database, so it uses the fixed public root below.
enum QAWallets {
    /// A: inscribe, send and lifecycle. B: send's counterparty. T: the treasury that tops the
    /// others up. S: the swap round trip alone, so the funding BEEF a swap sends the exchange
    /// carries only S's own unconfirmed ancestry, never A's ~180 KB inscriptions (an unconfirmed
    /// chain of them made the BEEF about 800 KB, and the exchange's validator ran out of fuel).
    enum Role: String, CaseIterable, Sendable {
        case A, B, T, S
    }

    enum WalletSet: String, CaseIterable, Sendable {
        case ci, sandbox, mac
    }

    static let rootKey = "ONESAT_QA_ROOT"
    static let setKey = "ONESAT_QA_SET"

    /// The local stack's root: public, since local storage holds nothing of value.
    static let localRoot = BSVHashing.sha256(Array("onesat-live-tests/local-stack-root".utf8)).bytes

    /// `HMAC-SHA256(key: root, message: "<set>/<role>")` as a private key.
    static func key(root: [UInt8], set: WalletSet, role: Role) throws -> PrivateKey {
        let label = Array("\(set.rawValue)/\(role.rawValue)".utf8)
        return try PrivateKey(BSVHashing.hmacSHA256(label, key: root).bytes)
    }

    /// The root and set for `backend`, from the environment for testnet.
    static func configuration(
        for backend: Backend,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (root: [UInt8], set: WalletSet) {
        let setText = environment[setKey] ?? (backend.kind == .local ? WalletSet.sandbox.rawValue : "")
        guard let set = WalletSet(rawValue: setText) else {
            throw LiveSetupError(
                "\(setKey) must be one of \(WalletSet.allCases.map(\.rawValue).joined(separator: ", "))"
                    + (setText.isEmpty ? " (it is unset)" : " (it is set to something else)"))
        }
        switch backend.kind {
        case .local:
            return (localRoot, set)
        case .testnet:
            guard let text = environment[rootKey], !text.isEmpty else {
                throw LiveSetupError("\(rootKey) is not set; a testnet run needs the QA root secret (32 bytes as hex) in the environment.")
            }
            // The message names the problem, never the value.
            guard text.utf8.count == 64,
                  let bytes = try? Hex.decode(text, maximumDecodedByteCount: 32)
            else {
                throw LiveSetupError("\(rootKey) is not 32 bytes as 64 hex characters (\(text.utf8.count) characters given).")
            }
            return (bytes, set)
        }
    }
}

/// One wallet connected the way the app connects (`WalletCache.connect`): a BRC-104 storage client
/// as the identity, a `RemoteWallet` over it, and the 1Sat context the app's action services build
/// (`PassActionsService.makeContext`).
struct LiveWallet: Sendable {
    let name: String
    let key: PrivateKey
    let backend: Backend
    let storage: StorageClient
    let auth: AuthID
    let wallet: RemoteWallet
    /// Where `SyncAddresses` keeps this wallet's processed txids and cursor for this process.
    let processed: FileProcessedTxStore

    var identityHex: String { Hex.encode(key.publicKey.compressedBytes) }

    /// Deposit address 0, the address the app shows on Receive.
    func receiveAddress() throws -> String {
        try wallet.receiveAddress(index: 0, network: backend.chain.network)
    }

    var context: OneSatContext {
        OneSatContext(identity: key, storage: storage, auth: auth, chain: backend.chain)
    }

    /// Connects `key` to the backend's storage. A second call with the same key is a second,
    /// independent client: the restore case.
    static func connect(name: String, key: PrivateKey, backend: Backend) async throws -> LiveWallet {
        let storage = try RemoteStorage.client(
            at: backend.storage,
            wallet: ProtoWallet(rootKey: key),
            allowInsecureTransport: backend.allowsInsecureTransport
        )
        let identityHex = Hex.encode(key.publicKey.compressedBytes)
        let auth = AuthID(identityKey: identityHex)
        let wallet = RemoteWallet(storage: storage, identityKey: key, auth: auth)
        let settings = try await wallet.connect()
        guard settings.chain.rawValue == backend.chain.rawValue else {
            throw LiveSetupError("storage for \(name) serves \(settings.chain.rawValue), expected \(backend.chain.rawValue)")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("onesat-live-\(ProcessInfo.processInfo.processIdentifier)")
            .appendingPathComponent("sync-\(backend.kind.rawValue)-\(identityHex.prefix(16))-\(UUID().uuidString).json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        return LiveWallet(
            name: name,
            key: key,
            backend: backend,
            storage: storage,
            auth: auth,
            wallet: wallet,
            processed: FileProcessedTxStore(fileURL: file)
        )
    }

    /// A wallet on a new random key: the "create wallet" case, and a throwaway for flows that
    /// must not touch the QA wallets.
    static func fresh(name: String, backend: Backend) async throws -> LiveWallet {
        var rng = SystemRandomNumberGenerator()
        while true {
            var bytes = [UInt8](repeating: 0, count: 32)
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            // A value outside the curve order is refused; draw again.
            guard let key = try? PrivateKey(bytes) else { continue }
            return try await connect(name: name, key: key, backend: backend)
        }
    }

    func balance() async throws -> Int64 {
        try await wallet.balance()
    }

    /// Prints what may be written down: the role, identity key and receive address.
    func describe() throws {
        print("WALLET \(name): identity \(identityHex) address \(try receiveAddress())")
    }
}

extension RemoteWallet: ActionInternalizer {}

/// The suite's QA wallets for this run, connected once per process.
actor QASuite {
    static let shared = QASuite()

    private var wallets: [QAWallets.Role: LiveWallet] = [:]

    func wallet(_ role: QAWallets.Role, backend: Backend) async throws -> LiveWallet {
        if let wallet = wallets[role] { return wallet }
        let (root, set) = try QAWallets.configuration(for: backend)
        let key = try QAWallets.key(root: root, set: set, role: role)
        let wallet = try await LiveWallet.connect(name: "\(set.rawValue)/\(role.rawValue)", key: key, backend: backend)
        try wallet.describe()
        // Each process starts with an empty processed-tx store, so the first sync would sweep
        // anything an earlier run left unswept. Do it now, before any test reads a baseline.
        let swept = try await Funding.sync(wallet)
        print("SYNCED \(wallet.name) on connect: processed \(swept.processed), failed \(swept.failed)")
        wallets[role] = wallet
        return wallet
    }
}
