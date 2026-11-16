import Foundation

/// The URLs of an Open Exchange host, as `@dcasegr/amm-client` 0.55.1 (skein-amm cc146be) builds
/// them from an origin.
public enum OpenExchangeURLs {
    /// `ROOT_APP` (lib/config.ts:34): the app the pages are at the origin's root.
    public static let rootApp = "amm"

    /// `exchangeBase` (lib/config.ts:55): an origin alone is the swap app at `<origin>/amm`; a URL
    /// with a path is the base as given. No trailing slash.
    public static func exchangeBase(_ origin: String) throws -> String {
        let url = try WebURL(origin)
        let path = trimTrailingSlashes(url.pathname)
        return path.isEmpty ? "\(url.origin)/\(rootApp)" : url.origin + path
    }

    /// `tokenBase` (lib/config.ts:66): a token instance's AMM base, `<origin>/@<tokenId>/amm` on
    /// the origin of `base`. The token id is written as given.
    public static func tokenBase(_ tokenId: String, from base: String) throws -> String {
        "\(try WebURL(base).origin)/@\(tokenId)/\(rootApp)"
    }

    /// `discoveryBase` (client.ts:1823): the discovery instance's 1Color app,
    /// `<origin>/@discovery/1color`.
    public static func discoveryBase(from base: String) throws -> String {
        "\(try WebURL(base).origin)/@discovery/1color"
    }

    /// `appName` (lib/config.ts:37): the base's last path segment unless it is an `@` handle.
    static func appName(_ base: String) -> String? {
        guard let url = try? WebURL(base) else { return nil }
        guard let last = url.pathname.split(separator: "/").last.map(String.init), !last.hasPrefix("@") else {
            return nil
        }
        return last.removingPercentEncoding ?? last
    }

    /// `instanceBase` (lib/skein.ts:28): the instance under which the app lives, the base without
    /// its app segment (`<origin>/amm` → `<origin>`, `<origin>/@h/amm` → `<origin>/@h`).
    static func instanceBase(_ base: String) -> String {
        guard let name = appName(base) else { return base }
        for suffix in ["/\(name)/", "/\(name)"] where base.hasSuffix(suffix) {
            return String(base.dropLast(suffix.count))
        }
        return base
    }

    static func trimTrailingSlashes(_ text: String) -> String {
        var out = Substring(text)
        while out.hasSuffix("/") { out = out.dropLast() }
        return String(out)
    }
}

/// The two parts of a WHATWG URL the client reads: `origin` (scheme, host, non-default port) and
/// `pathname` (`/` for none).
struct WebURL {
    let origin: String
    let pathname: String

    init(_ text: String) throws {
        guard let parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(),
              let host = parts.percentEncodedHost, !host.isEmpty else {
            throw OpenExchangeError.failed("Invalid URL: \(text)")
        }
        let defaultPort = ["http": 80, "https": 443, "ws": 80, "wss": 443][scheme]
        let port = parts.port.flatMap { $0 == defaultPort ? nil : ":\($0)" } ?? ""
        origin = "\(scheme)://\(host.lowercased())\(port)"
        pathname = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    }
}
