import Foundation

/// The immutable token facts used by sends and approval-time verification.
public struct Bsv21TokenDetails: Equatable, Sendable, Decodable {
    public struct Token: Equatable, Sendable, Decodable {
        public let id: String
        public let symbol: String?
        public let decimals: String?
        public let icon: String?

        public init(id: String, symbol: String?, decimals: String?, icon: String?) {
            self.id = id
            self.symbol = symbol
            self.decimals = decimals
            self.icon = icon
        }

        private enum CodingKeys: String, CodingKey {
            case id, icon
            case symbol = "sym"
            case decimals = "dec"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            if let value = try? container.decode(String.self, forKey: .decimals) {
                decimals = value
            } else if let value = try? container.decode(Int.self, forKey: .decimals) {
                decimals = String(value)
            } else {
                decimals = nil
            }
        }
    }

    public struct Status: Equatable, Sendable, Decodable {
        public let isActive: Bool?

        public init(isActive: Bool?) {
            self.isActive = isActive
        }

        private enum CodingKeys: String, CodingKey {
            case isActive = "is_active"
        }
    }

    public let tokenID: String
    public let token: Token
    public let status: Status

    public init(tokenID: String, token: Token, status: Status) {
        self.tokenID = tokenID
        self.token = token
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case tokenID = "tokenId"
        case token, status
    }
}

public struct Bsv21ValidatedOutput: Equatable, Sendable, Decodable {
    public let outpoint: String

    public init(outpoint: String) {
        self.outpoint = outpoint
    }
}

/// Network reads matching `@1sat/client`'s token-detail and output-validation routes.
public struct Bsv21Client: Sendable {
    private let baseURL: URL
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func tokenDetails(tokenID: String) async throws -> Bsv21TokenDetails {
        try decode(try await transport.send(
            method: "GET",
            url: endpoint(tokenID),
            headers: [:],
            body: nil
        ))
    }

    /// Returns only outpoints the BSV21 overlay currently recognizes for this token.
    public func validateOutputs(
        tokenID: String,
        outpoints: [String],
        unspent: Bool = false
    ) async throws -> [Bsv21ValidatedOutput] {
        var components = URLComponents(
            url: endpoint(tokenID).appendingPathComponent("outputs"),
            resolvingAgainstBaseURL: false
        )
        if unspent {
            components?.queryItems = [URLQueryItem(name: "unspent", value: "true")]
        }
        guard let url = components?.url else { throw OneSatClientError.unreadableResponse }
        return try decode(try await transport.send(
            method: "POST",
            url: url,
            headers: ["Content-Type": "application/json"],
            body: Array(try JSONEncoder().encode(outpoints))
        ))
    }

    private func endpoint(_ tokenID: String) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("bsv21")
            .appendingPathComponent(tokenID)
    }

    private func decode<T: Decodable>(
        _ response: (status: Int, body: [UInt8])
    ) throws -> T {
        guard (200..<300).contains(response.status) else {
            throw OneSatClientError.httpFailure(statusCode: response.status)
        }
        guard let value = try? JSONDecoder().decode(T.self, from: Data(response.body)) else {
            throw OneSatClientError.unreadableResponse
        }
        return value
    }
}
