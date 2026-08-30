import BSVScript

/// MAP (Magic Attribute Protocol) from `@1sat/templates` `bitcom/map.ts`.
public enum MAPCommand: String, Equatable, Sendable {
    case set = "SET"
    case remove = "REMOVE"
    case add = "ADD"
    case delete = "DELETE"
    case select = "SELECT"
    case clear = "CLEAR"
}

public struct MAPData: Sendable {
    public let command: String
    public let data: [(String, String)]
    public let adds: [String]
    public let deletes: [String]

    public init(
        command: String,
        data: [(String, String)] = [],
        adds: [String] = [],
        deletes: [String] = []
    ) {
        self.command = command
        self.data = data
        self.adds = adds
        self.deletes = deletes
    }
}

public enum MAPTemplate {
    public static let prefix = "1PuQa7K62MiKCtssSLKy1kh56WWU7MtUR5"

    public static func set(_ fields: [(String, String)]) throws -> Script {
        try lock(.set, fields)
    }

    public static func add(key: String, values: [String]) throws -> Script {
        try lockPushes([MAPCommand.add.rawValue, key] + values)
    }

    public static func remove(keys: [String]) throws -> Script {
        try lockPushes([MAPCommand.remove.rawValue] + keys)
    }

    public static func delete(key: String, values: [String]) throws -> Script {
        try lockPushes([MAPCommand.delete.rawValue, key] + values)
    }

    public static func app(
        _ appName: String,
        type: String,
        additional: [(String, String)] = []
    ) throws -> Script {
        try set([("app", appName), ("type", type)] + additional)
    }

    public static func decode(_ script: Script) -> MAPData? {
        guard let bitcom = BitCom.decode(script),
              let map = bitcom.protocols.first(where: { $0.protocol == prefix })
        else { return nil }
        guard let body = try? TemplateScript.script(bytes: map.script),
              let operations = try? TemplateScript.operations(body),
              let first = operations.first?.pushedData,
              let command = String(bytes: first, encoding: .utf8)
        else { return nil }

        let pushes = operations.compactMap { operation -> String? in
            guard let data = operation.pushedData else { return nil }
            return clean(String(bytes: data, encoding: .utf8) ?? "")
        }
        guard !pushes.isEmpty else { return nil }

        if command == MAPCommand.set.rawValue {
            var data: [(String, String)] = []
            var index = 1
            while index + 1 < pushes.count {
                data.append((pushes[index], pushes[index + 1]))
                index += 2
            }
            return MAPData(command: command, data: data)
        }
        if command == MAPCommand.add.rawValue, pushes.count >= 2 {
            let values = Array(pushes.dropFirst(2))
            return MAPData(
                command: command,
                data: [(pushes[1], values.joined(separator: " "))],
                adds: values
            )
        }
        if command == MAPCommand.remove.rawValue {
            var data: [(String, String)] = []
            for key in pushes.dropFirst() {
                data.append((key, ""))
            }
            return MAPData(command: command, data: data)
        }
        if command == MAPCommand.delete.rawValue, pushes.count >= 2 {
            let values = Array(pushes.dropFirst(2))
            return MAPData(
                command: command,
                data: [(pushes[1], values.joined(separator: " "))],
                deletes: values
            )
        }
        return MAPData(command: command)
    }

    private static func lock(_ command: MAPCommand, _ fields: [(String, String)]) throws -> Script {
        var body = try TemplateScript.empty()
        try TemplateScript.appendPush(Array(command.rawValue.utf8), to: &body)
        for (key, value) in fields {
            try TemplateScript.appendPush(Array(clean(key).utf8), to: &body)
            try TemplateScript.appendPush(Array(clean(value).utf8), to: &body)
        }
        return try BitCom.lock(
            protocols: [BitComProtocolEntry(protocol: prefix, script: body.bytes)]
        )
    }

    private static func lockPushes(_ pushes: [String]) throws -> Script {
        var body = try TemplateScript.empty()
        for push in pushes {
            try TemplateScript.appendPush(Array(clean(push).utf8), to: &body)
        }
        return try BitCom.lock(
            protocols: [BitComProtocolEntry(protocol: prefix, script: body.bytes)]
        )
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\0", with: " ")
            .replacingOccurrences(of: "\\u0000", with: " ")
    }
}
