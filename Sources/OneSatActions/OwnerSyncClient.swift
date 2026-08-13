import Foundation
import ToolboxServices

/// One output from `GET /1sat/owner/sync`. Matches `@1sat/types` `SyncOutput`.
public struct SyncOutput: Equatable, Sendable, Codable {
    public let outpoint: String
    public let score: Double
    public let spendTxid: String?

    public init(outpoint: String, score: Double, spendTxid: String? = nil) {
        self.outpoint = outpoint
        self.score = score
        self.spendTxid = spendTxid
    }
}

public protocol OwnerSyncSource: Sendable {
    func syncOutputs(owners: [String], from: Double?) async throws -> [SyncOutput]
}

public enum OwnerSyncError: Error, Equatable, Sendable {
    case httpFailure(statusCode: Int)
    case server(String)
    case unreadableOutput
    case invalidURL
}

/// `OwnerClient.sync` from `@1sat/client`. Fetches the SSE body through `HTTPGet`.
public struct OwnerSyncClient: OwnerSyncSource {
    public let baseURL: URL
    private let http: any HTTPGet

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        http: any HTTPGet = URLSessionHTTPGet()
    ) {
        self.baseURL = baseURL
        self.http = http
    }

    public func syncOutputs(owners: [String], from: Double?) async throws -> [SyncOutput] {
        let endpoint = baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("owner")
            .appendingPathComponent("sync")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw OwnerSyncError.invalidURL
        }
        var items = owners.map { URLQueryItem(name: "owner", value: $0) }
        if let from {
            items.append(URLQueryItem(name: "from", value: String(from)))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw OwnerSyncError.invalidURL }

        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw OwnerSyncError.httpFailure(statusCode: status)
        }
        return try Self.parse(sse: body)
    }

    /// `event: error` throws, `event: done` stops, `event: sync` is skipped.
    /// Frames with no event name are `SyncOutput` JSON. A named output that
    /// cannot be decoded is a thrown error, not a skip.
    static func parse(sse body: [UInt8]) throws -> [SyncOutput] {
        let text = String(decoding: body, as: UTF8.self)
        var outputs: [SyncOutput] = []

        for frame in text.components(separatedBy: "\n\n") {
            var event: String?
            var data = ""
            for line in frame.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("event:") {
                    event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    data = String(line.dropFirst("data:".count).drop(while: { $0 == " " }))
                }
            }
            if event == "done" { break }
            if event == "error" { throw OwnerSyncError.server(data) }
            if event == "sync" { continue }
            guard event == nil, !data.isEmpty else { continue }
            guard let decoded = try? JSONDecoder().decode(SyncOutput.self, from: Data(data.utf8))
            else {
                throw OwnerSyncError.unreadableOutput
            }
            outputs.append(decoded)
        }
        return outputs
    }
}
