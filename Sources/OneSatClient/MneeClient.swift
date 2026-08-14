import Foundation

public struct MneeConfig: Equatable, Sendable, Decodable {
    public let approver: String
    public let feeAddress: String
    public let burnAddress: String
    public let mintAddress: String
    public let fees: [MneeFeeTier]
    public let decimals: Int
    public let tokenId: String
}

public struct MneeFeeTier: Equatable, Sendable, Decodable {
    public let min: Int
    public let max: Int
    public let fee: Int
}

public struct MneeBalance: Equatable, Sendable, Decodable {
    public let address: String
    public let amt: Int
    public let precised: Double
}

public struct MneeUtxo: Equatable, Sendable, Decodable {
    public struct TokenData: Equatable, Sendable, Decodable {
        public let id: String
        public let op: String
        public let amt: Int
        public let sym: String?
        public let icon: String?
        public let dec: Int?
    }

    public struct CosignData: Equatable, Sendable, Decodable {
        public let address: String
        public let cosigner: String
    }

    public struct AssetData: Equatable, Sendable, Decodable {
        public let bsv21: TokenData?
        public let cosign: CosignData?
    }

    public let txid: String
    public let vout: Int
    public let outpoint: String
    public let satoshis: Int
    public let script: String
    public let owners: [String]
    public let senders: [String]
    public let height: Int
    public let idx: Int
    public let score: Double
    public let data: AssetData
}

public struct MneeTransferStatus: Equatable, Sendable, Decodable {
    public let id: String
    public let txid: String
    public let txHex: String
    public let actionRequested: String
    public let status: String
    public let createdAt: String
    public let updatedAt: String
    public let errors: String?

    enum CodingKeys: String, CodingKey {
        case id
        case txid = "tx_id"
        case txHex = "tx_hex"
        case actionRequested = "action_requested"
        case status
        case createdAt
        case updatedAt
        case errors
    }
}

public struct MneeSyncEntry: Equatable, Sendable, Decodable {
    public let txid: String
    public let height: Int
    public let idx: Int
    public let score: Double
    public let blocktime: Int
    public let rawtx: String
    public let outs: [Int]?
    public let senders: [String]
    public let receivers: [String]
}

public struct MneeSubmitResponse: Equatable, Sendable {
    public let ticketId: String?
    public let rawtx: [UInt8]?
}

public struct MneeClient: Sendable {
    private let baseURL: URL
    private let apiKey: String
    private let transport: any OneSatHTTPTransport

