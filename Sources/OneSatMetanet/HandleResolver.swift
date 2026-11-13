import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// BRC-169 handle resolution, ported from `client/src/handles.ts`.
///
///     https://<domain>/manifest.json → metanet.handles {version 1.x, resolve?}
///     <resolve>?handle=<handle>      → HandleResolution
///
/// The resolution is accepted only when its certificate's subject is the identity key it names.
public struct HandleResolver: Sendable {
    public static let defaultResolvePath = "/.well-known/metanet-handles/resolve"

    /// One GET. Returns the status and the body; never throws for a non-2xx status.
    public typealias Fetch = @Sendable (URL) async throws -> (status: Int, body: [UInt8])

    public struct Resolution: Equatable, Sendable {
        public let metanetHandles: String
        public let handle: String
        public let domain: String
        public let identityKey: String
        public let messagebox: String
        public let ttl: Int
        public let revoked: Bool
        public let tag: String?

        public init(
            metanetHandles: String, handle: String, domain: String, identityKey: String,
            messagebox: String, ttl: Int, revoked: Bool, tag: String? = nil
        ) {
            self.metanetHandles = metanetHandles
            self.handle = handle
            self.domain = domain
            self.identityKey = identityKey
            self.messagebox = messagebox
            self.ttl = ttl
            self.revoked = revoked
            self.tag = tag
        }
    }

    public let fetch: Fetch

    public init(fetch: @escaping Fetch = HandleResolver.urlSessionFetch) {
        self.fetch = fetch
    }

    public static let urlSessionFetch: Fetch = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, Array(data))
    }

    /// `@handle[+tag]@domain`, lowercased, with an optional leading `@`. A dotless domain is an
    /// ecosystem alias, which is not a hostname and is refused.
    public static func parse(_ recipient: String) throws -> (handle: String, tag: String?, domain: String) {
        var normalized = recipient.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("@") { normalized.removeFirst() }
        guard let at = normalized.firstIndex(of: "@") else {
            throw MetanetError.handle("handle has no domain: \(recipient)")
        }
        let local = String(normalized[..<at])
        let domain = String(normalized[normalized.index(after: at)...])
        guard domain.contains(".") else {
            throw MetanetError.handle("ecosystem aliases are not supported: \(domain)")
        }
        guard let plus = local.firstIndex(of: "+") else { return (local, nil, domain) }
        return (String(local[..<plus]), String(local[local.index(after: plus)...]), domain)
    }

    public func resolve(_ recipient: String) async throws -> Resolution {
        let (handle, tag, domain) = try Self.parse(recipient)
        guard let manifestURL = URL(string: "https://\(domain)/manifest.json") else {
            throw MetanetError.handle("not a domain: \(domain)")
        }
        let manifest = try await fetch(manifestURL)
        guard (200..<300).contains(manifest.status) else {
            throw MetanetError.handle("manifest fetch failed for \(domain): \(manifest.status)")
        }
        let object = try? JSONSerialization.jsonObject(with: Data(manifest.body)) as? [String: Any]
        guard let handles = (object?["metanet"] as? [String: Any])?["handles"] as? [String: Any] else {
            throw MetanetError.handle("\(domain) does not offer handle resolution")
        }
        let version = handles["version"] as? String
        guard version?.split(separator: ".", omittingEmptySubsequences: false).first == "1" else {
            throw MetanetError.handle(
                "\(domain) metanet.handles version \(version ?? "undefined") is not supported"
            )
        }
        let resolveBase = (handles["resolve"] as? String) ?? "https://\(domain)\(Self.defaultResolvePath)"
        guard var components = URLComponents(string: resolveBase), components.scheme == "https" else {
            throw MetanetError.handle("\(domain) names an unusable resolve endpoint")
        }
        components.percentEncodedQuery = "handle=" + Self.encodeURIComponent(handle)
        guard let resolveURL = components.url else {
            throw MetanetError.handle("\(domain) names an unusable resolve endpoint")
        }
        let answer = try await fetch(resolveURL)
        guard (200..<300).contains(answer.status) else {
            let body = try? JSONSerialization.jsonObject(with: Data(answer.body)) as? [String: Any]
            let code = ((body?["error"] as? [String: Any])?["code"] as? String).map { " \($0)" } ?? ""
            throw MetanetError.handle("resolve \(handle)@\(domain) failed: \(answer.status)\(code)")
        }
        guard let row = try? JSONSerialization.jsonObject(with: Data(answer.body)) as? [String: Any],
              let identityKey = row["identityKey"] as? String,
              let subject = (row["certificate"] as? [String: Any])?["subject"] as? String,
              subject == identityKey else {
            throw MetanetError.handle(
                "certificate subject does not match identity key for \(handle)@\(domain)"
            )
        }
        guard let messagebox = row["messagebox"] as? String else {
            throw MetanetError.handle("resolution for \(handle)@\(domain) names no messagebox")
        }
        return Resolution(
            metanetHandles: row["metanetHandles"] as? String ?? "",
            handle: row["handle"] as? String ?? handle,
            domain: row["domain"] as? String ?? domain,
            identityKey: identityKey,
            messagebox: messagebox,
            ttl: (row["ttl"] as? NSNumber)?.intValue ?? 0,
            revoked: row["revoked"] as? Bool ?? false,
            tag: tag
        )
    }

    /// JavaScript's `encodeURIComponent`.
    static func encodeURIComponent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
