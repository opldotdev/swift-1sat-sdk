import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BSVCore
import BSVScript
import BSVTransaction
import BSVWallet
import ToolboxActions

/// One BRC-24 `output-list` answer: each item a BEEF and the index of the listed output in its
/// subject transaction.
public struct ColorOutputList: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let beef: [UInt8]
        public let outputIndex: UInt32
        public init(beef: [UInt8], outputIndex: UInt32) {
            self.beef = beef
            self.outputIndex = outputIndex
        }
    }

    public let outputs: [Item]
    public init(outputs: [Item]) { self.outputs = outputs }
}

/// A BRC-22 overlay's answer for one topic of a submission (one STEAK entry).
public struct ColorAdmittance: Equatable, Sendable {
    public let outputsToAdmit: [UInt32]
    public let coinsToRetain: [UInt32]
    public init(outputsToAdmit: [UInt32], coinsToRetain: [UInt32] = []) {
        self.outputsToAdmit = outputsToAdmit
        self.coinsToRetain = coinsToRetain
    }
}

/// The overlay a BRC-207 wallet asks whether a token output is admitted and unspent, and submits
/// token transactions to. The module's `ColorOverlayProvider`.
///
/// - `spendability`: the queried outpoints the asset's overlay reports admitted and unspent.
/// - `admission`: the queried outpoints the overlay ever admitted (used for the deploy).
/// - `submit`: BRC-22 submit of BEEF to topics; returns the STEAK.
///
/// The lookup service behind the first two is the host's: no TypeScript source fixes its name or
/// query shape, so it is injected rather than assumed.
public protocol ColorOverlayProvider: Sendable {
    func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList
    func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList
    func submit(topics: [String], beef: [UInt8]) async throws -> [String: ColorAdmittance]
}

/// A listed output, matched to its queried outpoint.
public struct ColorListedOutput: Sendable {
    public let outpoint: String
    public let lockingScript: Script
    public let satoshis: UInt64
    public let transaction: Transaction
}

public enum ColorOverlay {
    static let beefLimits = WalletBEEFLimits.standard

    /// `readOutputList`: every listed output must be one of the queried outpoints, at most once;
    /// an unrelated, duplicate or malformed entry invalidates the whole answer.
    public static func readOutputList(_ answer: ColorOutputList, queried: [String]) throws -> [String: ColorListedOutput] {
        let wanted = Set(queried)
        var listed: [String: ColorListedOutput] = [:]
        for item in answer.outputs {
            let transaction: Transaction
            let txid: String
            do {
                let beef = try BEEF(bytes: item.beef, limits: beefLimits)
                transaction = try ColorBEEF.subject(of: beef)
                txid = try transaction.transactionID(limits: beefLimits.transactionLimits).displayHex
            } catch {
                throw ColorError.overlay("overlay answer carries invalid BEEF")
            }
            guard let index = Int(exactly: item.outputIndex), transaction.outputs.indices.contains(index) else {
                throw ColorError.overlay("overlay answer names a missing output")
            }
            let outpoint = "\(txid).\(item.outputIndex)"
            guard wanted.contains(outpoint) else { throw ColorError.overlay("overlay answered an unrelated output \(outpoint)") }
            guard listed[outpoint] == nil else { throw ColorError.overlay("overlay answered \(outpoint) twice") }
            let output = transaction.outputs[index]
            listed[outpoint] = ColorListedOutput(
                outpoint: outpoint, lockingScript: output.lockingScript, satoshis: output.satoshis,
                transaction: transaction
            )
        }
        return listed
    }
}

/// BRC-22 submission over HTTP, as `OverlayClient.submitBrc22`: `POST <base>/submit` with the
/// BEEF as `application/octet-stream` and `X-Topics: a,b`. Lookups are delegated to `lookup`.
public struct HTTPColorOverlay: ColorOverlayProvider {
    public typealias Post = @Sendable (URLRequest) async throws -> (status: Int, body: [UInt8])
    public typealias Lookup = @Sendable (_ kind: LookupKind, _ assetID: ColorAssetID, _ outpoints: [String]) async throws -> ColorOutputList

    public enum LookupKind: String, Sendable { case spendability, admission }

    public let baseURL: URL
    public let lookup: Lookup
    public let post: Post

    public init(baseURL: URL, lookup: @escaping Lookup, post: @escaping Post = HTTPColorOverlay.urlSessionPost) {
        self.baseURL = baseURL
        self.lookup = lookup
        self.post = post
    }

    public static let urlSessionPost: Post = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, Array(data))
    }

    public func spendability(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await lookup(.spendability, assetID, outpoints)
    }

    public func admission(assetID: ColorAssetID, outpoints: [String]) async throws -> ColorOutputList {
        try await lookup(.admission, assetID, outpoints)
    }

    public func submit(topics: [String], beef: [UInt8]) async throws -> [String: ColorAdmittance] {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/submit") else { throw ColorError.overlay("invalid overlay URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(topics.joined(separator: ","), forHTTPHeaderField: "X-Topics")
        request.httpBody = Data(beef)
        let (status, body) = try await post(request)
        guard (200..<300).contains(status) else { throw ColorError.overlay("overlay submit failed: \(status)") }
        return try Self.readSteak(body)
    }

    /// A STEAK: `{ <topic>: { outputsToAdmit: [n], coinsToRetain: [n], … } }`.
    public static func readSteak(_ body: [UInt8]) throws -> [String: ColorAdmittance] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else {
            throw ColorError.overlay("overlay submit returned no STEAK")
        }
        var steak: [String: ColorAdmittance] = [:]
        for (topic, value) in object {
            guard let entry = value as? [String: Any] else { continue }
            func indexes(_ key: String) -> [UInt32] {
                ((entry[key] as? [Any]) ?? []).compactMap { ($0 as? NSNumber).flatMap { UInt32(exactly: $0.doubleValue) } }
            }
            steak[topic] = ColorAdmittance(outputsToAdmit: indexes("outputsToAdmit"), coinsToRetain: indexes("coinsToRetain"))
        }
        return steak
    }
}
