import Foundation
import ToolboxAuth

/// Answers the two reads `StorageClient` makes before its first write, so a scripted transport
/// that knows only the calls under test still sees a store that is the user's active storage.
///
/// `StorageClient` refuses a write unless `findOrInsertUser` names this store, by its
/// `makeAvailable` identity key, as the user's `activeStorage` (swift-wallet-toolbox #48, as
/// `WalletStorageManager.runAsAuthorizedWriter` does in TS). A transport calls `reply(to:)` first
/// and returns the answer when there is one.
enum ActiveStorageReply {
    static let storageIdentityKey = "02bb"

    static func reply(to body: [UInt8]?) -> AuthenticatedResponse? {
        guard let body,
              let request = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let id = request["id"] as? Int else { return nil }
        let result: String
        switch request["method"] as? String {
        case "makeAvailable":
            result = #"{"storageIdentityKey":"\#(storageIdentityKey)","storageName":"test storage","chain":"main"}"#
        case "findOrInsertUser":
            let identityKey = (request["params"] as? [Any])?.first as? String ?? ""
            result = #"{"user":{"userId":7,"identityKey":"\#(identityKey)","activeStorage":"\#(storageIdentityKey)"},"isNew":false}"#
        default:
            return nil
        }
        return AuthenticatedResponse(
            statusCode: 200, headers: [:],
            body: Array(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8)
        )
    }
}
