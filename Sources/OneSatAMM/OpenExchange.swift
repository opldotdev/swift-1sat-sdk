import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BSVKeys
import BSVWallet
import ToolboxAuth
import OneSatSweep

/// An Open Exchange host as `createClient({origin})` of `@dcasegr/amm-client` 0.55.1 (skein-amm
/// cc146be) sees it: the swap app's base and the reads a listing needs. Every GET goes through
/// `http` (the TS client's `fetch`); the signed POST through a BRC-104 session per instance.
public struct OpenExchange: Sendable {
    /// A BRC-104 session to one instance (`<origin>` or `<origin>/@<handle>`), authenticated as
    /// `identity`: `authFetchPerInstance` (lib/skein.ts:65).
    public typealias SignedSession = @Sendable (_ identity: PrivateKey, _ instanceBase: URL) -> any AuthenticatedTransport

    /// The swap app's base (`exchangeBase`): `<origin>/amm` for an origin alone.
    public let base: String
    let http: any HTTPTransport
    let session: SignedSession

    /// GETs that skip the URL cache, as the client's `freshFetch` (client.ts:1313) asks.
    public static let freshTransport: any HTTPTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSessionHTTPTransport(session: URLSession(configuration: configuration))
    }()

    /// - Parameters:
    ///   - origin: the exchange, an origin alone (`https://testnet.openex.dev`) or an app base.
    ///   - http: every GET, and the default session's wire.
    ///   - session: the signed POST's session; by default an `AuthenticatedSession` as `identity`
    ///     over `http`, its handshake at the instance's own `/.well-known/auth`.
    public init(origin: String, http: any HTTPTransport = OpenExchange.freshTransport, session: SignedSession? = nil) throws {
        self.base = try OpenExchangeURLs.exchangeBase(origin)
        self.http = http
        self.session = session ?? { identity, instance in
            AuthenticatedSession(
                baseURL: URL(string: (try? WebURL(instance.absoluteString).origin) ?? instance.absoluteString) ?? instance,
                wallet: ProtoWallet(rootKey: identity),
                transport: InstanceTransport(instance: instance, inner: http)
            )
        }
    }

    /// `tokenBase` (lib/config.ts:66): `<origin>/@<tokenId>/amm`.
    public func tokenBase(_ tokenId: String) throws -> String {
        try OpenExchangeURLs.tokenBase(tokenId, from: base)
    }

    /// `discoveryBase` (client.ts:1823): `<origin>/@discovery/1color`.
    public func discoveryBase() throws -> String {
        try OpenExchangeURLs.discoveryBase(from: base)
    }

    // MARK: - Reads

    /// `defaults` (client.ts:1865), `readDefaults` (lib/skein.ts:199): `GET <swap>/defaults`.
    public func defaults() async throws -> OpenExchangeDefaults {
        do {
            return OpenExchangeDefaults.read(try await getJSON("\(base)/defaults"))
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `enabledList` (client.ts:783), `readTokens` (lib/skein.ts:142): the swap instance's token
    /// list, `GET <swap>/tokens`, every status, each token id written `<txid>_<vout>`.
    public func tokens() async throws -> [OpenExchangeToken] {
        do {
            let url = "\(base)/tokens"
            let rows = try await getJSON(url)?.array ?? []
            return rows.compactMap { OpenExchangeToken.read($0, listURL: url)?.canonical() }
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `enabledTokens` (client.ts:800): the tokens enabled on this exchange.
    public func enabledTokens() async throws -> [OpenExchangeToken] {
        try await tokens().filter { $0.status == .enabled }
    }

    /// `swapIdentity` (client.ts:906) by `claimStatus` (client.ts:882): the swap instance's
    /// identity key, lowercase hex, from `GET <instance>/.well-known/skein`.
    public func exchangeIdentity() async throws -> String {
        do {
            let url = "\(OpenExchangeURLs.instanceBase(base))/.well-known/skein"
            let response = try await get(url, accept: "application/json")
            guard (200..<300).contains(response.statusCode) else {
                Self.logHTTP("exchangeIdentity", url: url, status: response.statusCode, body: response.body)
                throw OpenExchangeError.failed("GET \(url): \(response.statusCode)")
            }
            let identity = (JSONValue.parse(response.body)?["identity"]?.text ?? "").lowercased()
            guard Self.isIdentityKey(identity) else {
                Self.logHTTP("exchangeIdentity: no identity", url: url, status: response.statusCode, body: response.body)
                throw OpenExchangeError.failed("GET \(url): no identity")
            }
            return identity
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    /// `readDiscoveryDeploy` (lib/overlay.ts:486): a token's deploy BEEF from discovery,
    /// `GET <discovery>/<tokenId>/deploy`; nil when discovery has none (404).
    public func discoveryDeployBeef(_ tokenId: String) async throws -> [UInt8]? {
        do {
            let url = "\(OpenExchangeURLs.trimTrailingSlashes(try discoveryBase()))/\(Self.uriComponent(tokenId))/deploy"
            let response = try await get(url, accept: "application/octet-stream")
            if response.statusCode == 404 { return nil }
            guard (200..<300).contains(response.statusCode) else {
                Self.logHTTP("discoveryDeployBeef", url: url, status: response.statusCode, body: response.body)
                throw OpenExchangeError.failed("GET \(url): \(response.statusCode) \(Self.preview(response.body))")
            }
            return response.body
        } catch {
            throw OpenExchangeError.of(error)
        }
    }

    // MARK: - HTTP

    func get(_ url: String, accept: String?) async throws -> HTTPResponse {
        guard let target = URL(string: url) else { throw OpenExchangeError.failed("Invalid URL: \(url)") }
        return try await http.send(HTTPRequest(method: "GET", url: target, headers: accept.map { ["accept": $0] } ?? [:]))
    }

    /// `getJson` (lib/skein.ts:105).
    func getJSON(_ url: String) async throws -> JSONValue? {
        let response = try await get(url, accept: "application/json")
        guard (200..<300).contains(response.statusCode) else {
            Self.logHTTP("getJSON", url: url, status: response.statusCode, body: response.body)
            throw OpenExchangeError.failed("GET \(url): \(response.statusCode) \(Self.preview(response.body))")
        }
        guard let value = JSONValue.parse(response.body) else {
            Self.logHTTP("getJSON: the answer is not JSON", url: url, status: response.statusCode, body: response.body)
            throw OpenExchangeError.failed("GET \(url): the answer is not JSON")
        }
        return value
    }

    /// Logs a failed or unusable Open Exchange answer in full: host and path (never the query,
    /// which can carry a payment's derivation), status and body.
    static func logHTTP(_ operation: String, method: String = "GET", url: String, status: Int, body: [UInt8]) {
        guard let target = URL(string: url) else {
            OneSatLog.error("OpenExchange.\(operation): HTTP \(status) from an unparseable URL", category: logCategory)
            return
        }
        OneSatHTTPFailure(
            service: "Open Exchange", operation: "OpenExchange.\(operation)", method: method, url: target,
            statusCode: status, body: body
        ).log(category: logCategory)
    }

    static let logCategory = "OneSatAMM"

    /// `(await res.text()).slice(0, 200)`.
    static func preview(_ body: [UInt8]) -> String {
        String(String(decoding: body, as: UTF8.self).prefix(200))
    }

    /// `/^0[23][0-9a-f]{64}$/`.
    static func isIdentityKey(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 66 && bytes[0] == UInt8(ascii: "0")
            && (bytes[1] == UInt8(ascii: "2") || bytes[1] == UInt8(ascii: "3"))
            && bytes[2...].allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// `encodeURIComponent`: everything but `A-Z a-z 0-9 - _ . ! ~ * ' ( )` percent-encoded.
    static func uriComponent(_ text: String) -> String {
        percentEncode(text, keeping: Array("-_.!~*'()".utf8), spaceAsPlus: false)
    }

    /// `URLSearchParams.toString()` of one value (application/x-www-form-urlencoded): everything
    /// but `A-Z a-z 0-9 * - . _` percent-encoded, a space as `+`.
    static func formComponent(_ text: String) -> String {
        percentEncode(text, keeping: Array("*-._".utf8), spaceAsPlus: true)
    }

    private static func percentEncode(_ text: String, keeping kept: [UInt8], spaceAsPlus: Bool) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in text.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a: out.append(byte)
            case 0x20 where spaceAsPlus: out.append(UInt8(ascii: "+"))
            case _ where kept.contains(byte): out.append(byte)
            default: out += [UInt8(ascii: "%"), digits[Int(byte >> 4)], digits[Int(byte & 0x0f)]]
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// `instanceFetch` (lib/skein.ts:42): a BRC-104 session keeps its handshake at the origin's
/// `/.well-known/auth`, but an instance under a path prefix (`<origin>/@<handle>`) takes it at
/// `<prefix>/.well-known/auth`. Every other request goes as it is.
struct InstanceTransport: HTTPTransport {
    let prefix: String
    let origin: String
    let inner: any HTTPTransport

    init(instance: URL, inner: any HTTPTransport) {
        let url = try? WebURL(instance.absoluteString)
        self.prefix = OpenExchangeURLs.trimTrailingSlashes(url?.pathname ?? "")
        self.origin = url?.origin ?? ""
        self.inner = inner
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !prefix.isEmpty, let url = try? WebURL(request.url.absoluteString), url.origin == origin,
              url.pathname == "/.well-known/auth",
              var parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
            return try await inner.send(request)
        }
        parts.percentEncodedPath = "\(prefix)/.well-known/auth"
        guard let rewritten = parts.url else { return try await inner.send(request) }
        return try await inner.send(HTTPRequest(method: request.method, url: rewritten, headers: request.headers, body: request.body))
    }
}