    public init(
        baseURL: URL = URL(string: "https://proxy-api.mnee.net")!,
        apiKey: String = "92982ec1c0975f31979da515d46bae9f",
        transport: any OneSatHTTPTransport = URLSessionOneSatTransport()
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public static func configURL(baseURL: URL, apiKey: String) -> URL {
        url(withAuth("\(trimmedBase(baseURL))/v1/config", apiKey: apiKey))
    }

    public static func balanceURL(baseURL: URL, apiKey: String) -> URL {
        url(withAuth("\(trimmedBase(baseURL))/v2/balance", apiKey: apiKey))
    }

    public static func utxosURL(page: Int?, size: Int?, order: String?, baseURL: URL, apiKey: String) -> URL {
        var path = "\(trimmedBase(baseURL))/v2/utxos"
        var params: [String] = []
        if let page { params.append("page=\(page)") }
        if let size { params.append("size=\(size)") }
        if let order { params.append("order=\(order)") }
        if !params.isEmpty {
            path += "?\(params.joined(separator: "&"))"
        }
        return url(withAuth(path, apiKey: apiKey))
    }

    public static func syncURL(fromScore: Double?, limit: Int, baseURL: URL, apiKey: String) -> URL {
        var path = "\(trimmedBase(baseURL))/v1/sync"
        var params: [String] = []
        if let fromScore { params.append("from=\(queryNumber(fromScore))") }
        if limit != 0 { params.append("limit=\(limit)") }
        if !params.isEmpty {
            path += "?\(params.joined(separator: "&"))"
        }
        return url(withAuth(path, apiKey: apiKey))
    }

    public static func ticketURL(ticketId: String, baseURL: URL, apiKey: String) -> URL {
        url(withAuth("\(trimmedBase(baseURL))/v2/ticket?ticketID=\(ticketId)", apiKey: apiKey))
    }

    public static func rawTxURL(txid: String, baseURL: URL, apiKey: String) -> URL {
        url(withAuth("\(trimmedBase(baseURL))/v1/tx/\(txid)", apiKey: apiKey))
    }

    public static func transferURL(baseURL: URL, apiKey: String) -> URL {
        url(withAuth("\(trimmedBase(baseURL))/v2/transfer", apiKey: apiKey))
    }

    /// Whole values print with no fraction ("840000"); fractions use Swift's shortest form.
    public static func queryNumber(_ value: Double) -> String {
        if value.isFinite, value.rounded(.towardZero) == value {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    public func getConfig() async throws -> MneeConfig {
        try await get(Self.configURL(baseURL: baseURL, apiKey: apiKey), as: MneeConfig.self)
    }

    public func getBalances(_ addresses: [String]) async throws -> [MneeBalance] {
        try await post(
            Self.balanceURL(baseURL: baseURL, apiKey: apiKey),
            jsonBody: addresses,
            as: [MneeBalance].self
        )
    }

    public func getUtxos(
        addresses: [String],
        page: Int? = nil,
        size: Int? = nil,
        order: String? = nil
    ) async throws -> [MneeUtxo] {
        let utxos: [MneeUtxo] = try await post(
            Self.utxosURL(page: page, size: size, order: order, baseURL: baseURL, apiKey: apiKey),
            jsonBody: addresses,
            as: [MneeUtxo].self
        )
        return utxos.filter { utxo in
            guard let op = utxo.data.bsv21?.op else { return false }
            return op == "transfer" || op == "deploy+mint"
        }
    }

    public func getAllUtxos(addresses: [String]) async throws -> [MneeUtxo] {
        var all: [MneeUtxo] = []
        var page = 1
        let size = 1000
        var hasMore = true
        while hasMore {
            let batch = try await getUtxos(addresses: addresses, page: page, size: size)
            all.append(contentsOf: batch)
            hasMore = batch.count == size
            page += 1
        }
        return all
    }

    public func getTxHistory(
        addresses: [String],
        fromScore: Double? = nil,
        limit: Int = 50
    ) async throws -> [MneeSyncEntry] {
        try await post(
            Self.syncURL(fromScore: fromScore, limit: limit, baseURL: baseURL, apiKey: apiKey),
            jsonBody: addresses,
            as: [MneeSyncEntry].self
        )
    }

    public func getTxStatus(ticketId: String) async throws -> MneeTransferStatus {
        try await get(
            Self.ticketURL(ticketId: ticketId, baseURL: baseURL, apiKey: apiKey),
            as: MneeTransferStatus.self
        )
    }

    public func fetchRawTx(txid: String) async throws -> [UInt8] {
        let envelope = try await get(
            Self.rawTxURL(txid: txid, baseURL: baseURL, apiKey: apiKey),
            as: RawTxEnvelope.self
        )
        guard let rawtx = envelope.rawtx, let data = Data(base64Encoded: rawtx) else {
            throw OneSatClientError.unreadableResponse
        }
        return Array(data)
    }

    public func submitRawTx(
        tx: [UInt8],
        broadcast: Bool = true,
        callbackUrl: String? = nil
    ) async throws -> MneeSubmitResponse {
        if !broadcast {
            return MneeSubmitResponse(ticketId: nil, rawtx: tx)
        }

        let body = Array(
            try JSONEncoder().encode(
                TransferRequest(rawtx: Data(tx).base64EncodedString(), callback_url: callbackUrl)
            )
        )
        let response = try await transport.send(
            method: "POST",
            url: Self.transferURL(baseURL: baseURL, apiKey: apiKey),
            headers: ["Content-Type": "application/json"],
            body: body
        )
        guard (200..<300).contains(response.status) else {
            throw OneSatClientError.httpFailure(statusCode: response.status)
        }
        guard let ticketId = String(bytes: response.body, encoding: .utf8) else {
            throw OneSatClientError.unreadableResponse
        }
        return MneeSubmitResponse(ticketId: ticketId, rawtx: nil)
    }

    private struct RawTxEnvelope: Decodable {
        let rawtx: String?
    }

    private struct TransferRequest: Encodable {
        let rawtx: String
        let callback_url: String?
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        try decode(
            try await transport.send(method: "GET", url: url, headers: [:], body: nil),
            as: type
        )
    }

    private func post<T: Decodable>(_ url: URL, jsonBody: some Encodable, as type: T.Type) async throws -> T {
        let body = Array(try JSONEncoder().encode(jsonBody))
        return try decode(
            try await transport.send(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body
            ),
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

    private static func withAuth(_ path: String, apiKey: String) -> String {
        let sep = path.contains("?") ? "&" : "?"
        return "\(path)\(sep)auth_token=\(apiKey)"
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
}
