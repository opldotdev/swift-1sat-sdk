import BSVCore
import BSVScript

/// Shared construction limits and helpers for 1Sat script templates.
enum TemplateScript {
    /// Ceiling used when assembling or parsing a template script.
    /// Matches 1sat-stack `maxScriptSizePolicy` so a 100_000-byte inscription plus envelope fits.
    static let maximumByteCount = 1_100_000

    static func empty() throws -> Script {
        try Script(bytes: [], maximumByteCount: maximumByteCount)
    }

    static func script(bytes: [UInt8]) throws -> Script {
        try Script(bytes: bytes, maximumByteCount: maximumByteCount)
    }

    static func script(hex: String) throws -> Script {
        try Script(hex: hex, maximumByteCount: maximumByteCount)
    }

    static func concatenating(_ parts: [[UInt8]]) throws -> Script {
        try script(bytes: parts.flatMap { $0 })
    }

    static func append(_ opcode: Opcode, to script: inout Script) throws {
        try script.append(opcode, maximumScriptByteCount: maximumByteCount)
    }

    static func appendPush(_ data: [UInt8], to script: inout Script) throws {
        try script.appendPushData(data, maximumScriptByteCount: maximumByteCount)
    }

    /// Pushes a Script number the way `@bsv/sdk` `writeNumber` does: a data push of
    /// the canonical little-endian signed-magnitude encoding.
    static func appendNumber(_ value: Int64, to script: inout Script) throws {
        let encoded = try ScriptNumber(value).serialized(maximumByteCount: 8)
        try appendPush(encoded, to: &script)
    }

    static func operations(_ script: Script) throws -> [ScriptOperation] {
        try script.operations(maximumPushDataByteCount: maximumByteCount)
    }

    static func indexOf(_ haystack: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        guard from <= last else { return nil }
        for index in from...last {
            if haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
        }
        return nil
    }

    static func encodedSize(_ operation: ScriptOperation) throws -> Int {
        switch operation {
        case .opcode:
            return 1
        case .push(_, let data):
            return try Script.pushDataPrefix(forByteCount: data.count).count + data.count
        }
    }
}
