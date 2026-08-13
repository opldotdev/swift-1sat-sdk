import BSVScript

/// BAP attestation types from `bitcom/bap.ts`.
public enum BAPAttestationType: String, Equatable, Sendable {
    case id = "ID"
    case attest = "ATTEST"
    case revoke = "REVOKE"
    case alias = "ALIAS"
}

/// Decoded BAP fields. `profileJSON` is the raw UTF-8 ALIAS chunk, not parsed JSON.
public struct BAPData: Equatable, Sendable {
    public let type: BAPAttestationType
    public let idKey: String?
    public let address: String?
    public let sequence: UInt64
    public let algorithm: String?
    public let signerAddr: String?
    public let signature: String?
    public let profileJSON: String?

    public init(
        type: BAPAttestationType,
        idKey: String? = nil,
        address: String? = nil,
        sequence: UInt64 = 0,
        algorithm: String? = nil,
        signerAddr: String? = nil,
        signature: String? = nil,
        profileJSON: String? = nil
    ) {
        self.type = type
        self.idKey = idKey
        self.address = address
        self.sequence = sequence
        self.algorithm = algorithm
        self.signerAddr = signerAddr
        self.signature = signature
        self.profileJSON = profileJSON
    }
}

/// BAP decode from `@1sat/templates` `bitcom/bap.ts`. Write path is `Identity.publish`.
public enum BAPTemplate {
    /// `BAP_PROTOCOL_PREFIX` in `bitcom/bap.ts`.
    public static let protocolPrefix = "1BAPSuaPnfGnSBM3GLV9yhxUdYe4vGbdMT"

    public static func decode(_ bitcom: BitComDecoded) -> BAPData? {
        guard let entry = bitcom.protocols.first(where: {
            $0.protocol == protocolPrefix
        }) else { return nil }
        guard let script = try? TemplateScript.script(bytes: entry.script),
              let operations = try? TemplateScript.operations(script),
              let typeData = operations.first?.pushedData,
              let typeText = String(bytes: typeData, encoding: .utf8),
              let type = BAPAttestationType(rawValue: typeText)
        else { return nil }

        var idKey: String?
        var address: String?
        var sequence: UInt64 = 0
        var profileJSON: String?

        switch type {
        case .id:
            idKey = utf8(operations, at: 1)
            address = utf8(operations, at: 2)
        case .attest, .revoke:
            idKey = utf8(operations, at: 1)
            guard let sequenceText = utf8(operations, at: 2),
                  let parsed = UInt64(sequenceText)
            else { return nil }
            sequence = parsed
        case .alias:
            idKey = utf8(operations, at: 1)
            profileJSON = utf8(operations, at: 2)
        }

        return BAPData(
            type: type,
            idKey: idKey,
            address: address,
            sequence: sequence,
            algorithm: utf8(operations, at: 3),
            signerAddr: utf8(operations, at: 4),
            signature: utf8(operations, at: 5),
            profileJSON: profileJSON
        )
    }

    private static func utf8(_ operations: [ScriptOperation], at index: Int) -> String? {
        guard operations.indices.contains(index),
              let data = operations[index].pushedData
        else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
