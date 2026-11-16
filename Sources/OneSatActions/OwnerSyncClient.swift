import Foundation
import OneSatSweep
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

public enum OwnerSyncError: Error, Equatable, Sendable, LocalizedError, CustomDebugStringConvertible {
    /// `detail` carries the host, path, server reason and body; it does not take part in `==`.
    case httpFailure(statusCode: Int, detail: OneSatHTTPFailure? = nil)
    case server(String)
    case unreadableOutput
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .httpFailure(_, let detail?):
            "Syncing with the 1Sat indexer failed. \(detail.userMessage)"
        case .httpFailure(let status, nil):
            "Syncing with the 1Sat indexer failed (HTTP \(status))."
        case .server(let message):
            OneSatHTTPFailure.oneLine(message).map { "The 1Sat indexer stopped the sync: \($0)" }
                ?? "The 1Sat indexer stopped the sync with an error."
        case .unreadableOutput:
            "The 1Sat indexer sent a sync entry this wallet could not read."
        case .invalidURL:
            "The 1Sat indexer address is not a valid URL."
        }
    }

    public var debugDescription: String {
        switch self {
        case .httpFailure(let status, let detail):
            "OwnerSyncError.httpFailure(\(status)): \(detail?.debugDescription ?? "no detail")"
        case .server(let message):
            "OwnerSyncError.server(\(OneSatHTTPFailure.logText(Array(message.utf8))))"
        case .unreadableOutput:
            "OwnerSyncError.unreadableOutput"
        case .invalidURL:
            "OwnerSyncError.invalidURL"
        }
    }

    public static func == (lhs: OwnerSyncError, rhs: OwnerSyncError) -> Bool {
        switch (lhs, rhs) {
        case (.httpFailure(let a, _), .httpFailure(let b, _)): a == b
        case (.server(let a), .server(let b)): a == b
        case (.unreadableOutput, .unreadableOutput), (.invalidURL, .invalidURL): true
        default: false
        }
    }
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
            let detail = OneSatHTTPFailure(
                service: "the 1Sat indexer", operation: "OwnerSyncClient.syncOutputs", method: "GET", url: url,
                statusCode: status, body: body
            )
            detail.log(category: "OneSatActions")
            throw OwnerSyncError.httpFailure(statusCode: status, detail: detail)
        }
        do {
            return try Self.parse(sse: body)
        } catch {
            OneSatLog.unreadable(
                "OwnerSyncClient.syncOutputs", method: "GET", url: url, body: body, error: error, category: "OneSatActions"
            )
            throw error
        }
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
            do {
                outputs.append(try JSONDecoder().decode(SyncOutput.self, from: Data(data.utf8)))
            } catch {
                OneSatLog.error(error, "OwnerSyncClient: sync entry \(OneSatHTTPFailure.logText(Array(data.utf8)))", category: "OneSatActions")
                throw OwnerSyncError.unreadableOutput
            }
        }
        return outputs
    }
}
