import BSVKeys
import BSVScript

enum ActionScript {
    static let maximumByteCount = 100_000

    static func payToPublicKeyHash(_ address: Address) throws -> Script {
        try Script.payToPublicKeyHash(address, maximumByteCount: maximumByteCount)
    }

    static func payToPublicKeyHash(_ address: String) throws -> Script {
        try payToPublicKeyHash(try Address(address))
    }

    static func appending(_ extra: Script, to base: Script) throws -> Script {
        try Script(bytes: base.bytes + extra.bytes, maximumByteCount: maximumByteCount)
    }
}
