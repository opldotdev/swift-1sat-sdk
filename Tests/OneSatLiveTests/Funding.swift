import BSVCore
import BSVTransaction
import BSVWallet
import Foundation
import OneSatActions
import OneSatClient
import ToolboxServices
import ToolboxWallet
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Money in and out of the live wallets, through the paths the app uses.
///
/// Paying an address is `RemoteWallet.pay(to:satoshis:description:)` (the app's `SendService`).
/// Receiving at an address is `SyncAddresses.execute` against the 1Sat API with the SDK's own
/// clients (the app's `DepositSyncService`), which internalizes the deposit and sweeps it into
/// the wallet's balance.
///
/// Topping up (testnet and local alike): when A is below `floor`, T pays A up to twice the floor.
/// When T cannot cover that, a local run pays T from the stack's faucet; a testnet run fails and
/// names T's address to fund at https://faucet.bananablocks.com.
///
/// The faucet is not called. Its own page script (`/faucet.js`) claims with
/// `POST /api/v1/claim { address, turnstileToken, ... }`, and `/api/v1/config` answers
/// `turnstileBypassAllowed: false`: every claim needs a Cloudflare Turnstile CAPTCHA a person
/// solves, one claim per IP and per address a day. Funding T is a manual step at the page.
/// TODO(faucet): automate only if the faucet gains a CAPTCHA-free path for this suite.
enum Funding {
    /// A's floor, from the test strategy: below this, T tops A up.
    static let floor: Int64 = 200_000
    /// What the local faucet gives T when T runs low.
    static let localTreasuryGrant: UInt64 = 5_000_000
    /// How long a testnet deposit may take to show in owner sync.
    static let depositTimeout: TimeInterval = 180

    // MARK: Paying

    /// Pays `satoshis` to `address` from `wallet`, as the app's Send does. Returns the txid.
    static func pay(
        from wallet: LiveWallet,
        to address: String,
        satoshis: UInt64,
        description: String
    ) async throws -> String {
        let sent = try await wallet.wallet.pay(to: address, satoshis: satoshis, description: description)
        let txid = sent.transactionID.displayHex
        print("PAY \(wallet.name) -> \(address) \(satoshis) sats: \(txid)")
        return txid
    }

    // MARK: Receiving

    /// One `SyncAddresses` run for `wallet` against the backend's 1Sat API.
    static func sync(_ wallet: LiveWallet) async throws -> SyncAddresses.Result {
        let base = wallet.backend.services
        let context = OneSatContext(
            identity: wallet.key,
            storage: wallet.storage,
            auth: wallet.auth,
            chain: wallet.backend.chain,
            services: OneSatStackServices(baseURL: base)
        )
        return try await SyncAddresses.execute(
            context,
            internalizer: wallet.wallet,
            beef: StackBeefSource(baseURL: base),
            syncSource: OwnerSyncClient(baseURL: base),
            assets: OneSatDepositAssets(baseURL: base),
            store: wallet.processed,
            request: SyncAddresses.Request(startIndex: 0, count: 5)
        )
    }

