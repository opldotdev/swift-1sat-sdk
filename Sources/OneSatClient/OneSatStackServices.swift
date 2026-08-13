import Foundation
import ToolboxServices

/// `WalletServices` over 1sat-stack. `currentHeight` and `chainTipHeader` read
/// `GET {base}/1sat/chaintracks/tip`. A live body on 2026-08-13 carries `height`,
/// `hash`, and hex `merkleRoot`. Every other method throws by name.
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
        guard (200..<300).contains(status) else {
            throw OneSatClientError.httpFailure(statusCode: status)
        }
        guard let tip = try? JSONDecoder().decode(TipBody.self, from: Data(body)),
              let height = tip.height
        else {
            throw OneSatClientError.unreadableResponse
        }
        return ChainBlockHeader(
            height: height,
            hash: tip.hash,
            merkleRoot: try Self.hexBytes(tip.merkleRoot)
        )
    }

    public func rawTX(txid _: String) async throws -> [UInt8] {
        throw ServiceError.notImplemented("rawTX")
    }

    public func postBEEF(_: [UInt8], txids _: [String]) async throws -> [BroadcastOutcome] {
        throw ServiceError.notImplemented("postBEEF")
    }

    public func merklePath(txid _: String) async throws -> [UInt8]? {
        throw ServiceError.notImplemented("merklePath")
    }

    public func header(atHeight _: UInt32) async throws -> ChainBlockHeader {
        throw ServiceError.notImplemented("header(atHeight:)")
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
