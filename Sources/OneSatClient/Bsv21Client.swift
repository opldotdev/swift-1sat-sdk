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

    /// `TokenStatus` from `@1sat/types`. `POST /{tokenId}/fund` returns this shape too.
    public struct Status: Equatable, Sendable, Decodable {
        public let isActive: Bool?
        public let feeAddress: String?
        public let feePerOutput: UInt64?
        /// Satoshis the fee address must receive before the token is indexed.
        public let minFunding: UInt64?

        public init(
            isActive: Bool?,
            feeAddress: String? = nil,
            feePerOutput: UInt64? = nil,
            minFunding: UInt64? = nil
        ) {
            self.isActive = isActive
            self.feeAddress = feeAddress
            self.feePerOutput = feePerOutput
            self.minFunding = minFunding
        }

        private enum CodingKeys: String, CodingKey {
            case isActive = "is_active"
            case feeAddress = "fee_address"
            case feePerOutput = "fee_per_output"
            case minFunding = "min_funding"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
            feeAddress = try? container.decodeIfPresent(String.self, forKey: .feeAddress)
            feePerOutput = try? container.decodeIfPresent(UInt64.self, forKey: .feePerOutput)
            minFunding = try? container.decodeIfPresent(UInt64.self, forKey: .minFunding)
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

/// Overlay state of a token outpoint, from `POST /1sat/bsv21/{tokenId}/outputs/status`.
public enum Bsv21OutputState: String, Equatable, Sendable, Codable {
    /// Indexed and unspent.
    case valid
    /// Indexed and spent.
    case spent
    /// Waiting in the token's indexing queue.
    case queued
    /// Neither indexed nor queued.
    case unknown
}

public struct Bsv21OutputStatus: Equatable, Sendable, Decodable {
    /// The outpoint exactly as it was sent.
    public let outpoint: String
    public let state: Bsv21OutputState

    public init(outpoint: String, state: Bsv21OutputState) {
        self.outpoint = outpoint
        self.state = state
    }
}

/// Payment outputs that fund a token's overlay, from `GET /1sat/bsv21/{tokenId}/fund`.
/// Empty when the token is active and funded past its backlog.
public struct Bsv21FundingTemplate: Equatable, Sendable, Decodable {
    public struct Output: Equatable, Sendable, Decodable {
        /// Hex locking script paying the token's fee address.
        public let lockingScript: String
        public let satoshis: UInt64
        public let outputDescription: String

        public init(lockingScript: String, satoshis: UInt64, outputDescription: String) {
            self.lockingScript = lockingScript
            self.satoshis = satoshis
            self.outputDescription = outputDescription
        }
    }

    public let outputs: [Output]

    public init(outputs: [Output]) {
        self.outputs = outputs
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

    /// The payment outputs that activate the token's overlay: enough to meet its minimum
    /// funding and index its queued backlog. Empty when no funding is needed.
    public func fundingTemplate(tokenID: String) async throws -> Bsv21FundingTemplate {
        try decode(try await transport.send(
            method: "GET",
            url: endpoint(tokenID).appendingPathComponent("fund"),
            headers: [:],
            body: nil
        ))
    }

    /// Submits a BEEF transaction paying the token's fee address. The server broadcasts it,
    /// indexes it, and starts the overlay if the funding qualifies. Returns the token's status.
    public func submitFunding(tokenID: String, beef: [UInt8]) async throws -> Bsv21TokenDetails.Status {
        try decode(try await transport.send(
            method: "POST",
            url: endpoint(tokenID).appendingPathComponent("fund"),
            headers: ["Content-Type": "application/octet-stream"],
            body: beef
        ))
    }

    /// The overlay state of each outpoint: valid, spent, queued, or unknown. Results come back
    /// in request order with outpoints as sent. Requests go out sequentially in batches of 1000.
    public func outputStatus(tokenID: String, outpoints: [String]) async throws -> [Bsv21OutputStatus] {
        let url = endpoint(tokenID)
            .appendingPathComponent("outputs")
            .appendingPathComponent("status")
        var results: [Bsv21OutputStatus] = []
        var start = 0
        while start < outpoints.count {
            let batch = Array(outpoints[start..<min(start + Self.outputStatusBatchSize, outpoints.count)])
            let decoded: [Bsv21OutputStatus] = try decode(try await transport.send(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: Array(try JSONEncoder().encode(batch))
            ))
            results.append(contentsOf: decoded)
            start += Self.outputStatusBatchSize
        }
        return results
    }

    static let outputStatusBatchSize = 1000

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