    /// Syncs `wallet` until `txid` has been internalized and swept, or fails at the deadline with
    /// what the last sync said. A failed internalize is not final: owner sync can list an outpoint
    /// before the BEEF is served or storage accepts it, and `SyncAddresses` retries a failed txid on
    /// the next pass.
    static func receive(_ wallet: LiveWallet, txid: String) async throws {
        let deadline = Date().addingTimeInterval(wallet.backend.kind == .local ? 10 : depositTimeout)
        var last: SyncAddresses.Result?
        var lastFailure: String?
        while true {
            let result: SyncAddresses.Result
            do {
                result = try await sync(wallet)
            } catch {
                // One failed pass (chain tip, owner sync, storage) is not the end of the wait.
                lastFailure = "sync failed: \(String(describing: error))"
                print("RETRY \(wallet.name) sync failed while waiting for \(txid): \(error)")
                guard Date() < deadline else { break }
                try await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            last = result
            if let failure = result.failures.first(where: { $0.txid == txid }) {
                lastFailure = "internalize: \(failure.message)"
                print("RETRY \(wallet.name) could not internalize \(txid) yet: \(failure.message)")
            }
            if try await wallet.processed.has(txid) {
                if let sweepError = result.sweepError {
                    throw LiveSetupError("\(wallet.name) internalized \(txid) but the deposit sweep failed: \(sweepError)")
                }
                print("RECEIVED \(wallet.name) \(txid) (processed \(result.processed), failed \(result.failed))")
                return
            }
            guard Date() < deadline else { break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw LiveSetupError(
            "\(wallet.name) never saw \(txid) at \(try wallet.receiveAddress()) through owner sync at "
                + "\(wallet.backend.services.absoluteString)"
                + (lastFailure.map { "; last failure: \($0)" } ?? "")
                + "; last sync: \(String(describing: last))")
    }

    // MARK: Topping up

    /// Makes sure A holds at least `floor`, paying from T. Returns A's balance afterwards.
    ///
    /// A sync runs first, so a deposit an earlier top-up left unswept counts before any new
    /// payment. T tops A up at most once per process (`TopUpBudget`): a second attempt in the same
    /// run fails rather than paying again.
    @discardableResult
    static func ensureFunded(_ a: LiveWallet, treasury t: LiveWallet) async throws -> Int64 {
        _ = try await sync(a)
        let balanceA = try await a.balance()
        print("BALANCE \(a.name) \(balanceA)")
        guard balanceA < floor else { return balanceA }
        let topUp = UInt64(2 * floor - balanceA)
        var balanceT = try await t.balance()
        print("BALANCE \(t.name) \(balanceT)")
        if balanceT < Int64(topUp) + 10_000 {
            switch t.backend.kind {
            case .local:
                let txid = try await localFaucet(t.backend, address: try t.receiveAddress(), satoshis: localTreasuryGrant)
                try await receive(t, txid: txid)
                balanceT = try await t.balance()
            case .testnet:
                throw LiveSetupError(
                    "treasury \(t.name) holds \(balanceT) sats, not enough to top \(a.name) up by \(topUp). "
                        + "Fund \(try t.receiveAddress()) at https://faucet.bananablocks.com (a CAPTCHA page, one claim per address a day) and run again.")
            }
        }
        try await TopUpBudget.shared.spend(topUp, to: a.name)
        let txid = try await pay(from: t, to: try a.receiveAddress(), satoshis: topUp, description: "QA top-up")
        try await receive(a, txid: txid)
        let after = try await a.balance()
        print("TOPPED UP \(a.name) from \(balanceA) to \(after) (\(txid))")
        return after
    }

    /// Pays `satoshis` to `address` from the local stack's faucet; a made-up proven transaction.
    static func localFaucet(_ backend: Backend, address: String, satoshis: UInt64) async throws -> String {
        precondition(backend.kind == .local, "the faucet endpoint exists only on the local stack")
        var request = URLRequest(url: backend.services.appendingPathComponent("__stack").appendingPathComponent("faucet"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["address": address, "satoshis": satoshis])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let txid = body["txid"] as? String
        else {
            throw LiveSetupError("local faucet answered HTTP \(status): \(String(decoding: data, as: UTF8.self))")
        }
        print("FAUCET \(satoshis) sats -> \(address): \(txid)")
        return txid
    }
}

/// What T may pay A in one process: one top-up, at most `2 × Funding.floor`.
actor TopUpBudget {
    static let shared = TopUpBudget()
    static let maximumTopUps = 1
    static let maximumSatoshis = UInt64(2 * Funding.floor)

    private var topUps = 0
    private var satoshis: UInt64 = 0

    func spend(_ amount: UInt64, to name: String) throws {
        guard topUps < Self.maximumTopUps, satoshis + amount <= Self.maximumSatoshis else {
            throw LiveSetupError(
                "\(name) needs another top-up of \(amount) sats after \(topUps) this run (\(satoshis) sats); "
                    + "the run allows \(Self.maximumTopUps) of at most \(Self.maximumSatoshis). An earlier top-up "
                    + "may not have arrived; see its RECEIVED or RETRY lines.")
        }
        topUps += 1
        satoshis += amount
    }
}

/// `GET {base}/1sat/beef/:txid` (`@1sat/client` `BeefClient.getBeef`), as the app's
/// `OneSatBeefSource` reads it.
struct StackBeefSource: ListingBeefSource {
    let baseURL: URL

    func beef(forTxid txid: String) async throws -> [UInt8] {
        let url = baseURL.appendingPathComponent("1sat").appendingPathComponent("beef").appendingPathComponent(txid)
        let (data, response) = try await URLSession.shared.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw LiveSetupError("GET \(url.absoluteString) answered HTTP \(status): \(String(decoding: data.prefix(500), as: UTF8.self))")
        }
        return Array(data)
    }
}
