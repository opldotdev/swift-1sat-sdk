import Foundation
import BSVCore
import BSVKeys
import BSVWallet
import OneSatCBOR
import ToolboxWallet

/// One authenticated binary POST to a message box server. Abstracted so tests can stand in for
/// the network; `MessageBoxHTTPRelay` is the real one.
public protocol MetanetTransport: Sendable {
    func post(host: URL, path: String, body: [UInt8]) async throws -> [UInt8]
}

/// Posts through a BRC-104 authenticated `MessageBoxClient` for each host, signing as `wallet`.
/// One client per host is kept, so the mutual-authentication handshake is not repeated.
public actor MessageBoxHTTPRelay: MetanetTransport {
    public let wallet: ProtoWallet
    private var clients: [String: MessageBoxClient] = [:]

    public init(wallet: ProtoWallet) { self.wallet = wallet }

    public func post(host: URL, path: String, body: [UInt8]) async throws -> [UInt8] {
        let key = host.absoluteString
        let client: MessageBoxClient
        if let cached = clients[key] {
            client = cached
        } else {
            client = try MessageBoxClient(host: host, wallet: wallet)
            clients[key] = client
        }
        do {
            return try await client.post(path, contentType: "application/cbor", body: body)
        } catch MessageBoxError.httpStatus(let status) {
            // The reference reports `<path without slash> <status>`.
            let name = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            throw MetanetError.relay("\(name) \(status)")
        }
    }
}

/// BRC-231 message relay over DAG-CBOR, as `actions/src/metanet/relay.ts`: `/sendMessage`,
/// `/listMessages` and `/acknowledgeMessage`, each body and reply one DAG-CBOR item.
public struct CborRelay: Sendable {
    public static let defaultHost = URL(string: "https://messagebox.1sat.app")!

    public struct Message: Equatable, Sendable {
        public let messageID: String
        public let body: [UInt8]
        public let sender: [UInt8]

        public init(messageID: String, body: [UInt8], sender: [UInt8]) {
            self.messageID = messageID
            self.body = body
            self.sender = sender
        }
    }

    public let transport: any MetanetTransport

    public init(transport: any MetanetTransport) { self.transport = transport }

    public func send(
        host: URL, recipient: [UInt8], messageBox: String, body: [UInt8]
    ) async throws -> (status: String, messageID: String) {
        let reply = try await call(host, "/sendMessage", .map(try DagCborMap([
            ("message", .map(try DagCborMap([
                ("recipient", .bytes(recipient)),
                ("messageBox", .text(messageBox)),
                ("body", .bytes(body)),
            ]))),
        ])))
        return (reply["status"]?.textValue ?? "", reply["messageId"]?.textValue ?? "")
    }

    public func list(host: URL, messageBox: String) async throws -> [Message] {
        let reply = try await call(host, "/listMessages", .map(try DagCborMap([
            ("messageBox", .text(messageBox)),
        ])))
        guard let rows = reply["messages"] else { return [] }
        guard let array = rows.arrayValue else {
            throw MetanetError.relay("listMessages returned malformed messages")
        }
        return try array.map { row in
            guard let message = row.mapValue,
                  let id = message["messageId"]?.textValue,
                  let body = message["body"]?.bytesValue,
                  let sender = message["sender"]?.bytesValue else {
                throw MetanetError.relay("listMessages returned a malformed message")
            }
            return Message(messageID: id, body: body, sender: sender)
        }
    }

    public func acknowledge(host: URL, messageIDs: [String]) async throws {
        _ = try await call(host, "/acknowledgeMessage", .map(try DagCborMap([
            ("messageIds", .array(messageIDs.map { .text($0) })),
        ])))
    }

    private func call(_ host: URL, _ path: String, _ request: DagCborValue) async throws -> DagCborMap {
        let bytes = try await transport.post(host: host, path: path, body: try DagCbor.encode(request))
        guard case .map(let reply) = try DagCbor.decode(bytes) else {
            throw MetanetError.relay("\(path.dropFirst()) returned a non-map reply")
        }
        return reply
    }
}
