import BSVCore
import BSVKeys
import BSVWallet
import Foundation
import OneSatActions
import OneSatSweep
import ToolboxAuth
import ToolboxStorageClient
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Where the live suite runs, chosen by `ONESAT_LIVE`.
///
/// - `local`: Tools/local-stack on this machine (`scripts/local-stack.sh start`), at
///   `ONESAT_LOCAL_URL` (default `http://127.0.0.1:18199`). Real TS storage server, stub chain;
///   the stack also serves the 1sat-stack reads the SDK makes, so one URL is both.
/// - `testnet`: the hosted testnet servers the app uses (`ChainEndpoints.for(.test)`): storage at
///   `https://testnet.wallet.1sat.app`, the 1Sat API at `OneSatAPI.testnetURL`, and Open Exchange
///   (the swap app and the 1Color overlay) at `https://testnet.openex.dev`. Broadcast is real,
///   done by storage as for any app send.
///
/// Unset, every live test skips.
struct Backend: Sendable {
    enum Kind: String, Sendable {
        case local
        case testnet
    }

    let kind: Kind
    let chain: OneSatChain
    /// Wallet storage (BRC-104 JSON-RPC).
    let storage: URL
    /// The 1sat-stack API base: owner sync, BEEF, chain tip.
    let services: URL
    /// Open Exchange: the swap app and the chain's 1Color overlay (`ChainEndpoints.colorOverlay`),
    /// one origin. Nil on the local stack, which serves no exchange.
    let exchange: URL?

    var allowsInsecureTransport: Bool { kind == .local }

    static let environmentKey = "ONESAT_LIVE"
    static let localURLKey = "ONESAT_LOCAL_URL"
    static let defaultLocalURL = URL(string: "http://127.0.0.1:18199")!
    static let testnetStorage = URL(string: "https://testnet.wallet.1sat.app")!
    static let testnetExchange = URL(string: "https://testnet.openex.dev")!

    /// The backend `ONESAT_LIVE` names. Skips the test when it is unset; an unknown value fails.
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Backend {
        guard let raw = environment[environmentKey], !raw.isEmpty else {
            throw XCTSkip("\(environmentKey) is not set; the live suite runs only with ONESAT_LIVE=local or ONESAT_LIVE=testnet.")
        }
        switch Kind(rawValue: raw) {
        case .local:
            let url: URL
            if let text = environment[localURLKey], !text.isEmpty {
                guard let parsed = URL(string: text), parsed.scheme != nil, parsed.host != nil else {
                    throw LiveSetupError("\(localURLKey)=\(text) is not a URL")
                }
                url = parsed
            } else {
                url = defaultLocalURL
            }
            return Backend(kind: .local, chain: .test, storage: url, services: url, exchange: nil)
        case .testnet:
            return Backend(
                kind: .testnet,
                chain: .test,
                storage: testnetStorage,
                services: OneSatAPI.baseURL(for: .testnet),
                exchange: testnetExchange
            )
        case nil:
            throw LiveSetupError("\(environmentKey)=\(raw) is not a backend; use local or testnet.")
        }
    }

    /// The only hosts a run may contact: storage, the 1Sat API and, on testnet, Open Exchange.
    var allowedHosts: Set<String> {
        Set([storage.host, services.host, exchange?.host].compactMap { $0?.lowercased() })
    }
}

/// A session the host guard is named on, so it sees (and can refuse) this session's requests on
/// every platform, with a per-request and a whole-resource timeout. `fresh` also skips the URL
/// cache, as `OpenExchange.freshTransport` does.
func guardedSession(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, fresh: Bool = false) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    if fresh {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
    }
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    // A configured session does not consult registered protocols on every platform; name the
    // guard so its requests are seen and checked too.
    configuration.protocolClasses = [HostGuard.self] + (configuration.protocolClasses ?? [])
    return URLSession(configuration: configuration)
}

/// A setup failure the suite reports as a failed test with this text, never a skip.
struct LiveSetupError: Error, CustomStringConvertible, LocalizedError {
    let description: String
    init(_ description: String) { self.description = description }
    var errorDescription: String? { description }
}

