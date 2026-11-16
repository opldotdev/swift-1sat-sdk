import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sees every URL loading request the process makes and, in a testnet run, refuses any to a
/// mainnet host, so a flow that reaches mainnet fails instead of spending or reading there.
///
/// Registered with `URLProtocol.registerClass`. It answers `canInit` for every request (that is
/// where it records the host) and takes over only a refused one; every other request goes on to
/// the system's own protocol. The SDK and toolbox clients use `URLSession.shared`; the guard's own
/// count of requests seen is checked by the flows, so a platform where it is not consulted fails
/// the run rather than passing it silently.
final class HostGuard: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String: Int] = [:]
    nonisolated(unsafe) private static var refused: [String] = []
    nonisolated(unsafe) private static var refuseMainnet = false
    nonisolated(unsafe) private static var installed = false

    /// Installs the guard once. `refuseMainnet` is set for a testnet run.
    static func install(refuseMainnet: Bool) {
        lock.lock()
        defer { lock.unlock() }
        Self.refuseMainnet = refuseMainnet
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

    /// Mainnet URLs a request was made to (and refused).
    static var mainnetRequests: [String] {
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
        guard refuseMainnet, Backend.isMainnetHost(host) else { return false }
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
                userInfo: [NSLocalizedDescriptionKey: "HostGuard refused a mainnet host in a testnet run: \(host)"]
            )
        )
    }

    override func stopLoading() {}
}
