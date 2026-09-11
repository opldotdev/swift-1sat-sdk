import BSVKeys
import BSVTransaction
import Foundation
import ToolboxCore
import ToolboxServices

/// Reads an address's categorised outputs from the 1Sat indexer (`api.1sat.app`).
///
/// This is the provider a safe sweep needs: it tags every output with events (`bsv21:`, `lock:`, an
/// ordinal marker) so an ordinal is never mistaken for a coin. WhatsOnChain cannot do this, which
/// is why it does not conform to `AssetScanner`.
///
/// The owner stream supplies asset events. Source transaction bytes supply the actual locking
/// scripts: an owner may control an OrdLock cancellation key, not just a P2PKH address.
/// A capped or interrupted response is refused so callers retain the source keys and retry.
public struct OneSatScanner: AssetScanner {
    /// The 1Sat-stack API base. `https://api.1sat.app` for mainnet.
    public let baseURL: URL
    private let http: any HTTPGet
    /// Maximum rows per scan. Reaching this bound is an explicit incomplete-scan error.
    private let limit: Int

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        network _: BitcoinNetwork = .mainnet,
        http: any HTTPGet = URLSessionHTTPGet(),
        limit: Int = 10_000
    ) {
        self.baseURL = baseURL
        self.http = http
        self.limit = limit
    }

    public func scan(address: String) async throws -> [ScannedOutput] {
        guard limit > 0, (try? Address(address)) != nil else {
            throw AssetScannerError.unreadableResponse
        }

        guard let url = URL(
            // Defaults on the endpoint already give unspent-only, satoshis, events and block.
            string: "\(baseURL.absoluteString)/1sat/owner/\(address)/txos?limit=\(limit)&unspent=true&sats=true&events=true&spend=true"
        ) else {
            throw AssetScannerError.unreadableResponse
        }

        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw AssetScannerError.httpFailure(statusCode: status)
        }
        let scanned = try Self.parse(sse: body, limit: limit)
        var transactions: [String: Transaction] = [:]
        var resolved: [ScannedOutput] = []
        for output in scanned {
            let transaction: Transaction
            if let cached = transactions[output.txid] {
                transaction = cached
            } else {
                // Matches BeefClient.getRawTx in @1sat/client.
                let sourceURL = baseURL.appendingPathComponent("1sat/beef/\(output.txid)/tx")
                let (sourceStatus, sourceBody) = try await http.get(sourceURL)
                guard (200..<300).contains(sourceStatus) else {
                    throw AssetScannerError.httpFailure(statusCode: sourceStatus)
                }
                transaction = try Transaction(bytes: sourceBody, limits: Sweep.defaultLimits)
                guard try transaction.transactionID(limits: Sweep.defaultLimits).displayHex == output.txid else {
                    throw AssetScannerError.unreadableResponse
                }
                transactions[output.txid] = transaction
            }
            guard transaction.outputs.indices.contains(Int(output.vout)) else {
                throw AssetScannerError.unreadableResponse
            }
            let source = transaction.outputs[Int(output.vout)]
            guard source.satoshis == output.satoshis else {
                throw AssetScannerError.unreadableResponse
            }
            resolved.append(ScannedOutput(
                txid: output.txid, vout: output.vout, satoshis: source.satoshis,
                lockingScript: source.lockingScript.bytes, events: output.events
            ))
        }
        return resolved
    }

    /// Parses the SSE stream into outputs.
    ///
    /// Only `event: txo` frames carry outputs; `sync` frames are progress and `done` ends the
    /// stream. A frame that names an output but cannot be read is a refusal — a dropped output on
    /// an import is money the wallet never learns it has.
    static func parse(sse body: [UInt8], limit: Int = .max) throws -> [ScannedOutput] {
        let text = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var outputs: [ScannedOutput] = []
        var count = 0
        var complete = false

        for frame in text.components(separatedBy: "\n\n") {
            var event = "message"
            var data = ""
            for line in frame.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("event:") {
                    event = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    data = String(line.dropFirst("data:".count).drop(while: { $0 == " " }))
                }
            }
            if event == "error" { throw AssetScannerError.unreadableResponse }
            if event == "done" { complete = true; break }
            guard event == "txo", !data.isEmpty else { continue }
            count += 1
            guard count < limit else { throw AssetScannerError.scanLimitReached(limit: limit) }

            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)),
                  let outpoint = json["outpoint"]?.stringValue,
                  let (txid, vout) = splitOutpoint(outpoint) else {
                throw AssetScannerError.unreadableResponse
            }
            // An output already spent is not ours to sweep. The endpoint filters these by default,
            // but a stray one is skipped rather than swept.
            if let spend = json["spend"]?.stringValue, !spend.isEmpty { continue }

            guard let satoshis = json["satoshis"]?.intValue.flatMap({ UInt64(exactly: $0) }),
                  // The owner API omits events for plain funding outputs.
                  let eventValues = (json["events"] ?? .array([])).arrayValue,
                  eventValues.allSatisfy({ $0.stringValue != nil }) else {
                throw AssetScannerError.unreadableResponse
            }
            let events = eventValues.compactMap(\.stringValue)

            outputs.append(
                ScannedOutput(
                    txid: txid, vout: vout, satoshis: satoshis,
                    lockingScript: [], events: events
                )
            )
        }
        guard complete else { throw AssetScannerError.unreadableResponse }
        return outputs
    }

    /// Splits `"txid.vout"` (the owner-txos SSE outpoint form).
    package static func splitOutpoint(_ outpoint: String) -> (txid: String, vout: UInt32)? {
        guard let index = outpoint.lastIndex(of: ".") else { return nil }
        let txid = String(outpoint[..<index])
        guard let vout = UInt32(outpoint[outpoint.index(after: index)...]),
              txid.count == 64,
              txid.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { return nil }
        return (txid, vout)
    }
}

public enum AssetScannerError: LocalizedError, Equatable, Sendable {
    case unreadableResponse
    case scanLimitReached(limit: Int)
    case httpFailure(statusCode: Int)

    public var errorDescription: String? {
        switch self {
        case .scanLimitReached(let limit):
            "Asset discovery reached its \(limit)-output limit; the scan is incomplete. Retain the source keys and retry with a larger limit."
        case .unreadableResponse:
            "Asset discovery returned an incomplete or unreadable response."
        case .httpFailure(let status):
            "Asset discovery failed (HTTP \(status))."
        }
    }
}