/// Checks, once per process, that the backend is there and speaks what the suite needs, so a
/// down server fails every test at once with one clear message instead of timing out in each.
///
/// Storage: a BRC-104 `makeAvailable` from a throwaway identity, asking for binary requests with
/// `X-BSV-Binary-Encoding: base64`. It must answer 200, signed, on the backend's chain, and echo
/// the header, without which large inscriptions hit the auth middleware's 100,000-value cap.
/// The 1Sat API: `GET /1sat/chaintracks/tip` must answer a height. Local also: `/__stack/health`.
/// Nothing is written: `makeAvailable` reads the store's settings only.
actor Preflight {
    static let shared = Preflight()

    private var outcome: Result<Report, LiveSetupError>?

    struct Report: Sendable {
        let storageIdentityKey: String
        let chain: String
        let tipHeight: UInt32
    }

    func check(_ backend: Backend) async throws -> Report {
        if let outcome { return try outcome.get() }
        let result: Result<Report, LiveSetupError>
        do {
            result = .success(try await Self.run(backend))
        } catch let error as LiveSetupError {
            result = .failure(error)
        } catch {
            result = .failure(LiveSetupError("preflight failed: \(String(describing: error))"))
        }
        outcome = result
        if case .success(let report) = result {
            print("PREFLIGHT ok: \(backend.kind.rawValue) storage \(backend.storage.absoluteString) "
                + "(\(report.chain), storage key \(report.storageIdentityKey)), "
                + "1Sat API \(backend.services.absoluteString) tip \(report.tipHeight)")
        }
        return try result.get()
    }

    static let timeout: TimeInterval = 20

    static func session() -> URLSession {
        guardedSession(requestTimeout: timeout, resourceTimeout: timeout * 2)
    }

    private static func run(_ backend: Backend) async throws -> Report {
        let session = session()
        if backend.kind == .local {
            let health = backend.services.appendingPathComponent("__stack").appendingPathComponent("health")
            let (status, body) = try await get(health, session: session, what: "local stack health")
            guard status == 200 else {
                throw LiveSetupError("local stack health \(health.absoluteString) answered HTTP \(status): \(String(decoding: body, as: UTF8.self))")
            }
        }

        // Storage.
        var keyBytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in keyBytes.indices { keyBytes[i] = UInt8.random(in: 0...255, using: &rng) }
        let probeKey = try PrivateKey(keyBytes)
        let transport = AuthenticatedSession(
            baseURL: backend.storage,
            wallet: ProtoWallet(rootKey: probeKey),
            transport: URLSessionHTTPTransport(session: session)
        )
        let identityHex = Hex.encode(probeKey.publicKey.compressedBytes)
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "makeAvailable",
            "params": [["identityKey": identityHex]],
            "id": 1,
        ]
        let body = try JSONSerialization.data(withJSONObject: request)
        let response: AuthenticatedResponse
        do {
            response = try await transport.send(
                method: "POST",
                path: backend.storage.path.isEmpty ? "/" : backend.storage.path,
                query: nil,
                headers: ["Content-Type": "application/json", "X-BSV-Binary-Encoding": "base64"],
                body: Array(body)
            )
        } catch {
            throw LiveSetupError(
                "storage \(backend.storage.absoluteString) is unreachable or refused the BRC-104 handshake "
                    + "(ONESAT_LIVE=\(backend.kind.rawValue)): \(String(describing: error)). "
                    + (backend.kind == .local
                        ? "Start it with scripts/local-stack.sh start."
                        : "Check this machine can reach \(backend.storage.host ?? "")."))
        }
        let text = String(decoding: response.body, as: UTF8.self)
        guard response.statusCode == 200 else {
            throw LiveSetupError("storage makeAvailable answered HTTP \(response.statusCode): \(text)")
        }
        let echoed = response.headers.first { $0.key.lowercased() == "x-bsv-binary-encoding" }?.value
        guard echoed == "base64" else {
            throw LiveSetupError(
                "storage \(backend.storage.absoluteString) did not echo X-BSV-Binary-Encoding: base64 "
                    + "(got \(echoed ?? "no header")). Without it the client sends bytes as JSON arrays and any "
                    + "transaction over ~100 KB is refused by the auth middleware. Server version item.")
        }
        guard let envelope = try JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any],
              let result = envelope["result"] as? [String: Any],
              let chain = result["chain"] as? String,
              let storageKey = result["storageIdentityKey"] as? String
        else {
            throw LiveSetupError("storage makeAvailable answered an unreadable body: \(text)")
        }
        guard chain == backend.chain.rawValue else {
            throw LiveSetupError("storage \(backend.storage.absoluteString) serves chain \(chain), the suite expects \(backend.chain.rawValue)")
        }

        // The 1Sat API.
        let tipURL = backend.services
            .appendingPathComponent("1sat").appendingPathComponent("chaintracks").appendingPathComponent("tip")
        let (status, tipBody) = try await get(tipURL, session: session, what: "1Sat API chain tip")
        guard status == 200,
              let tip = try? JSONSerialization.jsonObject(with: Data(tipBody)) as? [String: Any],
              let height = (tip["height"] as? NSNumber)?.uint32Value
        else {
            throw LiveSetupError("1Sat API \(tipURL.absoluteString) answered HTTP \(status): \(String(decoding: tipBody, as: UTF8.self))")
        }
        return Report(storageIdentityKey: storageKey, chain: chain, tipHeight: height)
    }

    private static func get(_ url: URL, session: URLSession, what: String) async throws -> (Int, [UInt8]) {
        do {
            let (data, response) = try await session.data(from: url)
            return ((response as? HTTPURLResponse)?.statusCode ?? -1, Array(data))
        } catch {
            throw LiveSetupError("\(what) \(url.absoluteString) is unreachable: \(String(describing: error))")
        }
    }
}
