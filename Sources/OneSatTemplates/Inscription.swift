import BSVCore
import BSVCrypto
import BSVScript

/// A 1Sat ordinals inscription: `OP_0 OP_IF "ord" … OP_ENDIF`, optionally wrapped
/// by a prefix (usually P2PKH) and a suffix.
///
/// This is the `@1sat/templates` envelope. It is not the BRC-307 helper in
/// `swift-sdk`, which places the locking script *after* the envelope.
public struct Inscription: Equatable, Sendable {
    public let content: [UInt8]
    public let contentType: String
    public let contentHash: Hash256
    public let parent: [UInt8]?
    public let scriptPrefix: Script?
    public let scriptSuffix: Script?
    public let fields: [String: [UInt8]]

    public init(
        content: [UInt8],
        contentType: String,
        parent: [UInt8]? = nil,
        scriptPrefix: Script? = nil,
        scriptSuffix: Script? = nil,
        fields: [String: [UInt8]] = [:]
    ) throws {
        guard !contentType.isEmpty, contentType.utf8.count <= 255 else {
            throw InscriptionTemplateError.invalidContentType
        }
        if let parent, parent.count != 36 {
            throw InscriptionTemplateError.invalidParent
        }
        self.content = content
        self.contentType = contentType
        self.contentHash = BSVHashing.sha256(content)
        self.parent = parent
        self.scriptPrefix = scriptPrefix
        self.scriptSuffix = scriptSuffix
        self.fields = fields
    }

    public static func create(
        content: [UInt8],
        contentType: String,
        parent: [UInt8]? = nil,
        scriptPrefix: Script? = nil,
        scriptSuffix: Script? = nil
    ) throws -> Inscription {
        try Inscription(
            content: content,
            contentType: contentType,
            parent: parent,
            scriptPrefix: scriptPrefix,
            scriptSuffix: scriptSuffix
        )
    }

    public static func fromText(
        _ text: String,
        contentType: String = "text/plain;charset=utf-8",
        parent: [UInt8]? = nil,
        scriptPrefix: Script? = nil,
        scriptSuffix: Script? = nil
    ) throws -> Inscription {
        try create(
            content: Array(text.utf8),
            contentType: contentType,
            parent: parent,
            scriptPrefix: scriptPrefix,
            scriptSuffix: scriptSuffix
        )
    }

    /// Envelope first, then `scriptSuffix` (P2PKH ± MAP). Write-side twin of `decode`.
    /// Port of `@1sat/templates` `buildInscriptionScript`.
    public static func compose(
        content: [UInt8],
        contentType: String,
        scriptSuffix: Script
    ) throws -> Script {
        try create(
            content: content,
            contentType: contentType,
            scriptSuffix: scriptSuffix
        ).lock()
    }

    /// `[prefix] OP_0 OP_IF "ord" OP_1 <type> [OP_3 <parent>] OP_0 <content> OP_ENDIF [suffix]`
    public func lock() throws -> Script {
        var script = try scriptPrefix ?? TemplateScript.empty()
        try TemplateScript.append(.zero, to: &script)
        try TemplateScript.append(.if, to: &script)
        try TemplateScript.appendPush(Array("ord".utf8), to: &script)
        try TemplateScript.append(.one, to: &script)
        try TemplateScript.appendPush(Array(contentType.utf8), to: &script)
        if let parent {
            try TemplateScript.append(.three, to: &script)
            try TemplateScript.appendPush(parent, to: &script)
        }
        try TemplateScript.append(.zero, to: &script)
        try TemplateScript.appendPush(content, to: &script)
        try TemplateScript.append(.endIf, to: &script)
        if let scriptSuffix {
            return try TemplateScript.concatenating([script.bytes, scriptSuffix.bytes])
        }
        return script
    }

    public func verify() -> Bool {
        contentHash.bytes == BSVHashing.sha256(content).bytes
    }

    public func text() -> String? {
        guard contentType.hasPrefix("text/") || contentType == "application/json" else {
            return nil
        }
        return String(bytes: content, encoding: .utf8)
    }

    public static func isInscription(_ script: Script) -> Bool {
        decode(script) != nil
    }

    public static func decode(_ script: Script) -> Inscription? {
        guard let operations = try? TemplateScript.operations(script) else { return nil }

        var start = -1
        if operations.count >= 3 {
            for index in 0..<(operations.count - 2) {
                if operations[index] == .opcode(.zero),
                   operations[index + 1] == .opcode(.if),
                   operations[index + 2].pushedData == Array("ord".utf8) {
                    start = index
                    break
                }
            }
        }
        guard start >= 0 else { return nil }

        var prefix: Script?
        if start > 0 {
            guard let prefixBytes = try? encodedPrefix(operations[0..<start]) else { return nil }
            prefix = try? TemplateScript.script(bytes: prefixBytes)
        }

        var position = start + 3
        var contentType = ""
        var content: [UInt8] = []
        var parent: [UInt8]?
        var fields: [String: [UInt8]] = [:]

        while position < operations.count {
            if operations[position] == .opcode(.endIf) {
                position += 1
                break
            }

            let field = operations[position]
            position += 1
            guard position < operations.count else { break }

            let data = operations[position].pushedData ?? []
            position += 1

            if let fieldNumber = fieldNumber(field) {
                switch fieldNumber {
                case 0:
                    content = data
                case 1:
                    contentType = String(bytes: data, encoding: .utf8) ?? ""
                case 3:
                    if data.count == 36 {
                        parent = data
                    } else if data.count == 32 {
                        parent = data + [0, 0, 0, 0]
                    }
                default:
                    fields[String(fieldNumber)] = data
                }
            } else if let key = field.pushedData, key.count > 1 {
                fields[String(decoding: key, as: UTF8.self)] = data
            }
        }

        guard !content.isEmpty else { return nil }

        var suffix: Script?
        if position < operations.count {
            guard let suffixBytes = try? encodedPrefix(operations[position...]) else { return nil }
            suffix = try? TemplateScript.script(bytes: suffixBytes)
        }

        return try? Inscription(
            content: content,
            contentType: contentType,
            parent: parent,
            scriptPrefix: prefix,
            scriptSuffix: suffix,
            fields: fields
        )
    }

    private static func fieldNumber(_ operation: ScriptOperation) -> Int? {
        switch operation {
        case .opcode(let opcode):
            if opcode == .zero { return 0 }
            if opcode.rawValue >= Opcode.one.rawValue, opcode.rawValue <= Opcode.sixteen.rawValue {
                return Int(opcode.rawValue - Opcode.one.rawValue) + 1
            }
            return nil
        case .push(_, let data) where data.count == 1:
            return Int(data[0])
        default:
            return nil
        }
    }

    private static func encodedPrefix<C: Collection>(
        _ operations: C
    ) throws -> [UInt8] where C.Element == ScriptOperation {
        var bytes: [UInt8] = []
        for operation in operations {
            switch operation {
            case .opcode(let opcode):
                bytes.append(opcode.rawValue)
            case .push(_, let data):
                bytes.append(contentsOf: try Script.pushDataPrefix(forByteCount: data.count))
                bytes.append(contentsOf: data)
            }
        }
        return bytes
    }
}

public enum InscriptionTemplateError: Error, Equatable, Sendable {
    case invalidContentType
    case invalidParent
}
