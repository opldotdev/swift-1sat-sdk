import Foundation

public protocol ProcessedTxStore: Sendable {
    func has(_ txid: String) async throws -> Bool
    func add(_ txid: String) async throws
    func lastScore() async throws -> Double
    func setLastScore(_ score: Double) async throws
}

/// JSON file `{ processed: [String], lastScore: Double }`. `lastScore` starts at 0.
public actor FileProcessedTxStore: ProcessedTxStore {
    private let fileURL: URL
    private var snapshot: Snapshot?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func has(_ txid: String) async throws -> Bool {
        try load().processed.contains(txid)
    }

    public func add(_ txid: String) async throws {
        var current = try load()
        if !current.processed.contains(txid) {
            current.processed.append(txid)
        }
        try persist(current)
    }

    public func lastScore() async throws -> Double {
        try load().lastScore
    }

    public func setLastScore(_ score: Double) async throws {
        var current = try load()
        current.lastScore = score
        try persist(current)
    }

    private func load() throws -> Snapshot {
        if let snapshot { return snapshot }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = Snapshot(processed: [], lastScore: 0)
            snapshot = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(Snapshot.self, from: data)
        snapshot = decoded
        return decoded
    }

    private func persist(_ next: Snapshot) throws {
        let data = try JSONEncoder().encode(next)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        snapshot = next
    }

    private struct Snapshot: Codable {
        var processed: [String]
        var lastScore: Double
    }
}
