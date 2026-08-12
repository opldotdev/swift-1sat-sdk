import BSVKeys
import BSVScript
import Foundation
import ToolboxCore
import ToolboxServices

/// Reads an address's categorised outputs from the 1Sat indexer (`api.1sat.app`).
///
/// This is the provider a safe sweep needs: it tags every output with events (`bsv21:`, `lock:`, an
/// ordinal marker) so an ordinal is never mistaken for a coin. WhatsOnChain cannot do this, which
/// is why it does not conform to `AssetScanner`.
///
/// The endpoint streams Server-Sent Events — `event: txo` frames with the output JSON, ended by an
/// `event: done` frame. The response carries the outpoint, satoshis and events, but **not** the
/// locking script; for a fundable P2PKH output the script is the P2PKH of the scanned address, so
/// it is reconstructed the same way `WhatsOnChainUTXOSource` does. Non-fundable outputs are only
/// reported, never spent, so their script is not needed.
public struct OneSatScanner: AssetScanner {
    /// The 1Sat-stack API base. `https://api.1sat.app` for mainnet.
    public let baseURL: URL
    private let network: BitcoinNetwork
    private let http: any HTTPGet
    /// The most outputs to read in one scan. An address with more than this is paginated by score
    /// in a later revision; for now it is a high bound that covers any real wallet.
    private let limit: Int

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        network: BitcoinNetwork = .mainnet,
        http: any HTTPGet = URLSessionHTTPGet(),
        limit: Int = 10_000
    ) {
        self.baseURL = baseURL
        self.network = network
        self.http = http
        self.limit = limit
    }

    public func scan(address: String) async throws -> [ScannedOutput] {
        // Fundable outputs are P2PKH to the scanned address. Deriving it once, and refusing an
        // address with no P2PKH script, beats returning outputs a sweep could not sign.
        let script: [UInt8]
        do {
            script = try Script.payToPublicKeyHash(
                try Address(address).publicKeyHash, maximumByteCount: 1 << 20
            ).bytes
        } catch {
            throw AssetScannerError.unreadableResponse
        }

        guard let url = URL(
            // Defaults on the endpoint already give unspent-only, satoshis, events and block.
            string: "\(baseURL.absoluteString)/1sat/owner/\(address)/txos?limit=\(limit)"
        ) else {
            throw AssetScannerError.unreadableResponse
        }

        let (status, body) = try await http.get(url)
        guard (200..<300).contains(status) else {
            throw AssetScannerError.httpFailure(statusCode: status)
        }
        return try Self.parse(sse: body, lockingScript: script)
    }

    /// Parses the SSE stream into outputs.
    ///
    /// Only `event: txo` frames carry outputs; `sync` frames are progress and `done` ends the
    /// stream. A frame that names an output but cannot be read is a refusal — a dropped output on
    /// an import is money the wallet never learns it has.
    static func parse(sse body: [UInt8], lockingScript: [UInt8]) throws -> [ScannedOutput] {
        let text = String(decoding: body, as: UTF8.self)
        var outputs: [ScannedOutput] = []

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
            guard event == "txo", !data.isEmpty else { continue }

            guard let json = try? JSONDecoder().decode(JSONValue.self, from: Data(data.utf8)),
                  let outpoint = json["outpoint"]?.stringValue,
                  let (txid, vout) = splitOutpoint(outpoint) else {
                throw AssetScannerError.unreadableResponse
            }
            // An output already spent is not ours to sweep. The endpoint filters these by default,
            // but a stray one is skipped rather than swept.
            if let spend = json["spend"]?.stringValue, !spend.isEmpty { continue }

            let satoshis = json["satoshis"]?.intValue.flatMap { UInt64(exactly: $0) } ?? 0
            let events = json["events"]?.arrayValue?.compactMap(\.stringValue) ?? []

            outputs.append(
                ScannedOutput(
                    txid: txid, vout: vout, satoshis: satoshis,
                    lockingScript: lockingScript, events: events
                )
            )
        }
        return outputs
    }

    /// Splits `"txid.vout"` (the indexer's outpoint form). The separator may also be `_`.
    static func splitOutpoint(_ outpoint: String) -> (txid: String, vout: UInt32)? {
        for separator: Character in [".", "_"] {
            guard let index = outpoint.lastIndex(of: separator) else { continue }
            let txid = String(outpoint[..<index])
            guard let vout = UInt32(outpoint[outpoint.index(after: index)...]),
                  txid.count == 64 else { continue }
            return (txid, vout)
        }
        return nil
    }
}

public enum AssetScannerError: Error, Equatable, Sendable {
    case unreadableResponse
    case httpFailure(statusCode: Int)
}
