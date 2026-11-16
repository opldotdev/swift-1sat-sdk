import Foundation
import ToolboxAuth

/// Answers the two reads a storage write makes first, so a fake that scripts only the write
/// itself still sees a store that is the user's active storage.
///
/// `StorageClient` refuses a write (`createAction`, `processAction`, `abortAction`,
/// `internalizeAction`, `relinquishOutput`, the action-batch calls, ...) unless
/// `findOrInsertUser` names this store, by its `makeAvailable` identity key, as the user's
/// `activeStorage`, as TS `WalletStorageManager.runAsAuthorizedWriter` does. A fake calls
/// `reply(to:)` before its own script and returns the answer when there is one; the write's own
/// request then reaches the script as before. Mirrors swift-wallet-toolbox's
/// `Tests/ToolboxStorageClientTests/ActiveStorageFixture.swift`.
enum ActiveStorageFixture {
    static let storageIdentityKey = "02bb"

    static func reply(to body: [UInt8]?) -> AuthenticatedResponse? {
        guard let body,
              let request = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any],
              let id = request["id"] as? Int else { return nil }
        let result: [String: Any]
        switch request["method"] as? String {
        case "makeAvailable":
            result = ["storageIdentityKey": storageIdentityKey, "storageName": "test storage", "chain": "main"]
        case "findOrInsertUser":
            let identityKey = (request["params"] as? [Any])?.first as? String ?? ""
            result = [
                "user": ["userId": 7, "identityKey": identityKey, "activeStorage": storageIdentityKey],
                "isNew": false,
            ]
        default:
            return nil
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return AuthenticatedResponse(statusCode: 200, headers: [:], body: Array(data))
    }
}
