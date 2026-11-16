import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sees the process's URL loading requests and refuses any to a host outside the backend's
/// allowlist (storage and the 1Sat API), so a flow that strays to another host, mainnet or new,
/// fails instead of spending or reading there.
///
/// Registered with `URLProtocol.registerClass`. It answers `canInit` for every request (that is
/// where it records the host) and takes over only a refused one; every other request goes on to
/// the system's own protocol.
///
/// Reach: a registered protocol is consulted by `URLSession.shared` only. A session built from its
/// own configuration (swift-sdk's BSVNetwork transports, `OneSatAMM.OpenExchange`) does not see
/// it, so the guard covers what the flows call through `.shared` (the toolbox storage client and
/// the SDK's 1Sat API clients) and the preflight, which names it in its configuration. Teardown
/// checks that storage was seen and that every host seen is on the allowlist.
final class HostGuard: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String: Int] = [:]
    nonisolated(unsafe) private static var refused: [String] = []
    nonisolated(unsafe) private static var allowed: Set<String>?
    nonisolated(unsafe) private static var installed = false

    /// Installs the guard once. Requests to any host outside `allowedHosts` are refused.
    static func install(allowedHosts: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        Self.allowed = Set(allowedHosts.map { $0.lowercased() })
        guard !installed else { return }
        installed = true
        let registered = URLProtocol.registerClass(HostGuard.self)
        precondition(registered, "URLProtocol refused to register HostGuard")
    }

    /// Hosts seen so far, with how many requests each.
    static var hostsSeen: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    /// URLs outside the allowlist a request was made to (and refused).
    static var refusedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return refused
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url, let host = url.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        // canInit can be asked more than once for one request; a count is still a count of asks.
        seen[host.lowercased(), default: 0] += 1
        guard let allowed, !allowed.contains(host.lowercased()) else { return false }
        refused.append(url.absoluteString)
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? "?"
        client?.urlProtocol(
            self,
            didFailWithError: URLError(
                .cannotConnectToHost,
                userInfo: [NSLocalizedDescriptionKey: "HostGuard refused a host outside the live suite's allowlist: \(host)"]
            )
        )
    }

    override func stopLoading() {}
}
