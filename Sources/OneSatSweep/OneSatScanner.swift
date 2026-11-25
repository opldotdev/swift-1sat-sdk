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
    /// The 1Sat-stack API base: `OneSatAPI.baseURL(for:)` unless one is passed.
    public let baseURL: URL
    private let http: any HTTPGet
    /// Maximum rows per scan. Reaching this bound is an explicit incomplete-scan error.
    private let limit: Int

    public init(
        baseURL: URL? = nil,
        network: BitcoinNetwork = .mainnet,
        http: any HTTPGet = URLSessionHTTPGet(),
        limit: Int = 10_000
    ) {
        self.baseURL = baseURL ?? OneSatAPI.baseURL(for: network)
        self.http = http
        self.limit = limit
    }

    public func scan(address: String) async throws -> [ScannedOutput] {
        // The address parse is a probe: its failure is reported below with the address.
        guard limit > 0, (try? Address(address)) != nil else {
            OneSatLog.error(
                "OneSatScanner.scan: not scanning \(address) (not an address, or limit \(limit) is not positive)",
                category: "OneSatSweep"
            )
            throw AssetScannerError.unreadableResponse
        }

        guard let url = URL(
            // Defaults on the endpoint already give unspent-only, satoshis, events and block.
            // `refresh=true` asks the indexer to sync the address first (`scan.ts` `scanAddress`,
            // `owner.getTxos(address, { refresh: true })`). Checked against api.1sat.app on
            // Nov 17: with `limit` set the stream is sync frames, then every txo, then `done`, so
            // one request does what TS does in two.
            string: "\(baseURL.absoluteString)/1sat/owner/\(address)/txos?limit=\(limit)&unspent=true&sats=true&events=true&spend=true&refresh=true"
        ) else {
            throw AssetScannerError.unreadableResponse
        }

        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw AssetScannerError.http("OneSatScanner.scan owner txos", url: url, status: status, body: body)
        }
        let scanned: [ScannedOutput]
        do {
            scanned = try Self.parse(sse: body, limit: limit)
        } catch AssetScannerError.unreadableResponse {
            OneSatLog.unreadable(
                "OneSatScanner.scan owner txos", method: "GET", url: url, body: body, error: nil, category: "OneSatSweep"
            )
            throw AssetScannerError.unreadableResponse
        }
        return try await resolve(scanned)
    }

    /// Twetch NFTs (twonks) held by an address. The indexer lists them under `twetch:<address>`,
    /// not in the owner stream, so wallets that don't know the format never take one for funds;
    /// ``scan(address:)`` therefore never returns them. Each comes back with its source locking
    /// script, so ``TwetchNFT`` can read its title and image.
    public func twetchNFTs(address: String) async throws -> [ScannedOutput] {
        guard limit > 0, (try? Address(address)) != nil else {
            OneSatLog.error(
                "OneSatScanner.twetchNFTs: not searching \(address) (not an address, or limit \(limit) is not positive)",
                category: "OneSatSweep"
            )
            throw AssetScannerError.unreadableResponse
        }
        guard let url = URL(
            string: "\(baseURL.absoluteString)/1sat/txo/search?key=twetch%3A\(address)&unspent=true&sats=true&events=true&limit=\(limit)"
        ) else {
            throw AssetScannerError.unreadableResponse
        }
        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw AssetScannerError.http("OneSatScanner.twetchNFTs txo search", url: url, status: status, body: body)
        }
        let found: [ScannedOutput]
        do {
            found = try Self.parse(search: body, limit: limit)
        } catch AssetScannerError.unreadableResponse {
            OneSatLog.unreadable(
                "OneSatScanner.twetchNFTs txo search", method: "GET", url: url, body: body, error: nil,
                category: "OneSatSweep"
            )
            throw AssetScannerError.unreadableResponse
        }
        return try await resolve(found)
    }

    /// Reads each output's locking script from its source transaction (fetched once per txid),
    /// checking that the indexer's row matches the transaction.
    private func resolve(_ scanned: [ScannedOutput]) async throws -> [ScannedOutput] {
        var transactions: [String: Transaction] = [:]
        var runTransactions: Set<String> = []
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
                    throw AssetScannerError.http(
                        "OneSatScanner.scan source transaction", url: sourceURL, status: sourceStatus, body: sourceBody
                    )
                }
                transaction = try Transaction(bytes: sourceBody, limits: Sweep.defaultLimits)
                guard try transaction.transactionID(limits: Sweep.defaultLimits).displayHex == output.txid else {
                    OneSatLog.error(
                        "OneSatScanner.scan: the 1Sat indexer's source transaction for \(output.txid) hashes to another txid",
                        category: "OneSatSweep"
                    )
                    throw AssetScannerError.unreadableResponse
                }
                transactions[output.txid] = transaction
                // `scan.ts` `detectRunTransactions`: any output of the source starting with the
                // RUN prefix holds back its funding outputs. A failed fetch already throws above;
                // TS would sweep such an output, we do not.
                if transaction.outputs.contains(where: { ScannedOutput.hasRunPrefix($0.lockingScript.bytes) }) {
                    runTransactions.insert(output.txid)
                }
            }
            guard transaction.outputs.indices.contains(Int(output.vout)) else {
                OneSatLog.error(
                    "OneSatScanner.scan: the 1Sat indexer listed \(output.txid).\(output.vout), which its transaction does not have",
                    category: "OneSatSweep"
                )
                throw AssetScannerError.unreadableResponse
            }
            let source = transaction.outputs[Int(output.vout)]
            guard source.satoshis == output.satoshis else {
                OneSatLog.error(
                    "OneSatScanner.scan: the 1Sat indexer listed \(output.txid).\(output.vout) at \(output.satoshis) sats; the transaction says \(source.satoshis)",
                    category: "OneSatSweep"
                )
                throw AssetScannerError.unreadableResponse
            }
            resolved.append(ScannedOutput(
                txid: output.txid, vout: output.vout, satoshis: source.satoshis,
                lockingScript: source.lockingScript.bytes, events: output.events,
                sourceHasRunOutput: runTransactions.contains(output.txid)
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
            if event == "error" {
                OneSatLog.error("OneSatScanner: the 1Sat indexer's owner stream sent an error: \(data)", category: "OneSatSweep")
                throw AssetScannerError.unreadableResponse
            }
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

    /// Parses a `/1sat/txo/search` JSON array (`null` when nothing matches). Reaching `limit`
    /// rows is refused like the owner stream, since the rest would go unlisted.
    static func parse(search body: [UInt8], limit: Int = .max) throws -> [ScannedOutput] {
        let text = String(decoding: body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "null" { return [] }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
              let rows = json.arrayValue else {
            throw AssetScannerError.unreadableResponse
        }
        guard rows.count < limit else { throw AssetScannerError.scanLimitReached(limit: limit) }
        var outputs: [ScannedOutput] = []
        for row in rows {
            guard let outpoint = row["outpoint"]?.stringValue,
                  let (txid, vout) = splitOutpoint(outpoint),
                  let satoshis = row["satoshis"]?.intValue.flatMap({ UInt64(exactly: $0) }),
                  let eventValues = (row["events"] ?? .array([])).arrayValue,
                  eventValues.allSatisfy({ $0.stringValue != nil }) else {
                throw AssetScannerError.unreadableResponse
            }
            if let spend = row["spend"]?.stringValue, !spend.isEmpty { continue }
            outputs.append(ScannedOutput(
                txid: txid, vout: vout, satoshis: satoshis,
                lockingScript: [], events: eventValues.compactMap(\.stringValue)
            ))
        }
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

public enum AssetScannerError: LocalizedError, Equatable, Sendable, CustomDebugStringConvertible {
    case unreadableResponse
    case scanLimitReached(limit: Int)
    /// `detail` carries the host, path, server reason and body; it does not take part in `==`.
    case httpFailure(statusCode: Int, detail: OneSatHTTPFailure? = nil)

    public var errorDescription: String? {
        switch self {
        case .scanLimitReached(let limit):
            "Asset discovery reached its \(limit)-output limit; the scan is incomplete. Retain the source keys and retry with a larger limit."
        case .unreadableResponse:
            "Asset discovery returned an incomplete or unreadable response."
        case .httpFailure(_, let detail?):
            "Asset discovery failed. \(detail.userMessage)"
        case .httpFailure(let status, nil):
            "Asset discovery failed (HTTP \(status))."
        }
    }

    public var debugDescription: String {
        switch self {
        case .httpFailure(let status, let detail):
            "AssetScannerError.httpFailure(\(status)): \(detail?.debugDescription ?? "no detail")"
        case .scanLimitReached(let limit):
            "AssetScannerError.scanLimitReached(limit: \(limit))"
        case .unreadableResponse:
            "AssetScannerError.unreadableResponse"
        }
    }

    public static func == (lhs: AssetScannerError, rhs: AssetScannerError) -> Bool {
        switch (lhs, rhs) {
        case (.unreadableResponse, .unreadableResponse): true
        case (.scanLimitReached(let a), .scanLimitReached(let b)): a == b
        case (.httpFailure(let a, _), .httpFailure(let b, _)): a == b
        default: false
        }
    }

    /// An HTTP failure from the 1Sat indexer, logged in full once here.
    static func http(_ operation: String, method: String = "GET", url: URL, status: Int, body: [UInt8]) -> AssetScannerError {
        let detail = OneSatHTTPFailure(
            service: "the 1Sat indexer", operation: operation, method: method, url: url, statusCode: status, body: body
        )
        detail.log(category: "OneSatSweep")
        return .httpFailure(statusCode: status, detail: detail)
    }
}
