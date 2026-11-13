import Foundation

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
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OneSatClientError.unreadableResponse
        }
        return (http.statusCode, Array(data))
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

/// `OrdfsMetadata` from `@1sat/types`, without the MAP payload. Only `outpoint` is required;
/// the other members decode when the server sends them.
public struct OrdfsMetadata: Equatable, Sendable, Decodable {
    public let outpoint: String
    public let origin: String?
    public let sequence: Int?
    public let contentType: String?
    public let contentLength: Int?
    public let parent: String?

    public init(
        outpoint: String,
        origin: String? = nil,
        sequence: Int? = nil,
        contentType: String? = nil,
        contentLength: Int? = nil,
        parent: String? = nil
    ) {
        self.outpoint = outpoint
        self.origin = origin
        self.sequence = sequence
        self.contentType = contentType
        self.contentLength = contentLength
        self.parent = parent
    }
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
        return try decode(
            try await transport.send(
                method: "POST",
                url: Self.originsURL(baseURL: baseURL),
                headers: ["Content-Type": "application/json"],
                body: body
            ),
            as: [String: Bool].self
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

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        try decode(
            try await transport.send(method: "GET", url: url, headers: [:], body: nil),
            as: type
        )
    }

    private func decode<T: Decodable>(
        _ response: (status: Int, body: [UInt8]),
        as type: T.Type
    ) throws -> T {
        guard (200..<300).contains(response.status) else {
            throw OneSatClientError.httpFailure(statusCode: response.status)
        }
        guard let value = try? JSONDecoder().decode(type, from: Data(response.body)) else {
            throw OneSatClientError.unreadableResponse
        }
        return value
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
