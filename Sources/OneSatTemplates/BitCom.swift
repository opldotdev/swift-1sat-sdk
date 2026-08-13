import BSVCore
import BSVScript

/// One BitCom protocol section after `OP_RETURN`, split on 1-byte `0x7c` pushes.
public struct BitComProtocolEntry: Equatable, Sendable {
    public let `protocol`: String
    public let script: [UInt8]

    public init(protocol: String, script: [UInt8]) {
        self.protocol = `protocol`
        self.script = script
    }
}

/// Decoded BitCom layout from `bitcom.ts`.
public struct BitComDecoded: Equatable, Sendable {
    public let protocols: [BitComProtocolEntry]
    public let scriptPrefix: [UInt8]

    public init(protocols: [BitComProtocolEntry], scriptPrefix: [UInt8]) {
        self.protocols = protocols
        self.scriptPrefix = scriptPrefix
    }
}

/// BitCom encode and decode from `@1sat/templates` `bitcom/bitcom.ts`.
public enum BitCom {
    /// Finds the first raw `0x6a` byte, takes the prefix before it, and splits the rest on `|`.
    public static func decode(_ script: Script) -> BitComDecoded? {
        let bytes = script.bytes
        guard let returnOffset = bytes.firstIndex(of: Opcode.return.rawValue) else { return nil }
        let prefix = returnOffset == 0 ? [UInt8]() : Array(bytes[..<returnOffset])
        let remaining = Array(bytes[(returnOffset + 1)...])
        guard let remainingScript = try? TemplateScript.script(bytes: remaining),
              let operations = try? TemplateScript.operations(remainingScript)
        else { return nil }

        var protocols: [BitComProtocolEntry] = []
        var index = 0
        while index < operations.count {
            guard let protocolData = operations[index].pushedData,
                  let protocolName = String(bytes: protocolData, encoding: .utf8)
            else { break }
            index += 1

            guard var body = try? TemplateScript.empty() else { return nil }
            while index < operations.count {
                let operation = operations[index]
                if let data = operation.pushedData, data.count == 1, data[0] == 0x7c {
                    index += 1
                    break
                }
                switch operation {
                case .opcode(let opcode):
                    guard (try? TemplateScript.append(opcode, to: &body)) != nil else { return nil }
                case .push(_, let data):
                    guard (try? TemplateScript.appendPush(data, to: &body)) != nil else { return nil }
                }
                index += 1
            }
            protocols.append(BitComProtocolEntry(protocol: protocolName, script: body.bytes))
        }

        return BitComDecoded(protocols: protocols, scriptPrefix: prefix)
    }

    /// Mirrors `bitcom.ts` `lock`: prefix as a data push, then `OP_RETURN` and protocol sections.
    public static func lock(
        protocols: [BitComProtocolEntry],
        scriptPrefix: [UInt8] = []
    ) throws -> Script {
        var script = try TemplateScript.empty()
        if !scriptPrefix.isEmpty {
            try TemplateScript.appendPush(scriptPrefix, to: &script)
        }
        guard !protocols.isEmpty else { return script }
        try TemplateScript.append(.return, to: &script)
        for (offset, entry) in protocols.enumerated() {
            try TemplateScript.appendPush(Array(entry.protocol.utf8), to: &script)
            if !entry.script.isEmpty {
                let body = try TemplateScript.script(bytes: entry.script)
                for operation in try TemplateScript.operations(body) {
                    switch operation {
                    case .opcode(let opcode):
                        try TemplateScript.append(opcode, to: &script)
                    case .push(_, let data):
                        try TemplateScript.appendPush(data, to: &script)
                    }
                }
            }
            if offset < protocols.count - 1 {
                try TemplateScript.appendPush([0x7c], to: &script)
            }
        }
        return script
    }
}
