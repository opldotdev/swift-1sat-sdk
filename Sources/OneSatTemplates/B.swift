import BSVScript

/// Decoded B protocol fields: `DATA MEDIA_TYPE ENCODING [FILENAME]`.
public struct BData: Equatable, Sendable {
    public let data: [UInt8]
    public let mediaType: String
    public let encoding: String
    public let filename: String?

    public init(data: [UInt8], mediaType: String, encoding: String, filename: String? = nil) {
        self.data = data
        self.mediaType = mediaType
        self.encoding = encoding
        self.filename = filename
    }
}

/// B (`B://`) binary data protocol from `@1sat/templates` `bitcom/b.ts`.
///
/// `lock` writes the bare BitCom fragment `OP_RETURN <prefix> <data> <mediaType> <encoding>
/// [<filename>]`; a standalone zero-satoshi output prepends `OP_FALSE` itself.
public enum BTemplate {
    /// The B protocol's BitCom address.
    public static let prefix = "19HxigV4QyBv3tHpQVcUEQyq1pzZVdoAut"

    /// Values written in the ENCODING field.
    public enum Encoding: String, Sendable {
        case utf8 = "utf-8"
        case binary = "binary"
        case base64 = "base64"
        case hex = "hex"
    }

    /// The B section body: `DATA MEDIA_TYPE ENCODING [FILENAME]`, without the protocol prefix.
    public static func body(
        _ data: [UInt8],
        mediaType: String,
        encoding: String,
        filename: String? = nil
    ) throws -> [UInt8] {
        var body = try TemplateScript.empty()
        try TemplateScript.appendPush(data, to: &body)
        try TemplateScript.appendPush(Array(mediaType.utf8), to: &body)
        try TemplateScript.appendPush(Array(encoding.utf8), to: &body)
        if let filename, !filename.isEmpty {
            try TemplateScript.appendPush(Array(filename.utf8), to: &body)
        }
        return body.bytes
    }

    /// `B.lock` for raw bytes: one BitCom section under ``prefix``.
    public static func lock(
        _ data: [UInt8],
        mediaType: String = "text/plain",
        encoding: Encoding = .utf8,
        filename: String? = nil
    ) throws -> Script {
        try BitCom.lock(protocols: [
            BitComProtocolEntry(
                protocol: prefix,
                script: try body(data, mediaType: mediaType, encoding: encoding.rawValue, filename: filename)
            ),
        ])
    }

    /// `B.decode`: the first B section of a BitCom script, or `nil`.
    public static func decode(_ script: Script) -> BData? {
        guard let bitcom = BitCom.decode(script),
              let section = bitcom.protocols.first(where: { $0.protocol == prefix }),
              let body = try? TemplateScript.script(bytes: section.script),
              let operations = try? TemplateScript.operations(body),
              operations.count >= 3
        else { return nil }

        let data: [UInt8]
        if let pushed = operations[0].pushedData {
            data = pushed
        } else if case .opcode(.zero) = operations[0] {
            data = []
        } else {
            return nil
        }
        guard let mediaType = operations[1].pushedData,
              let encoding = operations[2].pushedData
        else { return nil }
        let filename = operations.count >= 4
            ? operations[3].pushedData.map { String(decoding: $0, as: UTF8.self) }
            : nil
        return BData(
            data: data,
            mediaType: String(decoding: mediaType, as: UTF8.self),
            encoding: String(decoding: encoding, as: UTF8.self),
            filename: filename
        )
    }
}
