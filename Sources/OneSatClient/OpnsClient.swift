import Foundation
import OneSatSweep

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// One transport for every OpnsClient request, GET and POST alike.
public protocol OneSatHTTPTransport: Sendable {
    func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> (status: Int, body: [UInt8])
}

public struct URLSessionOneSatTransport: OneSatHTTPTransport {
    public init() {}

    public func send(
        method: String,
        url: URL,
        headers: [String: String],
        body: [UInt8]?
    ) async throws -> (status: Int, body: [UInt8]) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let body {
            request.httpBody = Data(body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw Self.urlFree(error)
        } catch {
            // On Linux URLSession throws an `NSError` in the URL domain, which does not cast to
            // `URLError` there; it carries the same full URL.
            guard let foundation = OneSatLog.FoundationError(error), foundation.domain == "NSURLErrorDomain" else {
                throw error
            }
            // `URLError.Code(rawValue:)` is failable in corelibs Foundation and not on Darwin.
            let code: URLError.Code? = URLError.Code(rawValue: foundation.code)
            throw Self.urlFree(URLError(code ?? .unknown, userInfo: foundation.userInfo))
        }
        guard let http = response as? HTTPURLResponse else {
            OneSatClientHTTP.unreadable(
                "URLSessionOneSatTransport.send", method: method, url: url, body: Array(data), why: "not an HTTP response"
            )
            throw OneSatClientError.unreadableResponse
        }
        return (http.statusCode, Array(data))
    }

    /// `error` rebuilt without the failing URL's query string: the same code and description,
    /// the failing URL as scheme, host and path, and the error under it as its domain, code and
    /// description only. Some services take an API key in the query (MNEE's `auth_token`), and
    /// URLSession's error carries the full URL to every caller and log.
    public static func urlFree(_ error: URLError) -> URLError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: OneSatLog.redactingQueries(error.localizedDescription)]
        let original = OneSatLog.FoundationError(error)
        if let failing = original?.failingURL, let bare = OneSatLog.withoutQuery(failing) {
            info[OneSatLog.failingURLKey] = bare
            info[OneSatLog.failingURLStringKey] = bare.absoluteString
        }
        if let underlying = original?.underlying {
            let inner = OneSatLog.FoundationError(underlying)
            info[NSUnderlyingErrorKey] = NSError(
                domain: inner?.domain ?? String(describing: type(of: underlying)), code: inner?.code ?? 0,
                userInfo: [NSLocalizedDescriptionKey: OneSatLog.redactingQueries(underlying.localizedDescription)]
            )
        }
        return URLError(error.code, userInfo: info)
    }
}

public struct OpnsOrigin: Equatable, Sendable, Decodable {
    public let name: String
    public let outpoint: String
}

public struct OpnsMine: Equatable, Sendable, Decodable {
    public let outpoint: String
    public let domain: String
}

public struct OpnsClient: Sendable {
    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `encodeURIComponent` bytes: leave `A-Za-z0-9-_.!~*'()` raw so `/` stays one path segment.
    public static func originURL(name: String, baseURL: URL) -> URL {
        url("\(trimmedBase(baseURL))/1sat/opns/origin/\(encodeURIComponent(name))")
    }

    public static func mineURL(name: String, baseURL: URL) -> URL {
        url("\(trimmedBase(baseURL))/1sat/opns/mine/\(encodeURIComponent(name))")
    }

    public static func originsURL(baseURL: URL) -> URL {
        url("\(trimmedBase(baseURL))/1sat/opns/origins")
    }

    public static func metadataURL(outpoint: String, seq: Int, baseURL: URL) -> URL {
        url("\(trimmedBase(baseURL))/1sat/ordfs/metadata/\(outpoint):\(seq)")
    }

    public func origin(forName name: String) async throws -> OpnsOrigin {
        try await get(Self.originURL(name: name, baseURL: baseURL), as: OpnsOrigin.self)
    }

    public func mine(forName name: String) async throws -> OpnsMine {
        try await get(Self.mineURL(name: name, baseURL: baseURL), as: OpnsMine.self)
    }

    public func validateOrigins(_ outpoints: [String]) async throws -> [String: Bool] {
        let body = Array(try JSONEncoder().encode(outpoints))
        let url = Self.originsURL(baseURL: baseURL)
        return try OneSatClientHTTP.decode(
            [String: Bool].self,
            try await transport.send(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body
            ),
            service: Self.service, operation: "OpnsClient.validateOrigins", method: "POST", url: url
        )
    }

    /// `OrdfsClient.getMetadata(outpoint, seq)`: GET `/1sat/ordfs/metadata/<outpoint>:<seq>`.
    /// `seq` -1 is the latest revision of the ordinal at `outpoint`.
    public func metadata(outpoint: String, seq: Int) async throws -> OrdfsMetadata {
        try await get(
            Self.metadataURL(outpoint: outpoint, seq: seq, baseURL: baseURL),
            as: OrdfsMetadata.self
        )
    }

    private static let service = "the OpNS name service"

    private func get<T: Decodable>(_ url: URL, as type: T.Type, operation: String = #function) async throws -> T {
        try OneSatClientHTTP.decode(
            type, try await transport.send(method: "GET", url: url, headers: [:], body: nil),
            service: Self.service, operation: "OpnsClient.\(operation)", method: "GET", url: url
        )
    }

    private static func trimmedBase(_ baseURL: URL) -> String {
        let absolute = baseURL.absoluteString
        if absolute.hasSuffix("/") {
            return String(absolute.dropLast())
        }
        return absolute
    }

    private static func url(_ string: String) -> URL {
        URL(string: string)!
    }

    /// Percent-encode every byte outside `A-Za-z0-9-_.!~*'()`, matching `encodeURIComponent`.
    private static func encodeURIComponent(_ value: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            if isURIComponentUnescaped(byte) {
                encoded.append(Character(UnicodeScalar(byte)))
            } else {
                encoded.append("%")
                encoded.append(hexDigit(byte >> 4))
                encoded.append(hexDigit(byte & 0x0F))
            }
        }
        return encoded
    }

    private static func isURIComponentUnescaped(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."),
             UInt8(ascii: "!"), UInt8(ascii: "~"), UInt8(ascii: "*"),
             UInt8(ascii: "'"), UInt8(ascii: "("), UInt8(ascii: ")"):
            true
        default:
            false
        }
    }

    private static func hexDigit(_ nibble: UInt8) -> Character {
        Character(UnicodeScalar(nibble < 10 ? 48 + nibble : 55 + nibble))
    }
}
