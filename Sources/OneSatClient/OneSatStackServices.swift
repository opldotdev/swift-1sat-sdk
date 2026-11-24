import Foundation
import ToolboxServices

/// `WalletServices` over 1sat-stack. `currentHeight` and `chainTipHeader` read
/// `GET {base}/1sat/chaintracks/tip`. A live body on 2026-08-13 carries `height`,
/// `hash`, and hex `merkleRoot`. `merklePath` reads `GET {base}/1sat/beef/{txid}/proof` and
/// `header(atHeight:)` reads `GET {base}/1sat/chaintracks/headers?height=N&count=1`, as
/// `@1sat/client` `OneSatServices` does. Every other method throws by name.
public struct OneSatStackServices: WalletServices {
    private let baseURL: URL
    private let http: any HTTPGet

    public init(
        baseURL: URL = URL(string: "https://api.1sat.app")!,
        http: any HTTPGet = URLSessionHTTPGet()
    ) {
        self.baseURL = baseURL
        self.http = http
    }

    public func currentHeight() async throws -> UInt32 {
        try await chainTipHeader().height
    }

    public func chainTipHeader() async throws -> ChainBlockHeader {
        let url = baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("chaintracks")
            .appendingPathComponent("tip")
        let (status, body) = try await http.get(url)
        let operation = "OneSatStackServices.chainTipHeader"
        let tip = try OneSatClientHTTP.decode(
            TipBody.self, (status, body), service: "the 1Sat chain tracker", operation: operation,
            method: "GET", url: url
        )
        guard let height = tip.height else {
            OneSatClientHTTP.unreadable(operation, method: "GET", url: url, body: body, why: "no height")
            throw OneSatClientError.unreadableResponse
        }
        let merkleRoot: [UInt8]
        do {
            merkleRoot = try Self.hexBytes(tip.merkleRoot)
        } catch {
            OneSatClientHTTP.unreadable(operation, method: "GET", url: url, body: body, why: "merkleRoot is not 32 bytes of hex")
            throw error
        }
        return ChainBlockHeader(
            height: height,
            hash: tip.hash,
            merkleRoot: merkleRoot
        )
    }

    public func rawTX(txid _: String) async throws -> [UInt8] {
        throw ServiceError.notImplemented("rawTX")
    }

    public func postBEEF(_: [UInt8], txids _: [String]) async throws -> [BroadcastOutcome] {
        throw ServiceError.notImplemented("postBEEF")
    }

    /// `BeefClient.getProof`: the BRC-74 merkle path of a mined transaction, as served. Nil when
    /// the indexer answers 404, which it does until the transaction is mined and indexed.
    public func merklePath(txid: String) async throws -> [UInt8]? {
        let url = Self.proofURL(txid: txid, baseURL: baseURL)
        let (status, body) = try await http.get(url)
        // Expected while the transaction waits for a block: not a failure to log.
        if status == 404 { return nil }
        try OneSatClientHTTP.check(
            (status, body), service: "the 1Sat indexer", operation: "OneSatStackServices.merklePath",
            method: "GET", url: url
        )
        return body
    }

    /// `OneSatServices.getHeaderForHeight` (`ChaintracksClient.getHeaderBytes(height, 1)`): the 80
    /// raw bytes of the block header at `height`, parsed as a `BlockHeader`. A body that is not
    /// one 80-byte header is logged and thrown as `unreadableResponse`.
    public func header(atHeight height: UInt32) async throws -> ChainBlockHeader {
        let operation = "OneSatStackServices.header(atHeight:)"
        guard let url = Self.headerURL(height: height, baseURL: baseURL) else {
            throw OneSatClientError.unreadableResponse
        }
        let (status, body) = try await http.get(url)
        try OneSatClientHTTP.check(
            (status, body), service: "the 1Sat chain tracker", operation: operation, method: "GET", url: url
        )
        do {
            return try ChainBlockHeader(height: height, serializedBytes: body)
        } catch {
            OneSatClientHTTP.unreadable(
                operation, method: "GET", url: url, body: body,
                why: "\(body.count) bytes, not one 80-byte block header"
            )
            throw OneSatClientError.unreadableResponse
        }
    }

    /// `GET {base}/1sat/beef/{txid}/proof`.
    public static func proofURL(txid: String, baseURL: URL) -> URL {
        baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("beef")
            .appendingPathComponent(txid)
            .appendingPathComponent("proof")
    }

    /// `GET {base}/1sat/chaintracks/headers?height=N&count=1`.
    public static func headerURL(height: UInt32, baseURL: URL) -> URL? {
        let path = baseURL
            .appendingPathComponent("1sat")
            .appendingPathComponent("chaintracks")
            .appendingPathComponent("headers")
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "height", value: String(height)),
            URLQueryItem(name: "count", value: "1"),
        ]
        return components?.url
    }

    public func header(forHash _: String) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header(forHash:)")
    }

    public func isValidRoot(_: [UInt8], atHeight _: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isValidRoot")
    }

    public func statusForTXIDs(_: [String]) async throws -> [TransactionStatusReport] {
        throw ServiceError.notImplemented("statusForTXIDs")
    }

    public func isUTXO(scriptHash _: String, txid _: String, vout _: UInt32) async throws -> Bool {
        throw ServiceError.notImplemented("isUTXO")
    }

    public func scriptHashHistory(_: String) async throws -> [ScriptHistoryEntry] {
        throw ServiceError.notImplemented("scriptHashHistory")
    }

    public func usdPerBSV() async throws -> Double {
        throw ServiceError.notImplemented("usdPerBSV")
    }

    /// Fields present on `GET /1sat/chaintracks/tip`. `height` is optional so a missing
    /// key becomes `unreadableResponse` instead of a silent zero.
    private struct TipBody: Decodable {
        let height: UInt32?
        let hash: String
        let merkleRoot: String
    }

    private static func hexBytes(_ hex: String) throws -> [UInt8] {
        let utf8 = Array(hex.utf8)
        guard utf8.count.isMultiple(of: 2), utf8.count == 64 else {
            throw OneSatClientError.unreadableResponse
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index]), let low = nibble(utf8[index + 1]) else {
                throw OneSatClientError.unreadableResponse
            }
            bytes.append((high << 4) | low)
            index += 2
        }
        return bytes
    }

    private static func nibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}
